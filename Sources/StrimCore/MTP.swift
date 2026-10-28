import Foundation
import MLX

public final class MTPState {
    public let attention = AttentionCache()
    /// Host token id, only used by the sync (`DraftChain.host`) path.
    public var seedToken: Int32 = -1
    /// GPU token id for the seed draft, kept unevaluated by the no-sync path so the
    /// next round's draft chain does not round-trip to the host between steps.
    public var seedTokenIndex: MLXArray?
    public var seedHidden: MLXArray?

    public init() {}
    public var position: Int { attention.offset }

    /// Drop MTP cache entries above `n` (speculative entries that were not verified).
    public func trim(to n: Int) {
        let drop = attention.offset - n
        if drop > 0 { attention.rollback(drop) }
    }
}

/// Qwen3.8 multi-token-prediction head: a one-layer transformer over the shifted
/// sequence. Entry `i` pairs the target backbone's hidden state at position `i`
/// with token `i+1`, and predicts token `i+2`; the head keeps its own KV cache so
/// drafts see the whole context instead of a single position.
public enum MTP {
    public static func forward(hidden: MLXArray, token: Int32, target: WeightStore,
                               head: WeightStore, state: MTPState, position: Int = 0) throws -> MLXArray {
        try logits(for: step(tokens: [token], hidden: hidden, target: target, head: head, state: state),
                   target: target, head: head)
    }

    /// Run the head over `tokens` (length n) with the target hiddens `hidden` ([1,n,5120]).
    /// Appends n entries to `state`'s cache and returns the head's output hidden [1,n,5120].
    public static func step(tokens: [Int32], hidden: MLXArray, target: WeightStore,
                            head: WeightStore, state: MTPState) throws -> MLXArray {
        let n = tokens.count
        let emb = try target.embedding("language_model.model.embed_tokens", tokens: tokens)
            .reshaped([1, n, 5120])
        let e = try head.rmsNorm("pre_fc_norm_embedding", emb)
        let h = try head.rmsNorm("pre_fc_norm_hidden", hidden)
        var x = try head.linear("fc", concatenated([e, h], axis: -1))

        let n1 = try head.rmsNorm("layers.0.input_layernorm", x)
        x = x + (try Attention.forward(n1, store: head, prefix: "layers.0.self_attn.",
                                       cache: state.attention))
        let n2 = try head.rmsNorm("layers.0.post_attention_layernorm", x)
        x = x + (try MLP.forward(n2, store: head, prefix: "layers.0.mlp."))
        return x
    }

    public static func logits(for hidden: MLXArray, target: WeightStore,
                              head: WeightStore) throws -> MLXArray {
        try target.linear("language_model.lm_head", head.rmsNorm("norm", hidden))
    }

    /// GPU-index variant of `step`: `tokens` is an int array (`[n]` or `[1,n]`) that
    /// may still be the lazy output of an `argMax`, so a draft chain can run without a
    /// host sync between steps. All arithmetic is identical to `step`.
    public static func stepIndex(tokens: MLXArray, hidden: MLXArray, target: WeightStore,
                                 head: WeightStore, state: MTPState) throws -> MLXArray {
        let n = tokens.size
        let emb = try target.embedding("language_model.model.embed_tokens", indices: tokens)
            .reshaped([1, n, 5120])
        let e = try head.rmsNorm("pre_fc_norm_embedding", emb)
        let h = try head.rmsNorm("pre_fc_norm_hidden", hidden)
        var x = try head.linear("fc", concatenated([e, h], axis: -1))

        let n1 = try head.rmsNorm("layers.0.input_layernorm", x)
        x = x + (try Attention.forward(n1, store: head, prefix: "layers.0.self_attn.",
                                       cache: state.attention))
        let n2 = try head.rmsNorm("layers.0.post_attention_layernorm", x)
        x = x + (try MLP.forward(n2, store: head, prefix: "layers.0.mlp."))
        return x
    }

    /// Draft-side logits. With `target.draftVocab` set, only the kept lm_head rows are
    /// multiplied, so the last axis is the truncated vocab (map back via `dv.idx`).
    private static func draftLogits(_ hidden: MLXArray, target: WeightStore,
                                    head: WeightStore) throws -> (MLXArray, DraftVocab?) {
        guard let dv = target.draftVocab else {
            return (try logits(for: hidden, target: target, head: head), nil)
        }
        return (target.qmm(try head.rmsNorm("norm", hidden), dv.w, dv.s, dv.b), dv)
    }

    /// `argMax` of the last position's logits as an `MLXArray` (`[1,1]`), for feeding
    /// straight back into `stepIndex`/the embedding lookup without `.item()`.
    public static func nextTokenIndex(_ hidden: MLXArray, target: WeightStore,
                                      head: WeightStore) throws -> MLXArray {
        let (lg, dv) = try draftLogits(hidden, target: target, head: head)
        let last = lg.shape[1] - 1
        let am = argMax(lg[0..., last ..< (last + 1), 0...], axis: -1)
        guard let dv else { return am }
        return dv.idx.take(am, axis: 0)
    }

    /// The hidden the drafter chains on: the head's final norm, exactly as the
    /// reference drafter returns from its layer stack.
    public static func normalized(_ x: MLXArray, head: WeightStore) throws -> MLXArray {
        try head.rmsNorm("norm", x)
    }

    /// Next-token argmax for an already-computed head output (last position).
    public static func nextToken(_ hidden: MLXArray, target: WeightStore,
                                 head: WeightStore) throws -> Int32 {
        let (lg, dv) = try draftLogits(hidden, target: target, head: head)
        let am = argMax(lg[0, lg.shape[1] - 1])
        return Int32((dv.map { $0.idx.take(am, axis: 0) } ?? am).item(Int32.self))
    }
}
