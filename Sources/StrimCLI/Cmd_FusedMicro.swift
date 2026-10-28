import Foundation
import MLX
import StrimCore

// `strim benchfusedmicro <model> [n=8]`: separate vs row-fused projections (GDN qkv+z,
// attention q+k+v) at M=1,4,8,1024, plus the "pad M 4->8" idea. Interleaved min-of-8 over
// several layers so weights are not cache-resident. Also checks fused slices are
// bit-identical to the separate matmuls.

func runFusedMicro(_ args: [String]) {
    guard args.count >= 3 else { print("usage: strim benchfusedmicro <model> [n]"); return }
    let n = args.count >= 4 ? Int(args[3]) ?? 8 : 8
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        typealias Q = (w: MLXArray, s: MLXArray, b: MLXArray)
        func q(_ name: String) throws -> Q {
            (try store.tensor(name + ".weight"), try store.tensor(name + ".scales"), try store.tensor(name + ".biases"))
        }
        func cat(_ qs: [Q]) -> Q {
            let r: Q = (concatenated(qs.map { $0.w }, axis: 0), concatenated(qs.map { $0.s }, axis: 0),
                        concatenated(qs.map { $0.b }, axis: 0))
            eval(r.w, r.s, r.b)
            return r
        }
        func mm(_ x: MLXArray, _ w: Q) -> MLXArray {
            quantizedMatmul(x, w.w, scales: w.s, biases: w.b, transpose: true, groupSize: 64, bits: 4)
        }
        let L = "language_model.model.layers."
        let gdnLayers = [0, 1, 2, 4, 5, 6, 8, 9]
        let attnLayers = [3, 7, 11, 15, 19, 23, 27, 31]
        struct Group { var name: String; var sep: [[Q]]; var fused: [Q]; var splits: [Int] }
        var groups: [Group] = []
        var g1 = Group(name: "gdn qkv+z", sep: [], fused: [], splits: [10240, 6144])
        for l in gdnLayers {
            let a = try q(L + "\(l).linear_attn.in_proj_qkv"), b = try q(L + "\(l).linear_attn.in_proj_z")
            g1.sep.append([a, b]); g1.fused.append(cat([a, b]))
        }
        groups.append(g1)
        var g2 = Group(name: "attn q+k+v", sep: [], fused: [], splits: [12288, 1024, 1024])
        for l in attnLayers {
            let a = try q(L + "\(l).self_attn.q_proj"), b = try q(L + "\(l).self_attn.k_proj"),
                c = try q(L + "\(l).self_attn.v_proj")
            g2.sep.append([a, b, c]); g2.fused.append(cat([a, b, c]))
        }
        groups.append(g2)
        let layersN = Double(gdnLayers.count)
        for g in groups {
            for M in [1, 4, 8, 1024] {
                let x = MLXRandom.normal([1, M, 5120]).asType(.bfloat16)
                let xp = M == 4 ? concatenated([x, MLXArray.zeros([1, 4, 5120], dtype: .bfloat16)], axis: 1) : x
                eval(x, xp)
                func sepRun() -> [MLXArray] { g.sep.flatMap { ws in ws.map { mm(x, $0) } } }
                func fusedRun() -> [MLXArray] { g.fused.map { mm(x, $0) } }
                func padRun() -> [MLXArray] { g.sep.flatMap { ws in ws.map { mm(xp, $0)[0..., 0 ..< 4, 0...] } } }
                func time(_ f: () -> [MLXArray]) -> Double {
                    let t0 = Date(); eval(f()); return Date().timeIntervalSince(t0) * 1000 / layersN
                }
                _ = time(sepRun); _ = time(fusedRun)
                var ts = Double.infinity, tf = Double.infinity, tp = Double.infinity
                for _ in 0 ..< n {
                    ts = min(ts, time(sepRun)); tf = min(tf, time(fusedRun))
                    if M == 4 { tp = min(tp, time(padRun)) }
                }
                // bit identity of slices
                var same = true
                for (i, ws) in g.sep.enumerated() {
                    let y = mm(x, g.fused[i]); var off = 0
                    for (j, w) in ws.enumerated() {
                        let ref = mm(x, w); let sl = y[0..., 0..., off ..< (off + g.splits[j])]; off += g.splits[j]
                        if !arrayEqual(ref, sl).item(Bool.self) { same = false }
                    }
                }
                print(String(format: "%@ M=%4d sep %.3f ms/layer fused %.3f saved %.3f ms/layer (x%d layers = %.2f ms/pass) pad8 %@ bitident=%@",
                             g.name as NSString, M, ts, tf, ts - tf, g.name.hasPrefix("gdn") ? 48 : 16,
                             (ts - tf) * (g.name.hasPrefix("gdn") ? 48 : 16),
                             (M == 4 ? String(format: "%.3f", tp) : "-") as NSString, (same ? "YES" : "NO") as NSString))
            }
        }
    } catch {
        FileHandle.standardError.write(Data("benchfusedmicro failed: \(error)\n".utf8)); exit(1)
    }
}
