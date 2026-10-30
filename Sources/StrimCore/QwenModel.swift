import Foundation
import MLX

/// CPU-only completed-round accounting. Positions are one-based; the bounded counters
/// cover depths 1...4. Larger experimental depths are counted in overflowProposed.
/// A cancelled/failed round is never recorded. No token/logit/device access here.
public struct MTPStats: Sendable, Equatable, Codable {
    public static let positionLimit = 4
    // Scalar storage keeps stream snapshots and per-round deltas allocation-free.
    private var proposed1 = 0, proposed2 = 0, proposed3 = 0, proposed4 = 0
    private var reached1 = 0, reached2 = 0, reached3 = 0, reached4 = 0
    private var acceptedPrefix1 = 0, acceptedPrefix2 = 0, acceptedPrefix3 = 0, acceptedPrefix4 = 0
    public var proposed: [Int] { [proposed1, proposed2, proposed3, proposed4] }
    public var reached: [Int] { [reached1, reached2, reached3, reached4] }
    public var acceptedPrefix: [Int] { [acceptedPrefix1, acceptedPrefix2, acceptedPrefix3, acceptedPrefix4] }
    public private(set) var rounds = 0
    public private(set) var emitted = 0
    public private(set) var overflowProposed = 0
    public init() {}

    public mutating func recordRound(depth: Int, accepted: Int) {
        let depth = max(depth, 0)
        let a = min(max(accepted, 0), depth)
        rounds += 1
        emitted += a + 1
        overflowProposed += max(0, depth - Self.positionLimit)
        if depth >= 1 {
            proposed1 += 1
            reached1 += 1
            if a >= 1 { acceptedPrefix1 += 1 }
        }
        if depth >= 2 {
            proposed2 += 1
            if a >= 1 { reached2 += 1 }
            if a >= 2 { acceptedPrefix2 += 1 }
        }
        if depth >= 3 {
            proposed3 += 1
            if a >= 2 { reached3 += 1 }
            if a >= 3 { acceptedPrefix3 += 1 }
        }
        if depth >= 4 {
            proposed4 += 1
            if a >= 3 { reached4 += 1 }
            if a >= 4 { acceptedPrefix4 += 1 }
        }
    }

    public mutating func add(_ other: MTPStats) {
        rounds += other.rounds; emitted += other.emitted
        overflowProposed += other.overflowProposed
        proposed1 += other.proposed1; proposed2 += other.proposed2
        proposed3 += other.proposed3; proposed4 += other.proposed4
        reached1 += other.reached1; reached2 += other.reached2
        reached3 += other.reached3; reached4 += other.reached4
        acceptedPrefix1 += other.acceptedPrefix1; acceptedPrefix2 += other.acceptedPrefix2
        acceptedPrefix3 += other.acceptedPrefix3; acceptedPrefix4 += other.acceptedPrefix4
    }

    /// Both snapshots must belong to the same stream lifetime, in time order.
    public func delta(since previous: MTPStats) -> MTPStats {
        var result = self
        result.rounds -= previous.rounds; result.emitted -= previous.emitted
        result.overflowProposed -= previous.overflowProposed
        result.proposed1 -= previous.proposed1; result.proposed2 -= previous.proposed2
        result.proposed3 -= previous.proposed3; result.proposed4 -= previous.proposed4
        result.reached1 -= previous.reached1; result.reached2 -= previous.reached2
        result.reached3 -= previous.reached3; result.reached4 -= previous.reached4
        result.acceptedPrefix1 -= previous.acceptedPrefix1; result.acceptedPrefix2 -= previous.acceptedPrefix2
        result.acceptedPrefix3 -= previous.acceptedPrefix3; result.acceptedPrefix4 -= previous.acceptedPrefix4
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case proposed, reached, acceptedPrefix, rounds, emitted, overflowProposed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(proposed, forKey: .proposed)
        try container.encode(reached, forKey: .reached)
        try container.encode(acceptedPrefix, forKey: .acceptedPrefix)
        try container.encode(rounds, forKey: .rounds)
        try container.encode(emitted, forKey: .emitted)
        try container.encode(overflowProposed, forKey: .overflowProposed)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let proposed = try container.decode([Int].self, forKey: .proposed)
        let reached = try container.decode([Int].self, forKey: .reached)
        let acceptedPrefix = try container.decode([Int].self, forKey: .acceptedPrefix)
        for (key, count) in [(CodingKeys.proposed, proposed.count), (.reached, reached.count), (.acceptedPrefix, acceptedPrefix.count)] {
            guard count == Self.positionLimit else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container,
                                                       debugDescription: "Expected \(Self.positionLimit) position counters")
            }
        }
        proposed1 = proposed[0]; proposed2 = proposed[1]; proposed3 = proposed[2]; proposed4 = proposed[3]
        reached1 = reached[0]; reached2 = reached[1]; reached3 = reached[2]; reached4 = reached[3]
        acceptedPrefix1 = acceptedPrefix[0]; acceptedPrefix2 = acceptedPrefix[1]
        acceptedPrefix3 = acceptedPrefix[2]; acceptedPrefix4 = acceptedPrefix[3]
        rounds = try container.decode(Int.self, forKey: .rounds)
        emitted = try container.decode(Int.self, forKey: .emitted)
        overflowProposed = try container.decode(Int.self, forKey: .overflowProposed)
    }
}

public struct SpecStats {
    public var mtp = MTPStats()
    public var emitted = 0
    public var passes = 0
    public var drafts = 0
    public var acceptedDrafts = 0
    public var promptTokens = 0
    public var seconds = 0.0
    /// Time spent on the prompt forward, excluded from the decode-only rate.
    public var prefillSeconds = 0.0
    public init() {}
    public var acceptRate: Double { drafts == 0 ? 0 : Double(acceptedDrafts) / Double(drafts) }
    public var msPerPass: Double { passes == 0 ? 0 : seconds / Double(passes) * 1000 }
    public var tokensPerPass: Double { passes == 0 ? 0 : Double(emitted) / Double(passes) }
    public var tokensPerSecond: Double { seconds == 0 ? 0 : Double(emitted) / seconds }
    public var decodeTokensPerSecond: Double {
        let d = seconds - prefillSeconds
        return d > 0 ? Double(emitted) / d : 0
    }
    public var summary: String {
        String(format: "passes %d  emitted %d  %.2f tok/pass  %.1f tok/s  %.1f decode  accept %.0f%% (%d/%d)  %.1f ms/pass  %.2fs",
               passes, emitted, tokensPerPass, tokensPerSecond, decodeTokensPerSecond,
               acceptRate * 100, acceptedDrafts, drafts, msPerPass, seconds)
    }
}

public enum QwenModel {
    /// Pipelined graph build: `asyncEval(h)` after every N-th layer of a decode / verify pass lets the GPU
    /// start while the host builds and encodes the remaining layers (hides the ~3 ms build). `STRIM_PIPE_LAYERS=N`
    /// sets N for decode and verify (M <= 8 rows) and batched decode; 0 = off. `STRIM_PIPE_PREFILL_LAYERS=N`
    /// does the same for prefill-sized chunks (default 0: GPU-bound, no gain). asyncEval never changes numerics.
    static func pipeEnv(_ key: String, _ def: Int) -> Int { max(Int(ProcessInfo.processInfo.environment[key] ?? "") ?? def, 0) }
    nonisolated(unsafe) public static var pipeEvery = pipeEnv("STRIM_PIPE_LAYERS", 4)
    nonisolated(unsafe) public static var pipePrefillEvery = pipeEnv("STRIM_PIPE_PREFILL_LAYERS", 0)
    @inline(__always) static func pipe(_ h: MLXArray, layer i: Int, of layers: Int, rows: Int) {
        let n = rows <= 8 ? pipeEvery : pipePrefillEvery
        if n > 0, (i + 1) % n == 0, i < layers - 1 { asyncEval(h) }
    }

    /// Limit speculative drafts so a verify round cannot exceed the output budget.
    static func draftDepth(_ requested: Int, remainingTokens: Int) -> Int {
        min(max(requested, 0), max(remainingTokens - 1, 0))
    }

    /// Forward a chunk of tokens, updating `cache`; returns logits for the last position.
    public static func forward(tokens: [Int32], store: WeightStore, cache: ModelCache? = nil,
                               layers: Int = 64) throws -> (hidden: MLXArray, logits: MLXArray) {
        var h = try store.embedding("language_model.model.embed_tokens", tokens: tokens)
            .reshaped([1, tokens.count, 5120])
        for i in 0 ..< layers {
            h = try DecoderLayer.forward(h, store: store, layer: i, cache: cache)
            pipe(h, layer: i, of: layers, rows: tokens.count)
        }
        let hidden = h
        h = try store.rmsNorm("language_model.model.norm", h)
        let logits = try store.linear("language_model.lm_head", h)
        cache?.position += tokens.count
        return (hidden, logits[0, tokens.count - 1])
    }

    public static func forwardAll(tokens: [Int32], store: WeightStore, cache: ModelCache,
                                  layers: Int = 64,
                                  lastTokenOnly: Bool = false) throws -> (hidden: MLXArray, logits: MLXArray) {
        let h = try OpTimer.time("embed", bytes: Double(tokens.count * 5120 * 2)) {
            try store.embedding("language_model.model.embed_tokens", tokens: tokens)
                .reshaped([1, tokens.count, 5120])
        }
        return try forwardAll(embedded: h, count: tokens.count, store: store, cache: cache,
                              layers: layers, lastTokenOnly: lastTokenOnly)
    }

    /// `forwardAll` with the token ids as a device array (`[n]` or `[1,n]`, possibly still
    /// the lazy output of a draft chain), so a verify pass can be built and queued
    /// without a host read of the drafts. Same embedding rows, same arithmetic.
    public static func forwardAll(indices: MLXArray, store: WeightStore, cache: ModelCache,
                                  layers: Int = 64,
                                  lastTokenOnly: Bool = false) throws -> (hidden: MLXArray, logits: MLXArray) {
        let n = indices.size
        let h = try OpTimer.time("embed", bytes: Double(n * 5120 * 2)) {
            try store.embedding("language_model.model.embed_tokens", indices: indices)
                .reshaped([1, n, 5120])
        }
        return try forwardAll(embedded: h, count: n, store: store, cache: cache,
                              layers: layers, lastTokenOnly: lastTokenOnly)
    }

    private static func forwardAll(embedded: MLXArray, count: Int, store: WeightStore, cache: ModelCache,
                                   layers: Int, lastTokenOnly: Bool) throws -> (hidden: MLXArray, logits: MLXArray) {
        var h = embedded
        for i in 0 ..< layers {
            h = try DecoderLayer.forward(h, store: store, layer: i, cache: cache)
            pipe(h, layer: i, of: layers, rows: count)
        }
        let hidden = h
        // Prefill only needs the last position's logits. Computing lm_head over every
        // prompt token is ~100 ms at 4K and allocates [1,S,152K]; verify needs them all.
        let hIn = lastTokenOnly ? h[0..., (count - 1) ..< count, 0...] : h
        let normed = try OpTimer.time("norm", flops: Double(hIn.size) * 4, bytes: Double(hIn.nbytes * 2),
                                      inputs: [h]) {
            try store.rmsNorm("language_model.model.norm", hIn)
        }
        let logits = try OpTimer.linear(store, "lm_head", "language_model.lm_head", normed)
        cache.position += count
        return (hidden, logits)
    }

    /// How a draft chain gets the next token id. `.index` keeps token ids on the GPU
    /// (one materialisation per round, right before the verify pass); `.host` is the
    /// original per-draft `.item()` chain, kept for interleaved A/B.
    public enum DraftChain: String, Sendable {
        case index
        case host
    }

    /// `STRIM_MTP_HOST=1` restores the per-draft sync path for A/B; the no-sync path
    /// is the default because it strictly removes host round trips.
    public static let defaultDraftChain: DraftChain =
        ProcessInfo.processInfo.environment["STRIM_MTP_HOST"] != nil ? .host : .index

    /// Adaptive depth: stays at 2 unless recent acceptance is high enough to try 3
    /// (code-shaped prompts). Corpus 2026-10-26: +7.4% mean, +11.3% on code, same 7/8
    /// EXACT; depth 1 never won, so it never goes below 2. `STRIM_MTP_FIXED=1` disables.
    public static let defaultAdaptiveDepth =
        ProcessInfo.processInfo.environment["STRIM_MTP_FIXED"] == nil
    /// Ceiling for adaptive depth. Depth 4 only pays at very high acceptance; the
    /// controller uses a stricter climb threshold above depth 3.
    public static let defaultMaxDepth =
        Int(ProcessInfo.processInfo.environment["STRIM_MTP_MAX_DEPTH"] ?? "") ?? 4

    /// Speculative greedy decode with `depth` MTP drafts per verify pass.
    ///
    /// Each round feeds `[b, d1, ..., dk]` to the target. `b` is the target's own
    /// next token (always accepted); drafts are accepted while the target's argmax
    /// after each prefix matches. The rejected suffix is dropped from the target
    /// cache exactly (KV slice for attention, per-token state history for GDN), so no
    /// token is ever re-forwarded and the output equals greedy decoding token for token.
    ///
    /// The MTP head keeps its own KV cache over the shifted stream and is re-seeded
    /// after every round with the verified hiddens, so drafts keep full context.
    public static func generateSpec(prompt: [Int32], maxTokens: Int, store: WeightStore,
                                    head: WeightStore, depth: Int = 2, layers: Int = 64,
                                    chain: DraftChain = QwenModel.defaultDraftChain,
                                    adaptive: Bool = QwenModel.defaultAdaptiveDepth,
                                    maxDepth: Int = QwenModel.defaultMaxDepth,
                                    onRound: ((Int, Int, [Int32]) -> Void)? = nil) throws -> ([Int32], SpecStats) {
        var stats = SpecStats()
        stats.promptTokens = prompt.count
        guard maxTokens > 0 else { return (prompt, stats) }
        let t0 = Date()
        let cache = ModelCache()
        let (hidden, logits) = try forwardAll(tokens: prompt, store: store, cache: cache,
                                              layers: layers, lastTokenOnly: true)
        var out = prompt
        let b = Int32(argMax(logits[0, 0]).item(Int32.self))
        let mtp = MTPState()
        var lastHidden: MLXArray? = nil
        if depth > 0 && maxTokens > 1 {
            try SpecStream.seedHead(tokens: prompt, next: b, hidden: hidden, store: store,
                                    head: head, mtp: mtp, chain: chain)
            lastHidden = try store.rmsNorm("language_model.model.norm",
                                           hidden[0..., (prompt.count - 1) ..< prompt.count, 0...])
            // Force the lazy head seed so prefillSeconds covers it (decode_tok_s excludes it).
            if let s = mtp.seedHidden { eval(s) }
            if let t = mtp.seedTokenIndex { eval(t) }
            if let k = mtp.attention.keys, let v = mtp.attention.values { eval(k, v) }
        }
        stats.prefillSeconds = Date().timeIntervalSince(t0)
        let stream = SpecStream(store: store, head: head, cache: cache, mtp: mtp, seedToken: b,
                                lastHidden: lastHidden, depth: depth, layers: layers, chain: chain,
                                adaptive: adaptive, maxDepth: maxDepth, maintainHead: false)
        stream.onRound = onRound
        while out.count - prompt.count < maxTokens {
            out.append(contentsOf: try stream.step(remaining: maxTokens - (out.count - prompt.count)))
        }
        stats.emitted = stream.stats.emitted
        stats.passes = stream.stats.passes
        stats.drafts = stream.stats.drafts
        stats.acceptedDrafts = stream.stats.acceptedDrafts
        stats.mtp = stream.stats.mtp
        stats.seconds = Date().timeIntervalSince(t0)
        stream.printTiming()
        return (out, stats)
    }

    /// Greedy MTP decode (depth 2 by default).
    public static func generateMTP(prompt: [Int32], maxTokens: Int, store: WeightStore,
                                   head: WeightStore, layers: Int = 64) throws -> [Int32] {
        try generateSpec(prompt: prompt, maxTokens: maxTokens, store: store, head: head,
                         depth: 2, layers: layers).0
    }

    public static func logits(tokens: [Int32], store: WeightStore, cache: ModelCache? = nil,
                              layers: Int = 64) throws -> MLXArray {
        try forward(tokens: tokens, store: store, cache: cache, layers: layers).logits
    }

    public static func lastLogits(tokens: [Int32], store: WeightStore, layers: Int = 64) throws -> MLXArray {
        try logits(tokens: tokens, store: store, cache: nil, layers: layers)
    }

    /// Greedy decode: prefill prompt, then one token per step using the cache.
    public static func generate(prompt: [Int32], maxTokens: Int, store: WeightStore,
                                layers: Int = 64) throws -> [Int32] {
        let cache = ModelCache()
        var ids = prompt
        var out = try logits(tokens: prompt, store: store, cache: cache, layers: layers)
        for _ in 0 ..< maxTokens {
            let next = Int32(argMax(out).item(Int32.self))
            ids.append(next)
            out = try logits(tokens: [next], store: store, cache: cache, layers: layers)
        }
        return ids
    }
}
