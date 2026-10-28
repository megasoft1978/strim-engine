import Foundation
import MLX
import MLXRandom

/// Sampling parameters for lossless speculative sampling. `temperature <= 0` is greedy
/// (callers keep the exact-argmax rule; this file is never used for it).
public struct SamplingConfig: Sendable, Equatable {
    public var temperature: Float
    public var topK: Int
    public var topP: Float
    public var seed: UInt64
    public init(temperature: Float, topK: Int = 0, topP: Float = 1, seed: UInt64) {
        self.temperature = temperature; self.topK = topK; self.topP = topP; self.seed = seed
    }
}

/// Lossless speculative sampling for a deterministic (one-hot) draft.
///
/// For a verified row with target logits `z` and draft `d`: P = top_p(top_k(softmax(z / T))),
/// accept `d` with probability P(d); on rejection emit a sample from P with d's mass removed
/// (the residual, normalised implicitly by Gumbel-max); after k accepted drafts emit a bonus
/// sample from P at the last row. Marginally every emitted token ~ P.
///
/// Randomness: each output position j gets key = MLXRandom.key(splitmix64(seed, j)) (a fold-in),
/// from which ONE uniform draw of shape [V+1] supplies the accept test (element V) and the
/// Gumbel noise (elements 0..<V, indexed by token id) for that position. Everything runs on
/// device; `verify` returns lazy scalars so the caller does a single host sync per round.
public enum SpecSampling {
    static func mix(_ seed: UInt64, _ position: Int) -> UInt64 {
        var z = seed &+ 0x9E37_79B9_7F4A_7C15 &* (UInt64(truncatingIfNeeded: position) &+ 1)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform noise `[positions.count, vocab + 1]` in [0,1), row r keyed by (seed, positions[r]).
    public static func noise(seed: UInt64, positions: [Int], vocab: Int) -> MLXArray {
        let rows = positions.map { MLXRandom.uniform(low: 0, high: 1, [vocab + 1], key: MLXRandom.key(mix(seed, $0))) }
        return rows.count == 1 ? rows[0].reshaped([1, vocab + 1]) : stacked(rows, axis: 0)
    }

    /// Filtered distribution as candidates: `ids [R,C]` (token ids, descending logit) and
    /// `logp [R,C]` (log-probabilities of the filtered, renormalised P; -inf outside the nucleus).
    public static func filtered(logits: MLXArray, temperature: Float, topK: Int, topP: Float) -> (ids: MLXArray, logp: MLXArray) {
        let l = logits.asType(.float32) / temperature
        let V = l.shape[l.ndim - 1]
        var ids: MLXArray
        var vals: MLXArray
        if topK > 0 && topK < V {
            let cand = argPartition(-l, kth: topK - 1, axis: -1)[0..., 0 ..< topK]
            let cv = takeAlong(l, cand, axis: -1)
            let o = argSort(-cv, axis: -1)
            ids = takeAlong(cand, o, axis: -1)
            vals = takeAlong(cv, o, axis: -1)
        } else if topP < 1 {
            ids = argSort(-l, axis: -1)
            vals = takeAlong(l, ids, axis: -1)
        } else {
            ids = broadcast(MLXArray(0 ..< Int32(V)).reshaped([1, V]), to: l.shape)
            vals = l
        }
        if topP < 1 {
            let probs = softmax(vals, axis: -1)
            let before = cumsum(probs, axis: -1) - probs            // mass strictly before each token
            vals = MLX.where(before .> topP, MLXArray(-Float.infinity), vals)
        }
        return (ids.asType(.int32), vals - logSumExp(vals, axis: -1, keepDims: true))
    }

    /// Per-row speculative-sampling outcome for `R` rows (rows are independent).
    /// - `drafts[r]` is the draft proposed for that row, or < 0 for none (bonus row).
    /// - returns `accept[r]` (draft accepted; false when no draft) and `token[r]`: the residual
    ///   sample (draft's mass removed) when a draft exists, else a plain sample from P.
    public static func rowOutcome(logits: MLXArray, drafts: MLXArray, noise: MLXArray,
                                  temperature: Float, topK: Int, topP: Float) -> (accept: MLXArray, token: MLXArray) {
        let V = logits.shape[logits.ndim - 1]
        let (ids, logp) = filtered(logits: logits, temperature: temperature, topK: topK, topP: topP)
        let u = noise[0..., 0 ..< V]
        let gumbel = -MLX.log(-MLX.log(MLX.maximum(u, MLXArray(Float(1e-30)))))
        let g = takeAlong(gumbel, ids, axis: -1)
        let eq = ids .== drafts.asType(.int32).reshaped([-1, 1])
        let pd = sum(MLX.where(eq, exp(logp), MLXArray(Float(0))), axis: -1)
        let accept = noise[0..., V] .< pd
        let scores = MLX.where(eq, MLXArray(-Float.infinity), logp) + g
        let pick = argMax(scores, axis: -1)
        let token = takeAlong(ids, pick.reshaped([-1, 1]), axis: -1).reshaped([-1])
        return (accept, token)
    }

    /// One verify round. `logits` is `[k+1, V]` (row i = target distribution after feed[i]),
    /// `drafts` the k proposed tokens, the token decided by row i sits at output position
    /// `firstIndex + i`. Returns lazy scalars (accepted draft count, next pending token).
    public static func verify(logits rawLogits: MLXArray, drafts: [Int32], config c: SamplingConfig,
                              firstIndex: Int, mask: MLXArray? = nil) -> (accepted: MLXArray, token: MLXArray) {
        let logits = mask.map { maskLogits(rawLogits, $0) } ?? rawLogits
        let k = drafts.count
        let V = logits.shape[logits.ndim - 1]
        let nz = noise(seed: c.seed, positions: Array(firstIndex ..< firstIndex + k + 1), vocab: V)
        let d = MLXArray(drafts + [-1])
        let (accept, tok) = rowOutcome(logits: logits, drafts: d, noise: nz,
                                       temperature: c.temperature, topK: c.topK, topP: c.topP)
        let n: MLXArray = k > 0
            ? cumprod(accept[0 ..< k].asType(.int32), axis: 0).sum()
            : MLXArray(Int32(0))
        return (n, tok[n])
    }

    /// Plain sample (no draft) from one position's logits `[V]` at output position `index`.
    public static func sample(logits rawLogits: MLXArray, config c: SamplingConfig, index: Int, mask: MLXArray? = nil) -> MLXArray {
        let logits = mask.map { maskLogits(rawLogits, $0) } ?? rawLogits
        let V = logits.shape[logits.ndim - 1]
        let nz = noise(seed: c.seed, positions: [index], vocab: V)
        let (_, tok) = rowOutcome(logits: logits.reshaped([1, V]), drafts: MLXArray([Int32(-1)]), noise: nz,
                                  temperature: c.temperature, topK: c.topK, topP: c.topP)
        return tok[0]
    }
}
