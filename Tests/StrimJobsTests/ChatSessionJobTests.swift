import Foundation
import Testing
import StrimHarness
@testable import StrimJobs

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_793_000_000)
    func now() -> Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

/// Scripted chat backend. A turn whose text is "block" waits for cancellation or `release()`.
private final class FakeChat: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var opened: [String] = []
    private(set) var closed: [String] = []
    private(set) var cancelled: [String] = []
    private(set) var turns: [(String, String)] = []
    private var blocked = Set<String>()
    private var running = Set<String>()
    private var cancelFlag = Set<String>()
    var openError: ChatError?
    var profiles: [RunProfile] = []

    func release(_ id: String) { lock.withLock { _ = blocked.remove(id) } }

    func openSession(spec: HarnessJobSpec, sessionID: String, profile: RunProfile) async throws {
        try lock.withLock {
            if let e = openError { throw e }
            opened.append(sessionID); profiles.append(profile)
        }
    }

    func appendUserTurn(sessionID: String, text: String) async throws -> AsyncStream<ChatEvent> {
        let already: Bool = lock.withLock {
            if running.contains(sessionID) { return true }
            running.insert(sessionID); turns.append((sessionID, text))
            if text == "block" { blocked.insert(sessionID) }
            return false
        }
        if already { throw ChatError.turnInProgress }
        let (s, c) = AsyncStream<ChatEvent>.makeStream()
        Task {
            c.yield(.stepStarted(1))
            c.yield(.toolCallStarted(name: "read_file", summary: "{\"path\":\"a\"}"))
            c.yield(.toolCallFinished(name: "read_file", summary: "ok", isError: false))
            c.yield(.textDelta("reply to \(text)"))
            var status = HarnessStatus.done
            while lock.withLock({ blocked.contains(sessionID) }) {
                if Task.isCancelled { status = .cancelled; break }
                if lock.withLock({ cancelFlag.contains(sessionID) }) { status = .cancelled; break }
                try? await Task.sleep(for: .milliseconds(2))
            }
            lock.withLock { _ = running.remove(sessionID); _ = cancelFlag.remove(sessionID); _ = blocked.remove(sessionID) }
            c.yield(.turnFinished(ChatTurnResult(userTurn: 1, status: status, summary: "reply", usage: HarnessUsage(), totalUsage: HarnessUsage())))
            c.finish()
        }
        return s
    }

    func cancelTurn(sessionID: String) async {
        lock.withLock { cancelled.append(sessionID); cancelFlag.insert(sessionID) }
        while lock.withLock({ running.contains(sessionID) }) { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func closeSession(sessionID: String) async -> HarnessJobResult? {
        lock.withLock { closed.append(sessionID); blocked.remove(sessionID) }
        return HarnessJobResult(status: .done, summary: "session closed")
    }
}

private func chatSpec() -> HarnessJobSpec { HarnessJobSpec(task: "", cwd: "/tmp/p", access: .write) }

private func manager(_ chat: FakeChat?, store: JobStore = InMemoryJobStore(), clock: Clock = Clock(),
                     maxSessions: Int = 2, idle: TimeInterval = 600) -> JobManager {
    JobManager(executor: { _, _, _ in HarnessJobResult(status: .done, summary: "ok") }, store: store,
               pollInterval: .seconds(3600), now: { clock.now() }, chat: chat, maxChatSessions: maxSessions,
               chatIdleTimeout: idle)
}

private func collect(_ s: AsyncStream<ChatEvent>) async -> [ChatEvent] {
    var out: [ChatEvent] = []
    for await e in s { out.append(e) }
    return out
}

@Suite struct ChatSessionJobTests {
    @Test func openAppendCloseLifecycle() async throws {
        let chat = FakeChat(), jm = manager(chat)
        let id = try await jm.openSession(chatSpec())
        var snap = try await jm.status(id)
        #expect(snap.status == .running && snap.profile == "interactive" && !snap.turnActive)
        #expect(snap.spec.limits.maxTurns == 80 && snap.spec.limits.maxSeconds == 1800 && snap.spec.verify == nil)
        let events = await collect(try await jm.appendUserTurn(id, text: "hello"))
        #expect(events.count == 5)
        snap = try await jm.status(id)
        #expect(snap.status == .running && !snap.turnActive && snap.progress.turn == 1)
        // A second turn on the same session.
        _ = await collect(try await jm.appendUserTurn(id, text: "again"))
        #expect(chat.turns.map(\.1) == ["hello", "again"])
        let jobEvents = try await jm.eventsSince(id, index: 0)
        #expect(jobEvents.map(\.kind).contains("tool_call") && jobEvents.map(\.kind).contains("turn_finished"))
        #expect(!jobEvents.contains { $0.text.contains("reply to") }, "text deltas are not recorded")
        let closed = try await jm.closeSession(id)
        #expect(closed.status == .done && closed.result?.summary == "session closed")
        #expect(chat.closed == [id])
        #expect(await jm.openChatSessions == 0)
        // Closing again is a no-op; appending is a typed error.
        _ = try await jm.closeSession(id)
        #expect(chat.closed == [id])
        await #expect(throws: ChatError.sessionClosed) { _ = try await jm.appendUserTurn(id, text: "x") }
    }

    @Test func turnsAreRejectedWhileRunning() async throws {
        let chat = FakeChat(), jm = manager(chat)
        let id = try await jm.openSession(chatSpec())
        let s = try await jm.appendUserTurn(id, text: "block")
        #expect(try await jm.status(id).turnActive)
        await #expect(throws: ChatError.turnInProgress) { _ = try await jm.appendUserTurn(id, text: "second") }
        #expect(chat.turns.count == 1, "the rejected turn never reached the backend")
        try await jm.cancelTurn(id)
        let ev = await collect(s)
        if case let .turnFinished(r)? = ev.last { #expect(r.status == .cancelled) } else { Issue.record("no turnFinished") }
        #expect(chat.cancelled == [id])
        // The session survives a cancel and accepts a new turn immediately.
        _ = await collect(try await jm.appendUserTurn(id, text: "next"))
        #expect(try await jm.status(id).status == .running)
        _ = try await jm.closeSession(id)
    }

    @Test func maxSessionsIsTypedAndFreedOnClose() async throws {
        let chat = FakeChat(), jm = manager(chat, maxSessions: 2)
        let a = try await jm.openSession(chatSpec())
        _ = try await jm.openSession(chatSpec())
        await #expect(throws: ChatError.maxSessions(2)) { _ = try await jm.openSession(chatSpec()) }
        #expect(chat.opened.count == 2)
        _ = try await jm.closeSession(a)
        _ = try await jm.openSession(chatSpec())
        #expect(await jm.openChatSessions == 2)
    }

    @Test func defaultMaxSessionsIsTwo() async throws {
        let jm = JobManager(executor: { _, _, _ in HarnessJobResult(status: .done, summary: "ok") }, chat: FakeChat())
        _ = try await jm.openSession(chatSpec()); _ = try await jm.openSession(chatSpec())
        await #expect(throws: ChatError.maxSessions(2)) { _ = try await jm.openSession(chatSpec()) }
    }

    @Test func openFailureIsTypedAndFinalizesTheJob() async throws {
        let chat = FakeChat(); chat.openError = .openFailed("no worktree")
        let jm = manager(chat)
        await #expect(throws: ChatError.openFailed("no worktree")) { _ = try await jm.openSession(chatSpec()) }
        #expect(await jm.openChatSessions == 0)
        let noChat = manager(nil)
        await #expect(throws: ChatError.openFailed("chat is not available")) { _ = try await noChat.openSession(chatSpec()) }
    }

    @Test func idleTimeoutClosesWithInjectedClock() async throws {
        let chat = FakeChat(), clock = Clock(), jm = manager(chat, clock: clock, idle: 600)
        let id = try await jm.openSession(chatSpec())
        clock.advance(599)
        #expect(await jm.sweepIdleSessions().isEmpty)
        clock.advance(2)
        #expect(await jm.sweepIdleSessions() == [id])
        let snap = try await jm.status(id)
        #expect(snap.status == .done && snap.reason == JobFailureReason.idleTimeout)
        #expect(chat.closed == [id])
        await #expect(throws: ChatError.idleTimeout) { _ = try await jm.appendUserTurn(id, text: "x") }
        await #expect(throws: ChatError.idleTimeout) { try await jm.cancelTurn(id) }
        #expect(await jm.sweepIdleSessions().isEmpty)
    }

    @Test func activityResetsTheIdleTimerAndRunningTurnsNeverIdleOut() async throws {
        let chat = FakeChat(), clock = Clock(), jm = manager(chat, clock: clock, idle: 600)
        let id = try await jm.openSession(chatSpec())
        clock.advance(500)
        _ = await collect(try await jm.appendUserTurn(id, text: "hi"))
        clock.advance(500)
        #expect(await jm.sweepIdleSessions().isEmpty, "idle counts from the end of the last turn")
        let s = try await jm.appendUserTurn(id, text: "block")
        clock.advance(10_000)
        #expect(await jm.sweepIdleSessions().isEmpty, "a running turn is not idle")
        chat.release(id)
        _ = await collect(s)
        clock.advance(601)
        #expect(await jm.sweepIdleSessions() == [id])
    }

    @Test func closeWhileTurnRunningEndsTheStream() async throws {
        let chat = FakeChat(), jm = manager(chat)
        let id = try await jm.openSession(chatSpec())
        let s = try await jm.appendUserTurn(id, text: "block")
        let snap = try await jm.closeSession(id)
        #expect(snap.status == .done && !snap.turnActive)
        let ev = await collect(s)
        #expect(ev.last.map { if case .turnFinished = $0 { true } else { false } } == true)
    }

    @Test func genericCancelClosesTheSession() async throws {
        let chat = FakeChat(), jm = manager(chat)
        let id = try await jm.openSession(chatSpec())
        let snap = try await jm.cancel(id)
        #expect(snap.status == .cancelled && snap.result?.status == .cancelled)
        #expect(chat.closed == [id])
    }

    @Test func hostRestartMarksOpenSessionsFailed() async throws {
        let store = InMemoryJobStore()
        let chat = FakeChat(), jm1 = manager(chat, store: store)
        let id = try await jm1.openSession(chatSpec())
        let closedId = try await jm1.openSession(chatSpec())
        _ = try await jm1.closeSession(closedId)
        await jm1.flush()
        // New host process: same store, no live sessions.
        let jm2 = manager(FakeChat(), store: store)
        await jm2.recover()
        let snap = try await jm2.status(id)
        #expect(snap.status == .failed && snap.reason == JobFailureReason.hostRestart && snap.profile == "interactive")
        #expect(try await jm2.status(closedId).status == .done)
        await #expect(throws: ChatError.sessionClosed) { _ = try await jm2.appendUserTurn(id, text: "x") }
        #expect(await jm2.openChatSessions == 0)
    }

    @Test func chatTurnPausesBackgroundJobs() async throws {
        let chat = FakeChat(), jm = manager(chat)
        let id = try await jm.openSession(chatSpec())
        #expect(await jm.hasActiveChatTurn == false)
        let s = try await jm.appendUserTurn(id, text: "block")
        #expect(await jm.hasActiveChatTurn)
        chat.release(id)
        _ = await collect(s)
        #expect(await jm.hasActiveChatTurn == false)
        _ = try await jm.closeSession(id)
    }

    @Test func delegatedJobsAreUnaffected() async throws {
        let jm = manager(FakeChat())
        let id = try await jm.submit(HarnessJobSpec(task: "t", cwd: "/tmp/p"), priority: .normal)
        let snap = try await jm.status(id, waitS: 5)
        #expect(snap.status == .done && snap.profile == nil && !snap.turnActive)
        await #expect(throws: ChatError.sessionNotFound(id)) { _ = try await jm.appendUserTurn(id, text: "x") }
    }
}
