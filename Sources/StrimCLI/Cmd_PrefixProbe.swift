import Foundation
import MLX
import MLXFast
import StrimCore

// Usage: strim probesplit <model dir> [N=4096] [layers=64] [tensor]
//   tensor: run the layer-level pass with GDN.metalOverride = false (deterministic tensor recurrence).
// Is a prefill split at chunk boundaries bitwise identical to a one-shot prefill?
// Kernel level: qmm row invariance, GDN blocked chain (+ short tail), SDPA with cache offset.
// Layer level: one-shot vs split runs in lockstep, layer-major (each layer runs over every
// chunk before the next). Same arithmetic as token-chunk-major order, because a layer's
// state (GDN ssm/conv, attention KV) is private to that layer.

private let hiddenSize = 5120
private let fullLayerCount = 64

private struct Row {
    let component: String
    let eq: Bool
    let diff: Double
}

private final class SplitRun {
    let name: String
    let ranges: [Range<Int>]
    let cache = ModelCache()
    var x: MLXArray
    var mixerEq: [Bool] = [], mixerDiff: [Double] = []
    var mlpEq: [Bool] = [], mlpDiff: [Double] = []
    var outEq: [Bool] = [], outDiff: [Double] = []

    init(name: String, ranges: [Range<Int>], x: MLXArray) {
        self.name = name
        self.ranges = ranges
        self.x = x
    }
}

/// Mirrors DecoderLayer.forward, exposing the mixer (GDN or attention) and MLP outputs.
private func layerStages(_ x: MLXArray, store: WeightStore, layer: Int, cache: ModelCache)
    throws -> (mixer: MLXArray, mlp: MLXArray, out: MLXArray) {
    let p = "language_model.model.layers.\(layer)."
    let n1 = try store.rmsNorm(p + "input_layernorm", x)
    let mixer: MLXArray
    if (layer + 1) % 4 != 0 {
        mixer = try GDN.forward(n1, store: store, layer: layer, state: cache.gdnState(layer))
    } else {
        mixer = try Attention.forward(n1, store: store, layer: layer, cache: cache.attentionCache(layer))
    }
    let h = x + mixer
    let n2 = try store.rmsNorm(p + "post_attention_layernorm", h)
    let mlp = try MLP.forward(n2, store: store, layer: layer)
    return (mixer, mlp, h + mlp)
}

/// FNV-1a over the fp32 bit patterns.
private func fp32Hash(_ a: MLXArray) -> String {
    let xs = a.asType(.float32).asArray(Float.self)
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for x in xs { h = (h ^ UInt64(x.bitPattern)) &* 0x0000_0100_0000_01b3 }
    return String(format: "%016llx", h)
}

private func maxAbsDiff(_ a: MLXArray, _ b: MLXArray) -> Double {
    let d = abs(a.asType(.float32) - b.asType(.float32)).max()
    return Double(d.item(Float.self))
}

private func rows(_ a: MLXArray, _ b: MLXArray) -> (eq: Bool, diff: Double) {
    (fp32Hash(a) == fp32Hash(b), maxAbsDiff(a, b))
}

private func chunkRanges(_ n: Int, step: Int) -> [Range<Int>] {
    Swift.stride(from: 0, to: n, by: step).map { $0 ..< min($0 + step, n) }
}

private func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s + " " : s + String(repeating: " ", count: w - s.count)
}

private func printRows(_ rs: [Row]) {
    print(pad("component", 56) + pad("bitwise", 9) + "max|diff|")
    for r in rs {
        print(pad(r.component, 56) + pad(r.eq ? "yes" : "no", 9) + String(format: "%.6g", r.diff))
    }
}

/// Deterministic pseudo-random values in [-1, 1), bf16.
private func synth(_ shape: [Int], salt: Double) -> MLXArray {
    var v = [Float](repeating: 0, count: shape.reduce(1, *))
    for i in 0 ..< v.count {
        let x = sin(Double(i) * 12.9898 + salt) * 43758.5453
        v[i] = Float((x - floor(x)) * 2 - 1)
    }
    return MLXArray(v, shape).asType(.bfloat16)
}

private func kernelProbes(store: WeightStore, emb: MLXArray, n: Int) throws -> [Row] {
    var out: [Row] = []

    // (1) qmm row invariance: rows [0,512) of an M-row call vs the M=512 call.
    let x = try store.rmsNorm("language_model.model.layers.0.input_layernorm", emb)
    for proj in ["language_model.model.layers.0.linear_attn.in_proj_qkv",
                 "language_model.model.layers.3.self_attn.q_proj"] {
        let name = proj.split(separator: ".").suffix(2).joined(separator: ".")
        let ref = try store.linear(proj, x[0..., 0 ..< 512, 0...])
        for m in [1024, 2048] {
            let y = try store.linear(proj, x[0..., 0 ..< m, 0...])[0..., 0 ..< 512, 0...]
            let r = rows(y, ref)
            out.append(Row(component: "qmm \(name) M=\(m) vs M=512", eq: r.eq, diff: r.diff))
        }
    }

    // (2) GDN: one S=2048 call vs chained S=1024 calls with carried state, plus a short tail
    // S<512 after a blocked S=1024 call. Run on the default (blocked Metal) path and on the
    // tensor path (GDN.metalOverride = false), which is deterministic and bypasses the blocked kernel.
    let gx = try store.rmsNorm("language_model.model.layers.0.input_layernorm",
                               emb[0..., 0 ..< 2048, 0...])
    for (tag, override) in [("GDN blocked-metal", nil), ("GDN tensor-path", false)] as [(String, Bool?)] {
        GDN.metalOverride = override
        defer { GDN.metalOverride = nil }
        let s1 = GDNState()
        let yOne = try GDN.forward(gx, store: store, layer: 0, state: s1)
        let s2 = GDNState()
        let ya = try GDN.forward(gx[0..., 0 ..< 1024, 0...], store: store, layer: 0, state: s2)
        let yb = try GDN.forward(gx[0..., 1024 ..< 2048, 0...], store: store, layer: 0, state: s2)
        let yChain = concatenated([ya, yb], axis: 1)
        let oc = rows(yOne, yChain)
        out.append(Row(component: "\(tag) S=2048 vs 1024+1024 (out)", eq: oc.eq, diff: oc.diff))
        let sc = rows(s1.ssm!, s2.ssm!)
        out.append(Row(component: "\(tag) S=2048 vs 1024+1024 (ssm state)", eq: sc.eq, diff: sc.diff))
        let cc = rows(s1.conv!, s2.conv!)
        out.append(Row(component: "\(tag) S=2048 vs 1024+1024 (conv state)", eq: cc.eq, diff: cc.diff))
        // Run-to-run determinism of the same call (same input, fresh state).
        let s3 = GDNState()
        let yOne2 = try GDN.forward(gx, store: store, layer: 0, state: s3)
        let rr = rows(yOne, yOne2)
        out.append(Row(component: "\(tag) S=2048 run 1 vs run 2 (out)", eq: rr.eq, diff: rr.diff))

        // Short tail S<512 (sequential Metal kernel on the default path).
        let t1 = GDNState()
        let yRef = try GDN.forward(gx[0..., 0 ..< 1324, 0...], store: store, layer: 0, state: t1)
        let t2 = GDNState()
        let ta = try GDN.forward(gx[0..., 0 ..< 1024, 0...], store: store, layer: 0, state: t2)
        let tb = try GDN.forward(gx[0..., 1024 ..< 1324, 0...], store: store, layer: 0, state: t2)
        let tChain = concatenated([ta, tb], axis: 1)
        let to = rows(yRef, tChain)
        out.append(Row(component: "\(tag) S=1324 vs 1024+300 tail (out)", eq: to.eq, diff: to.diff))
        let ts = rows(t1.ssm!, t2.ssm!)
        out.append(Row(component: "\(tag) S=1324 vs 1024+300 tail (ssm state)", eq: ts.eq, diff: ts.diff))
    }
    GDN.metalOverride = nil

    // (3) SDPA: causal over [0,N) vs the same queries against cached KV with an offset.
    let q = synth([1, 24, n, 256], salt: 0.1)
    let k = synth([1, 4, n, 256], salt: 0.2)
    let v = synth([1, 4, n, 256], salt: 0.3)
    let scale = pow(Float(256), -0.5)
    let full = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: .causal)
    for (label, rs) in [("SDPA causal N vs cached chunks C=1024", chunkRanges(n, step: 1024)),
                        ("SDPA causal N vs cached chunks C=512", chunkRanges(n, step: 512)),
                        ("SDPA causal N vs cached split p=1000", [0 ..< 1000, 1000 ..< n])] {
        let parts = rs.map { r -> MLXArray in
            MLXFast.scaledDotProductAttention(
                queries: q[0..., 0..., r.lowerBound ..< r.upperBound, 0...],
                keys: k[0..., 0..., 0 ..< r.upperBound, 0...],
                values: v[0..., 0..., 0 ..< r.upperBound, 0...],
                scale: scale, mask: .causal)
        }
        let cat = concatenated(parts, axis: 2)
        let r = rows(full, cat)
        out.append(Row(component: label, eq: r.eq, diff: r.diff))
    }
    return out
}

private func finalLogits(_ h: MLXArray, store: WeightStore, n: Int) throws -> MLXArray {
    let last = h[0..., (n - 1) ..< n, 0...]
    let normed = try store.rmsNorm("language_model.model.norm", last)
    return try store.linear("language_model.lm_head", normed)
}

private func probe(modelDir: String, n: Int, layers: Int, tensor: Bool) throws {
    let store = try WeightStore(dir: URL(fileURLWithPath: modelDir))
    let tokens = (0 ..< n).map { Int32(($0 &* 7919 &+ 17) % 150_000) }
    let emb = try store.embedding("language_model.model.embed_tokens", tokens: tokens)
        .reshaped([1, n, hiddenSize])
    print("probesplit  model=\(modelDir)  N=\(n)  layers=\(layers)/\(fullLayerCount)  GDN path=\(tensor ? "tensor (metalOverride=false)" : "default (blocked Metal for S>=512)")")

    // Replication check: the manual one-shot loop must match QwenModel.forwardAll.
    // Replication check only applies to the full stack (forwardAll always runs 64 layers).
    var refHash: String? = nil
    if layers == fullLayerCount {
        let (_, a) = try QwenModel.forwardAll(tokens: tokens, store: store, cache: ModelCache(), lastTokenOnly: true)
        let (_, b) = try QwenModel.forwardAll(tokens: tokens, store: store, cache: ModelCache(), lastTokenOnly: true)
        print("replication: forwardAll logits hash run 1 \(fp32Hash(a))  run 2 \(fp32Hash(b))")
        refHash = fp32Hash(a)
    }

    print("\n== kernel microprobes ==")
    printRows(try kernelProbes(store: store, emb: emb, n: n))

    // Layer-level lockstep.
    let runs = [
        SplitRun(name: "C=1024", ranges: chunkRanges(n, step: 1024), x: emb),
        SplitRun(name: "C=512", ranges: chunkRanges(n, step: 512), x: emb),
        SplitRun(name: "p=1000", ranges: [0 ..< 1000, 1000 ..< n], x: emb),
    ]
    let oneCache = ModelCache()
    var xFull = emb
    GDN.metalOverride = tensor ? false : nil
    for layer in 0 ..< layers {
        let full = try layerStages(xFull, store: store, layer: layer, cache: oneCache)
        let fMix = fp32Hash(full.mixer), fMlp = fp32Hash(full.mlp), fOut = fp32Hash(full.out)
        for run in runs {
            var parts: [(mixer: MLXArray, mlp: MLXArray, out: MLXArray)] = []
            for r in run.ranges {
                parts.append(try layerStages(run.x[0..., r.lowerBound ..< r.upperBound, 0...],
                                             store: store, layer: layer, cache: run.cache))
            }
            let mixer = concatenated(parts.map { $0.mixer }, axis: 1)
            let mlp = concatenated(parts.map { $0.mlp }, axis: 1)
            let out = concatenated(parts.map { $0.out }, axis: 1)
            let m = (fp32Hash(mixer) == fMix, maxAbsDiff(full.mixer, mixer))
            let p = (fp32Hash(mlp) == fMlp, maxAbsDiff(full.mlp, mlp))
            let o = (fp32Hash(out) == fOut, maxAbsDiff(full.out, out))
            run.mixerEq.append(m.0); run.mixerDiff.append(m.1)
            run.mlpEq.append(p.0); run.mlpDiff.append(p.1)
            run.outEq.append(o.0); run.outDiff.append(o.1)
            run.x = out
        }
        xFull = full.out
    }
    GDN.metalOverride = nil

    let finalOne = try finalLogits(xFull, store: store, n: n)
    let oneHash = fp32Hash(finalOne)
    if let refHash {
        print("replication: manual one-shot final logit hash \(oneHash)  "
              + (oneHash == refHash ? "== forwardAll" : "!= forwardAll (loop mismatch or run-to-run nondeterminism)"))
    }

    var verdicts: [String] = []
    for run in runs {
        print("\n== layer level: one-shot N vs split \(run.name) (all \(layers) layers, positions [0,\(n))) ==")
        let types: [(String, [Int])] = [
            ("GDN", (0 ..< layers).filter { (($0 + 1) % 4) != 0 }),
            ("attention", (0 ..< layers).filter { (($0 + 1) % 4) == 0 }),
        ]
        var rs: [Row] = []
        for (name, idx) in types {
            let mEq = idx.allSatisfy { run.mixerEq[$0] }
            let mDiff = idx.map { run.mixerDiff[$0] }.max() ?? 0
            rs.append(Row(component: "\(name) mixer output (\(idx.count) layers)", eq: mEq, diff: mDiff))
        }
        let allMlpEq = run.mlpEq.allSatisfy { $0 }
        rs.append(Row(component: "MLP output (\(layers) layers)", eq: allMlpEq,
                      diff: run.mlpDiff.max() ?? 0))
        let allOutEq = run.outEq.allSatisfy { $0 }
        rs.append(Row(component: "layer output / residual (\(layers) layers)", eq: allOutEq,
                      diff: run.outDiff.max() ?? 0))
        printRows(rs)

        var firstLine = "first diverging layer: none"
        if let first = run.outEq.firstIndex(of: false) {
            let isGDN = (first + 1) % 4 != 0
            let type: String
            if !run.mixerEq[first] {
                type = isGDN ? "GDN" : "attention"
            } else {
                type = "MLP"
            }
            firstLine = "first diverging layer: \(first) (\(type); mixer \(run.mixerEq[first] ? "equal" : "diff \(run.mixerDiff[first])"), mlp \(run.mlpEq[first] ? "equal" : "diff \(run.mlpDiff[first])"))"
        }
        print(firstLine)

        let splitLogits = try finalLogits(run.x, store: store, n: n)
        let splitHash = fp32Hash(splitLogits)
        let logitsEq = splitHash == oneHash
        print("final-logit hash one-shot \(oneHash)  split \(splitHash)  \(logitsEq ? "equal" : "DIFFERENT")")

        let pass = allOutEq && logitsEq
        verdicts.append("\(run.name): \(pass ? "PASS" : "FAIL")")
    }

    print("\n== verdict ==")
    let aligned = verdicts.first { $0.hasPrefix("C=1024") } ?? "C=1024: n/a"
    let unaligned = verdicts.first { $0.hasPrefix("p=1000") } ?? "p=1000: n/a"
    print("aligned split (C=1024): \(aligned.split(separator: " ").last ?? "")")
    print("unaligned split (p=1000): \(unaligned.split(separator: " ").last ?? "")")
    print("info: \(verdicts.first { $0.hasPrefix("C=512") } ?? "")")
}

func runPrefixProbe(_ args: [String]) {
    guard args.count >= 3 else {
        print("usage: strim probesplit <model dir> [N=4096]")
        return
    }
    let n = args.count >= 4 ? (Int(args[3]) ?? 0) : 4096
    guard n >= 2048 else {
        print("probesplit: N must be >= 2048 (got \(args.count >= 4 ? args[3] : "default"))")
        return
    }
    do {
        let layers = args.count >= 5 ? (Int(args[4]) ?? fullLayerCount) : fullLayerCount
    let tensor = args.count >= 6 && args[5] == "tensor"
    try probe(modelDir: args[2], n: n, layers: layers, tensor: tensor)
    } catch {
        print("probesplit failed: \(error)")
    }
}
