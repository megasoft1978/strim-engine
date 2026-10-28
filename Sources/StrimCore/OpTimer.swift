import Foundation
import MLX

/// Per-region GPU timing for prefill, gated by `STRIM_OPTIME`.
///
/// Off (default): `time`/`timeMany`/`linear` are one branch on a `static let` and then the plain
/// body; the flops/bytes/inputs autoclosures are never evaluated, nothing is allocated.
/// On: each region does `eval(inputs)`, starts a clock, runs the body, `eval(outputs)`, stops the
/// clock and accumulates by (context, region). Every region is a CPU/GPU fence, so on-mode wall
/// time is longer than the uninstrumented run; `calibrate()` measures the fence cost and the
/// report subtracts it per call. Region names use the layer-type prefix (`gdn.`, `attn.`,
/// `mlp.`, `norm`, `resid`, `embed`, `lm_head`); `ctx` separates the MTP head from the target.
public enum OpTimer {
    public static let on: Bool = parseFlag(ProcessInfo.processInfo.environment["STRIM_OPTIME"])

    static func parseFlag(_ v: String?) -> Bool {
        guard let v, !v.isEmpty else { return false }
        return v != "0" && v.lowercased() != "off" && v.lowercased() != "false"
    }

    /// Peak figures the report compares against (README of docs/PLAN-SPEED-WAVE2).
    public static let peakTFlops = 62.7
    public static let peakGBs = 530.0

    public struct Row {
        public let ctx: String
        public let name: String
        public let calls: Int
        public let rawMs: Double
        public let netMs: Double
        public let flops: Double
        public let bytes: Double
        public var tflops: Double { netMs > 0 ? flops / (netMs * 1e-3) / 1e12 : 0 }
        public var gbs: Double { netMs > 0 ? bytes / (netMs * 1e-3) / 1e9 : 0 }
    }

    struct Key: Hashable { let ctx: String; let name: String }
    struct Rec { var ns: UInt64 = 0; var calls = 0; var flops = 0.0; var bytes = 0.0 }

    nonisolated(unsafe) static var table: [Key: Rec] = [:]
    nonisolated(unsafe) static var order: [Key] = []
    /// Context label for new records ("main" or "mtp").
    nonisolated(unsafe) public static var ctx = "main"
    /// Median fence cost in nanoseconds (one tiny op: commit + wait).
    nonisolated(unsafe) public static var fenceNs: Double = 0

    /// When set, only regions whose name is in the set fence and record; the rest run unfenced.
    /// Used by the overhead sweep: fencing one region name at a time and differencing the wall
    /// against an unfenced run gives that region's true fence cost (STRIM_OPTIME_ONLY, benchprefill).
    nonisolated(unsafe) public static var only: Set<String>? = nil

    @inline(__always)
    static func active(_ name: String) -> Bool { only?.contains(name) ?? true }

    // MARK: marking

    @inline(__always)
    public static func time(_ name: String, flops: @autoclosure () -> Double = 0,
                            bytes: @autoclosure () -> Double = 0,
                            inputs: @autoclosure () -> [MLXArray] = [],
                            _ body: () throws -> MLXArray) rethrows -> MLXArray {
        if !on || !active(name) { return try body() }
        return try timedSlow(name, flops(), bytes(), inputs()) { try [body()] }[0]
    }

    @inline(__always)
    public static func timeMany(_ name: String, flops: @autoclosure () -> Double = 0,
                                bytes: @autoclosure () -> Double = 0,
                                inputs: @autoclosure () -> [MLXArray] = [],
                                _ body: () throws -> [MLXArray]) rethrows -> [MLXArray] {
        if !on || !active(name) { return try body() }
        return try timedSlow(name, flops(), bytes(), inputs(), body)
    }

    /// `store.linear` with flops (2*M*N*K) and bytes (weights + activations) filled in.
    @inline(__always)
    public static func linear(_ store: WeightStore, _ region: String, _ prefix: String,
                              _ x: MLXArray) throws -> MLXArray {
        if !on || !active(region) { return try store.linear(prefix, x) }
        let w = try store.tensor(prefix + ".weight")
        let wb = weightBytes(store, prefix)
        let (f, b) = linearCost(x, n: w.shape[0], weightBytes: wb, w: w, store: store, prefix: prefix)
        return try timedSlow(region, f, b, [x]) { [try store.linear(prefix, x)] }[0]
    }

    /// `store.qmm` on explicit (e.g. fused) quantized tensors.
    @inline(__always)
    public static func qmm(_ store: WeightStore, _ region: String, _ x: MLXArray,
                           _ w: MLXArray, _ s: MLXArray, _ b: MLXArray, spec: QuantSpec) -> MLXArray {
        if !on || !active(region) { return store.qmm(x, w, s, b, spec: spec) }
        let (f, by) = quantCost(x, w, s, b, groupSize: spec.groupSize)
        return timedSlow(region, f, by, [x]) { [store.qmm(x, w, s, b, spec: spec)] }[0]
    }

    static func weightBytes(_ store: WeightStore, _ prefix: String) -> Int {
        var t = 0
        for suffix in [".weight", ".scales", ".biases"] {
            if let a = try? store.tensor(prefix + suffix) { t += a.nbytes }
        }
        return t
    }

    static func linearCost(_ x: MLXArray, n: Int, weightBytes: Int, w: MLXArray,
                           store: WeightStore, prefix: String) -> (Double, Double) {
        let kk: Int
        if let s = try? store.tensor(prefix + ".scales") {
            kk = s.shape[s.ndim - 1] * ((try? store.quantSpec(prefix, w: w, s: s))?.groupSize ?? 64)
        } else {
            kk = w.shape[w.ndim - 1]
        }
        let m = x.size / max(x.shape.last ?? 1, 1)
        let f = 2.0 * Double(m) * Double(n) * Double(kk)
        let b = Double(weightBytes) + Double(x.nbytes) + Double(m * n * x.itemSize)
        return (f, b)
    }

    static func quantCost(_ x: MLXArray, _ w: MLXArray, _ s: MLXArray, _ b: MLXArray,
                          groupSize: Int = 64) -> (Double, Double) {
        let k = s.shape[s.ndim - 1] * groupSize
        let n = w.shape[0]
        let m = x.size / max(x.shape.last ?? 1, 1)
        return (2.0 * Double(m) * Double(n) * Double(k),
                Double(w.nbytes + s.nbytes + b.nbytes + x.nbytes + m * n * x.itemSize))
    }

    static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Core of every region; also called directly by the tests.
    static func timedSlow(_ name: String, _ flops: Double, _ bytes: Double, _ inputs: [MLXArray],
                          _ body: () throws -> [MLXArray]) rethrows -> [MLXArray] {
        if !inputs.isEmpty { eval(inputs) }
        let t0 = nowNs()
        let out = try body()
        eval(out)
        let dt = nowNs() &- t0
        record(name, ns: dt, flops: flops, bytes: bytes)
        return out
    }

    static func record(_ name: String, ns: UInt64, flops: Double, bytes: Double, ctx: String? = nil) {
        let k = Key(ctx: ctx ?? Self.ctx, name: name)
        if table[k] == nil { order.append(k); table[k] = Rec() }
        table[k]!.ns &+= ns
        table[k]!.calls += 1
        table[k]!.flops += flops
        table[k]!.bytes += bytes
    }

    /// Sum of raw region nanoseconds recorded so far under `ctx`.
    public static func rawNs(ctx: String) -> UInt64 {
        table.reduce(0) { $0 &+ ($1.key.ctx == ctx ? $1.value.ns : 0) }
    }

    /// Record a span measured outside the region helpers (e.g. a whole MTP step minus its inner regions).
    public static func recordRegion(_ name: String, ns: UInt64, ctx: String, flops: Double = 0, bytes: Double = 0) {
        record(name, ns: ns, flops: flops, bytes: bytes, ctx: ctx)
    }

    public static func nowNanos() -> UInt64 { nowNs() }

    public static func reset() {
        table = [:]
        order = []
    }

    // MARK: calibration and report

    /// Median round trip of a region around a trivial op (commit + wait + closure overhead).
    @discardableResult
    public static func calibrate(iterations: Int = 300) -> Double {
        let x = MLXArray.ones([64])
        eval(x)
        var samples: [UInt64] = []
        samples.reserveCapacity(iterations)
        for _ in 0 ..< iterations {
            let t0 = nowNs()
            let y = x + 1
            eval(y)
            samples.append(nowNs() &- t0)
        }
        samples.sort()
        fenceNs = Double(samples[samples.count / 2])
        return fenceNs
    }

    public static func rows() -> [Row] {
        order.map { k in
            let r = table[k]!
            let raw = Double(r.ns) / 1e6
            let net = max(raw - Double(r.calls) * fenceNs / 1e6, 0)
            return Row(ctx: k.ctx, name: k.name, calls: r.calls, rawMs: raw, netMs: net,
                       flops: r.flops, bytes: r.bytes)
        }
    }

    /// Markdown tables. `wallSeconds` is the instrumented wall for the same span, `plainSeconds`
    /// (optional) the uninstrumented wall; `tokens` is the number of prompt tokens in the span.
    public static func report(wallSeconds: Double, tokens: Int, plainSeconds: Double? = nil) -> String {
        let rs = rows()
        let rawSum = rs.reduce(0) { $0 + $1.rawMs }
        let netSum = rs.reduce(0) { $0 + $1.netMs }
        let calls = rs.reduce(0) { $0 + $1.calls }
        let flopSum = rs.reduce(0) { $0 + $1.flops }
        let byteSum = rs.reduce(0) { $0 + $1.bytes }
        var o = ""
        func f(_ v: Double, _ p: Int = 2) -> String { String(format: "%.\(p)f", v) }
        o += "| ctx | region | calls | raw ms | net ms | share % | GFLOP | GB | TF/s | %62.7 | GB/s | %530 |\n"
        o += "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n"
        for r in rs {
            o += "| \(r.ctx) | \(r.name) | \(r.calls) | \(f(r.rawMs, 1)) | \(f(r.netMs, 1)) | "
            o += "\(f(netSum > 0 ? r.netMs / netSum * 100 : 0, 1)) | \(f(r.flops / 1e9, 1)) | \(f(r.bytes / 1e9, 2)) | "
            o += "\(r.flops > 0 ? f(r.tflops, 1) : "-") | \(r.flops > 0 ? f(r.tflops / peakTFlops * 100, 0) : "-") | "
            o += "\(f(r.gbs, 0)) | \(f(r.gbs / peakGBs * 100, 0)) |\n"
        }
        // Roll-up by (ctx, prefix before the first dot).
        var groups: [String: (ms: Double, fl: Double, by: Double)] = [:]
        var gorder: [String] = []
        for r in rs {
            let p = r.name.split(separator: ".").first.map(String.init) ?? r.name
            let key = "\(r.ctx)/\(p)"
            if groups[key] == nil { groups[key] = (0, 0, 0); gorder.append(key) }
            groups[key]!.ms += r.netMs; groups[key]!.fl += r.flops; groups[key]!.by += r.bytes
        }
        o += "\n| group | net ms | share % | TF/s | GB/s |\n|---|---:|---:|---:|---:|\n"
        for k in gorder {
            let g = groups[k]!
            let s = g.ms * 1e-3
            o += "| \(k) | \(f(g.ms, 1)) | \(f(netSum > 0 ? g.ms / netSum * 100 : 0, 1)) | "
            o += "\(g.fl > 0 ? f(g.fl / s / 1e12, 1) : "-") | \(f(g.by / s / 1e9, 0)) |\n"
        }
        let fenceMs = Double(calls) * fenceNs / 1e6
        o += "\nfence per region: \(f(fenceNs / 1e3, 0)) us x \(calls) regions = \(f(fenceMs, 1)) ms\n"
        o += "sum raw \(f(rawSum, 1)) ms; sum net (raw - fences) \(f(netSum, 1)) ms; instrumented wall \(f(wallSeconds * 1e3, 1)) ms "
        o += "(unaccounted in-wall \(f((wallSeconds * 1e3 - rawSum) / (wallSeconds * 1e3) * 100, 1))%)\n"
        if let p = plainSeconds {
            o += "uninstrumented wall \(f(p * 1e3, 1)) ms; net sum vs plain wall: \(f((netSum - p * 1e3) / (p * 1e3) * 100, 1))%\n"
        }
        o += "counted work: \(f(flopSum / 1e9, 1)) GFLOP = \(f(tokens > 0 ? flopSum / 1e9 / Double(tokens) : 0, 2)) GFLOP/token; "
        o += "\(f(byteSum / 1e9, 1)) GB\n"
        return o
    }
}
