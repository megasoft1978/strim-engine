import Foundation
import Testing
import StrimAdmission
import StrimHarness
@testable import StrimJobs

/// Sticky latch: `wait()` returns once opened, or when the waiting task is cancelled. No clock involved.
private final class Latch: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let cont: AsyncStream<Void>.Continuation
    init() { (stream, cont) = AsyncStream<Void>.makeStream() }
    func open() { cont.finish() }
    func wait() async { for await _ in stream {} }
}

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var latches: [String: Latch] = [:]
    var log: [String] { lock.withLock { _log } }
    func note(_ s: String) { lock.withLock { _log.append(s) } }
    func latch(_ n: String) -> Latch { lock.withLock { if let l = latches[n] { return l }; let l = Latch(); latches[n] = l; return l } }
    func open(_ n: String) { latch(n).open() }
}

/// Task names: "instant"; "probe" records the gate load at start; "block" waits for its latch;
/// "turns" runs three turns, each gated by latch t0..t2 with a turn-boundary checkpoint between them.
private func executor(_ p: Probe, gate: PriorityGate) -> JobExecutor {
    { spec, _, _ in
        p.note("start:\(spec.task)")
        switch spec.task {
        case "probe":
            let s = await gate.stats()
            p.note("held:\(s.activeBackground + s.activeInteractive)")
        case "block":
            await p.latch("block").wait()
            if Task.isCancelled { p.note("cancelled"); return HarnessJobResult(status: .cancelled, summary: "stopped") }
        case "turns":
            for i in 0..<3 {
                p.note("turn\(i)")
                await p.latch("t\(i)").wait()
                if Task.isCancelled { p.note("cancelled"); return HarnessJobResult(status: .cancelled, summary: "stopped") }
                if i < 2 {
                    do { try await AdmissionCheckpoint.wait() } catch {
                        p.note("cancelled"); return HarnessJobResult(status: .cancelled, summary: "stopped")
                    }
                }
            }
        default: break
        }
        return HarnessJobResult(status: .done, summary: "ok")
    }
}

private func manager(_ p: Probe, _ gate: PriorityGate, chat: ChatBackend? = nil, maxConcurrent: Int = 2) -> JobManager {
    JobManager(executor: executor(p, gate: gate), maxConcurrent: maxConcurrent, pollInterval: .seconds(3600),
               chat: chat, admission: gate)
}

private func job(_ task: String) -> HarnessJobSpec { HarnessJobSpec(task: task, cwd: "/tmp/p") }

private func settle(_ limit: Int = 50_000, _ cond: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<limit {
        if await cond() { return true }
        await Task.yield()
    }
    return await cond()
}

private func status(_ m: JobManager, _ id: JobID) async -> JobStatus? { try? await m.status(id, waitS: 0).status }

private final class LatchChat: ChatBackend, @unchecked Sendable {
    let turn = Latch()
    func openSession(spec: HarnessJobSpec, sessionID: String, profile: RunProfile) async throws {}
    func appendUserTurn(sessionID: String, text: String) async throws -> AsyncStream<ChatEvent> {
        let (s, c) = AsyncStream<ChatEvent>.makeStream()
        Task {
            await turn.wait()
            c.yield(.turnFinished(ChatTurnResult(userTurn: 1, status: .done, summary: "r", usage: HarnessUsage(), totalUsage: HarnessUsage())))
            c.finish()
        }
        return s
    }
    func cancelTurn(sessionID: String) async {}
    func closeSession(sessionID: String) async -> HarnessJobResult? { HarnessJobResult(status: .done, summary: "closed") }
}

@Suite struct AdmissionJobTests {
    // Port of bench/test_mcp_gate.py: a delegated (MCP) job holds an admission slot while it runs.
    @Test func delegatedJobHoldsSlotWhileExecutorRuns() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 2)
        let m = manager(p, gate)
        let id = try await m.submit(job("probe"))
        #expect(await settle { await status(m, id) == .done })
        #expect(p.log == ["start:probe", "held:1"])
        let s = await gate.stats()
        #expect(s.admittedBackground == 1 && s.admittedInteractive == 0)
        #expect(await settle { await gate.stats().activeBackground == 0 })   // released after the run
    }

    @Test func backgroundJobWaitsForSlotThenRuns() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 1)
        let m = manager(p, gate)
        let chat = try await gate.lease(.interactive)
        let id = try await m.submit(job("instant"))
        #expect(await settle { await gate.stats().waitingBackground == 1 })
        #expect(await status(m, id) == .preparing)
        #expect(p.log.isEmpty)                                   // not started: admission precedes the executor
        await chat.release()
        #expect(await settle { await status(m, id) == .done })
        #expect(p.log == ["start:instant"])
    }

    @Test func boundedBackgroundJobs() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 3, maxBackground: 1)
        let m = manager(p, gate, maxConcurrent: 3)
        let ids = [try await m.submit(job("block")), try await m.submit(job("block")), try await m.submit(job("block"))]
        #expect(await settle { let g = await gate.stats(); return g.activeBackground == 1 && g.waitingBackground == 2 })
        #expect(p.log.count == 1)
        p.open("block")
        for id in ids { #expect(await settle { await status(m, id) == .done }) }
        #expect(p.log.count == 3)
    }

    @Test func cancelWhileWaitingForAdmission() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 1)
        let m = manager(p, gate)
        let hold = try await gate.lease(.interactive)
        let id = try await m.submit(job("instant"))
        #expect(await settle { await gate.stats().waitingBackground == 1 })
        let snap = try await m.cancel(id)
        #expect(snap.status == .cancelled)
        #expect(await settle { await gate.stats().waitingBackground == 0 })
        await hold.release()
        #expect(p.log.isEmpty)
        #expect(await gate.stats().admittedBackground == 0)
    }

    @Test func cancelWhileQueuedBehindMaxConcurrent() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 2)
        let m = manager(p, gate, maxConcurrent: 1)
        let a = try await m.submit(job("block")), b = try await m.submit(job("block"))
        #expect(await settle { await status(m, a) == .running })
        #expect(try await m.cancel(b).status == .cancelled)
        p.open("block")
        #expect(await settle { await status(m, a) == .done })
        #expect(p.log == ["start:block"])
    }

    @Test func cancelWhileRunningReleasesSlot() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 2)
        let m = manager(p, gate)
        let id = try await m.submit(job("block"))
        #expect(await settle { let g = await gate.stats(); let st = await status(m, id); return g.activeBackground == 1 && st == .running })
        _ = try await m.cancel(id)
        #expect(await settle { await gate.stats().activeBackground == 0 })
        #expect(await status(m, id) == .cancelled)
    }

    @Test func cancelAtCheckpointWhilePaused() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 2)
        let m = manager(p, gate)
        let i = try await gate.lease(.interactive)
        let id = try await m.submit(job("turns"))
        #expect(await settle { p.log.contains("turn0") })
        p.open("t0")
        #expect(await settle { await gate.stats().waitingBackground == 1 })   // parked at the boundary
        _ = try await m.cancel(id)
        #expect(await settle { p.log.contains("cancelled") })
        #expect(await settle { let g = await gate.stats(); return g.waitingBackground == 0 && g.activeBackground == 0 })
        #expect(await status(m, id) == .cancelled)
        await i.release()
    }

    // Background pauses between turns (never mid-turn) while interactive is active, then resumes.
    @Test func backgroundPausedBetweenTurnsWhileInteractiveActive() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 2)
        let m = manager(p, gate)
        let id = try await m.submit(job("turns"))
        #expect(await settle { p.log.contains("turn0") })
        let i = try await gate.lease(.interactive)             // chat becomes active mid-turn: turn 0 is not interrupted
        p.open("t0")                                           // turn 0 finishes, boundary reached
        #expect(await settle { await gate.stats().backgroundYields == 1 })
        #expect(await gate.stats().activeBackground == 0)
        #expect(!p.log.contains("turn1"))                      // paused while interactive holds the engine
        await i.release()
        #expect(await settle { p.log.contains("turn1") })
        p.open("t1"); p.open("t2")
        #expect(await settle { await status(m, id) == .done })
    }

    @Test func noPauseWithoutInteractive() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 2)
        let m = manager(p, gate)
        let id = try await m.submit(job("turns"))
        p.open("t0"); p.open("t1"); p.open("t2")
        #expect(await settle { await status(m, id) == .done })
        #expect(await gate.stats().backgroundYields == 0)
    }

    // Chat user turns are interactive work: the slot is held for the turn and background yields to it.
    @Test func chatTurnOutranksBackgroundAtBoundary() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 1)
        let chat = LatchChat()
        let m = manager(p, gate, chat: chat)
        let sid = try await m.openSession(job(""))
        let id = try await m.submit(job("turns"))
        #expect(await settle { p.log.contains("turn0") })
        let turn = Task { try await m.appendUserTurn(sid, text: "hi") }
        #expect(await settle { await gate.stats().waitingInteractive == 1 })
        p.open("t0")                                           // boundary: background yields its only slot
        let stream = try await turn.value
        #expect(await gate.stats().activeInteractive == 1)
        #expect(!p.log.contains("turn1"))
        chat.turn.open()
        for await _ in stream {}
        #expect(await settle { p.log.contains("turn1") })
        #expect(await gate.stats().admittedInteractive == 1)
        p.open("t1"); p.open("t2")
        #expect(await settle { await status(m, id) == .done })
        _ = try await m.closeSession(sid)
    }

    @Test func chatTurnSlotReleasedAtTurnEnd() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 1)
        let chat = LatchChat()
        let m = manager(p, gate, chat: chat)
        let sid = try await m.openSession(job(""))
        let stream = try await m.appendUserTurn(sid, text: "hi")
        #expect(await gate.stats().activeInteractive == 1)
        chat.turn.open()
        for await _ in stream {}
        #expect(await settle { await gate.stats().activeInteractive == 0 })
        _ = try await m.closeSession(sid)
    }

    @Test func closeSessionWhileTurnWaitsForAdmission() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 1)
        let m = manager(p, gate, chat: LatchChat())
        let sid = try await m.openSession(job(""))
        let hold = try await gate.lease(.background)
        let turn = Task { try await m.appendUserTurn(sid, text: "hi") }
        #expect(await settle { await gate.stats().waitingInteractive == 1 })
        _ = try await m.closeSession(sid)
        await #expect(throws: ChatError.self) { _ = try await turn.value }
        #expect(await settle { await gate.stats().waitingInteractive == 0 })
        await hold.release()
        #expect(await gate.stats().admittedInteractive == 0)
    }

    @Test func cancelTurnCallerWhileWaitingDropsWaiter() async throws {
        let p = Probe(), gate = PriorityGate(maxInflight: 1)
        let chat = LatchChat()
        let m = manager(p, gate, chat: chat)
        let sid = try await m.openSession(job(""))
        let hold = try await gate.lease(.background)
        let turn = Task { try await m.appendUserTurn(sid, text: "hi") }
        #expect(await settle { await gate.stats().waitingInteractive == 1 })
        turn.cancel()
        _ = try? await turn.value
        #expect(await settle { await gate.stats().waitingInteractive == 0 })
        // the session is usable again: turnActive was reset
        await hold.release()
        let stream = try await m.appendUserTurn(sid, text: "again")
        #expect(await gate.stats().activeInteractive == 1)
        chat.turn.open()
        for await _ in stream {}
        _ = try await m.closeSession(sid)
    }
}
