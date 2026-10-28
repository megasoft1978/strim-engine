import Foundation
import MLX
import StrimCore
import StrimPrompt
import StrimTemplate
import StrimTokenizer

public struct EngineConfig: Sendable {
    public var modelDir: String
    /// MTP head directory (nil: no speculation, plain greedy decode).
    public var headDir: String?
    /// Max sessions whose KV/GDN/MTP state stays resident after a turn. 0 disables hot sessions
    /// (every turn restores from the prefix trie). `STRIM_HOT_SESSIONS`, default 2.
    public var hotSessions: Int
    public var mtpDepth: Int
    /// nil: prefix trie disabled (`STRIM_PREFIX_CACHE=0`).
    public var prefixCacheBytes: Int?
    /// Admission budget: weights + trie + live request/session state must fit.
    public var memoryBudgetBytes: Int
    /// MLX buffer cache limit (default 4 GB; nil: MLX default, which tracks the memory limit).
    public var mlxCacheLimitBytes: Int?

    public init(modelDir: String, headDir: String? = nil, hotSessions: Int = 2, mtpDepth: Int = 2,
                prefixCacheBytes: Int? = Self.defaultPlan.prefix, memoryBudgetBytes: Int = Self.defaultPlan.budget,
                mlxCacheLimitBytes: Int? = Self.defaultPlan.mlxCache) {
        self.modelDir = modelDir; self.headDir = headDir; self.hotSessions = hotSessions
        self.mtpDepth = mtpDepth; self.prefixCacheBytes = prefixCacheBytes
        self.memoryBudgetBytes = memoryBudgetBytes; self.mlxCacheLimitBytes = mlxCacheLimitBytes
    }

    /// RAM-scaled plan for a ~16 GB model (callers that know the weights use `fromEnvironment`).
    public static var defaultPlan: MemoryModel.Plan {
        MemoryModel.plan(physicalMemory: ProcessInfo.processInfo.physicalMemory, weightFileBytes: 16 << 30)
    }
    public static var defaultBudget: Int { defaultPlan.budget }

    /// Reads STRIM_HOT_SESSIONS, STRIM_PREFIX_CACHE(=0), STRIM_PREFIX_CACHE_MB, STRIM_MEM_BUDGET_GB,
    /// STRIM_MLX_CACHE_MB, STRIM_MEM_FRACTION. Unset knobs follow `MemoryModel.plan` for these weights.
    public static func fromEnvironment(modelDir: String, headDir: String?) -> EngineConfig {
        let env = ProcessInfo.processInfo.environment
        let plan = MemoryModel.plan(physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                    weightFileBytes: EngineCore.safetensorsBytes(modelDir) + (headDir.map(EngineCore.safetensorsBytes) ?? 0),
                                    fraction: Double(env["STRIM_MEM_FRACTION"] ?? "") ?? MemoryModel.defaultRamFraction)
        var c = EngineConfig(modelDir: modelDir, headDir: headDir, prefixCacheBytes: plan.prefix,
                             memoryBudgetBytes: plan.budget, mlxCacheLimitBytes: plan.mlxCache)
        if let h = Int(env["STRIM_HOT_SESSIONS"] ?? "") { c.hotSessions = max(h, 0) }
        if env["STRIM_PREFIX_CACHE"] == "0" { c.prefixCacheBytes = nil }
        else if let mb = Int(env["STRIM_PREFIX_CACHE_MB"] ?? "") { c.prefixCacheBytes = mb << 20 }
        if let gb = Double(env["STRIM_MEM_BUDGET_GB"] ?? "") { c.memoryBudgetBytes = Int(gb * 1_073_741_824) }
        if let mb = Int(env["STRIM_MLX_CACHE_MB"] ?? "") { c.mlxCacheLimitBytes = mb << 20 }
        return c
    }
}

/// Resident state of a finished turn: the live caches plus the exact ids they hold.
final class HotState {
    let cache: ModelCache
    let stream: SpecStream?
    /// Ids represented by `cache` (prompt + every token forwarded). The next turn can continue
    /// hot only if this is a prefix of the session's new ledger.
    let cacheTokens: [Int32]
    init(cache: ModelCache, stream: SpecStream?, cacheTokens: [Int32]) {
        self.cache = cache; self.stream = stream; self.cacheTokens = cacheTokens
    }
    var bytes: Int { cache.byteSize + (stream?.mtp.attention.keys?.nbytes ?? 0) * 2 }
}

final class Session {
    enum Mode { case unset, messages, ids }
    let id: SessionID
    let config: SessionConfig
    var mode = Mode.unset
    var messages: [Message] = []
    var ledger: Ledger?
    var rawIds: [Int32] = []
    var opensReasoning = false
    var hot: HotState?
    var activeRequest: Int?
    init(id: SessionID, config: SessionConfig) { self.id = id; self.config = config }
    var ids: [Int32] { ledger?.ids ?? rawIds }
}

final class PrefillJob {
    let tokens: [Int32]
    var pos = 0
    var live: ModelCache
    var mtp: MTPState?
    var carry: MLXArray?
    var node: PrefixStore.Node?
    var canInsert = true
    var matched = 0
    var headOut: MLXArray?
    var logits: MLXArray?
    var lastHidden: MLXArray?
    var seedToken: Int32 = -1
    var hot: HotState?
    var hs: [MLXArray] = []
    init(tokens: [Int32], live: ModelCache) { self.tokens = tokens; self.live = live }
    var done: Bool { pos >= tokens.count }

    /// Jumps to the deepest trie node past `pos` that matches `tokens` (restored state is identical
    /// to computed state), so a request that waited behind a leader reuses what the leader inserted.
    /// Called right before each cold chunk: at a boundary `pos` equals the end of the chain walked
    /// so far, and a lookup only ever finds the same cuts the chunk loop would produce.
    @discardableResult
    func adoptCachedPrefix(_ store: PrefixStore, requireMTP: Bool) throws -> Bool {
        guard hot == nil, !done,
              let hit = store.lookup(tokens, maxTokens: tokens.count - 1, requireMTP: requireMTP),
              hit.end > pos else { return false }
        let restored = try store.restore(hit)
        if requireMTP { let r = try store.restoreMTP(hit); mtp = r.state; carry = r.carry }
        live = restored
        pos = hit.end; node = hit; matched = hit.end; canInsert = true
        return true
    }
}

final class Request {
    let id: Int
    let session: Session?
    let params: GenParams
    let priority: Priority
    let cont: AsyncThrowingStream<GenEvent, Error>.Continuation?
    let onDone: (@Sendable (Error?) -> Void)?
    let promptIds: [Int32]
    let stop: Set<Int32>
    let submitted: Date
    var job: PrefillJob?
    var stream: SpecStream?
    var cache: ModelCache?
    var next: Int32 = -1
    var sampler: Sampler?
    var decoder: StreamDecoder
    var parser: ToolCallParser
    var gen: [Int32] = []
    var fed: [Int32] = []
    var content = ""
    var reasoning = ""
    var toolCalls: [ToolCall] = []
    var curTool: (name: String, args: [OrderedJSON.Member])?
    var usage = Usage()
    var joinedBatch = false
    var tPrefillStart: Date?
    var tFirst: Date?
    var drafts0 = 0, accepted0 = 0, passes0 = 0
    var wantMTP = false
    var finished = false

    init(id: Int, session: Session?, params: GenParams, cont: AsyncThrowingStream<GenEvent, Error>.Continuation?,
         onDone: (@Sendable (Error?) -> Void)?, promptIds: [Int32], stop: Set<Int32>, submitted: Date,
         decoder: StreamDecoder, parser: ToolCallParser) {
        self.id = id; self.session = session; self.params = params; self.priority = params.priority
        self.cont = cont; self.onDone = onDone; self.promptIds = promptIds; self.stop = stop
        self.submitted = submitted; self.decoder = decoder; self.parser = parser
    }
}

/// The engine body. Every method runs on the one engine thread; every MLX object (weights,
/// caches, the prefix trie, hot sessions) is created and touched only there.
final class EngineCore: EngineWorker, @unchecked Sendable {
    let cfg: EngineConfig
    var store: WeightStore!
    var head: WeightStore?
    var tokenizer: Tokenizer!
    var prefix: PrefixStore?
    var defaultStops: Set<Int32> = []
    var weightBytes = 0
    var hotLimit: Int

    var sessions: [SessionID: Session] = [:]
    var requests: [Int: Request] = [:]
    var sched = Scheduler()
    var batch: BatchedModelCache?
    var batchOrder: [Int] = []
    var hotLRU: [SessionID] = []
    var admitted: [Int: Int] = [:]
    var nextSession: UInt64 = 0
    var stopFlag = false
    var unhealthy: String?
    var unitsRun = 0
    static let trace = ProcessInfo.processInfo.environment["STRIM_ENGINE_TRACE"] != nil
    /// STRIM_MEM_TRACE=1: MLX memory per work unit and after weight load (stderr). Off by default.
    static let memTrace = ProcessInfo.processInfo.environment["STRIM_MEM_TRACE"] != nil
    /// Experiment (only with STRIM_MEM_TRACE): `Memory.clearCache()` after every work unit.
    static let memClearEachUnit = ProcessInfo.processInfo.environment["STRIM_MEM_CLEAR"] != nil
    var memRunPeak = 0
    var footprintBytes = 0          // last sampled phys_footprint (see relieveMemoryPressure)
    var pressureTrims = 0
    var lastPressureUnit = -8

    private let statsLock = NSLock()
    private var statsSnap = EngineStats()

    init(config: EngineConfig) {
        cfg = config
        hotLimit = config.hotSessions
    }

    var shouldStop: Bool { stopFlag }

    // MARK: lifecycle

    func prepare() throws {
        try withError {
            store = try WeightStore(dir: URL(fileURLWithPath: cfg.modelDir))
            if let h = cfg.headDir {
                let hs = try WeightStore(dir: URL(fileURLWithPath: h))
                hs.useIntegratedMTPPrefixIfNeeded()
                head = hs
            }
            tokenizer = try Tokenizer.load(modelDir: cfg.modelDir)
            for name in ["<|im_end|>", "<|endoftext|>"] {
                if let id = tokenizer.specialIds[name] { defaultStops.insert(id) }
            }
            if let id = tokenizer.specialIds["<|im_start|>"] { PrefixPrefill.configureBoundary(id) }
            if let a = tokenizer.encode("assistant", allowSpecial: false).first, tokenizer.encode("assistant", allowSpecial: false).count == 1 { PrefixPrefill.configureAssistant(a) }
            weightBytes = Self.safetensorsBytes(cfg.modelDir) + (cfg.headDir.map(Self.safetensorsBytes) ?? 0)
            // MLX's own limit stays at the legacy 70% of RAM: the 50% budget is a soft target enforced by
            // admission and `relieveMemoryPressure`, and a hard MLX limit below a transient peak would fail a request.
            Memory.memoryLimit = max(cfg.memoryBudgetBytes, Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.70), weightBytes + (2 << 30))
            if let c = cfg.mlxCacheLimitBytes { Memory.cacheLimit = c }
            if let b = cfg.prefixCacheBytes { prefix = PrefixStore(budgetBytes: b) }
            if Self.memTrace { memLog("weights-expected=\(weightBytes >> 20)MB after-open") }
            // Warm kernels / compiled functions on this thread before any request is timed.
            let warm: [Int32] = [9707, 1234, 5678, 198, 2, 220, 17, 15]
            _ = try QwenModel.forward(tokens: Array(warm.prefix(3)), store: store, cache: ModelCache())
            if let head {
                for _ in 0 ..< 2 {
                    _ = try QwenModel.generateSpec(prompt: Array(warm.prefix(3)), maxTokens: 4, store: store,
                                                   head: head, depth: cfg.mtpDepth)
                }
            }
            if Self.memTrace { memLog("after-warm (weights + kernels) budget=\(cfg.memoryBudgetBytes >> 20)MB") }
        }
        publishStats()
    }

    static func safetensorsBytes(_ dir: String) -> Int {
        let url = URL(fileURLWithPath: dir)
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "safetensors" }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func shutdown() {
        for r in Array(requests.values) { failRequest(r, EngineError.shutdown) }
        sessions.removeAll(); hotLRU.removeAll(); batch = nil; batchOrder = []
    }

    // MARK: stats

    func currentStats() -> EngineStats { statsLock.lock(); defer { statsLock.unlock() }; return statsSnap }

    func publishStats() {
        var s = EngineStats()
        s.healthy = unhealthy == nil
        s.unhealthyReason = unhealthy
        s.lastHeartbeat = Date()
        s.unitsRun = unitsRun
        s.activeRequests = requests.count
        s.sessions = sessions.count
        s.hotSessions = hotLRU.count
        s.trieBytes = prefix?.totalBytes ?? 0
        s.trieNodes = prefix?.nodeCount ?? 0
        s.trieEvictions = prefix?.evictions ?? 0
        s.mlxActiveBytes = Memory.activeMemory
        s.mlxCacheBytes = Memory.cacheMemory
        s.mlxPeakBytes = Memory.peakMemory
        s.footprintBytes = footprintBytes
        s.trieThinned = prefix?.thinned ?? 0
        s.pressureTrims = pressureTrims
        s.admittedBytes = admitted.values.reduce(0, +)
        s.budgetBytes = cfg.memoryBudgetBytes
        statsLock.lock(); statsSnap = s; statsLock.unlock()
    }

    // MARK: sessions

    func openSession(_ config: SessionConfig) -> SessionID {
        nextSession += 1
        let id = SessionID(raw: nextSession)
        sessions[id] = Session(id: id, config: config)
        return id
    }

    func session(_ id: SessionID) throws -> Session {
        guard let s = sessions[id] else { throw EngineError.unknownSession(id) }
        return s
    }

    func fork(_ id: SessionID, at count: Int?) throws -> SessionID {
        let s = try session(id)
        nextSession += 1
        let nid = SessionID(raw: nextSession)
        let f = Session(id: nid, config: s.config)
        f.mode = s.mode
        switch s.mode {
        case .unset: break
        case .ids:
            f.rawIds = Array(s.rawIds.prefix(count ?? s.rawIds.count))
            f.opensReasoning = s.opensReasoning
        case .messages:
            let n = min(count ?? s.messages.count, s.messages.count)
            f.messages = Array(s.messages.prefix(n))
            if var l = s.ledger?.fork() {
                l.truncate(to: n)
                f.ledger = l
                if let last = f.messages.last, last.role != .assistant { try prepareMessages(f) }
            }
        }
        sessions[nid] = f
        return nid
    }

    func closeSession(_ id: SessionID) {
        guard let s = sessions[id] else { return }
        if let rid = s.activeRequest, let r = requests[rid] { finish(r, .cancelled) }
        dropHot(s)
        sessions[id] = nil
    }

    func append(_ id: SessionID, _ input: TurnInput) throws -> Int {
        let s = try session(id)
        guard s.activeRequest == nil else { throw EngineError.busy(id) }
        switch input {
        case let .messages(m):
            guard s.mode != .ids else { throw EngineError.badInput("session is in raw-ids mode") }
            let before = s.messages
            s.messages += m
            do { try prepareMessages(s) } catch { s.messages = before; throw error }
            s.mode = .messages
        case let .history(m):
            guard s.mode != .ids else { throw EngineError.badInput("session is in raw-ids mode") }
            let before = s.messages
            s.messages = m
            do { try prepareMessages(s) } catch { s.messages = before; throw error }
            s.mode = .messages
        case let .ids(a):
            guard s.mode != .messages else { throw EngineError.badInput("session is in messages mode") }
            s.mode = .ids
            s.rawIds += a
            s.opensReasoning = ToolCallParser.promptOpensReasoning(tokenizer.decode(Array(s.rawIds.suffix(8))))
        }
        return s.ids.count
    }

    func prepareMessages(_ s: Session) throws {
        let ledger = s.ledger ?? Ledger(tokenizer: tokenizer)
        let c = s.config
        let p = try PromptBuilder.prepare(
            ledger: ledger, messages: s.messages, tools: c.tools, reasoningPolicy: c.reasoningPolicy,
            enableThinking: c.enableThinking, toolChoice: c.toolChoice, reasoningEffort: c.reasoningEffort,
            preserveThinking: c.preserveThinking)
        s.ledger = p.ledger
        s.opensReasoning = ToolCallParser.promptOpensReasoning(tokenizer.decode(Array(p.ledger.ids.suffix(8))))
    }

    func ledgerSnapshot(_ id: SessionID) throws -> LedgerSnapshot {
        let s = try session(id)
        return LedgerSnapshot(ids: s.ids, messageCount: s.ledger?.messageCount ?? s.messages.count, ledger: s.ledger)
    }

    // MARK: hot sessions

    func dropHot(_ s: Session) {
        s.hot = nil
        hotLRU.removeAll { $0 == s.id }
    }

    func retainHot(_ s: Session, _ h: HotState) {
        guard hotLimit > 0 else { return }
        s.hot = h
        hotLRU.removeAll { $0 == s.id }
        hotLRU.append(s.id)
        while hotLRU.count > hotLimit, let old = hotLRU.first, let os = sessions[old] { dropHot(os) }
        hotLRU = hotLRU.filter { sessions[$0]?.hot != nil }
    }

    func setHotSessions(_ n: Int) {
        hotLimit = max(n, 0)
        while hotLRU.count > hotLimit, let old = hotLRU.first, let os = sessions[old] { dropHot(os) }
    }

    func hotUsable(_ h: HotState, ids: [Int32], greedyMTP: Bool) -> Bool {
        guard h.cacheTokens.count < ids.count, h.cache.position == h.cacheTokens.count else { return false }
        if greedyMTP && head != nil && h.stream == nil { return false }
        return ids.starts(with: h.cacheTokens)
    }

    // MARK: request entry

    func startGenerate(requestId: Int, sessionId: SessionID, params: GenParams, submitted: Date,
                       cont: AsyncThrowingStream<GenEvent, Error>.Continuation) {
        func fail(_ e: Error) { cont.finish(throwing: e) }
        if let u = unhealthy { return fail(EngineError.unhealthy(u)) }
        guard let s = sessions[sessionId] else { return fail(EngineError.unknownSession(sessionId)) }
        guard s.activeRequest == nil else { return fail(EngineError.busy(sessionId)) }
        let ids = s.ids
        guard !ids.isEmpty else { return fail(EngineError.badInput("session has no input")) }
        guard params.maxTokens >= 0 else { return fail(EngineError.badInput("maxTokens < 0")) }
        do {
            try withError {
                let req = Request(id: requestId, session: s, params: params, cont: cont, onDone: nil,
                                  promptIds: ids, stop: params.ignoreEOS ? Set(params.stopIds) : Set(params.stopIds).union(defaultStops), submitted: submitted,
                                  decoder: tokenizer.makeStreamDecoder(),
                                  parser: ToolCallParser(tools: s.config.tools, startsInReasoning: s.opensReasoning))
                req.usage.promptTokens = ids.count
                // STRIM_SAMPLED_DEPTH0=1 restores depth-0 decode for sampled requests (bench baseline).
                req.wantMTP = head != nil && (params.isGreedy || ProcessInfo.processInfo.environment["STRIM_SAMPLED_DEPTH0"] == nil)
                if !params.isGreedy { req.sampler = Sampler(params: params) }
                var hot: HotState? = nil
                if let h = s.hot {
                    if hotUsable(h, ids: ids, greedyMTP: req.wantMTP) { hot = h } else { dropHot(s) }
                }
                let newTokens = ids.count - (hot?.cacheTokens.count ?? 0)
                let needed = MemoryModel.requestBytes(tokens: MemoryModel.saturatingAdd(newTokens, params.maxTokens), mtp: head != nil)
                try admit(req, needed: needed, protect: hot != nil ? s.id : nil, hotBytes: hot?.bytes ?? 0)
                if let hot {
                    dropHot(s)
                    req.usage.cachedTokens = hot.cacheTokens.count
                    let job = PrefillJob(tokens: Array(ids[hot.cacheTokens.count...]), live: hot.cache)
                    job.hot = hot
                    req.job = job
                } else {
                    req.job = try coldJob(ids)
                }
                s.activeRequest = requestId
                requests[requestId] = req
                sched.add(id: requestId, priority: params.priority, phase: .prefill)
            }
        } catch {
            admitted[requestId] = nil
            fail(error)
        }
    }

    func startPrefetch(requestId: Int, ids: [Int32], priority: Priority, onDone: @escaping @Sendable (Error?) -> Void) {
        if let u = unhealthy { return onDone(EngineError.unhealthy(u)) }
        guard !ids.isEmpty else { return onDone(nil) }
        do {
            try withError {
                var p = GenParams(maxTokens: 0); p.priority = priority
                let req = Request(id: requestId, session: nil, params: p, cont: nil, onDone: onDone, promptIds: ids,
                                  stop: [], submitted: Date(), decoder: tokenizer.makeStreamDecoder(),
                                  parser: ToolCallParser())
                try admit(req, needed: MemoryModel.requestBytes(tokens: ids.count, mtp: head != nil), protect: nil, hotBytes: 0)
                req.job = try coldJob(ids)
                requests[requestId] = req
                sched.add(id: requestId, priority: priority, phase: .prefill)
            }
        } catch { admitted[requestId] = nil; onDone(error) }
    }

    func admit(_ req: Request, needed: Int, protect: SessionID?, hotBytes: Int) throws {
        let hot = hotLRU.compactMap { id in sessions[id]?.hot.map { (id: id.raw, bytes: $0.bytes) } }
        let d = Admission.decide(budget: cfg.memoryBudgetBytes, fixed: MemoryModel.fixedBytes(weightFileBytes: weightBytes, prefixBytes: cfg.prefixCacheBytes ?? 0,
                                                       mlxCacheBytes: cfg.mlxCacheLimitBytes),
                                 active: admitted.values.reduce(0, +), hot: hot, needed: needed, protect: protect?.raw)
        switch d.outcome {
        case let .reject(n, a): throw EngineError.insufficientMemory(needed: n, available: a)
        case .admit:
            for raw in d.evictHot { if let s = sessions[SessionID(raw: raw)] { dropHot(s) } }
            admitted[req.id] = needed + hotBytes
        }
    }

    /// Fresh prefill job, empty. The trie is consulted lazily, right before each chunk runs
    /// (`PrefillJob.adoptCachedPrefix`), not at admission: requests admitted together would all
    /// see the same empty trie, while a follower's first chunk runs after the leader's inserts.
    /// Prefill is FIFO within a class, so followers simply wait their turn; no in-flight waiting.
    func coldJob(_ ids: [Int32]) throws -> PrefillJob {
        let j = PrefillJob(tokens: ids, live: ModelCache())
        j.mtp = head != nil ? MTPState() : nil
        return j
    }

    // MARK: cancel / finish / fail

    func cancelSession(_ id: SessionID) {
        if let s = sessions[id], let rid = s.activeRequest, let r = requests[rid] { finish(r, .cancelled) }
    }

    func cancelRequest(_ id: Int) {
        if let r = requests[id] { finish(r, .cancelled) }
    }

    func release(_ r: Request) {
        r.finished = true
        sched.remove(r.id)
        if let i = batchOrder.firstIndex(of: r.id) {
            batchOrder.remove(at: i)
            batch?.remove(indices: [i])
            if batchOrder.isEmpty { batch = nil }
        }
        admitted[r.id] = nil
        requests[r.id] = nil
        if r.session?.activeRequest == r.id { r.session?.activeRequest = nil }
        r.job = nil; r.stream = nil; r.cache = nil
    }

    func failRequest(_ r: Request, _ error: Error) {
        guard !r.finished else { return }
        if let s = r.session { dropHot(s) }
        release(r)
        r.cont?.finish(throwing: error)
        r.onDone?(error)
    }

    /// Ends a request normally (stop/length) or by cancellation.
    func finish(_ r: Request, _ reason: FinishReason) {
        guard !r.finished else { return }
        if r.cont == nil {                       // prefetch
            release(r)
            r.onDone?(reason == .cancelled ? CancellationError() : nil)
            return
        }
        // Flush held text and an open tool call.
        var evs: [ParserEvent] = []
        let tail = r.decoder.flush()
        if !tail.isEmpty { evs += r.parser.feed(tail) }
        evs += r.parser.finish()
        let flushed = route(r, evs)
        if !flushed.isEmpty { r.cont?.yield(.tokens([], flushed)) }

        let now = Date()
        r.usage.completionTokens = r.gen.count
        if let f = r.tFirst {
            r.usage.decodeSeconds = now.timeIntervalSince(f)
        }
        if let st = r.stream, st.stats.drafts > r.drafts0 {
            r.usage.mtpAccept = Double(st.stats.acceptedDrafts - r.accepted0) / Double(st.stats.drafts - r.drafts0)
            r.usage.mtpPasses = st.stats.passes - r.passes0
        }
        if let s = r.session {
            if reason == .cancelled {
                dropHot(s)
            } else {
                recordTurn(r, s, reason)
            }
        }
        release(r)
        r.cont?.yield(.finished(reason, r.usage))
        r.cont?.finish()
    }

    /// Appends the generated ids to the session (ledger / raw ids) and keeps the caches hot.
    func recordTurn(_ r: Request, _ s: Session, _ reason: FinishReason) {
        if s.mode == .messages, var l = s.ledger {
            var calls = r.toolCalls
            if let c = r.curTool { calls.append(ToolCall(name: c.name, arguments: c.args)) }
            let msg = Message.assistant(r.content.isEmpty && !calls.isEmpty ? nil : r.content,
                                        reasoning: r.reasoning.isEmpty ? nil : r.reasoning, toolCalls: calls)
            let withEnd = reason == .stop && r.gen.last == l.imEndId
            do {
                try l.appendGenerated(ids: r.gen, finishedWithImEnd: withEnd, message: msg)
                s.ledger = l
                s.messages.append(msg)
            } catch {
                dropHot(s)
                return
            }
        } else {
            s.rawIds += r.gen
        }
        // Hot state: only a cache that still equals "prompt + forwarded tokens", whose MTP head
        // (when a head is loaded) was maintained by a SpecStream the whole way.
        guard hotLimit > 0, !r.joinedBatch, let cache = r.cache else { dropHot(s); return }
        if head != nil && r.stream == nil { dropHot(s); return }
        let tokens = r.promptIds + r.fed
        guard cache.position == tokens.count else { dropHot(s); return }
        retainHot(s, HotState(cache: cache, stream: r.stream, cacheTokens: tokens))
    }

    // MARK: output routing

    /// Maps parser events to stream events; returns the content text.
    func route(_ r: Request, _ evs: [ParserEvent]) -> String {
        var text = ""
        for e in evs {
            switch e {
            case let .text(t):
                text += t; r.content += t
            case let .reasoning(t):
                r.reasoning += t
                r.cont?.yield(.reasoning(t))
            case let .toolCallBegin(name):
                r.curTool = (name, [])
                r.cont?.yield(.toolCallBegin(name: name))
            case let .toolCallArg(key, value):
                r.curTool?.args.append(OrderedJSON.Member(key, value))
                r.cont?.yield(.toolCallArg(key: key, value: value))
            case .toolCallEnd:
                if let c = r.curTool { r.toolCalls.append(ToolCall(name: c.name, arguments: c.args)) }
                r.curTool = nil
                r.cont?.yield(.toolCallEnd)
            }
        }
        return text
    }

    /// Emits newly decided tokens in order. Returns a finish reason when the request is done.
    func emit(_ r: Request, _ toks: [Int32]) -> FinishReason? {
        var visible: [Int32] = []
        var reason: FinishReason? = nil
        for t in toks {
            if r.gen.count >= r.params.maxTokens { reason = .length; break }
            r.gen.append(t)
            if r.stop.contains(t) { reason = .stop; break }
            visible.append(t)
            if r.gen.count >= r.params.maxTokens { reason = .length; break }
        }
        if r.tFirst == nil {
            r.tFirst = Date()
            r.usage.ttft = r.tFirst!.timeIntervalSince(r.submitted)
            r.usage.prefillSeconds = r.tFirst!.timeIntervalSince(r.tPrefillStart ?? r.submitted)
        }
        if !visible.isEmpty {
            let text = r.decoder.push(visible)
            let content = text.isEmpty ? "" : route(r, r.parser.feed(text))
            r.cont?.yield(.tokens(visible, content))
        }
        return reason
    }

    // MARK: work units

    /// One stderr line of MLX memory (MB). In trace runs the peak is reset at each unit start,
    /// so `peak` is that unit's transient high-water mark and `runPeak` the max over the run.
    func memLog(_ tag: String) {
        func mb(_ b: Int) -> Int { b >> 20 }
        memRunPeak = max(memRunPeak, Memory.peakMemory)
        let line = "[mem] \(tag) active=\(mb(Memory.activeMemory)) peak=\(mb(Memory.peakMemory)) "
            + "runPeak=\(mb(memRunPeak)) cache=\(mb(Memory.cacheMemory)) "
            + "trie=\(mb(prefix?.totalBytes ?? 0))/\(prefix?.nodeCount ?? 0)nodes hot=\(hotLRU.count) "
            + "admitted=\(mb(admitted.values.reduce(0, +)))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    func runOneUnit() -> Bool {
        sched.policy = DecodePolicy.current()
        guard let unit = sched.pick() else { publishStats(); return false }
        unitsRun += 1
        if Self.memTrace { Memory.peakMemory = 0 }   // setter resets the MLX peak counter
        if Self.trace {
            FileHandle.standardError.write(Data("[engine] unit \(unitsRun) \(unit) batch=\(batchOrder) \(requests.values.sorted { $0.id < $1.id }.map { "r\($0.id):\($0.priority == .interactive ? "I" : "B")g\($0.gen.count)" })\n".utf8))
        }
        do {
            if Self.trace {
                // Diagnostics only: print the raw MLX error (withError would swallow it until block exit).
                try withErrorHandler({ msg in FileHandle.standardError.write(Data("[engine] MLX error: \(msg)\n".utf8)) }) {
                    try execute(unit)
                }
            } else {
                try withError { try execute(unit) }
            }
        } catch {
            handleUnitError(unit, error)
        }
        if Self.memTrace {
            var pos = ""
            if case let .prefill(id) = unit, let p = requests[id]?.job?.pos { pos = " pos=\(p)" }
            memLog("unit \(unitsRun) \(unit)\(pos) batch=\(batchOrder.count)")
            if Self.memClearEachUnit { Memory.clearCache() }
        }
        relieveMemoryPressure()
        publishStats()
        return true
    }

    func execute(_ unit: Scheduler.Unit) throws {
        if let u = unhealthy {
            for r in Array(requests.values) { failRequest(r, EngineError.unhealthy(u)) }
            return
        }
        switch unit {
        case let .prefill(id):
            guard let r = requests[id] else { sched.remove(id); return }
            try prefillUnit(r)
        case let .decodeSolo(id):
            guard let r = requests[id] else { sched.remove(id); return }
            try decodeSolo(r)
        case let .decodeBatch(join):
            try decodeBatch(join: join)
        }
    }

    func handleUnitError(_ unit: Scheduler.Unit, _ error: Error) {
        let msg = "\(error)"
        let lower = msg.lowercased()
        if lower.contains("command buffer") || lower.contains("metal") || lower.contains("[metal]") {
            unhealthy = msg
        }
        let wrapped: Error = (error is EngineError) ? error : EngineError.mlx(msg)
        switch unit {
        case let .prefill(id), let .decodeSolo(id):
            if let r = requests[id] { failRequest(r, wrapped) } else { sched.remove(id) }
        case .decodeBatch:
            // Batch state is undefined after an error: fail every member.
            for id in batchOrder { if let r = requests[id] { failRequest(r, wrapped) } }
            batch = nil; batchOrder = []
        }
        if let u = unhealthy {
            for r in Array(requests.values) { failRequest(r, EngineError.unhealthy(u)) }
        }
    }

    // MARK: prefill

    func prefillUnit(_ r: Request) throws {
        guard let j = r.job else { throw EngineError.badInput("request has no prefill job") }
        if r.tPrefillStart == nil { r.tPrefillStart = Date() }
        if j.hot != nil { try hotChunk(r, j) } else { try coldChunk(r, j) }
        if j.done { try finishPrefill(r, j) }
    }

    /// One aligned chunk of `PrefixPrefill.core`'s loop, verbatim arithmetic (the trie only
    /// guarantees exactness if hit and miss run identical chunks). Kept in step with that loop;
    /// `enginebench` checks it against `SpecPrefill.run`.
    func coldChunk(_ r: Request, _ j: PrefillJob) throws {
        let policy = prefix?.policy ?? PrefixPrefill.defaultPolicy
        if let prefix, try j.adoptCachedPrefix(prefix, requireMTP: head != nil) { r.usage.cachedTokens = j.matched }
        let tokens = j.tokens
        let pos = j.pos
        let cut = policy.blockEnd(tokens, from: pos, limit: tokens.count)
        let end = cut ?? tokens.count
        let last = end == tokens.count
        let part = Array(tokens[pos ..< end])
        var h = try store.embedding("language_model.model.embed_tokens", tokens: part)
            .reshaped([1, part.count, 5120])
        for i in 0 ..< 64 { h = try DecoderLayer.forward(h, store: store, layer: i, cache: j.live) }
        j.live.position += part.count
        let m = part.count
        if last {
            let normed = try store.rmsNorm("language_model.model.norm", h[0..., (m - 1)..., 0...])
            let lg = try store.linear("language_model.lm_head", normed)[0, 0]
            eval(lg, j.live)
            j.logits = lg
            j.lastHidden = normed
        }
        var block: MTPBlock? = nil
        if let head, let mtp = j.mtp {
            let hn = try store.rmsNorm("language_model.model.norm", h)
            var htoks = pos == 0 ? Array(tokens[1 ..< end]) : part
            var hid = j.carry.map { concatenated([$0, hn[0..., 0 ..< (m - 1), 0...]], axis: 1) }
                ?? hn[0..., 0 ..< (m - 1), 0...]
            if last {
                j.seedToken = r.sampler?.sampleFirst(j.logits!) ?? Int32(argMax(j.logits!).item(Int32.self))
                htoks.append(j.seedToken)
                hid = j.carry.map { concatenated([$0, hn], axis: 1) } ?? hn
            }
            let lo = pos == 0 ? 0 : pos - 1
            if !htoks.isEmpty {
                j.headOut = try MTP.step(tokens: htoks, hidden: hid, target: store, head: head, state: mtp)
            }
            j.carry = hn[0..., (m - 1) ..< m, 0...]
            if let k = mtp.attention.keys, let v = mtp.attention.values {
                if cut != nil, prefix != nil, end - 1 > lo {
                    block = MTPBlock(k: contiguous(k[0..., 0..., lo ..< (end - 1), 0...]),
                                     v: contiguous(v[0..., 0..., lo ..< (end - 1), 0...]),
                                     hidden: j.carry!)
                }
                eval(k, v, j.carry!)
            }
        }
        if !last { eval(j.live) }
        j.pos = end
        if let prefix, j.canInsert, cut != nil {
            j.node = try prefix.insert(parent: j.node, tokens: Array(tokens[0 ..< end]), cache: j.live, mtp: block)
            if j.node == nil { j.canInsert = false }   // did not fit: keep computing, stop storing
        }
        if last, r.wantMTP, let head, let mtp = j.mtp, let o = j.headOut {
            try SpecStream.setSeed(from: o, store: store, head: head, mtp: mtp, chain: QwenModel.defaultDraftChain)
        }
    }

    /// One chunk of a hot append (same arithmetic as `SpecStream.appendTokens`).
    func hotChunk(_ r: Request, _ j: PrefillJob) throws {
        let end = min(j.pos + PrefixPrefill.chunk, j.tokens.count)
        let res = try QwenModel.forwardAll(tokens: Array(j.tokens[j.pos ..< end]), store: store, cache: j.live,
                                           layers: 64, lastTokenOnly: true)
        j.hs.append(res.hidden)
        j.logits = res.logits[0, 0]
        eval(res.hidden, j.live)
        j.pos = end
        if j.done, r.wantMTP, let stream = j.hot?.stream {
            let hidden = j.hs.count == 1 ? j.hs[0] : concatenated(j.hs, axis: 1)
            let nextTok = r.sampler?.sampleFirst(j.logits!) ?? Int32(argMax(j.logits!).item(Int32.self))
            try stream.reseed(appended: j.tokens, hidden: hidden, nextToken: nextTok)
            j.seedToken = nextTok
        }
        if j.done { j.hs.removeAll() }
    }

    func finishPrefill(_ r: Request, _ j: PrefillJob) throws {
        guard let logits = j.logits else { throw EngineError.badInput("prefill produced no logits") }
        if r.cont == nil {                       // prefetch: the trie has the chunks, nothing to decode
            finish(r, .length)
            return
        }
        r.cache = j.live
        var first: Int32
        if r.wantMTP, let head {
            if let hs = j.hot?.stream {
                r.stream = hs
            } else {
                r.stream = SpecStream(store: store, head: head, cache: j.live, mtp: j.mtp!, seedToken: j.seedToken,
                                      lastHidden: j.lastHidden, depth: cfg.mtpDepth)
            }
            if let sm = r.sampler { r.stream!.enableSampling(sm.config) } else { r.stream!.disableSampling() }
            first = r.stream!.pending
            r.drafts0 = r.stream!.stats.drafts; r.accepted0 = r.stream!.stats.acceptedDrafts; r.passes0 = r.stream!.stats.passes
        } else if var sm = r.sampler {
            first = sm.sample(logits)
            r.sampler = sm
        } else {
            first = Int32(argMax(logits).item(Int32.self))
        }
        r.next = first
        r.job = nil
        if r.stream == nil { sched.setPrior(r.id, tokensPerUnit: 1, ms: 34) }
        sched.setPhase(r.id, .decode)
        if let reason = emit(r, [first]) { finish(r, reason) }
    }

    // MARK: decode

    func decodeSolo(_ r: Request) throws {
        let remaining = r.params.maxTokens - r.gen.count
        if remaining <= 0 { finish(r, .length); return }
        let t0 = Date()
        if let st = r.stream {
            // pending was already emitted; step forwards it (and accepted drafts) and decides the next.
            let out = try st.step(remaining: remaining)
            r.fed += out
            let newToks = Array(out.dropFirst()) + [st.pending]
            sched.record(r.id, tokens: newToks.count, ms: Date().timeIntervalSince(t0) * 1000)
            if let reason = emit(r, newToks) { finish(r, reason) }
            return
        }
        guard let cache = r.cache else { throw EngineError.badInput("decode without cache") }
        let lg = try QwenModel.forwardAll(tokens: [r.next], store: store, cache: cache, layers: 64).logits
        r.fed.append(r.next)
        let nt = pick(r, lg[0, 0])
        r.next = nt
        sched.record(r.id, tokens: 1, ms: Date().timeIntervalSince(t0) * 1000)
        if let reason = emit(r, [nt]) { finish(r, reason) }
    }

    func pick(_ r: Request, _ logits: MLXArray) -> Int32 {
        if var sm = r.sampler {
            let t = sm.sample(logits); r.sampler = sm; return t
        }
        return Int32(argMax(logits).item(Int32.self))
    }

    /// One lockstep pass over the whole batch: plain decode (no MTP), greedy or sampled per row.
    /// Members stay in the batch until they finish.
    func decodeBatch(join: [Int]) throws {
        for id in join {
            guard let r = requests[id] else { continue }
            let cache: ModelCache
            if let st = r.stream { cache = st.cache; r.next = st.pending } else if let c = r.cache { cache = c }
            else { throw EngineError.badInput("batch join without cache") }
            if batch == nil { batch = BatchedModelCache() }
            // After a speculative rollback the Metal decode kernel leaves the GDN state without its
            // batch axis ([Hv,Dv,Dk] from the per-step stack). Restore [1,Hv,Dv,Dk] before stacking.
            for (_, g) in cache.gdn { if let ssm = g.ssm, ssm.ndim == 3 { g.ssm = ssm.expandedDimensions(axis: 0) } }
            batch!.append(cache)
            batchOrder.append(id)
            r.joinedBatch = true
            r.stream = nil          // head state is stale from here on; plain decode until done
        }
        guard let bc = batch, !batchOrder.isEmpty else { return }
        let members = batchOrder.compactMap { requests[$0] }
        guard members.count == batchOrder.count else { throw EngineError.badInput("batch out of sync") }
        let lg = try BatchModel.forward(tokens: members.map { [$0.next] }, store: store, cache: bc)
        let toks: [Int32]
        if members.allSatisfy({ $0.sampler == nil }) {
            toks = argMax(lg, axis: -1).reshaped([members.count]).asArray(Int32.self)
        } else {
            toks = members.enumerated().map { (i, r) in pick(r, lg[i, 0]) }
        }
        var done: [(Request, FinishReason)] = []
        for (i, r) in members.enumerated() {
            r.fed.append(r.next)
            r.next = toks[i]
            if let reason = emit(r, [toks[i]]) { done.append((r, reason)) }
        }
        for (r, reason) in done { finish(r, reason) }   // release() drops the batch row
    }
}
