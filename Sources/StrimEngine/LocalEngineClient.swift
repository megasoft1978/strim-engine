import Foundation
import StrimCore
import StrimTokenizer

/// Handle for code that runs ON the engine thread (diagnostics, benches, parity checks).
/// Not Sendable-safe to stash: use it only inside the closure passed to `perform`.
public final class EngineContext {
    let core: EngineCore
    init(core: EngineCore) { self.core = core }
    public var store: WeightStore { core.store }
    public var head: WeightStore? { core.head }
    public var tokenizer: Tokenizer { core.tokenizer }
    public var prefix: PrefixStore? { core.prefix }
}

/// In-process `EngineClient`. All state lives on one engine thread (see `EngineLoop`); this
/// class only posts commands to its inbox and bridges replies / events back to async callers.
public final class LocalEngineClient: EngineClient, @unchecked Sendable {
    private let core: EngineCore
    private let loop: EngineLoop<EngineCore>
    private let ids = NSLock()
    private var requestCounter = 0

    private init(config: EngineConfig) {
        core = EngineCore(config: config)
        loop = EngineLoop(worker: core)
    }

    /// Spawns the engine thread, loads the model on it and waits until it is ready.
    public static func start(_ config: EngineConfig) async throws -> LocalEngineClient {
        let c = LocalEngineClient(config: config)
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            c.loop.start { err in
                if let err { k.resume(throwing: err) } else { k.resume() }
            }
        }
        return c
    }

    private func nextRequestId() -> Int {
        ids.lock(); defer { ids.unlock() }
        requestCounter += 1
        return requestCounter
    }

    private func call<T: Sendable>(_ body: @escaping @Sendable (EngineCore) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<T, Error>) in
            loop.send { core in
                if core.stopFlag { k.resume(throwing: EngineError.shutdown); return }
                do { k.resume(returning: try body(core)) } catch { k.resume(throwing: error) }
            }
        }
    }

    // MARK: EngineClient

    public func openSession(_ config: SessionConfig) async throws -> SessionID {
        try await call { $0.openSession(config) }
    }

    public func fork(_ session: SessionID, at messageCount: Int?) async throws -> SessionID {
        try await call { try $0.fork(session, at: messageCount) }
    }

    public func append(_ session: SessionID, _ input: TurnInput) async throws -> Int {
        try await call { try $0.append(session, input) }
    }

    public func generate(_ session: SessionID, _ params: GenParams) -> AsyncThrowingStream<GenEvent, Error> {
        let rid = nextRequestId()
        let submitted = Date()
        return AsyncThrowingStream(GenEvent.self, bufferingPolicy: .unbounded) { cont in
            cont.onTermination = { [loop] reason in
                if case .cancelled = reason { loop.send { $0.cancelRequest(rid) } }
            }
            loop.send { core in
                if core.stopFlag { cont.finish(throwing: EngineError.shutdown); return }
                core.startGenerate(requestId: rid, sessionId: session, params: params, submitted: submitted, cont: cont)
            }
        }
    }

    public func cancel(_ session: SessionID) async {
        loop.send { $0.cancelSession(session) }
    }

    public func prefetch(_ ids: [Int32], priority: Priority) async throws {
        let rid = nextRequestId()
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            loop.send { core in
                if core.stopFlag { k.resume(throwing: EngineError.shutdown); return }
                core.startPrefetch(requestId: rid, ids: ids, priority: priority) { err in
                    if let err { k.resume(throwing: err) } else { k.resume() }
                }
            }
        }
    }

    public func ledger(_ session: SessionID) async throws -> LedgerSnapshot {
        try await call { try $0.ledgerSnapshot(session) }
    }

    public func close(_ session: SessionID) async {
        loop.send { $0.closeSession(session) }
    }

    /// Lock-protected snapshot refreshed after every work unit: answers even mid-prefill.
    public func stats() -> EngineStats { core.currentStats() }

    // MARK: extras

    /// Runtime switch for hot sessions (0: every turn restores from the trie).
    public func setHotSessions(_ n: Int) async {
        loop.send { $0.setHotSessions(n) }
    }

    /// Replaces the prefix trie with an empty one of the same budget.
    public func resetPrefixCache() async throws {
        try await call { core in
            if let b = core.cfg.prefixCacheBytes { core.prefix = PrefixStore(budgetBytes: b) }
        }
    }

    /// Runs `body` on the engine thread (the only thread allowed to touch MLX objects here).
    public func perform<T: Sendable>(_ body: @escaping @Sendable (EngineContext) throws -> T) async throws -> T {
        try await call { core in try body(EngineContext(core: core)) }
    }

    /// Stops the engine thread after dropping all state; in-flight requests fail with `.shutdown`.
    public func shutdown() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            loop.send { core in core.stopFlag = true }
            loop.stop()
            DispatchQueue.global().async { [loop] in loop.waitUntilStopped(); k.resume() }
        }
    }
}
