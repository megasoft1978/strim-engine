import Foundation
import StrimAdmission
import StrimAPI
import StrimEngine
import StrimHTTP
import StrimTemplate

public struct ServerConfig: Sendable {
    public var modelId: String
    public var defaults: SamplingDefaults
    /// Maximum number of pooled engine sessions (LRU closes the oldest idle one).
    public var maxSessions: Int
    /// Required bearer token; nil disables auth (loopback dev only).
    public var bearerToken: String?
    /// Priority admission shared with the job layer. A generation request takes a slot (class from its
    /// `x-strim-priority`) before it touches the engine; nil disables admission.
    public var admission: (any AdmissionControlling)?
    /// Class the server grants every holder of the API token. A request may ask for a lower class
    /// (`x-strim-priority: background`) but never a higher one.
    public var apiPriority: Priority = .interactive
    /// Requests allowed to wait for an admission slot; more get 429 + Retry-After.
    public var maxQueuedRequests: Int = ServerLimits.maxQueuedRequests
    /// Longest wait for an admission slot, in seconds; then 503 + Retry-After.
    public var queueTimeoutSeconds: Int = ServerLimits.queueTimeoutSeconds
    public init(modelId: String, defaults: SamplingDefaults = SamplingDefaults(), maxSessions: Int = 8,
                bearerToken: String? = nil, admission: (any AdmissionControlling)? = nil) {
        self.modelId = modelId; self.defaults = defaults; self.maxSessions = maxSessions
        self.bearerToken = bearerToken; self.admission = admission
    }
}

/// OpenAI-compatible HTTP front over an `EngineClient`, running in the engine's process.
public final class StrimOpenAIServer: @unchecked Sendable {
    let engine: any EngineClient
    let config: ServerConfig
    private var http: HTTPServer?
    private var extraRoutes: [(method: String, path: String, handler: HTTPServer.Handler)] = []
    private var openRoutes: [(method: String, path: String, prefix: Bool, handler: HTTPServer.Handler)] = []
    private var extraPrefixRoutes: [(method: String, prefix: String, handler: HTTPServer.Handler)] = []
    let sessions: SessionTable
    let responseStore = ResponseStore()
    let lock = NSLock()
    var active: [String: SessionID] = [:]
    var requestsTotal = 0
    var requestsFailed = 0
    let logRequests = ProcessInfo.processInfo.environment["STRIM_SERVER_LOG"] != nil

    public init(engine: any EngineClient, config: ServerConfig) {
        self.engine = engine
        self.config = config
        self.sessions = SessionTable(engine: engine, capacity: config.maxSessions)
    }

    public var port: UInt16? { lock.withLock { http }?.port }

    /// Starts listening on 127.0.0.1:`port` (0: ephemeral) and returns the bound port. Auth is enforced here,
    /// not by HTTPServer, so 401s use the OpenAI error shape.
    public func start(port: UInt16) async throws -> UInt16 {
        let server = HTTPServer(port: port)
        register(server)
        lock.withLock { http = server }
        return try await server.start()
    }

    /// Registers an exact-path route behind the same auth guard as the built-in routes. Exact routes win over
    /// the catch-all `/` prefix route. Call before `start`; a later call registers on the running server.
    public func addGuardedRoute(_ method: String, _ path: String, _ handler: @escaping HTTPServer.Handler) {
        let running: HTTPServer? = lock.withLock {
            if http == nil { extraRoutes.append((method, path, handler)) }
            return http
        }
        running?.route(method, path) { [self] req, r in try await guarded(req, r) { try await handler(req, r) } }
    }

    /// Like `addGuardedRoute` for every path under `prefix` (longest prefix wins; exact routes win over prefixes).
    public func addGuardedPrefixRoute(_ method: String, prefix: String, _ handler: @escaping HTTPServer.Handler) {
        let running: HTTPServer? = lock.withLock {
            if http == nil { extraPrefixRoutes.append((method, prefix, handler)) }
            return http
        }
        running?.route(method, prefix: prefix) { [self] req, r in try await guarded(req, r) { try await handler(req, r) } }
    }

    /// Registers a route with NO server-side auth: the handler authenticates itself (the control API uses its own
    /// token, which the API/MCP bearer token must not unlock). Host/Origin checks still apply at the HTTP layer.
    /// Call before `start`.
    public func addOpenRoute(_ method: String, _ path: String, prefix: Bool = false, _ handler: @escaping HTTPServer.Handler) {
        let running: HTTPServer? = lock.withLock {
            if http == nil { openRoutes.append((method, path, prefix, handler)) }
            return http
        }
        if prefix { running?.route(method, prefix: path, handler) } else { running?.route(method, path, handler) }
    }

    public func stop() {
        lock.withLock { http }?.stop()
        let t = sessions
        Task { await t.closeAll() }
    }

    // MARK: routing

    private func register(_ s: HTTPServer) {
        s.route("GET", "/health") { [self] _, r in try await health(r) }
        s.route("GET", "/v1/models") { [self] req, r in try await guarded(req, r) { try await models(r) } }
        s.route("GET", "/metrics") { [self] req, r in try await guarded(req, r) { try await metrics(r) } }
        s.route("POST", "/v1/chat/completions") { [self] req, r in try await guarded(req, r) { try await chat(req, r) } }
        s.route("POST", "/v1/messages") { [self] req, r in try await guarded(req, r, style: .anthropic) { try await anthropicMessages(req, r) } }
        s.route("POST", "/v1/messages/count_tokens") { [self] req, r in try await guarded(req, r, style: .anthropic) { try await anthropicCountTokens(req, r) } }
        s.route("POST", "/v1/responses") { [self] req, r in try await guarded(req, r) { try await responses(req, r) } }
        s.route("POST", prefix: "/v1/strim/cancel/") { [self] req, r in try await guarded(req, r) { try await cancel(req, r) } }
        let extras = lock.withLock { extraRoutes }
        for e in extras {
            s.route(e.method, e.path) { [self] req, r in try await guarded(req, r) { try await e.handler(req, r) } }
        }
        for e in lock.withLock({ openRoutes }) {
            if e.prefix { s.route(e.method, prefix: e.path, e.handler) } else { s.route(e.method, e.path, e.handler) }
        }
        let prefixes = lock.withLock { extraPrefixRoutes }
        for e in prefixes {
            s.route(e.method, prefix: e.prefix) { [self] req, r in try await guarded(req, r) { try await e.handler(req, r) } }
        }
        for m in ["GET", "POST"] {
            s.route(m, prefix: "/") { [self] req, r in try await guarded(req, r) { throw APIError.notFound() } }
        }
    }

    func guarded(_ req: Request, _ r: Responder, style: ErrorStyle = .openai, _ body: () async throws -> Void) async throws {
        do {
            if let token = config.bearerToken, !Self.authorized(req, token) {
                var h = HTTPHeaders()
                h.append(name: "WWW-Authenticate", value: "Bearer")
                try await APIError.unauthorized().respond(r, style: style, headers: h)
                return
            }
            try await body()
        } catch let e as HTTPServerError {
            throw e
        } catch {
            try await APIError.from(error).respond(r, style: style)
        }
    }

    private static func authorized(_ req: Request, _ token: String) -> Bool {
        if let v = req.headers["Authorization"] {
            let parts = v.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, parts[0].lowercased() == "bearer", constantTimeEqual(String(parts[1]), token) { return true }
        }
        if let k = req.headers["x-api-key"], constantTimeEqual(k, token) { return true }   // Anthropic SDKs
        return false
    }

    private static func constantTimeEqual(_ x: String, _ y: String) -> Bool {
        let a = Array(x.utf8), b = Array(y.utf8)
        var diff = a.count ^ b.count
        for i in 0 ..< max(a.count, b.count) { diff |= Int((i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)) }
        return diff == 0
    }

    // MARK: simple endpoints

    func sendJSON(_ r: Responder, _ j: OrderedJSON, status: Int = 200) async throws {
        try await r.json(status, Data(j.serialized().utf8))
    }

    private func health(_ r: Responder) async throws {
        let st = engine.stats()
        if st.healthy {
            try await sendJSON(r, .ordered([("status", .string("ok")), ("engine", .string("up")), ("version", .string(StrimVersion.current))]))
        } else {
            try await sendJSON(r, .ordered([("status", .string("unhealthy")), ("engine", .string("down")), ("version", .string(StrimVersion.current))]), status: 503)   // reason stays on guarded /metrics
        }
    }

    private func models(_ r: Responder) async throws {
        try await sendJSON(r, .ordered([
            ("object", .string("list")),
            ("data", .array([.ordered([("id", .string(config.modelId)), ("object", .string("model")),
                                       ("created", .int(0)), ("owned_by", .string("strim"))])])),
        ]))
    }

    private func metrics(_ r: Responder) async throws {
        let st = engine.stats()
        let (total, failed, activeNow): (Int, Int, Int) = lock.withLock { (requestsTotal, requestsFailed, active.count) }
        let pooled = await sessions.count
        let reuse = await sessions.reuseCount
        let opened = await sessions.openCount
        func i(_ v: Int) -> OrderedJSON { .int(v) }
        try await sendJSON(r, .ordered([
            ("engine", .ordered([
                ("healthy", .bool(st.healthy)), ("unhealthy_reason", st.unhealthyReason.map { .string($0) } ?? .null),
                ("units_run", i(st.unitsRun)), ("active_requests", i(st.activeRequests)),
                ("sessions", i(st.sessions)), ("hot_sessions", i(st.hotSessions)),
                ("trie_bytes", i(st.trieBytes)), ("trie_nodes", i(st.trieNodes)), ("trie_evictions", i(st.trieEvictions)),
                ("mlx_active_bytes", i(st.mlxActiveBytes)), ("mlx_cache_bytes", i(st.mlxCacheBytes)),
                ("mlx_peak_bytes", i(st.mlxPeakBytes)), ("admitted_bytes", i(st.admittedBytes)),
                ("budget_bytes", i(st.budgetBytes)),
                ("mtp", .ordered([
                    ("coverage", .string("completed_specstream_rounds")),
                    ("batch_supported", .bool(false)),
                    ("unsupported_batch_tokens", i(st.mtpUnsupportedBatchTokens)),
                    ("lifetime", .string(st.mtpLifetime)),
                    ("started_at", .string(ISO8601DateFormatter().string(from: st.mtpStartedAt))),
                    ("resets", .string("engine_creation")),
                    ("rounds", i(st.mtp.rounds)), ("emitted", i(st.mtp.emitted)),
                    ("positions", .array((1...st.mtp.proposed.count).map { .int($0) })),
                    ("proposed", .array(st.mtp.proposed.map { .int($0) })),
                    ("reached", .array(st.mtp.reached.map { .int($0) })),
                    ("accepted_prefix", .array(st.mtp.acceptedPrefix.map { .int($0) })),
                    ("overflow_proposed", i(st.mtp.overflowProposed)),
                ])),

            ])),
            ("server", .ordered([
                ("requests_total", i(total)), ("requests_failed", i(failed)), ("requests_active", i(activeNow)),
                ("pooled_sessions", i(pooled)), ("session_reuses", i(reuse)), ("sessions_opened", i(opened)),
            ])),
        ]))
    }

    private func cancel(_ req: Request, _ r: Responder) async throws {
        let id = String(req.path.dropFirst("/v1/strim/cancel/".count))
        guard let session = lock.withLock({ active[id] }) else { throw APIError.notFound("no active request \(id)") }
        await engine.cancel(session)
        try await sendJSON(r, .ordered([("id", .string(id)), ("cancelled", .bool(true))]))
    }

    // MARK: chat completions

    private func chat(_ req: Request, _ responder: Responder) async throws {
        lock.withLock { requestsTotal += 1 }
        do {
            try await chatInner(req, responder)
        } catch {
            lock.withLock { requestsFailed += 1 }
            throw error
        }
    }

    private func chatInner(_ req: Request, _ responder: Responder) async throws {
        let creq = try ChatRequest.parse(req.body, headerPriority: req.headers["x-strim-priority"],
                                         defaults: config.defaults, ceiling: config.apiPriority)
        let slot = try await admit(creq, responder)
        do { try await chatAdmitted(creq, responder) } catch { await slot?.release(); throw error }
        await slot?.release()
    }

    private func chatAdmitted(_ creq: ChatRequest, _ responder: Responder) async throws {
        let lease: SessionTable.Lease
        do { lease = try await sessions.acquire(fingerprint: creq.fingerprint, config: creq.config) }
        catch { throw APIError.from(error) }
        do {
            _ = try await engine.append(lease.session, .history(creq.messages))
        } catch {
            var keep = true
            if case EngineError.unknownSession? = error as? EngineError { keep = false }
            await sessions.release(lease, keep: keep)
            throw APIError.from(error)
        }

        let cid = "chatcmpl-" + OutputTranslator.randomId()
        let created = Int(Date().timeIntervalSince1970)
        lock.withLock { active[cid] = lease.session }
        let meta = ChunkMeta(id: cid, created: created, model: config.modelId)
        let engine = self.engine

        // The generation runs in its own task so a client disconnect can cancel it; cancelling the task
        // terminates the engine stream, which cancels exactly this request.
        let work = Task { [self] () -> Result<Bool, Error> in
            do {
                let keep = creq.stream
                    ? try await streamResponse(creq, lease, meta, responder, engine)
                    : try await collectResponse(creq, lease, meta, responder, engine)
                return .success(keep)
            } catch { return .failure(error) }
        }
        responder.onClose { work.cancel() }
        let result = await work.value
        lock.withLock { active[cid] = nil }
        switch result {
        case .success(let keep):
            await sessions.release(lease, keep: keep)
        case .failure(let error):
            await sessions.release(lease, keep: false)
            if error is HTTPServerError { return }
            throw error
        }
    }

    /// Per-request engine timing on stderr (`STRIM_SERVER_LOG=1`).
    func logDone(_ id: String, _ u: Usage) {
        guard logRequests else { return }
        let tps = u.decodeSeconds > 0 ? Double(max(u.completionTokens - 1, 0)) / u.decodeSeconds : 0
        let line = String(format: "[serve] %@ prompt=%d cached=%d completion=%d ttft=%.0fms prefill=%.0fms decode=%.2fs (%.1f tok/s) mtp=%@\n",
                          id, u.promptTokens, u.cachedTokens, u.completionTokens, u.ttft * 1000, u.prefillSeconds * 1000,
                          u.decodeSeconds, tps, u.mtpAccept.map { String(format: "%.2f", $0) } ?? "-")
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Returns whether the session is still good to reuse.
    private func streamResponse(_ creq: ChatRequest, _ lease: SessionTable.Lease, _ meta: ChunkMeta,
                                _ responder: Responder, _ engine: any EngineClient) async throws -> Bool {
        var tr = OutputTranslator(stop: creq.stop)
        var it = engine.generate(lease.session, creq.params).makeAsyncIterator()
        let first: GenEvent?
        do { first = try await it.next() } catch { throw APIError.from(error) }

        try await responder.startSSE()
        do {
            try await responder.sseWrite(meta.chunk(delta: .ordered([("role", .string("assistant"))])))
            var ev = first
            var cancelSent = false
            var finished = false
            while let e = ev {
                for o in tr.handle(e) {
                    switch o {
                    case .done(let reason, let usage):
                        finished = true
                        logDone(meta.id, usage)
                        try await responder.sseWrite(meta.chunk(delta: .object([]), finish: reason))
                        if creq.includeUsage { try await responder.sseWrite(meta.usageChunk(usage)) }
                    default:
                        try await responder.sseWrite(meta.chunk(delta: meta.delta(o)))
                    }
                }
                if tr.stopHit && !cancelSent { cancelSent = true; await engine.cancel(lease.session) }
                ev = try await it.next()
            }
            if Task.isCancelled && !finished { return true }   // client went away; the engine cancel is queued
            try await responder.sseWrite("[DONE]")
            return true
        } catch let e as HTTPServerError {
            await engine.cancel(lease.session)
            while (try? await it.next()) != nil {}            // drain so the session is idle for the next turn
            throw e
        } catch {
            let api = APIError.from(error)
            try? await responder.sseWrite(api.json.serialized())
            try? await responder.sseWrite("[DONE]")
            return false
        }
    }

    private func collectResponse(_ creq: ChatRequest, _ lease: SessionTable.Lease, _ meta: ChunkMeta,
                                 _ responder: Responder, _ engine: any EngineClient) async throws -> Bool {
        var tr = OutputTranslator(stop: creq.stop)
        var content = "", reasoning = ""
        var calls: [(id: String, name: String, args: String)] = []
        var done: (String, Usage)?
        var cancelSent = false
        do {
            for try await e in engine.generate(lease.session, creq.params) {
                for o in tr.handle(e) {
                    switch o {
                    case .content(let t): content += t
                    case .reasoning(let t): reasoning += t
                    case .toolStart(_, let id, let name): calls.append((id, name, ""))
                    case .toolArgs(let i, let f): calls[i].args += f
                    case .done(let r, let u): done = (r, u); logDone(meta.id, u)
                    }
                }
                if tr.stopHit && !cancelSent { cancelSent = true; await engine.cancel(lease.session) }
            }
        } catch {
            throw APIError.from(error)
        }
        guard let (reason, usage) = done else { return true }   // cancelled by a disconnect
        // A call truncated mid-function is never returned as something to execute.
        calls = calls.enumerated().filter { !tr.abortedCalls.contains($0.offset) }.map(\.element)
        var msg: [(String, OrderedJSON)] = [("role", .string("assistant"))]
        msg.append(("content", content.isEmpty && !calls.isEmpty ? .null : .string(content)))
        if !reasoning.isEmpty { msg.append(("reasoning_content", .string(reasoning))) }
        if !calls.isEmpty {
            msg.append(("tool_calls", .array(calls.map {
                .ordered([("id", .string($0.id)), ("type", .string("function")),
                          ("function", .ordered([("name", .string($0.name)), ("arguments", .string($0.args))]))])
            })))
        }
        let body: OrderedJSON = .ordered([
            ("id", .string(meta.id)), ("object", .string("chat.completion")), ("created", .int(meta.created)),
            ("model", .string(meta.model)),
            ("choices", .array([.ordered([("index", .int(0)), ("message", .ordered(msg)),
                                          ("finish_reason", .string(reason))])])),
            ("usage", meta.usage(usage)),
        ])
        try await responder.json(200, Data(body.serialized().utf8))
        return true
    }
}

struct ChunkMeta {
    let id: String
    let created: Int
    let model: String

    func chunk(delta: OrderedJSON, finish: String? = nil) -> String {
        OrderedJSON.ordered([
            ("id", .string(id)), ("object", .string("chat.completion.chunk")), ("created", .int(created)),
            ("model", .string(model)),
            ("choices", .array([.ordered([("index", .int(0)), ("delta", delta),
                                          ("finish_reason", finish.map { .string($0) } ?? .null)])])),
        ]).serialized()
    }

    func usageChunk(_ u: Usage) -> String {
        OrderedJSON.ordered([
            ("id", .string(id)), ("object", .string("chat.completion.chunk")), ("created", .int(created)),
            ("model", .string(model)), ("choices", .array([])), ("usage", usage(u)),
        ]).serialized()
    }

    func usage(_ u: Usage) -> OrderedJSON {
        .ordered([
            ("prompt_tokens", .int(u.promptTokens)), ("completion_tokens", .int(u.completionTokens)),
            ("total_tokens", .int(u.promptTokens + u.completionTokens)),
            ("prompt_tokens_details", .ordered([("cached_tokens", .int(u.cachedTokens))])),
        ])
    }

    func delta(_ o: Out) -> OrderedJSON {
        switch o {
        case .content(let t): return .ordered([("content", .string(t))])
        case .reasoning(let t): return .ordered([("reasoning_content", .string(t))])
        case let .toolStart(i, id, name):
            return .ordered([("tool_calls", .array([.ordered([
                ("index", .int(i)), ("id", .string(id)), ("type", .string("function")),
                ("function", .ordered([("name", .string(name)), ("arguments", .string(""))])),
            ])]))])
        case let .toolArgs(i, f):
            return .ordered([("tool_calls", .array([.ordered([
                ("index", .int(i)), ("function", .ordered([("arguments", .string(f))])),
            ])]))])
        case .done: return .object([])
        }
    }
}
