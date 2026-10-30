import Foundation
import MLX

/// Gated full attention used on every 4th Qwen3.5/3.8 layer.
public enum Attention {
    static let Hq = 24, Hkv = 4, D = 256, rotaryDim = 64

    public static func forward(_ x: MLXArray, store: WeightStore, layer: Int, cache: AttentionCache? = nil) throws -> MLXArray {
        try forward(x, store: store, prefix: "language_model.model.layers.\(layer).self_attn.", cache: cache)
    }

    public static func forward(_ x: MLXArray, store: WeightStore, prefix: String,
                               cache: AttentionCache? = nil, offsetOverride: Int? = nil) throws -> MLXArray {
        if MacroPrefill.splits(x) {
            let projected = try ["q_proj", "k_proj", "v_proj"].map { try store.linear(prefix + $0, x) }
            let live = cache ?? AttentionCache()
            let parts = try MacroPrefill.ranges(count: x.shape[1]).map { r in
                try forwardRange(x[0..., r, 0...], store: store, prefix: prefix, cache: live,
                                 offsetOverride: offsetOverride.map { $0 + r.lowerBound },
                                 projections: projected.map { $0[0..., r, 0...] }, deferOutput: true)
            }
            return try store.linear(prefix + "o_proj", concatenated(parts, axis: 1))
        }
        return try forwardRange(x, store: store, prefix: prefix, cache: cache, offsetOverride: offsetOverride)
    }

    private static func forwardRange(_ x: MLXArray, store: WeightStore, prefix: String,
                                     cache: AttentionCache?, offsetOverride: Int?,
                                     projections: [MLXArray]? = nil, deferOutput: Bool = false) throws -> MLXArray {
        let p = prefix
        let B = x.shape[0], S = x.shape[1]

        let qProj = try projections?[0] ?? OpTimer.linear(store, "attn.proj", p + "q_proj", x)
        let kProj = try (projections?[1] ?? OpTimer.linear(store, "attn.proj", p + "k_proj", x)).reshaped([B, S, Hkv, D])
        let vProj = try (projections?[2] ?? OpTimer.linear(store, "attn.proj", p + "v_proj", x)).reshaped([B, S, Hkv, D])

        let qkv = try OpTimer.timeMany("attn.qknorm", flops: Double(B * S * (Hq + Hkv) * D) * 4,
                                       bytes: Double(qProj.nbytes + kProj.nbytes) * 1.5,
                                       inputs: [qProj, kProj, vProj]) {
            let halves = qProj.reshaped([B, S, Hq, 2, D]).split(parts: 2, axis: 3)
            let queries0 = halves[0].squeezed(axis: 3)
            let gate = halves[1].squeezed(axis: 3).reshaped([B, S, Hq * D])

            let qNormW = try store.tensor(p + "q_norm.weight")
            let kNormW = try store.tensor(p + "k_norm.weight")
            let q = MLXFast.rmsNorm(queries0, weight: qNormW, eps: 1e-6).transposed(0, 2, 1, 3)
            let k = MLXFast.rmsNorm(kProj, weight: kNormW, eps: 1e-6).transposed(0, 2, 1, 3)
            let v = vProj.transposed(0, 2, 1, 3)
            return [q, k, v, gate]
        }
        let q = qkv[0], k = qkv[1], v = qkv[2], gate = qkv[3]

        let offset = offsetOverride ?? cache?.offset ?? 0
        let kv = OpTimer.timeMany("attn.rope_append", flops: Double(B * S * (Hq + Hkv) * rotaryDim) * 3,
                                  bytes: Double(q.nbytes + k.nbytes * 2 + v.nbytes) * 1.5,
                                  inputs: [q, k, v]) {
            var kR = MLXFast.RoPE(k, dimensions: rotaryDim, traditional: false, base: 10_000_000,
                                  scale: 1.0, offset: offset)
            let qR = MLXFast.RoPE(q, dimensions: rotaryDim, traditional: false, base: 10_000_000,
                                  scale: 1.0, offset: offset)
            var values = v
            if let cache {
                (kR, values) = cache.append(kR, values)
            }
            return [qR, kR, values]
        }
        let qR = kv[0], kR = kv[1], values = kv[2]

        // Single token needs no mask; otherwise let MLX apply bottom-right-aligned causal
        // masking (queries are the last S of `total` positions; see CausalTests).
        let maskMode: MLXFast.ScaledDotProductAttentionMaskMode = S > 1 ? .causal : .none
        // Causal pairs: each of the S queries sees `offset` cached keys plus its own prefix.
        let pairs = Double(S) * Double(offset) + Double(S) * Double(S + 1) / 2
        let out = OpTimer.time("attn.sdpa", flops: Double(B) * 4 * Double(Hq * D) * (S > 1 ? pairs : Double(offset + 1)),
                               bytes: Double(qR.nbytes + kR.nbytes + values.nbytes + B * S * Hq * D * 2),
                               inputs: [qR, kR, values]) {
            MLXFast.scaledDotProductAttention(
                queries: qR, keys: kR, values: values, scale: pow(Float(D), -0.5), mask: maskMode)
        }
        let gated = OpTimer.time("attn.gate", flops: Double(B * S * Hq * D) * 4,
                                 bytes: Double(out.nbytes * 3), inputs: [out, gate]) {
            let flat = out.transposed(0, 2, 1, 3).reshaped([B, S, Hq * D])
            return Fused.attnGate(flat, gate)
        }
        if deferOutput { return gated }
        return try OpTimer.linear(store, "attn.o", p + "o_proj", gated)
    }
}
