import Foundation
import MLX
import MLXRandom
import StrimCore

/// Temperature / top-k / top-p sampling with a per-request seeded PRNG key. Greedy requests
/// never touch this (plain argmax, and MTP speculation stays available).
struct Sampler {
    let temperature: Float
    let topK: Int
    let topP: Float
    private var key: MLXArray
    /// Resolved request seed; position-keyed speculative sampling derives from it.
    let seed: UInt64

    init(params: GenParams) {
        temperature = params.temperature
        topK = params.topK
        topP = params.topP
        seed = params.seed ?? UInt64.random(in: 0 ... UInt64.max)
        key = MLXRandom.key(seed)
    }

    /// Config for `SpecSampling` / `SpecStream.enableSampling`.
    var config: SamplingConfig { SamplingConfig(temperature: temperature, topK: topK, topP: topP, seed: seed) }

    /// Output token 0 (from the prefill logits `[vocab]`), drawn with the position-keyed scheme
    /// so the speculative stream continues at index 1. Syncs.
    func sampleFirst(_ logits: MLXArray) -> Int32 {
        SpecSampling.sample(logits: logits, config: config, index: 0).item(Int32.self)
    }

    /// Next token from one position's logits `[vocab]`. Syncs (reads the id back).
    mutating func sample(_ logits: MLXArray) -> Int32 {
        let (next, use) = MLXRandom.split(key: key)
        key = next
        var l = logits.asType(.float32) / temperature
        let V = l.shape[l.ndim - 1]
        if topK > 0 && topK < V {
            // keep the k largest: threshold at the k-th largest value
            let kth = sorted(l, axis: -1)[V - topK]
            l = MLX.where(l .< kth, MLXArray(-Float.infinity), l)
        }
        if topP < 1 {
            let order = argSort(l, axis: -1)[.stride(by: -1)]          // descending
            let sl = takeAlong(l, order, axis: -1)
            let probs = softmax(sl, axis: -1)
            let before = cumsum(probs, axis: -1) - probs               // mass before each token
            let masked = MLX.where(before .> topP, MLXArray(-Float.infinity), sl)
            let pick = MLXRandom.categorical(masked, key: use)
            return Int32(order[pick].item(Int32.self))
        }
        return Int32(MLXRandom.categorical(l, key: use).item(Int32.self))
    }
}
