import Foundation
import Testing
@testable import StrimEngine

/// Fake engine body: records the thread it runs on and the interleaving of commands and units.
final class FakeWorker: EngineWorker, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _units = 0
    private var _work = 0
    private var _stop = false
    private var _threads = Set<String>()
    var prepareFails = false
    struct Boom: Error {}

    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    var units: Int { lock.lock(); defer { lock.unlock() }; return _units }
    var threads: Set<String> { lock.lock(); defer { lock.unlock() }; return _threads }
    var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return _stop }

    func prepare() throws {
        if prepareFails { throw Boom() }
        mark("prepare")
    }
    func shutdown() { mark("shutdown") }
    func mark(_ s: String) {
        lock.lock(); _log.append(s); _threads.insert(Thread.current.name ?? "?"); lock.unlock()
    }
    func addWork(_ n: Int) { lock.lock(); _work += n; _log.append("work+\(n)"); lock.unlock() }
    func requestStop() { lock.lock(); _stop = true; lock.unlock() }

    func runOneUnit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _work > 0 else { return false }
        _work -= 1; _units += 1; _log.append("unit")
        _threads.insert(Thread.current.name ?? "?")
        return true
    }
}

@Suite struct LoopTests {
    private func start(_ w: FakeWorker) -> EngineLoop<FakeWorker> {
        let loop = EngineLoop(worker: w)
        let ready = DispatchSemaphore(value: 0)
        loop.start { _ in ready.signal() }
        ready.wait()
        return loop
    }

    @Test func everythingRunsOnTheOneEngineThread() {
        let w = FakeWorker()
        let loop = start(w)
        let done = DispatchSemaphore(value: 0)
        loop.send { $0.addWork(5) }
        loop.send { $0.mark("cmd"); done.signal() }
        done.wait()
        loop.send { $0.requestStop() }
        loop.stop()
        loop.waitUntilStopped()
        #expect(w.threads == ["strim-engine"])
        #expect(!Thread.isMainThread)
    }

    @Test func commandsApplyAtUnitBoundariesInPushOrder() {
        let w = FakeWorker()
        let loop = start(w)
        let done = DispatchSemaphore(value: 0)
        loop.send { $0.addWork(3) }
        loop.send { $0.mark("cancel") }       // processed before the next unit
        loop.send { _ in done.signal() }
        done.wait()
        // let the units drain
        for _ in 0 ..< 200 where w.units < 3 { Thread.sleep(forTimeInterval: 0.005) }
        loop.send { $0.requestStop() }
        loop.stop()
        loop.waitUntilStopped()
        let log = w.log
        let iWork = log.firstIndex(of: "work+3")!
        let iCancel = log.firstIndex(of: "cancel")!
        let firstUnit = log.firstIndex(of: "unit")!
        #expect(iWork < iCancel)
        #expect(iCancel < firstUnit)     // the cancel was applied before any unit ran
        #expect(w.units == 3)
        #expect(log.last == "shutdown")
    }

    @Test func idleLoopParksInsteadOfSpinning() {
        let w = FakeWorker()
        let loop = start(w)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(w.units == 0)
        let done = DispatchSemaphore(value: 0)
        loop.send { $0.addWork(1); done.signal() }
        done.wait()
        for _ in 0 ..< 200 where w.units < 1 { Thread.sleep(forTimeInterval: 0.005) }
        #expect(w.units == 1)             // woke from the park to run the unit its command created
        loop.send { $0.requestStop() }
        loop.stop()
        loop.waitUntilStopped()
    }

    @Test func manyProducersLoseNothing() {
        let w = FakeWorker()
        let loop = start(w)
        let group = DispatchGroup()
        for p in 0 ..< 8 {
            DispatchQueue.global().async(group: group) {
                for _ in 0 ..< 50 { loop.send { $0.addWork(1) }; _ = p }
            }
        }
        group.wait()
        for _ in 0 ..< 1000 where w.units < 400 { Thread.sleep(forTimeInterval: 0.005) }
        #expect(w.units == 400)
        loop.send { $0.requestStop() }
        loop.stop()
        loop.waitUntilStopped()
    }

    @Test func prepareFailureIsReported() {
        let w = FakeWorker(); w.prepareFails = true
        let loop = EngineLoop(worker: w)
        let got = DispatchSemaphore(value: 0)
        let err = LockedBox<Error?>(nil)
        loop.start { e in err.value = e; got.signal() }
        got.wait()
        #expect(err.value is FakeWorker.Boom)
        loop.waitUntilStopped()
    }

    @Test func inboxDrainKeepsOrder() {
        let ib = Inbox<Int>()
        for i in 0 ..< 10 { ib.push(i) }
        #expect(ib.drain() == Array(0 ..< 10))
        #expect(ib.drain().isEmpty)
        ib.wait()     // 10 unconsumed signals: returns at once
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let l = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
}
