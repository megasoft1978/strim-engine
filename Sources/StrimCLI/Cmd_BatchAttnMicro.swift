import Foundation
import MLX
import MLXFast
import MLXRandom
import StrimCore

// `strim benchbatchattn [reps=7]`: the 16 full-attention layers' decode-step cost at B in {4,8}, ctx in {1K,4K,16K},
// ragged lengths (len_b = ctx * (0.55 + 0.45 * b/(B-1))). Layers are chained serially (layer i+1's query depends on
// layer i's output) so MLX's concurrent encoder cannot overlap them (see L8). Random weights-free: only the attention
// glue is timed (RoPE, KV append, SDPA); projections are identical in every variant and excluded.
//  looped   : per sequence RoPE(q,k) + in-place append + SDPA over its valid prefix (today's BatchedAttention)
//  batched  : one RoPE with per-row offsets, one scatter append, one SDPA over a padded [B,..,maxLen] KV with an array mask
//  batchedNM: batched with equal lengths and no mask (lower bound for a ragged kernel)
func runBatchAttnMicro(_ args: [String]) {
    let reps = args.count >= 3 ? Int(args[2]) ?? 7 : 7
    let Hq = 24, Hkv = 4, D = 256, rot = 64, layers = 16
    let scale = Float(1.0 / 16.0)
    func rope(_ x: MLXArray, _ off: Int) -> MLXArray {
        MLXFast.RoPE(x, dimensions: rot, traditional: false, base: 10_000_000, scale: 1.0, offset: off)
    }
    for ctx in [1024, 4096, 16384] {
        for B in [4, 8] {
            let lens = (0 ..< B).map { b in Int(Float(ctx) * (0.55 + 0.45 * Float(b) / Float(B - 1))) }
            let maxLen = lens.max()!
            let cap = maxLen + 1
            // KV buffers shared by all 16 layers (same bytes streamed per layer as distinct buffers; no cache residency
            // at these sizes), per-sequence [1,Hkv,cap,D] for looped, one [B,Hkv,cap,D] for batched.
            var ks: [MLXArray] = [], vs: [MLXArray] = []
            for _ in 0 ..< B {
                ks.append((MLXRandom.normal([1, Hkv, cap, D]) * 0.5).asType(.bfloat16))
                vs.append((MLXRandom.normal([1, Hkv, cap, D]) * 0.5).asType(.bfloat16))
            }
            let kb = concatenated(ks, axis: 0), vb = concatenated(vs, axis: 0)
            let q0 = (MLXRandom.normal([B, Hq, 1, D]) * 0.5).asType(.bfloat16)
            let kn = (MLXRandom.normal([B, Hkv, 1, D]) * 0.5).asType(.bfloat16)
            let vn = (MLXRandom.normal([B, Hkv, 1, D]) * 0.5).asType(.bfloat16)
            eval(kb, vb, q0, kn, vn); eval(ks + vs)
            let offs = MLXArray(lens.map { Int32($0) })
            let posIdx = MLXArray(lens.map { Int32($0) }).reshaped([B, 1, 1, 1])
            let ar = MLXArray(Array(0 ..< Int32(cap))).reshaped([1, 1, 1, cap])
            let mask = ar .<= posIdx   // valid positions 0...len (the new token included)
            func tick(_ o: MLXArray) -> MLXArray { o * 0.01 + q0 }  // serial dependency into the next layer's query

            func looped() -> MLXArray {
                var q = q0
                for _ in 0 ..< layers {
                    var outs: [MLXArray] = []
                    for b in 0 ..< B {
                        let off = lens[b]
                        let qb = rope(q[b ..< (b + 1)], off), knb = rope(kn[b ..< (b + 1)], off)
                        ks[b][0..., 0..., off ..< (off + 1)] = knb
                        vs[b][0..., 0..., off ..< (off + 1)] = vn[b ..< (b + 1)]
                        outs.append(MLXFast.scaledDotProductAttention(
                            queries: qb, keys: ks[b][0..., 0..., 0 ..< (off + 1)], values: vs[b][0..., 0..., 0 ..< (off + 1)],
                            scale: scale, mask: .none))
                    }
                    q = tick(concatenated(outs, axis: 0))
                }
                return q
            }
            func batched(equal: Bool) -> MLXArray {
                var q = q0
                let eq = equal ? maxLen : 0
                for _ in 0 ..< layers {
                    let qr: MLXArray, kr: MLXArray
                    if equal { qr = rope(q, eq); kr = rope(kn, eq) }
                    else {
                        qr = MLXFast.RoPE(q, dimensions: rot, traditional: false, base: 10_000_000, scale: 1.0, offset: offs)
                        kr = MLXFast.RoPE(kn, dimensions: rot, traditional: false, base: 10_000_000, scale: 1.0, offset: offs)
                    }
                    var kk = kb, vv = vb   // persistent batched buffers; appends are in-place row slice writes
                    if equal {
                        kk[0..., 0..., eq ..< (eq + 1)] = kr; vv[0..., 0..., eq ..< (eq + 1)] = vn
                    } else {
                        for b in 0 ..< B {
                            kk[b ..< (b + 1), 0..., lens[b] ..< (lens[b] + 1)] = kr[b ..< (b + 1)]
                            vv[b ..< (b + 1), 0..., lens[b] ..< (lens[b] + 1)] = vn[b ..< (b + 1)]
                        }
                    }
                    let o = equal
                        ? MLXFast.scaledDotProductAttention(queries: qr, keys: kk[0..., 0..., 0 ..< (eq + 1)], values: vv[0..., 0..., 0 ..< (eq + 1)], scale: scale, mask: .none)
                        : MLXFast.scaledDotProductAttention(queries: qr, keys: kk, values: vv, scale: scale, mask: mask)
                    q = tick(o)
                }
                return q
            }
            func time(_ f: () -> MLXArray) -> Double {
                var best = Double.infinity
                for i in 0 ..< reps + 1 {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let r = f(); eval(r)
                    let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                    if i > 0 { best = min(best, dt) }
                }
                return best
            }
            // Variants alternate (ABAB) to cancel drift.
            var tl = Double.infinity, tb = Double.infinity, tn = Double.infinity
            for _ in 0 ..< 2 {
                tl = min(tl, time(looped)); tb = min(tb, time { batched(equal: false) }); tn = min(tn, time { batched(equal: true) })
            }
            let a = looped(), bb = batched(equal: false); eval(a, bb)
            let diff = abs(a.asType(.float32) - bb.asType(.float32)).max().item(Float.self)
            print(String(format: "B=%d ctx=%5d maxLen=%5d  looped %.2f ms  batched(masked, padded) %.2f ms  batched(equal,nomask) %.2f ms  save(masked)=%+.2f ms  maxabsdiff=%.4g",
                         B, ctx, maxLen, tl, tb, tn, tl - tb, diff))
        }
    }
}
