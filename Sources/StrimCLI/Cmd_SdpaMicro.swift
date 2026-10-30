import Foundation
import MLX
import MLXFast
import MLXRandom

// `strim benchsdpa [reps=7] [layers=8]`: long-context prefill SDPA throughput (Hq=24, Hkv=4, D=256, bf16, q chunk 1024 vs
// kv 4K/16K/32K, bottom-right causal) with MLX's fast SDPA, against bf16 GEMM reference shapes of a flash tile loop.
//  sdpa causal : what prefill runs today (flops = 4*Hq*D*pairs, causal pairs only)
//  sdpa nomask : same shapes without the causal mask (full S*kv pairs): shows what the mask costs
//  gemm QK/PV  : the two dense products of one kv head group (M=6*1024 grouped q rows, K=256 / N=4096-wide kv tile), no softmax:
//                an upper bound for any flash kernel built on the same matrix pipe.
// Layers are chained (output feeds the next query) so MLX cannot overlap them. Min of reps after one warm-up.
func runSdpaMicro(_ args: [String]) {
    let reps = args.count >= 3 ? Int(args[2]) ?? 7 : 7
    let layers = args.count >= 4 ? Int(args[3]) ?? 8 : 8
    let Hq = 24, Hkv = 4, D = 256, S = 1024
    let scale = Float(1.0 / 16.0)
    func ms(_ f: () -> MLXArray) -> Double {
        var best = Double.infinity
        for i in 0 ... reps {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let r = f(); eval(r)
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if i > 0 { best = min(best, dt) }
        }
        return best
    }
    func rnd(_ shape: [Int]) -> MLXArray { (MLXRandom.normal(shape) * 0.5).asType(.bfloat16) }
    print("host: layers/iter=\(layers) reps=\(reps); TF/s = 1e-9*flops/ms; dense plateau reference 62.7 TF/s")
    for kv in [4096, 16384, 32768] {
        let q0 = rnd([1, Hq, S, D]), k = rnd([1, Hkv, kv, D]), v = rnd([1, Hkv, kv, D])
        eval(q0, k, v)
        let off = kv - S
        let pairs = Double(S) * Double(off) + Double(S) * Double(S + 1) / 2
        let fCausal = 4 * Double(Hq * D) * pairs, fFull = 4 * Double(Hq * D) * Double(S) * Double(kv)
        func chain(_ mask: MLXFast.ScaledDotProductAttentionMaskMode) -> () -> MLXArray {
            {
                var q = q0
                for _ in 0 ..< layers {
                    let o = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: mask)
                    q = o * 0.01 + q0
                }
                return q
            }
        }
        var tc = Double.infinity, tn = Double.infinity
        for _ in 0 ..< 2 {
            tc = min(tc, ms(chain(.causal))); tn = min(tn, ms(chain(.none)))
        }
        let c1 = tc / Double(layers), n1 = tn / Double(layers)
        // GEMM reference: per kv group, scores = Qg[6*S, D] @ Kt[D, T] and out = P[6*S, T] @ V[T, D] over kv tiles of T=4096
        // (summed over tiles = all kv, full non-causal flops), 4 kv groups batched.
        let T = 4096, tiles = max(kv / T, 1)
        let qg = rnd([Hkv, 6 * S, D]), kt = rnd([Hkv, D, T]), p = rnd([Hkv, 6 * S, T]), vt = rnd([Hkv, T, D])
        eval(qg, kt, p, vt)
        func gemm(_ qk: Bool) -> () -> MLXArray {
            {
                var acc = qg
                for _ in 0 ..< layers * tiles {
                    if qk {
                        let s = matmul(acc, kt)             // [4, 6S, T]
                        acc = qg + s[0..., 0..., 0 ..< D] * 0.001
                    } else {
                        let o = matmul(p, vt + acc[0..., 0 ..< T, 0...] * 0.001)   // [4, 6S, D]; vt depends on acc so layers stay serial
                        acc = qg + o * 0.001
                    }
                }
                return acc
            }
        }
        var tq = Double.infinity, tp = Double.infinity
        for _ in 0 ..< 2 { tq = min(tq, ms(gemm(true))); tp = min(tp, ms(gemm(false))) }
        let gFlopsOne = 2 * Double(Hkv) * Double(6 * S) * Double(D) * Double(T) * Double(layers * tiles)
        let qkTF = gFlopsOne / tq / 1e9, pvTF = gFlopsOne / tp / 1e9
        let allTime = (tq + tp) / Double(layers)    // QK + PV for the full kv, full flops, no softmax
        let allTF = fFull / allTime / 1e9
        print(String(format: "kv=%5d  sdpa causal %7.2f ms  %5.1f TF/s (%.0f%% of 62.7)   sdpa nomask %7.2f ms  %5.1f TF/s (full flops)   gemm QK %5.1f TF/s  PV %5.1f TF/s  QK+PV(full) %5.1f TF/s -> would-be causal-skipping time %.2f ms (%.1f TF/s equiv)",
                     kv, c1, fCausal / c1 / 1e9, fCausal / c1 / 1e9 / 62.7 * 100, n1, fFull / n1 / 1e9, qkTF, pvTF, allTF,
                     allTime * fCausal / fFull, fCausal / (allTime * fCausal / fFull) / 1e9))
    }
}
