import Foundation
import MLX

public enum SpecStreamError: Error, CustomStringConvertible {
    case cancelled
    case failed
    case headNotSeeded
    case headStale(String)
    public var description: String {
        switch self {
        case .cancelled: return "SpecStream cancelled"
        case .failed: return "SpecStream failed earlier; state is undefined"
        case .headNotSeeded: return "MTP head is not seeded (depth > 0 needs mtp.seedHidden and a seed token)"
        case .headStale(let why): return "MTP head cannot be re-seeded: \(why)"
        }
    }
}

/// Resumable speculative greedy decode over an EXTERNAL `ModelCache` + `MTPState`.
///
/// One `step` is one verify round (draft chain, verify pass, exact rollback, head replay)
/// and returns the verified tokens it emitted. State (cache, mtp, pending token, adaptive
/// depth controller) lives in the object, so a session can interleave `step` calls with
/// anything else, or append a new turn (`appendTokens` / `reseed`) and keep decoding.
///
/// Invariant between steps: `cache.position` tokens are in the cache, `pending` is the
/// target's next token (not yet in the cache), and with depth > 0 the head holds
/// `cache.position` entries and is seeded for the next draft round.
public final class SpecStream {
    public let store: WeightStore
    public let head: WeightStore
    public let cache: ModelCache
    public let mtp: MTPState
    public let depth: Int
    public let layers: Int
    public let chain: QwenModel.DraftChain
    public let adaptive: Bool
    public let maxDepth: Int
    /// Keep the head in step on the depth-0 fallback round (remaining == 1). A session
    /// needs it; the one-shot `generateSpec` skips it (nothing follows the last token).
    public let maintainHead: Bool

    /// The target's next token, already decided, not yet in `cache`.
    public private(set) var pending: Int32
    /// Final-normed target hidden at `cache.position - 1`; the head's input for re-seeding.
    public private(set) var lastHidden: MLXArray?
    public var stats = SpecStats()
    /// Lossless speculative sampling (nil = exact greedy). `sampleIndex` is the output position
    /// of the token the next round decides first (pending has index sampleIndex - 1).
    public private(set) var sampling: SamplingConfig?
    public private(set) var sampleIndex = 0

    /// Switch to sampled decode. `pending` must already be the token sampled at output index
    /// `nextIndex - 1` (normally 0, so nextIndex = 1).
    public func enableSampling(_ cfg: SamplingConfig, nextIndex: Int = 1) { sampling = cfg; sampleIndex = nextIndex }
    public func disableSampling() { sampling = nil }
    /// Optional token constraint (grammar / forced tokens). nil: no masking and no extra work per round.
    public var constraint: VerifyConstraint?

    /// Offline diagnostics only. Draft ids are already materialized by verification.
    /// Called only after a successful round; nil on the production/default path.
    public var onRound: ((_ depth: Int, _ accepted: Int, _ drafts: [Int32]) -> Void)?

    private var d: Int
    /// Ceiling of the cost-per-token policy: 3 unless STRIM_MTP_MAX_DEPTH is set (depth 4 lost to fixed 3 on low-acceptance agent prompts, L16).
    private var policyMax: Int { SpecStream.envMaxDepth ? maxDepth : min(maxDepth, 3) }
    private static let envMaxDepth = ProcessInfo.processInfo.environment["STRIM_MTP_MAX_DEPTH"] != nil
    private let minD: Int
    private var acceptEWMA = 0.5
    private var roundsSinceChange = 0
    /// EWMA of P(accepted prefix >= i), i = 1...4 (prior: measured 4K/16K/32K code, STRIM_MTP_FIXED=4 traces, L16).
    private var survival: [Double] = [0.88, 0.75, 0.60, 0.45]
    private let timing: Bool = { let v = ProcessInfo.processInfo.environment["STRIM_TIMING"]; return v != nil && v != "trace" }()
    /// `STRIM_TIMING=trace` (trace only, no timing syncs): one stderr line per speculative round (context, depth used, accepted prefix, round ms).
    private let trace = ProcessInfo.processInfo.environment["STRIM_TIMING"] == "trace"
    private var tDraft = 0.0, tVerify = 0.0, tReseed = 0.0
    private var syncs = 0, draftRounds = 0, depthSum = 0
    /// STRIM_TIMING only: seconds the host spent blocked in a device read (`tWait`) and the
    /// rest of the round, i.e. building graphs and host logic (`tHost`).
    private var tWait = 0.0
    /// Greedy rounds keep the draft tokens on the device and read drafts + target predictions
    /// in ONE host read after the verify pass is queued (opt-in: `STRIM_SPEC_DEVICEFEED=1`; default off, measured below the 1.5 ms/pass gate; unset keeps the
    /// extra read between the draft chain and the verify pass). Same ids, same arithmetic.
    /// `STRIM_MTP_POLICY=legacy` restores the threshold controller (A/B); default is the cost-per-token policy.
    static let ewmaPolicy = ProcessInfo.processInfo.environment["STRIM_MTP_POLICY"] != "legacy"
    static let envDepth: Int? = Int(ProcessInfo.processInfo.environment["STRIM_MTP_DEPTH"] ?? "")
    public static let deviceFeed = ProcessInfo.processInfo.environment["STRIM_SPEC_DEVICEFEED"] != nil

    private let lock = NSLock()
    private var cancelled = false
    private var failed = false

    /// `mtp` must already be seeded (see `seedHead`) when `depth > 0`. `lastHidden` is the
    /// final-normed target hidden at the last cached position.
    public init(store: WeightStore, head: WeightStore, cache: ModelCache, mtp: MTPState,
                seedToken: Int32, lastHidden: MLXArray? = nil, depth: Int = 2, layers: Int = 64,
                chain: QwenModel.DraftChain = QwenModel.defaultDraftChain,
                adaptive: Bool = QwenModel.defaultAdaptiveDepth,
                maxDepth: Int = QwenModel.defaultMaxDepth, maintainHead: Bool = true) {
        self.store = store; self.head = head; self.cache = cache; self.mtp = mtp
        self.pending = seedToken; self.lastHidden = lastHidden
        // Bench knob: STRIM_MTP_DEPTH=N overrides the starting (or, with STRIM_MTP_FIXED=1, the fixed) draft depth.
        let depth = depth > 0 ? (SpecStream.envDepth ?? depth) : depth
        self.depth = depth; self.layers = layers; self.chain = chain
        self.adaptive = adaptive; self.maxDepth = maxDepth; self.maintainHead = maintainHead
        self.d = min(max(depth, 0), maxDepth)
        // Fixed depth 3 beat every other fixed depth and the threshold controller (L16), so start there.
        if adaptive, SpecStream.ewmaPolicy, depth >= 2 { self.d = min(max(self.d, 3), SpecStream.envMaxDepth ? maxDepth : min(maxDepth, 3)) }
        // Depth 1 is never better than 2 on the measured prompts (depth sweep, 2026-10-25),
        // so adaptive only climbs to 3 and falls back to 2.
        self.minD = min(2, maxDepth)
    }

    /// Request cancellation. `step` checks it before touching any state, so the stream
    /// stays consistent (a round is atomic).
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    // MARK: head seeding

    /// Seed `mtp` after a prefill: entry i pairs the target hidden at i with token i+1, the
    /// last entry pairs the last hidden with `next`. `hidden` is the pre-norm target hidden
    /// over `tokens` ([1,n,5120]).
    public static func seedHead(tokens: [Int32], next: Int32, hidden: MLXArray, store: WeightStore,
                                head: WeightStore, mtp: MTPState, chain: QwenModel.DraftChain) throws {
        let shifted = Array(tokens.dropFirst()) + [next]
        let mtpIn = try store.rmsNorm("language_model.model.norm", hidden)
        let o = try MTP.step(tokens: shifted, hidden: mtpIn, target: store, head: head, state: mtp)
        try setSeed(from: o, store: store, head: head, mtp: mtp, chain: chain)
    }

    /// Set the head's seed (hidden + next draft token) from the last row of a head output.
    public static func setSeed(from o: MLXArray, store: WeightStore, head: WeightStore, mtp: MTPState,
                        chain: QwenModel.DraftChain) throws {
        let on = try MTP.normalized(o, head: head)
        let last = o.shape[1] - 1
        let seedHidden = o[0..., last ..< (last + 1), 0...]
        mtp.seedHidden = on[0..., last ..< (last + 1), 0...]
        if chain == .index {
            mtp.seedTokenIndex = try MTP.nextTokenIndex(seedHidden, target: store, head: head)
        } else {
            mtp.seedToken = try MTP.nextToken(seedHidden, target: store, head: head)
        }
    }

    // MARK: decode

    /// One verify round. Returns the verified tokens (>= 1, <= `remaining`).
    public func step(remaining: Int) throws -> [Int32] {
        try Task.checkCancellation()
        if isCancelled { throw SpecStreamError.cancelled }
        if failed { throw SpecStreamError.failed }
        guard remaining > 0 else { return [] }
        do { return try round(remaining: remaining) } catch { failed = true; throw error }
    }

    /// Print the STRIM_TIMING split (no-op unless enabled).
    public func printTiming() {
        guard timing, stats.passes > 0 else { return }
        let n = Double(stats.passes)
        FileHandle.standardError.write(Data(String(
            format: "ms/pass: mtp_draft %.1f, verify %.1f, reseed %.1f, host_wait %.1f, rounds %d, depth avg %.2f, syncs/round %.2f\n",
            tDraft / n * 1000, tVerify / n * 1000, tReseed / n * 1000, tWait / n * 1000,
            stats.passes, Double(depthSum) / Double(max(draftRounds, 1)), Double(syncs) / n).utf8))
    }

    private func round(remaining: Int) throws -> [Int32] {
        let b = pending
        var drafts: [Int32] = []
        var feed: [Int32] = []
        var feedDev: MLXArray? = nil
        var h = mtp.seedHidden
        let tA = Date()
        if adaptive && depth > 0 && roundsSinceChange >= DepthPolicy.holdRounds && SpecStream.ewmaPolicy {
            let nd = DepthPolicy.best(survival: survival, ctx: cache.position, current: d, minD: minD, maxD: policyMax)
            if nd != d { d = nd; roundsSinceChange = 0 }
        } else if adaptive && depth > 0 && !SpecStream.ewmaPolicy && roundsSinceChange >= 2 {
            // Hysteresis: move after two rounds at the current depth. Depth 4
            // costs a longer verify pass, so require higher acceptance to try it.
            let climb = d >= 3 ? 0.84 : 0.82
            if acceptEWMA > climb && d < maxDepth {
                d += 1; roundsSinceChange = 0
            } else if acceptEWMA < 0.60 && d > minD {
                d -= 1; roundsSinceChange = 0
            }
        }
        let roundDepth = QwenModel.draftDepth(d, remainingTokens: remaining)
        if roundDepth > 0 {
            guard h != nil, chain == .host || mtp.seedTokenIndex != nil else { throw SpecStreamError.headNotSeeded }
            let before = mtp.position
            switch chain {
            case .index:
                // Drafts stay on the GPU: each token id is the lazy `argMax` fed
                // straight into the next step's embedding lookup.
                var tokenIndex: [MLXArray] = [mtp.seedTokenIndex!]
                for _ in 1 ..< roundDepth {
                    let o = try MTP.stepIndex(tokens: tokenIndex.last!, hidden: h!,
                                              target: store, head: head, state: mtp)
                    let on = try MTP.normalized(o, head: head)
                    tokenIndex.append(try MTP.nextTokenIndex(o, target: store, head: head))
                    h = on
                }
                var pieces: [MLXArray] = [MLXArray([b])]
                pieces.append(contentsOf: tokenIndex.map { $0.reshaped([1]).asType(.int32) })
                let fd = concatenated(pieces, axis: 0)
                if SpecStream.deviceFeed && sampling == nil && constraint == nil {
                    // Verify consumes the device ids directly; the host reads them together
                    // with the target predictions after the verify pass is queued.
                    feedDev = fd
                } else {
                    // Timing only: materialise the lazy draft chain before tDraft is read.
                    if timing { eval(tokenIndex) }
                    // The host read in the draft chain: sampled verify needs Swift ints.
                    let tW = Date()
                    feed = fd.asArray(Int32.self)
                    tWait += Date().timeIntervalSince(tW)
                    syncs += 1
                    drafts = Array(feed.dropFirst())
                }
            case .host:
                drafts.append(mtp.seedToken)
                for _ in 1 ..< roundDepth {
                    let o = try MTP.step(tokens: [drafts.last!], hidden: h!, target: store,
                                         head: head, state: mtp)
                    let on = try MTP.normalized(o, head: head)
                    drafts.append(try MTP.nextToken(o, target: store, head: head))
                    syncs += 1
                    h = on
                }
                feed = [b] + drafts
            }
            stats.drafts += roundDepth
            draftRounds += 1; depthSum += roundDepth
            tDraft += Date().timeIntervalSince(tA)

            let tB = Date()
            cache.beginVerify()
            let v: (hidden: MLXArray, logits: MLXArray)
            if let fd = feedDev {
                v = try QwenModel.forwardAll(indices: fd, store: store, cache: cache, layers: layers)
            } else {
                v = try QwenModel.forwardAll(tokens: feed, store: store, cache: cache, layers: layers)
            }
            var preds: [Int32] = []
            var accepted = 0
            var nextTok: Int32 = 0
            let vmask = constraint?.verifyMask(drafts: drafts)
            if let sc = sampling {
                let (n, t) = SpecSampling.verify(logits: v.logits[0], drafts: drafts, config: sc, firstIndex: sampleIndex, mask: vmask)
                let tW = Date()
                let r = concatenated([n.reshaped([1]), t.reshaped([1])], axis: 0).asArray(Int32.self)
                tWait += Date().timeIntervalSince(tW)
                syncs += 1
                accepted = Int(r[0]); nextTok = r[1]
                sampleIndex += accepted + 1
            } else {
                let tW = Date()
                if let fd = feedDev {
                    let pd = argMax(v.logits, axis: -1).reshaped([-1]).asType(.int32)
                    let all = concatenated([fd, pd], axis: 0).asArray(Int32.self)
                    let m = roundDepth + 1
                    feed = Array(all.prefix(m))
                    drafts = Array(feed.dropFirst())
                    preds = Array(all.dropFirst(m))
                } else {
                    preds = argMax(vmask.map { maskLogits(v.logits, $0) } ?? v.logits, axis: -1).asArray(Int32.self)
                }
                tWait += Date().timeIntervalSince(tW)
                syncs += 1
                for i in 0 ..< roundDepth {
                    if preds[i] == drafts[i] { accepted += 1 } else { break }
                }
                nextTok = preds[accepted]
            }
            if adaptive {
                for i in 0 ..< min(roundDepth, survival.count) {
                    survival[i] += DepthPolicy.alpha * ((accepted > i ? 1.0 : 0.0) - survival[i])
                }
                acceptEWMA = 0.7 * acceptEWMA + 0.3 * (Double(accepted) / Double(roundDepth))
            }
            roundsSinceChange += 1
            let keep = 1 + accepted
            cache.rollback(drop: feed.count - keep)
            cache.endVerify()
            tVerify += Date().timeIntervalSince(tB)

            if ProcessInfo.processInfo.environment["STRIM_DEBUG"] != nil {
                FileHandle.standardError.write(Data("b=\(b) drafts=\(drafts) preds=\(preds) keep=\(keep) pos=\(cache.position)\n".utf8))
            }
            stats.emitted += keep
            stats.passes += 1
            stats.acceptedDrafts += accepted

            // Rebuild the MTP cache: drop speculative entries, replay accepted
            // drafts with the target's verified hiddens, then seed with the next token.
            let tC = Date()
            mtp.trim(to: before)
            let vNorm = try store.rmsNorm("language_model.model.norm", v.hidden)
            pending = nextTok
            try replayHead(tokens: Array(drafts.prefix(accepted)) + [pending],
                           hidden: vNorm[0..., 0 ..< (accepted + 1), 0...])
            lastHidden = vNorm[0..., accepted ..< (accepted + 1), 0...]
            tReseed += Date().timeIntervalSince(tC)
            if trace {
                FileHandle.standardError.write(Data(String(format: "TRACE ctx=%d d=%d acc=%d ms=%.2f\n", cache.position, roundDepth, accepted, Date().timeIntervalSince(tA) * 1000).utf8))
            }
            stats.mtp.recordRound(depth: roundDepth, accepted: accepted)
            onRound?(roundDepth, accepted, drafts)
            return Array(feed.prefix(keep))
        } else {
            cache.beginVerify()
            let v = try QwenModel.forwardAll(tokens: [b], store: store, cache: cache, layers: layers)
            cache.endVerify()
            let m0 = constraint?.verifyMask(drafts: [])
            if let sc = sampling {
                pending = SpecSampling.sample(logits: v.logits[0, 0], config: sc, index: sampleIndex, mask: m0.map { $0.reshaped([-1]) }).item(Int32.self)
                sampleIndex += 1
            } else {
                pending = argMax(m0.map { maskLogits(v.logits, $0) } ?? v.logits, axis: -1).asArray(Int32.self)[0]
            }
            syncs += 1
            stats.emitted += 1
            stats.passes += 1
            if depth > 0 && maintainHead {
                let vNorm = try store.rmsNorm("language_model.model.norm", v.hidden)
                try replayHead(tokens: [pending], hidden: vNorm)
                lastHidden = vNorm
            }
            stats.mtp.recordRound(depth: 0, accepted: 0)
            onRound?(0, 0, [])
            return [b]
        }
    }

    /// Append head entries for `tokens` (paired with `hidden`, normed target hiddens) and
    /// re-seed the next draft.
    private func replayHead(tokens: [Int32], hidden: MLXArray) throws {
        let replay: MLXArray
        switch chain {
        case .index:
            replay = try MTP.stepIndex(tokens: MLXArray(tokens), hidden: hidden,
                                       target: store, head: head, state: mtp)
        case .host:
            replay = try MTP.step(tokens: tokens, hidden: hidden, target: store, head: head, state: mtp)
        }
        let last = replay.shape[1] - 1
        let seed = replay[0..., last ..< (last + 1), 0...]
        mtp.seedHidden = try MTP.normalized(seed, head: head)
        switch chain {
        case .index:
            mtp.seedTokenIndex = try MTP.nextTokenIndex(seed, target: store, head: head)
        case .host:
            mtp.seedToken = try MTP.nextToken(seed, target: store, head: head)
            syncs += 1
        }
        // Timing only: materialise the replay and seed before tReseed is read.
        if timing {
            if let s = mtp.seedHidden { eval(s) }
            if let t = mtp.seedTokenIndex { eval(t) }
        }
    }

    // MARK: hot session continuation

    /// New turn: prefill `tokens` onto the existing cache in `chunk`-token pieces, then
    /// re-seed. `tokens` normally starts with `pending` (the token the previous turn
    /// ended on, which is not in the cache yet). Returns the last-position logits.
    @discardableResult
    public func appendTokens(_ tokens: [Int32], chunk: Int = PrefixPrefill.chunk) throws -> MLXArray {
        try Task.checkCancellation()
        if isCancelled { throw SpecStreamError.cancelled }
        if failed { throw SpecStreamError.failed }
        guard !tokens.isEmpty, chunk > 0 else { throw SpecStreamError.headStale("empty append") }
        do {
            var hs: [MLXArray] = []
            var logits: MLXArray! = nil
            var pos = 0
            while pos < tokens.count {
                let end = min(pos + chunk, tokens.count)
                let r = try QwenModel.forwardAll(tokens: Array(tokens[pos ..< end]), store: store, cache: cache,
                                                 layers: layers, lastTokenOnly: true)
                hs.append(r.hidden)
                logits = r.logits
                eval(r.hidden, cache)
                pos = end
            }
            let hidden = hs.count == 1 ? hs[0] : concatenated(hs, axis: 1)
            let next = Int32(argMax(logits[0, 0]).item(Int32.self))
            try reseed(appended: tokens, hidden: hidden, nextToken: next)
            return logits[0, 0]
        } catch { failed = true; throw error }
    }

    /// Resume decoding after an external prefill appended `appended` to `cache` (so
    /// `cache.position` already includes them). `hidden` is the pre-norm target hidden
    /// over the appended tokens ([1,m,5120]); `nextToken` is the argmax after the last one.
    public func reseed(appended: [Int32], hidden: MLXArray, nextToken: Int32) throws {
        let m = appended.count
        let p0 = cache.position - m
        guard m > 0, p0 >= 0, hidden.shape[1] == m else { throw SpecStreamError.headStale("bad append shape") }
        pending = nextToken
        guard depth > 0 else { lastHidden = nil; return }
        let hn = try store.rmsNorm("language_model.model.norm", hidden)
        var tokens: [Int32]
        var hid: MLXArray
        if p0 == 0 {
            mtp.trim(to: 0)
            tokens = Array(appended.dropFirst()) + [nextToken]
            hid = hn
        } else {
            // Entry p0-1 paired the old pending token with hidden(p0-1); redo it with the
            // actual first appended token, then add one entry per appended position.
            guard let lh = lastHidden else { throw SpecStreamError.headStale("no last hidden") }
            guard mtp.position >= p0 - 1 else { throw SpecStreamError.headStale("head behind cache") }
            mtp.trim(to: p0 - 1)
            tokens = appended + [nextToken]
            hid = concatenated([lh, hn], axis: 1)
        }
        try replayHead(tokens: tokens, hidden: hid)
        lastHidden = hn[0..., (m - 1) ..< m, 0...]
    }
}

/// Adaptive draft-depth policy: pick the depth with the best expected emitted tokens per ms.
/// Q(d) = 1 + sum_{i<=d} P(accepted prefix >= i); cost(d, ctx) is a fitted pass-time model
/// (4K/16K/32K fixed-depth traces, L16: d2 43.9/46.3/54.2 ms, +3.5/5.8/6.6 ms per extra draft).
/// Pure and timing-free, so the choice depends only on acceptance history and context.
enum DepthPolicy {
    static let alpha = 0.1
    /// Rounds to stay at a depth before the policy may move (switching is not free).
    static let holdRounds = 8
    /// Relative rate gain needed to leave the current depth (hysteresis).
    static let margin = 0.05

    static func cost(depth: Int, ctx: Int) -> Double {
        let k = Double(min(max(ctx, 0), 32768)) / 1024.0
        return 42.5 + 0.35 * k + (3.3 + 3.3 * k / 32.0) * Double(depth - 2)
    }

    static func rate(depth: Int, survival: [Double], ctx: Int) -> Double {
        var q = 1.0
        for i in 0 ..< min(depth, survival.count) { q += survival[i] }
        return q / cost(depth: depth, ctx: ctx)
    }

    static func best(survival: [Double], ctx: Int, current: Int, minD: Int, maxD: Int) -> Int {
        let hi = min(maxD, survival.count)
        guard hi >= minD else { return current }
        var bestD = current, bestR = rate(depth: current, survival: survival, ctx: ctx)
        let curR = bestR
        for d in minD ... hi where d != current {
            let r = rate(depth: d, survival: survival, ctx: ctx)
            if r > bestR { bestR = r; bestD = d }
        }
        return bestR > curR * (1 + margin) ? bestD : current
    }
}
