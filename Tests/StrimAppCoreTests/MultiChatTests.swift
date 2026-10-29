import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

private func delta(_ sid: String, _ k: ChatDeltaKind, _ t: String, status: ChatTurnStatus? = nil) -> StrimEvent { .chatDelta(ChatDelta(sessionID: sid, kind: k, text: t, status: status)) }

private func appendsReach(_ fake: FakeControlClient, _ n: Int) async -> Bool {
    for _ in 0..<600 { if await fake.appends.count >= n { return true }; try? await Task.sleep(for: .milliseconds(5)) }
    return false
}

@MainActor
private struct Rig {
    let fake: FakeControlClient
    let model: AppModel
    let store: MemoryChatStore
    let dirs: [String]
    let scratch: String

    static func make(projects n: Int = 3, recents: [String]? = nil, store: MemoryChatStore = MemoryChatStore(), maxSessions: Int? = 2) async -> Rig {
        let fake = FakeControlClient()
        await fake.setUniqueSessions(true); await fake.setMaxSessions(maxSessions)
        let dirs = (0..<n).map { _ in tempDir("proj") }
        let scratch = tempDir("scratch")
        let settings = AppSettings(modelPath: "/models/q", projectPath: dirs.first, recentProjects: recents ?? dirs, startServerWhenOpens: false)
        let m = AppModel(client: fake, settings: settings, clock: RecordingClock(auto: 1000), mcp: MockMcp(), persist: { _ in },
                         pollInterval: nil, modelDownloader: ModelDownloader(modelExists: { true }), chatStore: store, scratchRoot: scratch + "/Strim Scratch")
        m.start()
        _ = await waitFor { m.connection.isConnected }
        await fake.emit(.status(FakeControlClient.sampleStatus))
        _ = await waitFor { m.lastEventTime != nil }
        return Rig(fake: fake, model: m, store: store, dirs: dirs, scratch: scratch)
    }

    /// New chat in project `i`, selected, with a live session. Returns (thread id, session id).
    func open(_ i: Int) async -> (String, String)? {
        guard let p = model.projects.first(where: { $0.path == dirs[i] }), let t = model.newThread(projectID: p.id) else { return nil }
        await model.probeChat()
        guard case .ready(let s) = model.chat else { return nil }
        return (t.id, s.sessionID)
    }
}

@MainActor
@Suite struct MultiChatTests {
    @Test func migratesRecentsAndDropsInvalid() async {
        let gone = tempDir("gone"); try? FileManager.default.removeItem(atPath: gone)
        let a = tempDir("a"), b = tempDir("b")
        let rig = await Rig.make(projects: 0, recents: [b, gone, a, b], store: MemoryChatStore())
        // projectPath is nil with 0 dirs; recents order is kept, the missing and the duplicate entry are dropped
        #expect(rig.model.projects.map(\.path) == [b, a])
        #expect(rig.store.storedIndex.projects.map(\.path) == [b, a])
        // a second launch on the same store does not migrate again
        let again = await Rig.make(projects: 0, recents: [tempDir("c")], store: rig.store)
        #expect(again.model.projects.map(\.path) == [b, a])
        rig.model.stop(); again.model.stop()
    }

    @Test func projectPathComesFirstInMigration() async {
        let rig = await Rig.make(projects: 2, recents: [])
        #expect(rig.model.projects.map(\.path) == [rig.dirs[0]])
        rig.model.stop()
    }

    @Test func deltasRouteToTheRightThreadWhenSessionsInterleave() async {
        let rig = await Rig.make()
        guard let (ta, sa) = await rig.open(0), let (tb, sb) = await rig.open(1) else { Issue.record("no sessions"); return }
        #expect(sa != sb)
        await rig.fake.emit(delta(sa, .text, "alpha "))
        await rig.fake.emit(delta(sb, .text, "beta "))
        await rig.fake.emit(delta(sa, .toolCall, "ls -a"))
        await rig.fake.emit(delta(sb, .reasoning, "hmm"))
        await rig.fake.emit(delta(sa, .toolResult, "ls: 2 entries"))
        await rig.fake.emit(delta(sb, .text, "two"))
        #expect(await waitFor { rig.model.messages[tb]?.last?.text == "two" && rig.model.messages[ta]?.last?.tool?.finished == true })
        let a = rig.model.messages[ta] ?? [], b = rig.model.messages[tb] ?? []
        #expect(a.map(\.role) == [.assistant, .tool] && a[0].text == "alpha ")
        #expect(b.map(\.role) == [.assistant, .reasoning, .assistant] && b[0].text == "beta " && b[1].text == "hmm")
        #expect(rig.model.chatMessages.map(\.role) == [.assistant, .reasoning, .assistant])   // B is selected
        await rig.fake.emit(delta("unknown-session", .text, "stray"))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!(rig.model.messages[ta] ?? []).contains { $0.text == "stray" } && !(rig.model.messages[tb] ?? []).contains { $0.text == "stray" })
        rig.model.stop()
    }

    @Test func secondSendQueuesThenRunsAfterDone() async {
        let rig = await Rig.make()
        guard let (ta, sa) = await rig.open(0), let (tb, sb) = await rig.open(1) else { Issue.record("no sessions"); return }
        await rig.model.send("first", in: ta)
        #expect(rig.model.generatingThreadID == ta)
        await rig.model.send("second", in: tb)
        await rig.model.send("third", in: tb)           // at most one queued per thread
        #expect(rig.model.queue == [QueuedSend(threadID: tb, text: "second")])
        #expect(await rig.fake.appends.count == 1)
        #expect(rig.model.messages[tb]?.isEmpty == true)
        await rig.fake.emit(delta(sa, .text, "done A"))
        await rig.fake.emit(delta(sa, .done, "ok"))
        #expect(await waitFor { rig.model.generatingThreadID == tb && rig.model.queue.isEmpty })
        #expect(await appendsReach(rig.fake, 2))
        #expect(await rig.fake.appends.last == ChatAppendRequest(sessionID: sb, text: "second", enableThinking: true))
        #expect(rig.model.messages[tb]?.first?.text == "second")
        await rig.fake.emit(delta(sb, .done, "ok"))
        #expect(await waitFor { rig.model.generatingThreadID == nil })
        rig.model.stop()
    }

    @Test func cancellingAQueuedMessageDoesNotTouchTheHost() async {
        let rig = await Rig.make()
        guard let (ta, _) = await rig.open(0), let (tb, _) = await rig.open(1) else { Issue.record("no sessions"); return }
        await rig.model.send("first", in: ta)
        await rig.model.send("second", in: tb)
        #expect(rig.model.queue.count == 1)
        await rig.model.cancel(tb)
        #expect(rig.model.queue.isEmpty && rig.model.generatingThreadID == ta)
        #expect(await !rig.fake.calls.contains { $0.hasPrefix("chat_cancel") })
        await rig.model.cancel(ta)
        #expect(await rig.fake.calls.contains { $0.hasPrefix("chat_cancel") })
        #expect(rig.model.generatingThreadID == nil)
        rig.model.stop()
    }

    @Test func lruClosesLeastRecentIdleSessionNeverTheGeneratingOne() async {
        let rig = await Rig.make()
        guard let (ta, sa) = await rig.open(0), let (tb, sb) = await rig.open(1) else { Issue.record("no sessions"); return }
        // A (oldest) starts generating: it must survive even though it is least recent
        await rig.model.send("work", in: ta)
        #expect(rig.model.generatingThreadID == ta)
        guard let (_, sc) = await rig.open(2) else { Issue.record("third session failed: \(rig.model.lastError ?? "")"); return }
        #expect(await rig.fake.closedSessions == [sb])
        #expect(rig.model.liveSessions[ta]?.sessionID == sa && rig.model.liveSessions[tb] == nil)
        #expect(Set(rig.model.liveSessions.values.map(\.sessionID)) == [sa, sc])
        #expect(rig.model.liveSessions.count <= AppModel.maxLiveSessions)
        rig.model.stop()
    }

    @Test func closedSessionGetsADividerAndReopensFresh() async {
        let rig = await Rig.make()
        guard let (ta, sa) = await rig.open(0) else { Issue.record("no session"); return }
        await rig.model.send("hello", in: ta)
        await rig.fake.emit(delta(sa, .text, "hi"))
        await rig.fake.emit(delta(sa, .done, "ok"))
        #expect(await waitFor { rig.model.generatingThreadID == nil })
        guard await rig.open(1) != nil else { Issue.record("no second"); return }
        guard await rig.open(2) != nil else { Issue.record("no third"); return }
        #expect(await rig.fake.closedSessions == [sa])                // A is the least recent idle one
        #expect(rig.model.messages[ta]?.last?.marker == .sessionBreak)
        #expect(rig.store.stored(ta).last?.sessionBreak == true)
        rig.model.selectThread(ta)
        await rig.model.send("again", in: ta)
        #expect(rig.model.liveSessions[ta] != nil && rig.model.liveSessions[ta]?.sessionID != sa)
        rig.model.stop()
    }

    @Test func manyThreadsNeverHitMaxSessions() async {
        let rig = await Rig.make(projects: 5)
        for i in 0..<5 { _ = await rig.open(i) }
        for i in 0..<5 { _ = await rig.open(i) }
        #expect(rig.model.lastError == nil)
        #expect(rig.model.chatUnavailable.isEmpty)
        #expect(await rig.fake.openSessions.count <= 2)
        #expect(rig.model.liveSessions.count <= 2)
        rig.model.stop()
    }

    @Test func readOnlyHistoryBlocksSendAndWrites() async {
        var idx = ChatIndex(); idx.readOnly = true; idx.notice = "newer"
        let dir = tempDir("ro")
        idx.projects = [ChatProject(path: dir)]
        idx.threads = [ChatThread(projectId: idx.projects[0].id)]
        let store = MemoryChatStore(index: idx)
        let rig = await Rig.make(projects: 0, recents: [], store: store)
        #expect(rig.model.chatReadOnly && rig.model.chatStoreNotice == "newer")
        let tid = rig.model.threads[0].id
        rig.model.selectThread(tid)
        #expect(rig.model.sendAvailability(for: tid).enabled == false)
        #expect(store.saveCount == 0)
        rig.model.stop()
    }

    @Test func titleFromFirstMessageAndRenameSticks() async {
        let rig = await Rig.make()
        guard let (ta, sa) = await rig.open(0) else { Issue.record("no session"); return }
        #expect(rig.model.thread(ta)?.title == "New chat")
        await rig.model.send("Why does ParseTests fail? Please look at the parser and explain.", in: ta)
        #expect(rig.model.thread(ta)?.title == "Why does ParseTests fail?")
        await rig.fake.emit(delta(sa, .done, "ok"))
        #expect(await waitFor { rig.model.generatingThreadID == nil })
        rig.model.renameThread(ta, to: "  My name  ")
        await rig.model.send("Another thing. More.", in: ta)
        await rig.fake.emit(delta(sa, .done, "ok"))
        #expect(await waitFor { rig.model.generatingThreadID == nil })
        #expect(rig.model.thread(ta)?.title == "My name" && rig.model.thread(ta)?.titleIsUser == true)
        #expect(rig.store.storedIndex.threads.first { $0.id == ta }?.title == "My name")
        let long = String(repeating: "a", count: 200)
        rig.model.renameThread(ta, to: "")
        #expect(rig.model.thread(ta)?.title == "My name")
        #expect(AppModel.title(from: long).count == 60)
        rig.model.stop()
    }

    @Test func missingFolderDisablesSend() async {
        let rig = await Rig.make()
        guard let (ta, _) = await rig.open(0) else { Issue.record("no session"); return }
        try? FileManager.default.removeItem(atPath: rig.dirs[0])
        #expect(rig.model.sendAvailability(for: ta) == .no("Folder moved or deleted"))
        #expect(rig.model.folderMissing(rig.model.thread(ta)!.projectId))
        await rig.model.send("x", in: ta)
        #expect(await rig.fake.appends.isEmpty && rig.model.generatingThreadID == nil)
        // relocate repoints the project and send works again
        let moved = tempDir("moved")
        let r = await rig.model.relocateProject(rig.model.thread(ta)!.projectId, path: moved)
        if case .failure = r { Issue.record("relocate failed") }
        #expect(rig.model.sendAvailability(for: ta) == .yes)
        await rig.model.send("x", in: ta)
        #expect(await rig.fake.appends.count == 1)
        rig.model.stop()
    }

    @Test func scratchFolderIsCreatedLazilyAndPassesSafetyChecks() async {
        let rig = await Rig.make(projects: 0, recents: [])
        guard let t = rig.model.newThread() else { Issue.record("no thread"); return }
        let p = rig.model.project(t.projectId)!
        #expect(p.isScratch && p.name == "Scratch")
        let dir = rig.model.cwd(for: t)!
        #expect(!FileManager.default.fileExists(atPath: dir))
        #expect(rig.model.folderProblem(for: t.id) == nil)
        await rig.model.probeChat()
        guard case .ready(let s) = rig.model.chat else { Issue.record("not ready: \(rig.model.chat)"); return }
        #expect(s.cwd == dir)
        var st = stat()
        #expect(stat(dir, &st) == 0 && (st.st_mode & 0o777) == 0o700)
        #expect(ProjectFolder.resolve(dir) == .success(dir))
        let home = NSHomeDirectory()
        for bad in ["/Library", "/.strim", "/.config", "/.claude"] { #expect(!AppModel.scratchDefault.hasPrefix(home + bad)) }
        #expect(AppModel.scratchDefault == home + "/Documents/Strim Scratch")
        rig.model.stop()
    }

    @Test func transcriptsPersistAcrossRestart() async {
        let store = MemoryChatStore()
        let rig = await Rig.make(store: store)
        guard let (ta, sa) = await rig.open(0) else { Issue.record("no session"); return }
        await rig.model.send("remember me", in: ta)
        await rig.fake.emit(delta(sa, .text, "noted"))
        await rig.fake.emit(delta(sa, .done, "ok"))
        #expect(await waitFor { rig.model.generatingThreadID == nil })
        #expect(store.stored(ta).map(\.text) == ["remember me", "noted"])
        #expect(store.stored(ta).last?.ledger != nil)
        rig.model.stop()

        let reborn = await Rig.make(projects: 0, recents: [], store: store)
        #expect(reborn.model.thread(ta)?.title == "remember me" && reborn.model.thread(ta)?.messageCount == 2)
        reborn.model.selectThread(ta)
        #expect(reborn.model.chatMessages.map(\.text) == ["remember me", "noted"])
        #expect(reborn.model.liveSessions.isEmpty)       // sessions are never persisted
        reborn.model.stop()
    }

    @Test func unreadFinishedReplyAndThreadManagement() async {
        let rig = await Rig.make()
        guard let (ta, sa) = await rig.open(0), let (tb, _) = await rig.open(1) else { Issue.record("no sessions"); return }
        rig.model.selectThread(ta)
        await rig.model.send("go", in: ta)
        rig.model.selectThread(tb)
        await rig.fake.emit(delta(sa, .done, "ok"))
        #expect(await waitFor { rig.model.generatingThreadID == nil })
        #expect(rig.model.thread(ta)?.unread == true)
        rig.model.selectThread(ta)
        #expect(rig.model.thread(ta)?.unread == false)

        let dup = rig.model.duplicateThread(ta)
        #expect(dup != nil && rig.model.messages[dup!.id]?.last?.marker == .sessionBreak && rig.model.hasLiveSession(dup!.id) == false)
        #expect(rig.model.thread(dup!.id)?.title == "go copy")

        await rig.model.deleteThread(ta)
        #expect(rig.model.thread(ta) == nil && rig.store.stored(ta).isEmpty)
        #expect(await rig.fake.closedSessions.contains(sa))
        rig.model.stop()
    }

    @Test func removeProjectDeletesChatsNotTheFolder() async {
        let rig = await Rig.make()
        guard let (ta, _) = await rig.open(0) else { Issue.record("no session"); return }
        let pid = rig.model.thread(ta)!.projectId
        await rig.model.removeProject(pid)
        #expect(rig.model.project(pid) == nil && rig.model.threads.allSatisfy { $0.projectId != pid })
        #expect(FileManager.default.fileExists(atPath: rig.dirs[0]))
        #expect(rig.model.liveSessions.isEmpty)
        rig.model.stop()
    }

    @Test func closeAllSessionsOnStopAndSettingProjectStartsAFreshChat() async {
        let rig = await Rig.make()
        guard let (_, sa) = await rig.open(0), let (_, sb) = await rig.open(1) else { Issue.record("no sessions"); return }
        await rig.model.closeAllSessions()
        #expect(Set(await rig.fake.closedSessions) == [sa, sb])
        let stillOpen = await rig.fake.openSessions
        #expect(rig.model.liveSessions.isEmpty && stillOpen.isEmpty)
        let before = rig.model.threads.count
        #expect(rig.model.setProject(rig.dirs[2]))
        #expect(rig.model.threads.count == before + 1 && rig.model.chatMessages.isEmpty)
        #expect(rig.model.setProject(rig.dirs[2]) && rig.model.threads.count == before + 1)   // empty draft is reused
        rig.model.stop()
    }

    @Test func sessionNotFoundOnAppendDropsTheDeadSession() async {
        let rig = await Rig.make()
        guard let (ta, sa) = await rig.open(0) else { Issue.record("no session"); return }
        await rig.fake.setFailNext(APIError(code: "not_found", message: "no session"))
        await rig.model.send("x", in: ta)
        #expect(rig.model.generatingThreadID == nil && rig.model.liveSessions[ta] == nil)
        await rig.model.send("y", in: ta)
        #expect(rig.model.liveSessions[ta] != nil && rig.model.liveSessions[ta]?.sessionID != sa)
        rig.model.stop()
    }

    @Test func firstTurnRecordsTheThinkingSettingItUsed() async {
        let rig = await Rig.make()
        guard let (ta, _) = await rig.open(0) else { Issue.record("no session"); return }
        rig.model.thinkingEnabled = false
        await rig.model.send("hello", in: ta)
        #expect(rig.model.thread(ta)?.thinking == false)
        rig.model.stop()
    }
}

@MainActor
@Suite struct ChatDoneSummaryTests {
    @Test func doneSummaryRendersWhenNoAssistantTextArrived() async {
        let rig = await Rig.make()
        guard let (t, s) = await rig.open(0) else { Issue.record("no session"); return }
        await rig.fake.emit(delta(s, .done, "hello", status: .done))
        #expect(await waitFor { rig.model.messages[t]?.last?.text == "hello" })
        #expect(rig.model.messages[t]?.last?.role == .assistant)
        rig.model.stop()
    }

    @Test func declinedSummaryRendersWhenNoAssistantTextArrived() async {
        let rig = await Rig.make()
        guard let (t, s) = await rig.open(0) else { Issue.record("no session"); return }
        await rig.fake.emit(delta(s, .done, "cannot do that", status: .declined))
        #expect(await waitFor { rig.model.messages[t]?.last?.text == "cannot do that" })
        #expect(rig.model.messages[t]?.last?.role == .assistant)
        rig.model.stop()
    }

    @Test func doneWithoutStatusDoesNotAddSummaryAsReply() async {
        // New hosts send the summary as text themselves; a status-less done must not add a second copy.
        let rig = await Rig.make()
        guard let (t, s) = await rig.open(0) else { Issue.record("no session"); return }
        await rig.model.send("go", in: t)
        await rig.fake.emit(delta(s, .done, "hello"))
        #expect(await waitFor { rig.model.generatingThreadID == nil })
        #expect(rig.model.messages[t]?.contains { $0.role == .assistant } == false)
        rig.model.stop()
    }

    @Test(arguments: [ChatTurnStatus.failed, .cancelled, .limit])
    func nonAnswerTurnSummaryIsNotShownAsReply(_ status: ChatTurnStatus) async {
        // Error and step-limit summaries describe the turn; they are not the assistant's reply.
        let rig = await Rig.make()
        guard let (t, s) = await rig.open(0) else { Issue.record("no session"); return }
        await rig.model.send("go", in: t)
        await rig.fake.emit(delta(s, .done, "step limit reached", status: status))
        #expect(await waitFor { rig.model.generatingThreadID == nil })
        #expect(rig.model.messages[t]?.contains { $0.role == .assistant } == false)
        rig.model.stop()
    }

    @Test func doneDeltaDecodesWithOrWithoutStatus() throws {
        // Old hosts omit `status`; the field is additive and must not break decoding.
        let old = try JSONDecoder().decode(ChatDelta.self, from: Data(#"{"session_id":"s","kind":"done","text":"ok"}"#.utf8))
        #expect(old == ChatDelta(sessionID: "s", kind: .done, text: "ok"))
        #expect(old.status == nil)
        let new = try JSONDecoder().decode(ChatDelta.self, from: Data(#"{"session_id":"s","kind":"done","text":"x","status":"failed"}"#.utf8))
        #expect(new.status == .failed)
    }

    @Test func doneSummaryAfterToolRendersEvenWithEarlierText() async {
        let rig = await Rig.make()
        guard let (t, s) = await rig.open(0) else { Issue.record("no session"); return }
        await rig.fake.emit(delta(s, .text, "Looking."))
        await rig.fake.emit(delta(s, .toolCall, "ls -a"))
        await rig.fake.emit(delta(s, .toolResult, "ls: 2 entries"))
        await rig.fake.emit(delta(s, .done, "found 2", status: .done))
        #expect(await waitFor { rig.model.messages[t]?.last?.text == "found 2" })
        rig.model.stop()
    }

    @Test func doneSummaryIsNotDuplicatedWhenTextStreamed() async {
        let rig = await Rig.make()
        guard let (t, s) = await rig.open(0) else { Issue.record("no session"); return }
        await rig.fake.emit(delta(s, .text, "hello"))
        await rig.fake.emit(delta(s, .done, "hello", status: .done))
        #expect(await waitFor { rig.model.generatingThreadID == nil && rig.model.messages[t]?.last?.text == "hello" })
        #expect(rig.model.messages[t]?.filter { $0.role == .assistant }.count == 1)
        rig.model.stop()
    }
}
