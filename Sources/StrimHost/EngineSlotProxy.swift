import Foundation
import StrimEngine

/// `EngineClient` that forwards to whatever engine its `EngineSlot` currently holds. It is the only handle
/// the server and harness keep, so unloading drops the real engine's last reference.
///
/// Session ids are tagged with the load generation (high 16 bits), so ids from an unloaded engine are
/// refused (`unknownSession`) instead of aliasing sessions of the next engine.
public final class SlotEngineClient: EngineClient, @unchecked Sendable {
    private static let genShift: UInt64 = 48
    private static let rawMask: UInt64 = (1 << 48) - 1

    private let lock = NSLock()
    private var engine: (any EngineClient)?
    private var generation: UInt64 = 0
    private var draining = false
    private var inflight = 0
    private let meter: EngineMeter

    init(meter: EngineMeter) { self.meter = meter }

    // MARK: slot side

    func install(_ e: any EngineClient) {
        lock.withLock { engine = e; generation += 1; draining = false }
    }
    func uninstall() -> (any EngineClient)? {
        lock.withLock { let e = engine; engine = nil; draining = false; return e }
    }
    func setDraining(_ on: Bool) { lock.withLock { draining = on } }

    /// Generations in flight through this proxy.
    public var activeRequests: Int { lock.withLock { inflight } }
    public var isLoaded: Bool { lock.withLock { engine != nil } }

    // MARK: id mapping

    private func wrap(_ raw: SessionID, gen: UInt64) -> SessionID { SessionID(raw: (gen << Self.genShift) | (raw.raw & Self.rawMask)) }

    private func resolve(_ id: SessionID) throws -> (any EngineClient, SessionID) {
        let (e, g): ((any EngineClient)?, UInt64) = lock.withLock { (engine, generation) }
        guard let e, id.raw >> Self.genShift == g else { throw EngineError.unknownSession(id) }
        return (e, SessionID(raw: id.raw & Self.rawMask))
    }

    private func current(forOpen: Bool = false) throws -> (any EngineClient, UInt64) {
        let (e, g, d): ((any EngineClient)?, UInt64, Bool) = lock.withLock { (engine, generation, draining) }
        guard let e else { throw EngineError.unhealthy("no model loaded") }
        if forOpen, d { throw EngineError.unhealthy("model is unloading") }
        return (e, g)
    }

    // MARK: EngineClient

    public func openSession(_ config: SessionConfig) async throws -> SessionID {
        let (e, g) = try current(forOpen: true)
        return wrap(try await e.openSession(config), gen: g)
    }

    public func fork(_ session: SessionID, at messageCount: Int?) async throws -> SessionID {
        let (e, raw) = try resolve(session)
        return wrap(try await e.fork(raw, at: messageCount), gen: session.raw >> Self.genShift)
    }

    public func append(_ session: SessionID, _ input: TurnInput) async throws -> Int {
        let (e, raw) = try resolve(session)
        return try await e.append(raw, input)
    }

    public func generate(_ session: SessionID, _ params: GenParams) -> AsyncThrowingStream<GenEvent, Error> {
        guard let (e, raw) = try? resolve(session) else {
            return AsyncThrowingStream { $0.finish(throwing: EngineError.unknownSession(session)) }
        }
        lock.withLock { inflight += 1 }
        let inner = e.generate(raw, params)
        let meter = self.meter
        return AsyncThrowingStream { cont in
            let task = Task { [weak self] in
                defer { self?.lock.withLock { self?.inflight -= 1 } }
                do {
                    for try await ev in inner {
                        if case let .finished(_, usage) = ev { meter.record(usage) }
                        cont.yield(ev)
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(_ session: SessionID) async {
        guard let (e, raw) = try? resolve(session) else { return }
        await e.cancel(raw)
    }

    public func prefetch(_ ids: [Int32], priority: Priority) async throws {
        let (e, _) = try current(forOpen: true)
        try await e.prefetch(ids, priority: priority)
    }

    public func ledger(_ session: SessionID) async throws -> LedgerSnapshot {
        let (e, raw) = try resolve(session)
        return try await e.ledger(raw)
    }

    public func close(_ session: SessionID) async {
        guard let (e, raw) = try? resolve(session) else { return }
        await e.close(raw)
    }

    public func stats() -> EngineStats {
        let e = lock.withLock { engine }
        if let e { return e.stats() }
        var s = EngineStats()
        s.healthy = false; s.unhealthyReason = "no model loaded"
        return s
    }
}
