import Foundation
import Testing
@testable import StrimAdmission

/// Lets spawned tasks run until `cond` holds. Pure scheduler yields: no sleeps, no wall clock.
func settle(_ gate: PriorityGate, limit: Int = 20_000, _ cond: @Sendable (AdmissionStats) -> Bool) async -> Bool {
    for _ in 0..<limit {
        if cond(await gate.stats()) { return true }
        await Task.yield()
    }
    return cond(await gate.stats())
}

/// A task that takes a slot and holds it until `open()`; mirrors the old Python `hold()`.
final class Holder: @unchecked Sendable {
    let task: Task<Void, Error>
    private let latch: AsyncStream<Void>.Continuation
    init(_ gate: PriorityGate, _ cls: AdmissionClass) {
        let (s, c) = AsyncStream<Void>.makeStream()
        latch = c
        task = Task {
            let l = try await gate.lease(cls)
            for await _ in s { break }
            await l.release()
        }
    }
    func open() { latch.yield(()) }
}

@Suite struct PriorityGateTests {
    // Port of bench/test_priority.py (max_inflight=2, max_background=1).
    @Test func pythonPriorityScenario() async throws {
        let gate = PriorityGate(maxInflight: 2, maxBackground: 1)
        // Spawn one at a time so bg1 deterministically holds the slot (asyncio gave FIFO for free).
        let bg1 = Holder(gate, .background)
        #expect(await settle(gate) { $0.activeBackground == 1 })
        let bg2 = Holder(gate, .background)
        #expect(await settle(gate) { $0.waitingBackground == 1 })
        let bg3 = Holder(gate, .background)
        #expect(await settle(gate) { $0.activeBackground == 1 && $0.waitingBackground == 2 })

        let i1 = Holder(gate, .interactive)
        #expect(await settle(gate) { $0.activeInteractive == 1 })
        let i2 = Holder(gate, .interactive)
        #expect(await settle(gate) { $0.activeInteractive == 1 && $0.activeBackground == 1 && $0.waitingInteractive == 1 })

        // Releasing the background slot must go to the waiting interactive, not background.
        bg1.open()
        #expect(await settle(gate) { $0.activeInteractive == 2 && $0.activeBackground == 0 })
        #expect(await gate.stats().waitingBackground == 2)

        // With no interactive waiting, one background (and only one) proceeds.
        i1.open()
        #expect(await settle(gate) { $0.activeInteractive == 1 && $0.activeBackground == 1 })
        #expect(await gate.stats().waitingBackground == 1)

        i2.open()
        #expect(await settle(gate) { $0.activeInteractive == 0 && $0.activeBackground == 1 })
        #expect(await gate.stats().waitingBackground == 1)

        bg2.open()
        #expect(await settle(gate) { $0.activeBackground == 1 && $0.waitingBackground == 0 })

        bg3.open()
        for h in [bg1, bg2, bg3, i1, i2] { try await h.task.value }
        let s = await gate.stats()
        #expect(s.activeInteractive == 0 && s.activeBackground == 0)
        #expect(s.admittedInteractive == 2 && s.admittedBackground == 3)
    }

    // Port of bench/test_priority_ordering.py and bench/test_mcp_gate.py: the slot is held while the work runs.
    @Test func slotHeldWhileWorkRuns() async throws {
        let gate = PriorityGate(maxInflight: 2, maxBackground: 1)
        for cls in AdmissionClass.allCases {
            let held = try await gate.withSlot(cls) { () -> Int in
                let s = await gate.stats(); return s.activeInteractive + s.activeBackground
            }
            #expect(held >= 1)
        }
        let s = await gate.stats()
        #expect(s.activeInteractive + s.activeBackground == 0)
    }

    @Test func slotReleasedWhenWorkThrows() async {
        struct Boom: Error {}
        let gate = PriorityGate(maxInflight: 1)
        await #expect(throws: Boom.self) { try await gate.withSlot(.background) { throw Boom() } }
        let s = await gate.stats()
        #expect(s.activeBackground == 0)
    }

    @Test func arrivingInteractiveNeverWaitsBehindBackground() async throws {
        let gate = PriorityGate(maxInflight: 2, maxBackground: 2)  // cap clamps to 1
        let bg = Holder(gate, .background), bg2 = Holder(gate, .background)
        #expect(await settle(gate) { $0.activeBackground == 1 && $0.waitingBackground == 1 })
        let i = Holder(gate, .interactive)
        #expect(await settle(gate) { $0.activeInteractive == 1 })
        for h in [bg, bg2, i] { h.open() }
        for h in [bg, bg2, i] { try await h.task.value }
    }

    @Test func cancelWhileWaitingDropsWaiter() async throws {
        let gate = PriorityGate(maxInflight: 1)
        let hold = Holder(gate, .interactive)
        #expect(await settle(gate) { $0.activeInteractive == 1 })
        let w = Task { try await gate.acquire(.background) }
        #expect(await settle(gate) { $0.waitingBackground == 1 })
        w.cancel()
        await #expect(throws: CancellationError.self) { _ = try await w.value }
        #expect(await settle(gate) { $0.waitingBackground == 0 })
        hold.open(); try await hold.task.value
        #expect(await gate.stats().admittedBackground == 0)
    }

    @Test func cancelBeforeAcquireThrowsAndLeavesNothing() async {
        let gate = PriorityGate(maxInflight: 1)
        let t = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await gate.acquire(.interactive); return false } catch { return true }
        }
        #expect(await t.value)
        let s = await gate.stats()
        #expect(s.activeInteractive == 0 && s.waitingInteractive == 0)
    }

    @Test func cancelledWaiterLetsNextClassProceed() async throws {
        let gate = PriorityGate(maxInflight: 1)
        let hold = Holder(gate, .background)
        #expect(await settle(gate) { $0.activeBackground == 1 })
        let w1 = Task { try await gate.acquire(.interactive) }
        let w2 = Holder(gate, .background)
        #expect(await settle(gate) { $0.waitingInteractive == 1 && $0.waitingBackground == 1 })
        w1.cancel()
        _ = try? await w1.value
        hold.open(); try await hold.task.value
        #expect(await settle(gate) { $0.activeBackground == 1 })
        w2.open(); try await w2.task.value
    }

    @Test func releaseIsIdempotent() async throws {
        let gate = PriorityGate(maxInflight: 1)
        let t = try await gate.acquire(.interactive)
        await gate.release(t); await gate.release(t)
        let l = try await gate.lease(.background)
        await l.release(); await l.release()
        let s = await gate.stats()
        #expect(s.activeInteractive == 0 && s.activeBackground == 0)
    }

    // Background yields its slot at a turn boundary while interactive is active or queued, never otherwise.
    @Test func checkpointIsNoOpWithoutInteractive() async throws {
        let gate = PriorityGate(maxInflight: 2)
        let l = try await gate.lease(.background)
        try await l.checkpoint()
        let s = await gate.stats()
        #expect(s.backgroundYields == 0 && s.activeBackground == 1)
        await l.release()
    }

    @Test func backgroundPausedWhileInteractiveActive() async throws {
        let gate = PriorityGate(maxInflight: 2)
        let bg = try await gate.lease(.background)
        let i = try await gate.lease(.interactive)
        let resumed = Task { try await bg.checkpoint() }
        #expect(await settle(gate) { $0.backgroundYields == 1 && $0.waitingBackground == 1 && $0.activeBackground == 0 })
        await Task.yield()
        #expect(await gate.stats().waitingBackground == 1)   // still paused
        await i.release()
        try await resumed.value
        let s = await gate.stats()
        #expect(s.activeBackground == 1 && s.waitingBackground == 0)
        await bg.release()
    }

    @Test func yieldedSlotGoesToWaitingInteractive() async throws {
        let gate = PriorityGate(maxInflight: 1)
        let bg = try await gate.lease(.background)
        let w = Task { try await gate.lease(.interactive) }
        #expect(await settle(gate) { $0.waitingInteractive == 1 })
        let cp = Task { try await bg.checkpoint() }
        let il = try await w.value                 // interactive got the slot the background gave up
        #expect(await gate.stats().activeInteractive == 1)
        await il.release()
        try await cp.value
        #expect(await gate.stats().activeBackground == 1)
        await bg.release()
    }

    @Test func cancelWhilePausedAtCheckpoint() async throws {
        let gate = PriorityGate(maxInflight: 2)
        let bg = try await gate.lease(.background)
        let i = try await gate.lease(.interactive)
        let cp = Task { try await bg.checkpoint() }
        #expect(await settle(gate) { $0.waitingBackground == 1 })
        cp.cancel()
        await #expect(throws: CancellationError.self) { try await cp.value }
        await bg.release()          // lease still releases cleanly; nothing leaks
        await i.release()
        let s = await gate.stats()
        #expect(s.activeBackground == 0 && s.waitingBackground == 0 && s.activeInteractive == 0)
    }

    @Test func releaseDuringPausedCheckpointDoesNotLeakSlot() async throws {
        let gate = PriorityGate(maxInflight: 2)
        let bg = try await gate.lease(.background)
        let i = try await gate.lease(.interactive)
        let cp = Task { try await bg.checkpoint() }
        #expect(await settle(gate) { $0.waitingBackground == 1 })
        await bg.release()                                  // job cancelled while parked at the boundary
        await i.release()
        try await cp.value
        #expect(await settle(gate) { $0.activeBackground == 0 && $0.waitingBackground == 0 })
    }

    @Test func waitStatsUseInjectedClock() async throws {
        let t = ClockBox()
        let gate = PriorityGate(limits: AdmissionLimits(maxInflight: 1), clock: { t.value })
        let a = try await gate.acquire(.interactive)
        let w = Task { try await gate.acquire(.interactive) }
        #expect(await settle(gate) { $0.waitingInteractive == 1 })
        t.value = 5
        await gate.release(a)
        let b = try await w.value
        #expect(await gate.stats().totalWaitInteractive == 5)
        await gate.release(b)
    }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0.0
    var value: Double { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}
