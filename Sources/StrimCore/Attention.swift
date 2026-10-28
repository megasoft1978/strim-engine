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
        let p = prefix
        let B = x.shape[0], S = x.shape[1]

        let halves = try store.linear(p + "q_proj", x)
            .reshaped([B, S, Hq, 2, D]).split(parts: 2, axis: 3)
        let queries0 = halves[0].squeezed(axis: 3)
        let gate = halves[1].squeezed(axis: 3).reshaped([B, S, Hq * D])

        let kProj = try store.linear(p + "k_proj", x).reshaped([B, S, Hkv, D])
        let vProj = try store.linear(p + "v_proj", x).reshaped([B, S, Hkv, D])

        let qNormW = try store.tensor(p + "q_norm.weight")
        let kNormW = try store.tensor(p + "k_norm.weight")
        let q = MLXFast.rmsNorm(queries0, weight: qNormW, eps: 1e-6).transposed(0, 2, 1, 3)
        let k = MLXFast.rmsNorm(kProj, weight: kNormW, eps: 1e-6).transposed(0, 2, 1, 3)
        let v = vProj.transposed(0, 2, 1, 3)

        let offset = offsetOverride ?? cache?.offset ?? 0
        var kR = MLXFast.RoPE(k, dimensions: rotaryDim, traditional: false, base: 10_000_000,
                              scale: 1.0, offset: offset)
        let qR = MLXFast.RoPE(q, dimensions: rotaryDim, traditional: false, base: 10_000_000,
                              scale: 1.0, offset: offset)
        var values = v
        if let cache {
            (kR, values) = cache.append(kR, values)
        }

        // Single token needs no mask; otherwise let MLX apply bottom-right-aligned causal
        // masking (queries are the last S of `total` positions; see CausalTests).
        let maskMode: MLXFast.ScaledDotProductAttentionMaskMode = S > 1 ? .causal : .none
        let out = MLXFast.scaledDotProductAttention(
            queries: qR, keys: kR, values: values, scale: pow(Float(D), -0.5), mask: maskMode)
        let flat = out.transposed(0, 2, 1, 3).reshaped([B, S, Hq * D])
        let gated = Fused.attnGate(flat, gate)
        return try store.linear(p + "o_proj", gated)
    }
}
