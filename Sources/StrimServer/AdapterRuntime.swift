import Foundation
import StrimAdmission
import StrimEngine
import StrimHTTP
import StrimTemplate

/// Generation plumbing shared by the Anthropic and Responses adapters: session lease, history append, a
/// cancellable generation task, and the stream/collect loops over `OutputTranslator`.
struct Collected {
    var content = ""
    var reasoning = ""
    var calls: [(id: String, name: String, args: String)] = []
    var done: (reason: String, usage: Usage)?
    var stopMatched: String?
}

extension StrimOpenAIServer {
    func parseChat(_ body: OrderedJSON, priorityHeader: String?) throws -> ChatRequest {
        try ChatRequest.parse(Data(body.serialized().utf8), headerPriority: priorityHeader, defaults: config.defaults, ceiling: config.apiPriority)
    }

    /// Leases the session for `creq`, appends its history, then runs `body(lease, promptIds)` in a task that a
    /// client disconnect cancels. `body` returns whether the session is still good to reuse.
    func runTurn(_ creq: ChatRequest, id: String, responder: Responder,
                 _ body: @escaping @Sendable (SessionTable.Lease, Int) async throws -> Bool) async throws {
        lock.withLock { requestsTotal += 1 }
        do {
            try await runTurnInner(creq, id: id, responder: responder, body)
        } catch {
            lock.withLock { requestsFailed += 1 }
            throw error
        }
    }

    /// Takes the admission slot for `creq.params.priority` before any engine call (nil without admission).
    /// A client disconnect while queued drops the waiter.
    func admit(_ creq: ChatRequest, _ responder: Responder) async throws -> AdmissionLease? {
        guard let gate = config.admission else { return nil }
        let cls = AdmissionClass(rawValue: creq.params.priority.rawValue) ?? .interactive
        let st = await gate.stats()
        let retryAfter = max(1, min(config.queueTimeoutSeconds, 5 * (st.waitingInteractive + st.waitingBackground) / max(1, st.activeInteractive + st.activeBackground)))
        if st.waitingInteractive + st.waitingBackground >= config.maxQueuedRequests {
            throw APIError.queueFull(retryAfter: retryAfter)
        }
        let wait = Task { try await gate.lease(cls) }
        let timedOut = TimeoutFlag()
        let deadline = Task {
            try await Task.sleep(for: .seconds(config.queueTimeoutSeconds))
            timedOut.set()
            wait.cancel()
        }
        defer { deadline.cancel() }
        responder.onClose { wait.cancel() }
        do { return try await withTaskCancellationHandler { try await wait.value } onCancel: { wait.cancel() } }
        catch is CancellationError {
            if timedOut.isSet { throw APIError.queueTimeout(retryAfter: retryAfter) }
            throw HTTPServerError.connectionClosed
        }
    }

    private func runTurnInner(_ creq: ChatRequest, id: String, responder: Responder,
                              _ body: @escaping @Sendable (SessionTable.Lease, Int) async throws -> Bool) async throws {
        let slot = try await admit(creq, responder)
        do { try await runAdmitted(creq, id: id, responder: responder, body) } catch { await slot?.release(); throw error }
        await slot?.release()
    }

    private func runAdmitted(_ creq: ChatRequest, id: String, responder: Responder,
                             _ body: @escaping @Sendable (SessionTable.Lease, Int) async throws -> Bool) async throws {
        let lease: SessionTable.Lease
        do { lease = try await sessions.acquire(fingerprint: creq.fingerprint, config: creq.config) }
        catch { throw APIError.from(error) }
        let promptIds: Int
        do {
            promptIds = try await engine.append(lease.session, .history(creq.messages))
        } catch {
            var keep = true
            if case EngineError.unknownSession? = error as? EngineError { keep = false }
            await sessions.release(lease, keep: keep)
            throw APIError.from(error)
        }
        lock.withLock { active[id] = lease.session }
        let work = Task { () -> Result<Bool, Error> in
            do { return .success(try await body(lease, promptIds)) } catch { return .failure(error) }
        }
        responder.onClose { work.cancel() }
        let result = await work.value
        lock.withLock { active[id] = nil }
        switch result {
        case .success(let keep):
            await sessions.release(lease, keep: keep)
        case .failure(let error):
            await sessions.release(lease, keep: false)
            if error is HTTPServerError { return }
            throw error
        }
    }

    /// Streams `OutputTranslator` events to `emit` (second argument: the matched stop string, if any). `start`
    /// runs after the first engine event arrives (so early engine errors are still plain HTTP errors) and once
    /// the SSE response is open. A failure after that point goes to `fail`. Returns whether the session is reusable.
    func driveStream(_ creq: ChatRequest, _ lease: SessionTable.Lease, _ responder: Responder, logId: String,
                     start: () async throws -> Void,
                     emit: (Out, String?) async throws -> Void,
                     fail: (APIError) async -> Void) async throws -> Bool {
        var tr = OutputTranslator(stop: creq.stop)
        var it = engine.generate(lease.session, creq.params).makeAsyncIterator()
        let first: GenEvent?
        do { first = try await it.next() } catch { throw APIError.from(error) }
        try await responder.startSSE()
        do {
            try await start()
            var ev = first
            var cancelSent = false
            while let e = ev {
                for o in tr.handle(e) {
                    if case .done(_, let u) = o { logDone(logId, u) }
                    try await emit(o, tr.stopMatched)
                }
                if tr.stopHit && !cancelSent { cancelSent = true; await engine.cancel(lease.session) }
                ev = try await it.next()
            }
            return true
        } catch let e as HTTPServerError {
            await engine.cancel(lease.session)
            while (try? await it.next()) != nil {}
            throw e
        } catch {
            await fail(APIError.from(error))
            return false
        }
    }

    func collect(_ creq: ChatRequest, _ lease: SessionTable.Lease, logId: String) async throws -> Collected {
        var tr = OutputTranslator(stop: creq.stop)
        var c = Collected()
        var cancelSent = false
        do {
            for try await e in engine.generate(lease.session, creq.params) {
                for o in tr.handle(e) {
                    switch o {
                    case .content(let t): c.content += t
                    case .reasoning(let t): c.reasoning += t
                    case .toolStart(_, let id, let name): c.calls.append((id, name, ""))
                    case .toolArgs(let i, let f): c.calls[i].args += f
                    case .done(let r, let u): c.done = (r, u); logDone(logId, u)
                    }
                }
                if tr.stopHit && !cancelSent { cancelSent = true; await engine.cancel(lease.session) }
            }
        } catch {
            throw APIError.from(error)
        }
        c.stopMatched = tr.stopMatched
        return c
    }

    /// Parses accumulated tool-call arguments (always a JSON object by construction).
    static func argsObject(_ s: String) -> OrderedJSON {
        if let j = try? OrderedJSON.parse(s), case .object = j { return j }
        return .object([])
    }
}

/// Set by the queue-deadline task so `admit` can tell a timeout from a client disconnect.
final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
