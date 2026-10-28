import Foundation
import MLX

/// Per-layer batched attention state: one preallocated `AttentionCache` per sequence, so a
/// decode step appends in place (no per-step KV concatenation or padding) and each sequence
/// keeps its own length.
public final class BatchedAttentionCache {
    public var seqs: [AttentionCache] = []
    public var lengths: [Int] { seqs.map { $0.offset } }
    public init(B: Int) {}
    /// Append to sequence `b` in place; returns views over its valid positions.
    public func append(_ b: Int, _ k: MLXArray, _ v: MLXArray) -> (keys: MLXArray, values: MLXArray) {
        seqs[b].append(k, v)
    }
}

public final class BatchedModelCache {
    public var attention: [Int: BatchedAttentionCache] = [:]
    public var gdn: [Int: GDNState] = [:]
    public var position = 0
    public var batchSize = 0
    public init() {}

    /// Add one prefilled sequence to the batch (its ModelCache).
    public func append(_ c: ModelCache) {
        batchSize += 1
        for layer in 0 ..< 64 {
            if (layer + 1) % 4 == 0 {
                let n = AttentionCache(); n.copyState(from: c.attentionCache(layer))
                attentionCache(layer, B: batchSize).seqs.append(n)
            } else {
                let src = c.gdnState(layer)
                let dst = gdnState(layer)
                if let conv = dst.conv, let ssm = dst.ssm {
                    dst.conv = concatenated([conv, src.conv!], axis: 0)
                    dst.ssm = concatenated([ssm, src.ssm!], axis: 0)
                } else {
                    dst.conv = src.conv
                    dst.ssm = src.ssm
                }
            }
        }
    }

    /// Remove the sequences at these batch indices (finished requests).
    public func remove(indices drop: Set<Int>) {
        guard !drop.isEmpty else { return }
        let keep = (0 ..< batchSize).filter { !drop.contains($0) }
        let idx = MLXArray(keep.map { Int32($0) })
        for (_, c) in attention {
            c.seqs = keep.map { c.seqs[$0] }
        }
        for (_, s) in gdn where keep.count > 0 {
            s.conv = s.conv!.take(idx, axis: 0)
            s.ssm = s.ssm!.take(idx, axis: 0)
        }
        if keep.isEmpty {
            for (_, s) in gdn { s.conv = nil; s.ssm = nil }
        }
        batchSize = keep.count
    }

    public func attentionCache(_ layer: Int, B: Int) -> BatchedAttentionCache {
        if let c = attention[layer] { return c }
        let c = BatchedAttentionCache(B: B); attention[layer] = c; return c
    }
    public func gdnState(_ layer: Int) -> GDNState {
        if let s = gdn[layer] { return s }
        let s = GDNState(); gdn[layer] = s; return s
    }
}

public enum BatchModel {
    public static func from(_ caches: [ModelCache]) -> BatchedModelCache {
        let out = BatchedModelCache()
        out.position = caches[0].position
        out.batchSize = caches.count
        for layer in 0 ..< 64 {
            if (layer + 1) % 4 == 0 {
                let cs = caches.map { $0.attentionCache(layer) }
                let c = BatchedAttentionCache(B: caches.count)
                c.seqs = cs.map { src in
                    let n = AttentionCache(); n.copyState(from: src); return n
                }
                out.attention[layer] = c
            } else {
                let ss = caches.map { $0.gdnState(layer) }
                let s = GDNState()
                s.conv = concatenated(ss.map { $0.conv! }, axis: 0)
                s.ssm = concatenated(ss.map { $0.ssm! }, axis: 0)
                out.gdn[layer] = s
            }
        }
        return out
    }

    /// Batched prefill for equally long prompts. Attention gets a causal/per-sequence mask;
    /// GDN uses the blocked prefill kernel with the batch dimension in the grid. Returns the
    /// last-token logits [B,1,vocab] and leaves the cache ready for BatchModel.forward.
    public static func prefill(tokens: [[Int32]], store: WeightStore,
                               cache: BatchedModelCache, layers: Int = 64,
                               chunk: Int = 1024) throws -> MLXArray {
        let B = tokens.count
        guard B > 0, let S = tokens.first?.count, S > 0,
              tokens.allSatisfy({ $0.count == S }) else {
            throw WeightError.missingTensor("batched prefill requires non-empty equal-length prompts")
        }
        var result: MLXArray? = nil
        var start = 0
        while start < S {
            let end = min(start + chunk, S)
            let c = end - start
            let ids = tokens.flatMap { Array($0[start ..< end]) }
            var h = try store.embedding("language_model.model.embed_tokens",
                                        indices: MLXArray(ids).reshaped([B, c]))
            for i in 0 ..< layers {
                h = try DecoderLayer.forwardBatched(h, store: store, layer: i, cache: cache)
            }
            if end == S {
                let last = h[0..., (c - 1) ..< c, 0...]
                let normed = try store.rmsNorm("language_model.model.norm", last)
                result = try store.linear("language_model.lm_head", normed)
            }
            start = end
        }
        cache.batchSize = B
        guard let result else { throw WeightError.missingTensor("empty prefill") }
        return result
    }

    /// One decode step for B sequences (each contributes one token), returning [B,1,vocab].
    public static func forward(tokens: [[Int32]], store: WeightStore,
                               cache: BatchedModelCache, layers: Int = 64) throws -> MLXArray {
        let B = tokens.count
        let idx = MLXArray(tokens.map { $0[0] }).reshaped([B, 1])
        var h = try store.embedding("language_model.model.embed_tokens", indices: idx)
        for i in 0 ..< layers {
            h = try DecoderLayer.forwardBatched(h, store: store, layer: i, cache: cache)
        }
        let normed = try store.rmsNorm("language_model.model.norm", h)
        return try store.linear("language_model.lm_head", normed)
    }
}

public enum BatchedAttention {
    public static func forward(_ x: MLXArray, store: WeightStore, layer: Int,
                               cache: BatchedAttentionCache) throws -> MLXArray {
        let prefix = "language_model.model.layers.\(layer).self_attn."
        let B = x.shape[0], S = x.shape[1]
        let Hq = 24, Hkv = 4, D = 256, rotaryDim = 64

        let halves = try store.linear(prefix + "q_proj", x)
            .reshaped([B, S, Hq, 2, D]).split(parts: 2, axis: 3)
        let queries0 = halves[0].squeezed(axis: 3)
        let gate = halves[1].squeezed(axis: 3).reshaped([B, S, Hq * D])
        let kProj = try store.linear(prefix + "k_proj", x).reshaped([B, S, Hkv, D])
        let vProj = try store.linear(prefix + "v_proj", x).reshaped([B, S, Hkv, D])
        let qNormW = try store.tensor(prefix + "q_norm.weight")
        let kNormW = try store.tensor(prefix + "k_norm.weight")
        let q = MLXFast.rmsNorm(queries0, weight: qNormW, eps: 1e-6).transposed(0, 2, 1, 3)
        let k = MLXFast.rmsNorm(kProj, weight: kNormW, eps: 1e-6).transposed(0, 2, 1, 3)
        let v = vProj.transposed(0, 2, 1, 3)

        while cache.seqs.count < B { cache.seqs.append(AttentionCache()) }
        // Per sequence: RoPE at its own offset, in-place append into its preallocated
        // buffer, SDPA over its valid prefix (same arithmetic as the B=1 path).
        let maskMode: MLXFast.ScaledDotProductAttentionMaskMode = S > 1 ? .causal : .none
        let scale = pow(Float(D), -0.5)
        var outs: [MLXArray] = []
        outs.reserveCapacity(B)
        for b in 0 ..< B {
            let sc = cache.seqs[b]
            let off = sc.offset
            let qb = MLXFast.RoPE(B == 1 ? q : q[b ..< (b + 1), 0..., 0..., 0...],
                                  dimensions: rotaryDim, traditional: false,
                                  base: 10_000_000, scale: 1.0, offset: off)
            let kb = MLXFast.RoPE(B == 1 ? k : k[b ..< (b + 1), 0..., 0..., 0...],
                                  dimensions: rotaryDim, traditional: false,
                                  base: 10_000_000, scale: 1.0, offset: off)
            let vb = B == 1 ? v : v[b ..< (b + 1), 0..., 0..., 0...]
            let (kk, vv) = sc.append(kb, vb)
            outs.append(MLXFast.scaledDotProductAttention(
                queries: qb, keys: kk, values: vv, scale: scale, mask: maskMode))
        }
        let out = B == 1 ? outs[0] : concatenated(outs, axis: 0)
        let flat = out.transposed(0, 2, 1, 3).reshaped([B, S, Hq * D])
        let gated = Fused.attnGate(flat, gate)
        return try store.linear(prefix + "o_proj", gated)
    }
}

extension DecoderLayer {
    public static func forwardBatched(_ x: MLXArray, store: WeightStore, layer: Int,
                                      cache: BatchedModelCache) throws -> MLXArray {
        let p = "language_model.model.layers.\(layer)."
        let n1 = try store.rmsNorm(p + "input_layernorm", x)
        let mixed: MLXArray
        if (layer + 1) % 4 != 0 {
            mixed = try GDN.forward(n1, store: store, layer: layer, state: cache.gdnState(layer))
        } else {
            mixed = try BatchedAttention.forward(n1, store: store, layer: layer,
                                                 cache: cache.attentionCache(layer, B: x.shape[0]))
        }
        let h = x + mixed
        let n2 = try store.rmsNorm(p + "post_attention_layernorm", h)
        return h + (try MLP.forward(n2, store: store, layer: layer))
    }
}
