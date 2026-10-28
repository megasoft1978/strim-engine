import Foundation
import Testing
import StrimEngine
@testable import StrimHost

/// Engine stub with a deinit probe; never generates unless `hold` is used.
final class SlotFakeEngine: EngineClient, @unchecked Sendable {
    let onDeinit: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var next: UInt64 = 0
    private(set) var closed: [SessionID] = []
    var active: EngineStats = { var s = EngineStats(); s.mlxActiveBytes = 7 << 30; return s }()
    var script: [GenEvent] = []
    init(onDeinit: (@Sendable () -> Void)? = nil) { self.onDeinit = onDeinit }
    deinit { onDeinit?() }

    func openSession(_ config: SessionConfig) async throws -> SessionID {
        lock.withLock { next += 1; return SessionID(raw: next) }
    }
    func fork(_ session: SessionID, at messageCount: Int?) async throws -> SessionID { session }
    func append(_ session: SessionID, _ input: TurnInput) async throws -> Int { 1 }
    func generate(_ session: SessionID, _ params: GenParams) -> AsyncThrowingStream<GenEvent, Error> {
        let events = script
        return AsyncThrowingStream { c in for e in events { c.yield(e) }; c.finish() }
    }
    func cancel(_ session: SessionID) async {}
    func prefetch(_ ids: [Int32], priority: Priority) async throws {}
    func ledger(_ session: SessionID) async throws -> LedgerSnapshot { LedgerSnapshot(ids: [], messageCount: 0) }
    func close(_ session: SessionID) async { lock.withLock { closed.append(session) } }
    func stats() -> EngineStats { active }
}

private final class Flag: @unchecked Sendable {
    private let l = NSLock(); private var v = 0
    func bump() { l.withLock { v += 1 } }
    var count: Int { l.withLock { v } }
}

/// Holds a factory call until `open()`.
private actor Gate {
    private var conts: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async { if isOpen { return }; await withCheckedContinuation { conts.append($0) } }
    func open() { isOpen = true; conts.forEach { $0.resume() }; conts = [] }
}

private struct Boom: Error, CustomStringConvertible { var description: String { "boom: weights missing" } }

@Suite("EngineSlot", .serialized)
struct EngineSlotTests {
    @Test("load -> ready; engine is reachable through the proxy; stats mirror the engine")
    func loadReady() async throws {
        let slot = EngineSlot(factory: { _, _, _ in SlotFakeEngine() })
        #expect(await slot.status().state == .stopped)
        try await slot.load(model: "m", mtp: "h")
        let st = await slot.status()
        #expect(st.state == .ready && st.model == "m" && st.mtp == "h" && st.progress == nil)
        #expect(st.weightsBytes == 7 << 30)
        let id = try await slot.client.openSession(SessionConfig())
        #expect(id.raw & ((1 << 48) - 1) == 1)
        #expect(slot.client.stats().healthy)
    }

    @Test("nothing loaded: proxy is unhealthy and refuses sessions")
    func unloadedProxy() async throws {
        let slot = EngineSlot(factory: { _, _, _ in SlotFakeEngine() })
        #expect(!slot.client.stats().healthy)
        await #expect(throws: EngineError.self) { _ = try await slot.client.openSession(SessionConfig()) }
    }

    @Test("failed load -> .error with message; retry succeeds")
    func failureAndRetry() async throws {
        let fail = Flag()
        let slot = EngineSlot(factory: { _, _, _ in
            if fail.count == 0 { fail.bump(); throw Boom() }
            return SlotFakeEngine()
        })
        await #expect(throws: EngineSlotError.loadFailed("boom: weights missing")) { try await slot.load(model: "m") }
        let e = await slot.status()
        #expect(e.state == .error && e.errorMessage == "boom: weights missing" && e.model == "m")
        try await slot.load(model: "m")
        let ok = await slot.status()
        #expect(ok.state == .ready && ok.errorMessage == nil)
    }

    @Test("load while loading is refused; only one factory call; state is .loading with progress")
    func loadWhileLoading() async throws {
        let gate = Gate(); let calls = Flag()
        let slot = EngineSlot(factory: { _, _, progress in
            calls.bump(); progress(0.5); await gate.wait(); return SlotFakeEngine()
        })
        let first = Task { try await slot.load(model: "m") }
        while await slot.status().state != .loading { await Task.yield() }
        await #expect(throws: EngineSlotError.loading) { try await slot.load(model: "m") }
        await #expect(throws: EngineSlotError.loading) { try await slot.beginLoad(model: "other") }
        await #expect(throws: EngineSlotError.loading) { try await slot.unload() }
        for _ in 0..<200 where (await slot.status().progress ?? 0) < 0.5 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await slot.status().progress == 0.5)
        await gate.open()
        try await first.value
        #expect(calls.count == 1)
        #expect(await slot.status().state == .ready)
    }

    @Test("20 concurrent loads: exactly one wins, the rest are no-ops or refusals, never two factories")
    func concurrentLoads() async throws {
        let calls = Flag()
        let slot = EngineSlot(factory: { _, _, _ in
            calls.bump(); try await Task.sleep(for: .milliseconds(30)); return SlotFakeEngine()
        })
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<20 { g.addTask { try? await slot.load(model: "m") } }
        }
        #expect(calls.count == 1)
        #expect(await slot.status().state == .ready)
    }

    @Test("same model again is a no-op; another model while ready is refused")
    func reload() async throws {
        let calls = Flag()
        let slot = EngineSlot(factory: { _, _, _ in calls.bump(); return SlotFakeEngine() })
        try await slot.load(model: "a", mtp: "h")
        try await slot.load(model: "a", mtp: "h")
        #expect(calls.count == 1)
        await #expect(throws: EngineSlotError.alreadyLoaded(model: "a")) { try await slot.load(model: "b") }
        #expect(await slot.status().model == "a")
    }

    @Test("beginLoad returns at once in .loading; failure shows up as .error")
    func beginLoad() async throws {
        let gate = Gate()
        let slot = EngineSlot(factory: { _, _, _ in await gate.wait(); throw Boom() })
        try await slot.beginLoad(model: "m")
        #expect(await slot.status().state == .loading)
        await gate.open()
        await slot.waitForLoad()
        let st = await slot.status()
        #expect(st.state == .error && st.errorMessage == "boom: weights missing")
    }

    @Test("unload releases the engine (deinit probe), calls release, new sessions fail")
    func unloadReleases() async throws {
        let deinits = Flag(); let released = Flag()
        let slot = EngineSlot(factory: { _, _, _ in
            let e = SlotFakeEngine(onDeinit: { deinits.bump() }); return e
        }, release: { _ in released.bump() })
        try await slot.load(model: "m")
        let id = try await slot.client.openSession(SessionConfig())
        try await slot.unload()
        for _ in 0..<50 where deinits.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(deinits.count == 1, "engine still referenced after unload")
        #expect(released.count == 1)
        let st = await slot.status()
        #expect(st.state == .stopped && st.model == nil)
        await #expect(throws: EngineError.self) { _ = try await slot.client.openSession(SessionConfig()) }
        await #expect(throws: EngineError.self) { _ = try await slot.client.append(id, .ids([1])) }
    }

    @Test("sessions of an unloaded engine are not honoured by the next one")
    func staleSessions() async throws {
        let slot = EngineSlot(factory: { _, _, _ in SlotFakeEngine() })
        try await slot.load(model: "m")
        let old = try await slot.client.openSession(SessionConfig())
        try await slot.unload()
        try await slot.load(model: "m")
        let fresh = try await slot.client.openSession(SessionConfig())
        #expect(old != fresh)
        await #expect(throws: EngineError.self) { _ = try await slot.client.append(old, .ids([1])) }
        _ = try await slot.client.append(fresh, .ids([1]))
    }

    @Test("unload with work running is refused (.busy) and leaves the slot ready; force unloads")
    func unloadBusy() async throws {
        let n = Flag()
        let slot = EngineSlot(factory: { _, _, _ in SlotFakeEngine() }, busyProbe: { n.count })
        try await slot.load(model: "m")
        n.bump()
        #expect(await slot.status().state == .busy)
        await #expect(throws: EngineSlotError.busy(activeWork: 1)) { try await slot.unload() }
        #expect(await slot.status().model == "m")
        _ = try await slot.client.openSession(SessionConfig())   // draining was reverted
        try await slot.unload(force: true)
        #expect(await slot.status().state == .stopped)
    }

    @Test("a generation in flight through the proxy counts as busy")
    func inflightBusy() async throws {
        let engine = SlotFakeEngine()
        let slot = EngineSlot(factory: { _, _, _ in engine })
        try await slot.load(model: "m")
        let id = try await slot.client.openSession(SessionConfig())
        let stream = slot.client.generate(id, GenParams())
        #expect(slot.client.activeRequests == 1)
        for try await _ in stream {}
        for _ in 0..<50 where slot.client.activeRequests > 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(slot.client.activeRequests == 0)
    }

    @Test("a second unload while one is running is refused and does not clear the draining flag")
    func unloadReentrancy() async throws {
        let gate = Gate()
        let slot = EngineSlot(factory: { _, _, _ in SlotFakeEngine() }, busyProbe: { await gate.wait(); return 1 })
        try await slot.load(model: "m")
        let first = Task { try await slot.unload() }          // parks in the busy probe, draining set
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: EngineSlotError.unloading) { try await slot.unload() }
        await #expect(throws: EngineError.self) { _ = try await slot.client.openSession(SessionConfig()) }   // still draining
        await gate.open()
        await #expect(throws: EngineSlotError.busy(activeWork: 1)) { try await first.value }
        _ = try await slot.client.openSession(SessionConfig())   // the holder reverted it
    }

    @Test("unload while stopped is a no-op; from .error goes back to stopped")
    func unloadIdle() async throws {
        let slot = EngineSlot(factory: { _, _, _ in throw Boom() })
        try await slot.unload()
        try? await slot.load(model: "m")
        #expect(await slot.status().state == .error)
        try await slot.unload()
        let st = await slot.status()
        #expect(st.state == .stopped && st.errorMessage == nil)
    }

    @Test("unload racing 10 session opens: no session survives into the stopped slot")
    func unloadRace() async throws {
        let slot = EngineSlot(factory: { _, _, _ in SlotFakeEngine() })
        try await slot.load(model: "m")
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<10 { g.addTask { _ = try? await slot.client.openSession(SessionConfig()) } }
            g.addTask { try? await slot.unload() }
        }
        #expect(await slot.status().state == .stopped)
        await #expect(throws: EngineError.self) { _ = try await slot.client.openSession(SessionConfig()) }
    }

    @Test("observers see loading -> ready -> stopped")
    func observe() async throws {
        let log = LockedLog()
        let slot = EngineSlot(factory: { _, _, _ in SlotFakeEngine() })
        _ = await slot.observe { log.add($0.state) }
        try await slot.load(model: "m")
        try await slot.unload()
        #expect(log.items == [.loading, .ready, .stopped])
    }

    @Test("meter: EWMA throughput, cache hit rate and saved prefill seconds from Usage")
    func meter() {
        let m = EngineMeter()
        var u = Usage()
        u.promptTokens = 1000; u.cachedTokens = 0; u.prefillSeconds = 2; u.completionTokens = 100; u.decodeSeconds = 4
        u.mtpAccept = 0.5; u.mtpPasses = 50
        m.record(u)
        var v = Usage()
        v.promptTokens = 1000; v.cachedTokens = 900; v.prefillSeconds = 0.2; v.completionTokens = 50; v.decodeSeconds = 1
        m.record(v)
        let s = m.snapshot()
        #expect(s.requests == 2 && s.completionTokens == 150 && s.tokensToday == 150)
        #expect(abs(s.prefixHitRate - 0.45) < 1e-9)
        #expect(abs(s.decodeTPS - (25 + 0.2 * (50 - 25))) < 1e-9)
        #expect(s.prefillTPS > 0 && s.savedPrefillSeconds > 0)
        #expect(abs(s.mtpAcceptance - 0.5) < 1e-9 && abs(s.mtpDepth - 2) < 1e-9)
    }

    @Test("proxy feeds the meter from finished generations")
    func proxyMeter() async throws {
        let engine = SlotFakeEngine()
        var u = Usage(); u.promptTokens = 10; u.completionTokens = 20; u.decodeSeconds = 2
        engine.script = [.finished(.stop, u)]
        let slot = EngineSlot(factory: { _, _, _ in engine })
        try await slot.load(model: "m")
        let id = try await slot.client.openSession(SessionConfig())
        for try await _ in slot.client.generate(id, GenParams()) {}
        #expect(abs(slot.meter.snapshot().decodeTPS - 10) < 1e-9)
    }
}

private final class LockedLog: @unchecked Sendable {
    private let l = NSLock(); private var a: [SlotState] = []
    func add(_ s: SlotState) { l.withLock { a.append(s) } }
    var items: [SlotState] { l.withLock { a } }
}
