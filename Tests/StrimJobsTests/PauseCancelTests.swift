import Foundation
import Testing
import StrimAdmission
import StrimHarness
@testable import StrimJobs

private final class PGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var started: [String] = []
    private var cancelled: [String] = []
    func open() { lock.withLock { opened = true } }
    var isOpen: Bool { lock.withLock { opened } }
    func note(start t: String) { lock.withLock { started.append(t) } }
    func note(cancel t: String) { lock.withLock { cancelled.append(t) } }
    var starts: [String] { lock.withLock { started } }
    var cancels: [String] { lock.withLock { cancelled } }
}

/// Task names: "block" waits for the gate (or cancel); "final" emits `finished` then waits; "failed" / "limit" /
/// "declined" return that status at once; anything else is done at once.
private func pcExec(_ g: PGate) -> JobExecutor {
    { spec, _, emit in
        g.note(start: spec.task)
        switch spec.task {
        case "failed": return HarnessJobResult(status: .failed, summary: "boom")
        case "limit": return HarnessJobResult(status: .limit, summary: "limit")
        case "declined": return HarnessJobResult(status: .declined, summary: "no")
        case "block", "final":
            if spec.task == "final" { emit(.finished(.done)) }
            while !g.isOpen {
                if Task.isCancelled { g.note(cancel: spec.task); return HarnessJobResult(status: .cancelled, summary: "stopped") }
                try? await Task.sleep(for: .milliseconds(3))
            }
        default: break
        }
        return HarnessJobResult(status: .done, summary: "ok")
    }
}

private func mk(_ t: String) -> HarnessJobSpec { HarnessJobSpec(task: t, cwd: "/tmp/p") }

private func waitFor(_ m: JobManager, _ id: JobID, _ s: JobStatus, timeout: Double = 3) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if (try? await m.status(id, waitS: 0).status) == s { return true }
        try? await Task.sleep(for: .milliseconds(3))
    }
    return false
}

private func stateOf(_ m: JobManager, _ id: JobID) async -> JobStatus? { try? await m.status(id, waitS: 0).status }

@Suite struct CancelStateMachineTests {
    /// One row per JobStatus: build a job in that state, cancel it, check the outcome.
    struct Row: Sendable, CustomStringConvertible {
        let status: JobStatus
        var description: String { status.rawValue }
        var terminal: Bool { status.isTerminal }
    }
    static let rows: [Row] = [.queued, .preparing, .running, .pausedInteractive, .awaitingApproval, .finalizing,
                              .done, .failed, .cancelled, .limit, .declined].map(Row.init)

    /// Returns the manager, the id in `row.status`, and the gate. Throws when the state cannot be reached.
    private func make(_ row: Row) async throws -> (JobManager, JobID, PGate) {
        let g = PGate()
        switch row.status {
        case .queued:
            let m = JobManager(executor: pcExec(g), maxConcurrent: 1, pollInterval: .seconds(3600))
            _ = try await m.submit(mk("block"))
            let id = try await m.submit(mk("later"))
            return (m, id, g)
        case .preparing:
            let gate = PriorityGate(maxInflight: 1, maxBackground: 1)
            let hold = try await gate.lease(.background)       // the only background slot is taken
            let m = JobManager(executor: pcExec(g), maxConcurrent: 1, pollInterval: .seconds(3600), admission: gate)
            let id = try await m.submit(mk("x"))
            #expect(await waitFor(m, id, .preparing))
            Task { try? await Task.sleep(for: .seconds(30)); await hold.release() }
            return (m, id, g)
        case .running:
            let m = JobManager(executor: pcExec(g), maxConcurrent: 1, pollInterval: .seconds(3600))
            let id = try await m.submit(mk("block"))
            #expect(await waitFor(m, id, .running))
            return (m, id, g)
        case .pausedInteractive:
            let m = JobManager(executor: pcExec(g), maxConcurrent: 1, interactiveBusy: { true }, pollInterval: .milliseconds(5))
            let id = try await m.submit(mk("block"))
            #expect(await waitFor(m, id, .pausedInteractive))
            return (m, id, g)
        case .awaitingApproval:
            let m = JobManager(executor: pcExec(g), maxConcurrent: 1, requireApproval: true, pollInterval: .seconds(3600))
            let id = try await m.submit(mk("block"))
            #expect(await waitFor(m, id, .awaitingApproval))
            return (m, id, g)
        case .finalizing:
            let m = JobManager(executor: pcExec(g), maxConcurrent: 1, pollInterval: .seconds(3600))
            let id = try await m.submit(mk("final"))
            #expect(await waitFor(m, id, .finalizing))
            return (m, id, g)
        case .done:
            let m = JobManager(executor: pcExec(g), pollInterval: .seconds(3600))
            let id = try await m.submit(mk("x")); #expect(await waitFor(m, id, .done)); return (m, id, g)
        case .failed:
            let m = JobManager(executor: pcExec(g), pollInterval: .seconds(3600))
            let id = try await m.submit(mk("failed")); #expect(await waitFor(m, id, .failed)); return (m, id, g)
        case .limit:
            let m = JobManager(executor: pcExec(g), pollInterval: .seconds(3600))
            let id = try await m.submit(mk("limit")); #expect(await waitFor(m, id, .limit)); return (m, id, g)
        case .declined:
            let m = JobManager(executor: pcExec(g), pollInterval: .seconds(3600))
            let id = try await m.submit(mk("declined")); #expect(await waitFor(m, id, .declined)); return (m, id, g)
        case .cancelled:
            let m = JobManager(executor: pcExec(g), maxConcurrent: 1, pollInterval: .seconds(3600))
            let id = try await m.submit(mk("block")); #expect(await waitFor(m, id, .running))
            _ = try await m.cancel(id)
            return (m, id, g)
        }
    }

    @Test(arguments: rows) func cancelAtEveryState(_ row: Row) async throws {
        let (m, id, g) = try await make(row)
        #expect(await stateOf(m, id) == row.status)
        let snap = try await m.cancel(id)
        if row.terminal {
            #expect(snap.status == row.status, "a finished job is unchanged")
        } else {
            #expect(snap.status == .cancelled)
            #expect(snap.result?.status == .cancelled)
        }
        // Idempotent: a second cancel changes nothing.
        let again = try await m.cancel(id)
        #expect(again.status == snap.status)
        // Never runs afterwards.
        if row.status == .queued { #expect(!g.starts.contains("later")) }
        g.open()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await stateOf(m, id) == snap.status)
    }

    @Test func cancelFreesTheSlotForQueuedWork() async throws {
        let g = PGate()
        let m = JobManager(executor: pcExec(g), maxConcurrent: 1, pollInterval: .seconds(3600))
        let a = try await m.submit(mk("block"))
        let b = try await m.submit(mk("next"))
        #expect(await waitFor(m, a, .running))
        _ = try await m.cancel(a)
        #expect(await waitFor(m, b, .done))
    }

    @Test func cancelUnknownJobThrows() async {
        let m = JobManager(executor: pcExec(PGate()), pollInterval: .seconds(3600))
        await #expect(throws: JobError.notFound("j_nope")) { _ = try await m.cancel("j_nope") }
    }
}

@Suite struct BackgroundPauseTests {
    @Test func pausedQueueIsNotAdmittedUntilResume() async throws {
        let g = PGate()
        let m = JobManager(executor: pcExec(g), maxConcurrent: 1, pollInterval: .seconds(3600))
        await m.pauseBackground()
        #expect(await m.isBackgroundPaused)
        let id = try await m.submit(mk("x"))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await stateOf(m, id) == .queued)
        #expect(g.starts.isEmpty)
        #expect(await m.backgroundCounts.queued == 1)
        await m.resumeBackground()
        #expect(await waitFor(m, id, .done))
        #expect(await !m.isBackgroundPaused)
    }

    @Test func runningJobsFinishByDefault() async throws {
        let g = PGate()
        let m = JobManager(executor: pcExec(g), maxConcurrent: 1, pollInterval: .seconds(3600))
        let a = try await m.submit(mk("block"))
        let b = try await m.submit(mk("next"))
        #expect(await waitFor(m, a, .running))
        let n = await m.pauseBackground()
        #expect(n == 0)
        #expect(await stateOf(m, a) == .running)
        g.open()
        #expect(await waitFor(m, a, .done))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await stateOf(m, b) == .queued, "the queued job waits while paused")
        await m.resumeBackground()
        #expect(await waitFor(m, b, .done))
    }

    @Test func cancelRunningStopsAdmittedJobs() async throws {
        let g = PGate()
        let m = JobManager(executor: pcExec(g), maxConcurrent: 2, pollInterval: .seconds(3600))
        let a = try await m.submit(mk("block"))
        let b = try await m.submit(mk("block"))
        let c = try await m.submit(mk("block"))
        #expect(await waitFor(m, a, .running)); #expect(await waitFor(m, b, .running))
        let n = await m.pauseBackground(cancelRunning: true)
        #expect(n == 2)
        #expect(await waitFor(m, a, .cancelled)); #expect(await waitFor(m, b, .cancelled))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await stateOf(m, c) == .queued)
        g.open()
        await m.resumeBackground()
        #expect(await waitFor(m, c, .done))
    }

    @Test func approvedJobWaitsWhilePaused() async throws {
        let g = PGate()
        let m = JobManager(executor: pcExec(g), maxConcurrent: 1, requireApproval: true, pollInterval: .milliseconds(10))
        let id = try await m.submit(mk("x"))
        #expect(await waitFor(m, id, .awaitingApproval))
        await m.pauseBackground()
        try await m.approve(id)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(g.starts.isEmpty, "an approved job does not start while paused")
        await m.resumeBackground()
        #expect(await waitFor(m, id, .done))
    }

    @Test func cancelWhileHeldByPauseDropsTheJob() async throws {
        let g = PGate()
        let m = JobManager(executor: pcExec(g), maxConcurrent: 1, requireApproval: true, pollInterval: .milliseconds(10))
        let id = try await m.submit(mk("x"))
        #expect(await waitFor(m, id, .awaitingApproval))
        await m.pauseBackground()
        try await m.approve(id)
        _ = try await m.cancel(id)
        #expect(await waitFor(m, id, .cancelled))
        await m.resumeBackground()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(g.starts.isEmpty)
    }

    @Test func pauseAndResumeAreIdempotent() async {
        let m = JobManager(executor: pcExec(PGate()), pollInterval: .seconds(3600))
        await m.pauseBackground(); await m.pauseBackground()
        #expect(await m.isBackgroundPaused)
        await m.resumeBackground(); await m.resumeBackground()
        #expect(await !m.isBackgroundPaused)
    }

    /// Chat (interactive) sessions are never blocked by a background pause.
    @Test func chatSessionsIgnoreThePause() async throws {
        let chat = StubChat()
        let m = JobManager(executor: pcExec(PGate()), pollInterval: .seconds(3600), chat: chat)
        await m.pauseBackground()
        let sid = try await m.openSession(mk(""))
        var seen = ""
        for await e in try await m.appendUserTurn(sid, text: "hi") { if case .textDelta(let t) = e { seen += t } }
        #expect(seen == "ok")
        try await m.setChatThinking(sid, enabled: false)
        #expect(chat.thinking == [false])
        _ = try await m.closeSession(sid)
    }
}

private final class StubChat: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _thinking: [Bool?] = []
    var thinking: [Bool?] { lock.withLock { _thinking } }
    func openSession(spec: HarnessJobSpec, sessionID: String, profile: RunProfile) async throws {}
    func appendUserTurn(sessionID: String, text: String) async throws -> AsyncStream<ChatEvent> {
        AsyncStream { c in
            c.yield(.textDelta("ok"))
            c.yield(.turnFinished(ChatTurnResult(userTurn: 1, status: .done, summary: "d", usage: HarnessUsage(), totalUsage: HarnessUsage())))
            c.finish()
        }
    }
    func cancelTurn(sessionID: String) async {}
    func closeSession(sessionID: String) async -> HarnessJobResult? { HarnessJobResult(status: .done, summary: "closed") }
    func setThinking(sessionID: String, enabled: Bool?) async { lock.withLock { _thinking.append(enabled) } }
}
