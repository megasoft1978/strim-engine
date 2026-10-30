import Foundation
import StrimEngine
import StrimTemplate

/// Scripted `EngineClient` for driving the server without a GPU.
final class FakeEngine: EngineClient, @unchecked Sendable {
    enum Step: Sendable {
        case event(GenEvent)
        case wait(Duration)
        /// Blocks until cancelled (by `cancel(session)` or by the consumer dropping the stream).
        case hang
        case fail(EngineError)
    }

    struct Call: Sendable {
        let session: SessionID
        let params: GenParams
    }

    private let lock = NSLock()
    private var scripts: [[Step]] = []
    private var lastScript: [Step] = []
    private var nextSession: UInt64 = 0
    private var live: [SessionID: AsyncThrowingStream<GenEvent, Error>.Continuation] = [:]
    private(set) var opened: [(SessionID, SessionConfig)] = []
    private(set) var closed: [SessionID] = []
    private(set) var appends: [(SessionID, TurnInput)] = []
    private(set) var generates: [Call] = []
    private(set) var cancels: [SessionID] = []
    private(set) var terminatedCancelled = 0
    /// Overrides the ledger length `append` returns (default 1).
    var appendCounter: (@Sendable (TurnInput) -> Int)?
    var openError: EngineError?
    var reportedStats = EngineStats()
    var unhealthy: String?

    /// Queue one script per expected `generate` call (the last one used repeats when the queue is empty).
    func script(_ steps: [Step]) { lock.withLock { scripts.append(steps) } }

    func snapshot<T>(_ body: (FakeEngine) -> T) -> T { lock.withLock { body(self) } }

    func openSession(_ config: SessionConfig) async throws -> SessionID {
        try lock.withLock {
            if let e = openError { throw e }
            nextSession += 1
            let id = SessionID(raw: nextSession)
            opened.append((id, config))
            return id
        }
    }

    func fork(_ session: SessionID, at messageCount: Int?) async throws -> SessionID { session }

    func append(_ session: SessionID, _ input: TurnInput) async throws -> Int {
        lock.withLock { appends.append((session, input)) }
        return appendCounter?(input) ?? 1
    }

    func generate(_ session: SessionID, _ params: GenParams) -> AsyncThrowingStream<GenEvent, Error> {
        let steps: [Step] = lock.withLock {
            generates.append(Call(session: session, params: params))
            if !scripts.isEmpty { lastScript = scripts.removeFirst() }
            return lastScript
        }
        return AsyncThrowingStream(GenEvent.self, bufferingPolicy: .unbounded) { cont in
            let task = Task {
                for step in steps {
                    if Task.isCancelled { return }
                    switch step {
                    case .event(let e): cont.yield(e)
                    case .wait(let d): try? await Task.sleep(for: d)
                    case .hang: try? await Task.sleep(for: .seconds(60))
                    case .fail(let e): cont.finish(throwing: e); return
                    }
                }
                cont.finish()
            }
            lock.withLock { live[session] = cont }
            cont.onTermination = { [weak self] reason in
                task.cancel()
                guard let self else { return }
                self.lock.withLock {
                    self.live[session] = nil
                    if case .cancelled = reason { self.terminatedCancelled += 1 }
                }
            }
        }
    }

    func cancel(_ session: SessionID) async {
        let c: AsyncThrowingStream<GenEvent, Error>.Continuation? = lock.withLock {
            cancels.append(session)
            return live[session]
        }
        var u = Usage(); u.promptTokens = 10; u.completionTokens = 1
        c?.yield(.finished(.cancelled, u))
        c?.finish()
    }

    func prefetch(_ ids: [Int32], priority: Priority) async throws {}
    func ledger(_ session: SessionID) async throws -> LedgerSnapshot { LedgerSnapshot(ids: [], messageCount: 0, ledger: nil) }
    func close(_ session: SessionID) async { lock.withLock { closed.append(session) } }

    func stats() -> EngineStats {
        var s = reportedStats
        if let u = lock.withLock({ unhealthy }) { s.healthy = false; s.unhealthyReason = u }
        return s
    }
}

func makeUsage(prompt: Int = 10, cached: Int = 0, completion: Int = 3) -> Usage {
    var u = Usage()
    u.promptTokens = prompt; u.cachedTokens = cached; u.completionTokens = completion
    return u
}
