import Foundation
import MLX
import StrimCore

// `strim benchqmmcurve <model> [n=8]`: per-layer cost curve of the real 4-bit quantized matmul
// shapes vs M (rows of x), weights rotated over 8 layers so they are not cache-resident,
// interleaved min-of-n. Also times split-M groupings (k calls of smaller M + concatenate) against
// the single call, and checks per-row bit identity of the split result vs the single call.

func runQmmCurve(_ args: [String]) {
    guard args.count >= 3 else { print("usage: strim benchqmmcurve <model> [n]"); return }
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
        let gdn = [0, 1, 2, 4, 5, 6, 8, 9]
        let attn = [3, 7, 11, 15, 19, 23, 27, 31]
        // name, K, N, weights per layer (one entry per layer)
        var shapes: [(name: String, K: Int, N: Int, ws: [Q])] = []
        shapes.append(("gdn in_proj_qkv", 5120, 10240, try gdn.map { try q(L + "\($0).linear_attn.in_proj_qkv") }))
        shapes.append(("gdn in_proj_z", 5120, 6144, try gdn.map { try q(L + "\($0).linear_attn.in_proj_z") }))
        shapes.append(("gdn out_proj", 6144, 5120, try gdn.map { try q(L + "\($0).linear_attn.out_proj") }))
        shapes.append(("attn q_proj", 5120, 12288, try attn.map { try q(L + "\($0).self_attn.q_proj") }))
        shapes.append(("attn k_proj", 5120, 1024, try attn.map { try q(L + "\($0).self_attn.k_proj") }))
        shapes.append(("attn o_proj", 6144, 5120, try attn.map { try q(L + "\($0).self_attn.o_proj") }))
        shapes.append(("mlp gate+up fused", 5120, 34816, try gdn.map {
            cat([try q(L + "\($0).mlp.gate_proj"), try q(L + "\($0).mlp.up_proj")]) }))
        shapes.append(("mlp down", 17408, 5120, try gdn.map { try q(L + "\($0).mlp.down_proj") }))
        let Ms = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 16, 24, 32, 64]
        let layersN = 8.0
        func timeIt(_ f: () -> [MLXArray]) -> Double {
            let t0 = Date(); eval(f()); return Date().timeIntervalSince(t0) * 1000 / layersN
        }
        var base1: [String: Double] = [:]
        print("# curve: shape M ms/layer GB/s(weights once) ratio_vs_M1 ms_per_row")
        for sh in shapes {
            let bytes = Double(sh.N) * Double(sh.K) * (0.5 + 4.0 / 64.0)  // 4-bit + bf16 scale+bias per 64
            var best: [Int: Double] = [:]
            var xs: [Int: MLXArray] = [:]
            for M in Ms { xs[M] = MLXRandom.normal([1, M, sh.K]).asType(.bfloat16); eval(xs[M]!) }
            for M in Ms { _ = timeIt { sh.ws.map { mm(xs[M]!, $0) } } }
            for _ in 0 ..< n {
                for M in Ms { best[M] = min(best[M] ?? .infinity, timeIt { sh.ws.map { mm(xs[M]!, $0) } }) }
            }
            for M in Ms {
                let t = best[M]!
                if M == 1 { base1[sh.name] = t }
                print(String(format: "CURVE %@ M=%d %.4f ms %.0f GB/s x%.2f %.4f ms/row", sh.name as NSString, M, t,
                             bytes / (t * 1e-3) / 1e9, t / (base1[sh.name] ?? t), t / Double(M)))
            }
        }
        // split-M groupings
        let groupings: [Int: [[Int]]] = [
            5: [[5], [3, 2]], 6: [[6], [3, 3], [4, 2], [5, 1]], 7: [[7], [4, 3], [5, 2]],
            8: [[8], [4, 4], [5, 3], [6, 2]], 10: [[10], [5, 5], [4, 4, 2]], 12: [[12], [4, 4, 4], [6, 6], [5, 5, 2]],
            16: [[16], [4, 4, 4, 4], [8, 8], [5, 5, 5, 1]],
        ]
        print("# split: shape M grouping ms/layer(incl concat) ratio_vs_single bitident_vs_single")
        for sh in shapes {
            for M in groupings.keys.sorted() {
                let x = MLXRandom.normal([1, M, sh.K]).asType(.bfloat16); eval(x)
                let gs = groupings[M]!
                func run(_ g: [Int]) -> [MLXArray] {
                    sh.ws.map { w in
                        if g.count == 1 { return mm(x, w) }
                        var off = 0; var parts: [MLXArray] = []
                        for c in g { parts.append(mm(x[0..., off ..< (off + c), 0...], w)); off += c }
                        return concatenated(parts, axis: 1)
                    }
                }
                for g in gs { _ = timeIt { run(g) } }
                var bestT = [Double](repeating: .infinity, count: gs.count)
                for _ in 0 ..< n { for (i, g) in gs.enumerated() { bestT[i] = min(bestT[i], timeIt { run(g) }) } }
                let ref = run(gs[0])
                for (i, g) in gs.enumerated() {
                    var same = true
                    if i > 0 { let o = run(g); for (a, b) in zip(ref, o) where !arrayEqual(a, b).item(Bool.self) { same = false } }
                    print(String(format: "SPLIT %@ M=%d %@ %.4f ms x%.2f ident=%@", sh.name as NSString, M,
                                 g.map(String.init).joined(separator: "+") as NSString, bestT[i], bestT[i] / bestT[0],
                                 (i == 0 ? "ref" : (same ? "YES" : "NO")) as NSString))
                }
            }
        }
        // row-level identity vs M=1 calls (informational): does M-call row i equal the M=1 call of row i?
        print("# rowident: shape M frac_of_rows_equal_to_M1_call")
        for sh in shapes {
            for M in [2, 4, 5, 6, 8, 12, 16] {
                let x = MLXRandom.normal([1, M, sh.K]).asType(.bfloat16); eval(x)
                let w = sh.ws[0]
                let y = mm(x, w); var eq = 0
                for r in 0 ..< M {
                    let yr = mm(x[0..., r ..< (r + 1), 0...], w)
                    if arrayEqual(y[0..., r ..< (r + 1), 0...], yr).item(Bool.self) { eq += 1 }
                }
                print("ROWIDENT \(sh.name) M=\(M) \(eq)/\(M)")
            }
        }
        // pad M up to 13 / 16 (qmm regime) with zero rows, slice back; compare vs single qmv_wide call
        print("# pad: shape M padTo ms/layer ratio_vs_single ident_vs_single rowinvariant")
        for sh in shapes {
            for M in [5, 6, 7, 8, 10, 12] {
                let x = MLXRandom.normal([1, M, sh.K]).asType(.bfloat16); eval(x)
                func single() -> [MLXArray] { sh.ws.map { mm(x, $0) } }
                var best: [Int: Double] = [:]
                let pads = [M, 13, 16]
                func run(_ P: Int) -> [MLXArray] {
                    if P == M { return single() }
                    let xp = concatenated([x, MLXArray.zeros([1, P - M, sh.K], dtype: .bfloat16)], axis: 1)
                    return sh.ws.map { mm(xp, $0)[0..., 0 ..< M, 0...] }
                }
                for P in pads { _ = timeIt { run(P) } }
                for _ in 0 ..< n { for P in pads { best[P] = min(best[P] ?? .infinity, timeIt { run(P) }) } }
                let ref = single()
                for P in pads {
                    var same = true; var inv = true
                    if P != M {
                        let o = run(P); for (a, b) in zip(ref, o) where !arrayEqual(a, b).item(Bool.self) { same = false }
                        // row invariance: same rows with different filler rows give same output
                        let xr = concatenated([x, MLXRandom.normal([1, P - M, sh.K]).asType(.bfloat16)], axis: 1)
                        let w = sh.ws[0]
                        let a = mm(xr, w)[0..., 0 ..< M, 0...]
                        let b = mm(concatenated([x, MLXArray.zeros([1, P - M, sh.K], dtype: .bfloat16)], axis: 1), w)[0..., 0 ..< M, 0...]
                        inv = arrayEqual(a, b).item(Bool.self)
                    }
                    print(String(format: "PAD %@ M=%d pad%d %.4f ms x%.2f ident=%@ rowinv=%@", sh.name as NSString, M, P,
                                 best[P]!, best[P]! / best[M]!, (P == M ? "ref" : (same ? "YES" : "NO")) as NSString,
                                 (P == M ? "-" : (inv ? "YES" : "NO")) as NSString))
                }
            }
        }
    } catch {
        FileHandle.standardError.write(Data("benchqmmcurve failed: \(error)\n".utf8)); exit(1)
    }
}

// `strim benchqmmstep <model> [n=5]`: all 64 layers' projections chained serially at M rows
// (real weights, 14 GB streamed per step, nothing cache-resident), under row-split policies.
func runQmmStep(_ args: [String]) {
    guard args.count >= 3 else { print("usage: strim benchqmmstep <model> [n]"); return }
    let n = args.count >= 4 ? Int(args[3]) ?? 5 : 5
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        typealias Q = (w: MLXArray, s: MLXArray, b: MLXArray)
        func q(_ name: String) throws -> Q {
            (try store.tensor(name + ".weight"), try store.tensor(name + ".scales"), try store.tensor(name + ".biases"))
        }
        func mm1(_ x: MLXArray, _ w: Q) -> MLXArray {
            quantizedMatmul(x, w.w, scales: w.s, biases: w.b, transpose: true, groupSize: 64, bits: 4)
        }
        struct Lay { var gdn: Bool; var a: [Q]; var gu: Q; var down: Q }
        var lays: [Lay] = []
        let L = "language_model.model.layers."
        for l in 0 ..< 64 {
            let gdn = (l + 1) % 4 != 0
            let a: [Q] = gdn
                ? [try q(L + "\(l).linear_attn.in_proj_qkv"), try q(L + "\(l).linear_attn.in_proj_z"), try q(L + "\(l).linear_attn.out_proj")]
                : [try q(L + "\(l).self_attn.q_proj"), try q(L + "\(l).self_attn.k_proj"), try q(L + "\(l).self_attn.v_proj"),
                   try q(L + "\(l).self_attn.o_proj")]
            let f = try store.mlpFused(l)
            lays.append(Lay(gdn: gdn, a: a, gu: f, down: try q(L + "\(l).mlp.down_proj")))
            if l % 8 == 7 { eval(lays.last!.gu.w) }
        }
        // policy: chunk sizes applied to (attn projections, mlp) ; 0 = single call; pad16 for mlp via padMlp
        struct Pol { var name: String; var splitAttn: Int; var splitMlp: Int; var padMlp: Int }
        let pols = [Pol(name: "single", splitAttn: 0, splitMlp: 0, padMlp: 0),
                    Pol(name: "split4 mlp-only", splitAttn: 0, splitMlp: 4, padMlp: 0),
                    Pol(name: "split4 all", splitAttn: 4, splitMlp: 4, padMlp: 0),
                    Pol(name: "pad16 mlp-only", splitAttn: 0, splitMlp: 0, padMlp: 16),
                    Pol(name: "pad16 gateup + split4 rest", splitAttn: 4, splitMlp: 4, padMlp: 16)]
        func mm(_ x: MLXArray, _ w: Q, split: Int, pad: Int = 0) -> MLXArray {
            let M = x.shape[1]
            if pad > M {
                let xp = concatenated([x, MLXArray.zeros([1, pad - M, x.shape[2]], dtype: x.dtype)], axis: 1)
                return mm1(xp, w)[0..., 0 ..< M, 0...]
            }
            if split == 0 || M <= split { return mm1(x, w) }
            var parts: [MLXArray] = []; var off = 0
            while off < M { let c = min(split, M - off); parts.append(mm1(x[0..., off ..< (off + c), 0...], w)); off += c }
            return concatenated(parts, axis: 1)
        }
        func step(_ x0: MLXArray, _ p: Pol) -> MLXArray {
            var h = x0
            for ly in lays {
                if ly.gdn {
                    let qkv = mm(h, ly.a[0], split: p.splitAttn), z = mm(h, ly.a[1], split: p.splitAttn)
                    let t = qkv[0..., 0..., 0 ..< 6144] * z * 0.05
                    h = h + mm(t, ly.a[2], split: p.splitAttn) * 0.05
                } else {
                    let qq = mm(h, ly.a[0], split: p.splitAttn), k = mm(h, ly.a[1], split: p.splitAttn)
                    let v = mm(h, ly.a[2], split: p.splitAttn)
                    let t = qq[0..., 0..., 0 ..< 6144] * 0.05 + concatenated([k, v, k, v, k, v], axis: 2)[0..., 0..., 0 ..< 6144] * 0.05
                    h = h + mm(t, ly.a[3], split: p.splitAttn) * 0.05
                }
                let gu = mm(h, ly.gu, split: p.splitMlp, pad: p.padMlp)
                let act = gu[0..., 0..., 0 ..< 17408] * gu[0..., 0..., 17408 ..< 34816] * 0.05
                h = h + mm(act, ly.down, split: p.splitMlp) * 0.05
            }
            return h
        }
        for M in (ProcessInfo.processInfo.environment["QS_M"] ?? "1,4,6,8,9,11,13,14,15,16,24,32").split(separator: ",").map({ Int($0)! }) {
            let x = (MLXRandom.normal([1, M, 5120]) * 0.1).asType(.bfloat16); eval(x)
            let ps = M == 1 ? [pols[0]] : pols
            for p in ps { eval(step(x, p)) }
            var best = [Double](repeating: .infinity, count: ps.count)
            for _ in 0 ..< n {
                for (i, p) in ps.enumerated() {
                    let t0 = Date(); eval(step(x, p)); best[i] = min(best[i], Date().timeIntervalSince(t0) * 1000)
                }
            }
            let ref = step(x, ps[0]); eval(ref)
            for (i, p) in ps.enumerated() {
                let same = i == 0 ? "ref" : (arrayEqual(ref, step(x, p)).item(Bool.self) ? "YES" : "NO")
                print(String(format: "STEP M=%d %@ %.2f ms (x%.3f vs single) final-h-identical=%@", M, p.name as NSString,
                             best[i], best[i] / best[0], same as NSString))
            }
        }
    } catch {
        FileHandle.standardError.write(Data("benchqmmstep failed: \(error)\n".utf8)); exit(1)
    }
}
