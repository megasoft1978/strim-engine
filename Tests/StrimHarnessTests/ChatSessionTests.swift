import Testing
import Foundation
import StrimEngine
import StrimTemplate
@testable import StrimHarness

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ChatEvent] = []
    func add(_ e: ChatEvent) { lock.withLock { items.append(e) } }
    var all: [ChatEvent] { lock.withLock { items } }
    var text: String { all.compactMap { if case let .textDelta(t) = $0 { t } else { nil } }.joined() }
    var patches: [ChatPatch] { all.compactMap { if case let .patchReady(p) = $0 { p } else { nil } } }
    var finished: [ChatTurnResult] { all.compactMap { if case let .turnFinished(r) = $0 { r } else { nil } } }
}

private func drain(_ s: AsyncStream<ChatEvent>) async -> Collector {
    let c = Collector()
    for await e in s { c.add(e) }
    return c
}

private func call(_ name: String, _ args: [(String, OrderedJSON)] = []) -> [FakeEngine.Step] {
    var s: [FakeEngine.Step] = [.event(.toolCallBegin(name: name))]
    for (k, v) in args { s.append(.event(.toolCallArg(key: k, value: v))) }
    s.append(.event(.toolCallEnd))
    return s
}
private func gen(_ steps: [FakeEngine.Step], prompt: Int = 100, completion: Int = 10) -> [FakeEngine.Step] {
    steps + [.event(.finished(.stop, makeUsage(prompt: prompt, completion: completion)))]
}
private func say(_ text: String) -> [FakeEngine.Step] { gen([.event(.tokens([1, 2], text))]) }
private func edit(_ path: String = "a.txt", old: String = "one", new: String = "two") -> [FakeEngine.Step] {
    gen(call("edit_file", [("path", .string(path)), ("old", .string(old)), ("new", .string(new))]))
}

private struct Fixture {
    let root: URL, repo: String, wtDir: URL, jobs: URL
    var iso: GitWorktreeIsolation { GitWorktreeIsolation(baseDir: wtDir) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    var worktrees: Int { ((try? FileManager.default.contentsOfDirectory(atPath: wtDir.path)) ?? []).count }
}

private func sh(_ args: [String], in dir: String) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: try GitWorktreeIsolation.gitExecutable())
    p.arguments = args
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_TERMINAL_PROMPT": "0"]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    try p.run(); p.waitUntilExit()
    if p.terminationStatus != 0 { throw NSError(domain: "git", code: Int(p.terminationStatus)) }
}

private func makeFixture() throws -> Fixture {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cs-\(UUID().uuidString)")
    let repo = root.appendingPathComponent("repo").path
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try sh(["init", "-q", "-b", "main"], in: repo)
    try sh(["config", "user.name", "Test"], in: repo)
    try sh(["config", "user.email", "test@example.com"], in: repo)
    try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    try "x\n".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)
    try sh(["add", "-A"], in: repo)
    try sh(["commit", "-q", "-m", "init"], in: repo)
    return Fixture(root: root, repo: repo, wtDir: root.appendingPathComponent("wt"), jobs: root.appendingPathComponent("jobs"))
}

private final class CountingIsolation: WorkspaceIsolation, @unchecked Sendable {
    let inner: GitWorktreeIsolation
    private let lock = NSLock()
    private var n = 0, p = 0
    var cleanups: Int { lock.withLock { n } }
    var patches: Int { lock.withLock { p } }
    init(_ inner: GitWorktreeIsolation) { self.inner = inner }
    func prepare(cwd: String, access: AccessLevel, files: [String]) async throws -> Workspace {
        try await inner.prepare(cwd: cwd, access: access, files: files)
    }
    func collectPatch(_ w: Workspace) async throws -> String { lock.withLock { p += 1 }; return try await inner.collectPatch(w) }
    func cleanup(_ w: Workspace) async { lock.withLock { n += 1 }; await inner.cleanup(w) }
}

private func runner(_ e: FakeEngine, _ f: Fixture, iso: WorkspaceIsolation? = nil) -> HarnessRunner {
    HarnessRunner(engine: e, isolation: iso ?? f.iso, sandboxed: false, jobsDir: f.jobs,
                  now: { Date(timeIntervalSince1970: 1_793_000_000) })
}

private func writeSpec(_ f: Fixture, limits: HarnessLimits = HarnessLimits()) -> HarnessJobSpec {
    HarnessJobSpec(task: "ignored", cwd: f.repo, access: .write, limits: limits)
}

@Suite struct RunProfileTests {
    @Test func delegatedMatchesExistingDefaults() {
        let p = RunProfile.delegated
        #expect(p.limits() == HarnessLimits())
        #expect(p.maxTurns == 40 && p.maxSeconds == 900 && p.priority == .background && p.verifyRequired && !p.streamsDeltas)
    }

    @Test func interactiveProfile() {
        let p = RunProfile.interactive
        #expect(p.maxTurns == 80 && p.maxSeconds == 1800 && p.priority == .interactive)
        #expect(!p.verifyRequired && p.streamsDeltas && p.patchApproval)
        #expect(p.limits().maxTurns == 80 && p.limits().maxSeconds == 1800)
    }

    @Test func requestedLimitsAreClampedToCeilings() {
        var l = HarnessLimits(); l.maxTurns = 500; l.maxSeconds = 10
        let c = RunProfile.interactive.limits(requested: l)
        #expect(c.maxTurns == 80 && c.maxSeconds == 10)
        #expect(RunProfile.named("interactive") == .interactive && RunProfile.named("delegated") == .delegated)
        #expect(RunProfile.named("nope") == nil)
    }

    @Test func toolSetAndPromptPrefixAreProfileIndependent() async throws {
        let f = try makeFixture(); defer { f.remove() }
        // Delegated run.
        let e1 = FakeEngine(); e1.script(say("ok"))
        _ = await runner(e1, f).run(spec: HarnessJobSpec(task: "t", cwd: f.repo, access: .write), jobID: "d1", onEvent: { _ in })
        // Chat session.
        let e2 = FakeEngine(); e2.script(say("ok"))
        let hr = runner(e2, f)
        try await hr.openSession(spec: writeSpec(f), sessionID: "c1")
        _ = await drain(try await hr.appendUserTurn(sessionID: "c1", text: "t"))
        await hr.closeSession(sessionID: "c1")
        let d = e1.snapshot { $0.opened[0].1 }, c = e2.snapshot { $0.opened[0].1 }
        #expect(d.tools == c.tools && d.reasoningPolicy == c.reasoningPolicy)
        #expect(ToolCatalog.renderedSpecs(ToolCatalog.all(runner: ProcessRunner(profile: SandboxProfile(access: .read, writableRoots: [], jobTmp: "/tmp"), sandboxed: false)))
                    .contains("\"finish\""))
        let s1 = e1.snapshot { $0.appends[0].1 }, s2 = e2.snapshot { $0.appends[0].1 }
        if case let .messages(m1) = s1, case let .messages(m2) = s2 { #expect(m1[0] == m2[0]) } else { Issue.record("appends") }
    }
}

@Suite struct StreamRedactionTests {
    @Test func secretSplitAcrossDeltasIsRedacted() {
        var r = StreamRedactor()
        let token = "ghp_" + String(repeating: "a1B2", count: 8)
        var out = ""
        for chunk in ["token is ", String(token.prefix(7)), String(token.dropFirst(7)), " and more\n"] { out += r.push(chunk) }
        out += r.flush()
        #expect(!out.contains("ghp_") && out.contains("[REDACTED]") && out.contains("and more"))
    }

    @Test func keyAndValueSplitAtSpace() {
        var r = StreamRedactor()
        var out = ""
        for chunk in ["use Bearer ", "abcdefghijklmnop1234567890", " now"] { out += r.push(chunk) }
        out += r.flush()
        #expect(!out.contains("abcdefghijklmnop") && out.contains("Bearer"))
        var r2 = StreamRedactor()
        var o2 = ""
        for chunk in ["password", " = ", "hunter2hunter2hunter2", "\n"] { o2 += r2.push(chunk) }
        o2 += r2.flush()
        #expect(!o2.contains("hunter2hunter2"))
    }

    @Test func registeredSecretSplitAcrossDeltas() {
        Redactor.register(secret: "zq-secret-VALUE-42")
        var r = StreamRedactor()
        var out = r.push("value zq-secret-")
        out += r.push("VALUE-42 end ")
        out += r.flush()
        #expect(!out.contains("VALUE-42") && out.contains("end"))
    }

    @Test func proseStreamsAtWordBoundaries() {
        var r = StreamRedactor()
        let a = r.push("Hello there, this is plain ")
        #expect(a == "Hello there, this is plain ")
        #expect(r.push("tex") == "")
        #expect(r.flush() == "tex")
    }

    @Test func unterminatedPemIsHeld() {
        var r = StreamRedactor()
        var out = r.push("key:\n-----BEGIN PRIVATE KEY-----\nMIIEvAIBADANBg\n")
        out += r.push("more lines\n")
        #expect(out.isEmpty)
        out += r.flush()
        #expect(!out.contains("MIIEv") && out.contains("[REDACTED]"))
    }

    @Test func mapperRedactsAndTruncatesToolSummaries() {
        let m = ChatEventMapper(streamsDeltas: true)
        let secret = "sk-" + String(repeating: "x", count: 30)
        let started = m.map(.toolCall(name: "bash", args: "{\"command\":\"curl -H 'Authorization: Bearer \(secret)'\"}"))
        guard case let .toolCallStarted(name, summary)? = started.first else { Issue.record("no event"); return }
        #expect(name == "bash" && !summary.contains(secret))
        let finished = m.map(.toolResult(name: "bash", output: String(repeating: "y", count: 5000) + "\n" + secret, isError: true))
        guard case let .toolCallFinished(_, s2, err)? = finished.first else { Issue.record("no event"); return }
        #expect(err && s2.count <= ChatLimits.summaryChars + 1 && !s2.contains(secret))
    }

    @Test func nonStreamingProfileDropsDeltas() {
        let m = ChatEventMapper(streamsDeltas: false)
        #expect(m.map(.textDelta("hello\n")).isEmpty && m.flush().isEmpty)
    }
}

@Suite struct ChatSessionTests {
    @Test func twoTurnConversationKeepsStateAndWorktree() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(edit())                       // turn 1, step 1
        e.script(say("changed one to two"))    // turn 1, step 2: plain text ends the turn
        e.script(say("it is two now"))         // turn 2
        let hr = runner(e, f)
        try await hr.openSession(spec: writeSpec(f), sessionID: "chat1")
        let root = try #require(await hr.workspaceRoot(sessionID: "chat1"))
        #expect(e.snapshot { $0.opened.count } == 0, "engine session opens lazily with the first turn")

        let c1 = await drain(try await hr.appendUserTurn(sessionID: "chat1", text: "change one to two in a.txt"))
        #expect(c1.finished.count == 1 && c1.finished[0].status == .done && c1.finished[0].userTurn == 1)
        #expect(c1.text.contains("changed one to two"))
        #expect(c1.patches.count == 1 && c1.patches[0].filesChanged.map(\.path) == ["a.txt"])
        #expect(c1.patches[0].patch?.contains("+two") == true && c1.patches[0].userTurn == 1)
        // Worktree persists across turns; parent tree untouched.
        #expect(FileManager.default.fileExists(atPath: root) && f.worktrees == 1)
        #expect(try String(contentsOfFile: root + "/a.txt", encoding: .utf8) == "two\n")
        #expect(try String(contentsOfFile: f.repo + "/a.txt", encoding: .utf8) == "one\n")

        let c2 = await drain(try await hr.appendUserTurn(sessionID: "chat1", text: "what does a.txt say now?"))
        #expect(c2.finished[0].userTurn == 2 && c2.finished[0].summary == "it is two now")
        #expect(c2.patches.isEmpty, "no new change, no new patch event")
        #expect(c2.finished[0].totalUsage.turns == 3 && c2.finished[0].usage.turns == 1)
        #expect(c2.finished[0].totalUsage.promptTokens == 300)

        e.snapshot { f in
            // One engine session, append-only: [system+env/task], [tool result], [user turn 2].
            #expect(f.opened.count == 1 && f.closed.isEmpty)
            #expect(Set(f.generates.map(\.session)).count == 1)
            #expect(f.generates.allSatisfy { $0.params.priority == .interactive })
            guard case let .messages(first) = f.appends[0].1, case let .messages(last) = f.appends[f.appends.count - 1].1 else {
                Issue.record("appends"); return
            }
            if case let .text(t) = first[1].content { #expect(t.contains("# Task\nchange one to two in a.txt")) }
            #expect(last.count == 1 && last[0].role == .user)
            if case let .text(t) = last[0].content { #expect(t == "what does a.txt say now?") }
        }

        let r = try #require(await hr.closeSession(sessionID: "chat1"))
        #expect(r.status == .done && r.filesChanged.map(\.path) == ["a.txt"] && r.usage.turns == 3)
        #expect(f.worktrees == 0 && !FileManager.default.fileExists(atPath: root))
        #expect(e.snapshot { $0.closed.count } == 1)
        #expect(await hr.hasSession("chat1") == false)
        #expect(FileManager.default.fileExists(atPath: f.jobs.path + "/chat1/result.json"))
    }

    @Test func thinkingRequestReachesTheFirstEngineSession() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(say("thinking"))   // session "think-on", turn 1
        e.script(say("default"))    // session "think-default", turn 1
        let hr = runner(e, f)
        try await hr.openSession(spec: writeSpec(f), sessionID: "think-on")
        await hr.setThinking(sessionID: "think-on", enabled: true)
        _ = await drain(try await hr.appendUserTurn(sessionID: "think-on", text: "hi"))
        try await hr.openSession(spec: writeSpec(f), sessionID: "think-default")
        _ = await drain(try await hr.appendUserTurn(sessionID: "think-default", text: "hi"))
        e.snapshot { f in
            #expect(f.opened.count == 2)
            // Requested on: the template default with thinking enabled, as the thinking turns of the agent loop.
            #expect(f.opened[0].1.enableThinking == true && f.opened[0].1.reasoningPolicy == .templateDefault)
            // Never set: unchanged default, no enable_thinking sent.
            #expect(f.opened[1].1.enableThinking == nil && f.opened[1].1.reasoningPolicy == .disableWhenTools)
        }
        _ = await hr.closeSession(sessionID: "think-on")
        _ = await hr.closeSession(sessionID: "think-default")
    }

    @Test func secondTurnWhileRunningIsRejected() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine(); e.script([.hang])
        let hr = runner(e, f)
        try await hr.openSession(spec: writeSpec(f), sessionID: "chat2")
        let s = try await hr.appendUserTurn(sessionID: "chat2", text: "slow")
        await #expect(throws: ChatError.turnInProgress) { _ = try await hr.appendUserTurn(sessionID: "chat2", text: "again") }
        #expect(await hr.isTurnActive(sessionID: "chat2"))
        await hr.cancelTurn(sessionID: "chat2")
        let c = await drain(s)
        #expect(c.finished.first?.status == .cancelled)
        #expect(await hr.isTurnActive(sessionID: "chat2") == false)
        await #expect(throws: ChatError.sessionNotFound("nope")) { _ = try await hr.appendUserTurn(sessionID: "nope", text: "x") }
        await #expect(throws: ChatError.emptyText) { _ = try await hr.appendUserTurn(sessionID: "chat2", text: "  \n") }
        await #expect(throws: ChatError.textTooLong(ChatLimits.maxUserTextChars)) {
            _ = try await hr.appendUserTurn(sessionID: "chat2", text: String(repeating: "a", count: ChatLimits.maxUserTextChars + 1))
        }
        await hr.closeSession(sessionID: "chat2")
    }

    @Test func cancelMidTurnReachesEngineAndSessionStaysUsable() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script([.event(.tokens([1], "thinking about it "))] + [.hang])
        e.script(say("back again"))
        let hr = runner(e, f)
        try await hr.openSession(spec: writeSpec(f), sessionID: "chat3")
        let s = try await hr.appendUserTurn(sessionID: "chat3", text: "go")
        for _ in 0..<500 where e.snapshot({ $0.generates.count }) < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        await hr.cancelTurn(sessionID: "chat3")
        let c = await drain(s)
        #expect(c.finished.first?.status == .cancelled)
        let session = e.snapshot { $0.opened[0].0 }
        #expect(e.snapshot { $0.cancels }.contains(session), "cancel must reach the engine")
        #expect(e.snapshot { $0.closed.isEmpty }, "session survives a cancelled turn")
        // Next turn works on the same engine session.
        let c2 = await drain(try await hr.appendUserTurn(sessionID: "chat3", text: "again"))
        #expect(c2.finished.first?.status == .done && c2.finished.first?.summary == "back again")
        #expect(e.snapshot { Set($0.generates.map(\.session)).count } == 1)
        await hr.closeSession(sessionID: "chat3")
        #expect(f.worktrees == 0)
    }

    @Test func droppingTheStreamCancelsTheTurn() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine(); e.script([.hang])
        let hr = runner(e, f)
        try await hr.openSession(spec: writeSpec(f), sessionID: "chat4")
        do {
            let s = try await hr.appendUserTurn(sessionID: "chat4", text: "go")
            let t = Task { for await _ in s {} }
            for _ in 0..<500 where e.snapshot({ $0.generates.count }) < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
            t.cancel()
            await t.value
        }
        for _ in 0..<500 where await hr.isTurnActive(sessionID: "chat4") { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(await hr.isTurnActive(sessionID: "chat4") == false)
        #expect(e.snapshot { !$0.cancels.isEmpty || $0.terminatedCancelled > 0 })
        await hr.closeSession(sessionID: "chat4")
    }

    @Test func closeCancelsRunningTurnAndCleansUpExactlyOnce() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(edit())
        e.script([.hang])
        let iso = CountingIsolation(f.iso)
        let hr = runner(e, f, iso: iso)
        try await hr.openSession(spec: writeSpec(f), sessionID: "chat5")
        let s = try await hr.appendUserTurn(sessionID: "chat5", text: "edit then stall")
        for _ in 0..<500 where e.snapshot({ $0.generates.count }) < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        async let r1 = hr.closeSession(sessionID: "chat5")
        async let r2 = hr.closeSession(sessionID: "chat5")
        let (a, b) = await (r1, r2)
        #expect((a == nil) != (b == nil), "exactly one close wins")
        _ = await drain(s)
        #expect(iso.cleanups == 1 && f.worktrees == 0)
        #expect(e.snapshot { $0.closed.count } == 1)
        let won = try #require(a ?? b)
        #expect(won.filesChanged.map(\.path) == ["a.txt"], "the edit made before the cancel is still in the final patch")
        await #expect(throws: ChatError.sessionNotFound("chat5")) { _ = try await hr.appendUserTurn(sessionID: "chat5", text: "x") }
        #expect(iso.cleanups == 1)
    }

    @Test func perTurnPatchTracksChanges() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(edit()); e.script(say("one change"))
        e.script(edit("b.txt", old: "x", new: "y")); e.script(say("second change"))
        let hr = runner(e, f)
        try await hr.openSession(spec: writeSpec(f), sessionID: "chat6")
        let c1 = await drain(try await hr.appendUserTurn(sessionID: "chat6", text: "a"))
        let c2 = await drain(try await hr.appendUserTurn(sessionID: "chat6", text: "b"))
        #expect(c1.patches.map { $0.filesChanged.map(\.path) } == [["a.txt"]])
        #expect(c2.patches.map { $0.filesChanged.map(\.path) } == [["a.txt", "b.txt"]], "the patch is cumulative against the base")
        #expect(c2.patches[0].userTurn == 2)
        let cur = try await hr.currentPatch(sessionID: "chat6")
        #expect(cur.contains("+two") && cur.contains("+y"))
        await hr.closeSession(sessionID: "chat6")
    }

    @Test func readOnlySessionNeverCollectsPatch() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine(); e.script(say("nothing to change"))
        let iso = CountingIsolation(f.iso)
        let hr = runner(e, f, iso: iso)
        try await hr.openSession(spec: HarnessJobSpec(task: "", cwd: f.repo, access: .read), sessionID: "chat7")
        let c = await drain(try await hr.appendUserTurn(sessionID: "chat7", text: "look"))
        #expect(c.patches.isEmpty && iso.patches == 0)
        await hr.closeSession(sessionID: "chat7")
    }

    @Test func deltasAreRedactedBeforeTheyLeave() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let token = "ghp_" + String(repeating: "Zq9x", count: 8)
        let e = FakeEngine()
        e.script(gen([.event(.tokens([1], "the token is ")), .event(.tokens([2], String(token.prefix(10)))),
                      .event(.tokens([3], String(token.dropFirst(10)) + " ok\n")), .event(.reasoning("secret thought " + token))]))
        let hr = runner(e, f)
        try await hr.openSession(spec: writeSpec(f), sessionID: "chat8")
        let c = await drain(try await hr.appendUserTurn(sessionID: "chat8", text: "go"))
        let all = c.all.map { "\($0)" }.joined(separator: "\n")
        #expect(!all.contains("ghp_"), "no part of the token may leave")
        #expect(c.text.contains("[REDACTED]") && c.text.contains("ok"))
        #expect(!(c.finished[0].summary.contains("ghp_")))
        await hr.closeSession(sessionID: "chat8")
        let log = try String(contentsOfFile: f.jobs.path + "/chat8/events.jsonl", encoding: .utf8)
        #expect(!log.contains("ghp_"))
    }

    @Test func limitEventAndPerTurnLimits() async throws {
        let f = try makeFixture(); defer { f.remove() }
        var l = HarnessLimits(); l.maxTurns = 2
        let e = FakeEngine()
        e.script(gen(call("list_files", [("path", .string("."))])))   // 2 steps hit the per-turn limit
        e.script(gen(call("list_files", [("path", .string("src"))])))
        e.script(say("after limit"))
        let hr = runner(e, f)
        try await hr.openSession(spec: writeSpec(f, limits: l), sessionID: "chat9")
        let c = await drain(try await hr.appendUserTurn(sessionID: "chat9", text: "loop"))
        #expect(c.finished[0].status == .limit)
        #expect(c.all.contains { if case .limit = $0 { true } else { false } })
        // The turn limit is per user turn: the session continues.
        let c2 = await drain(try await hr.appendUserTurn(sessionID: "chat9", text: "next"))
        #expect(c2.finished[0].userTurn == 2)
        await hr.closeSession(sessionID: "chat9")
    }

    @Test func invalidIdsAndCwdAreTypedOpenFailures() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let hr = runner(FakeEngine(), f)
        await #expect(throws: ChatError.openFailed("invalid session id")) {
            try await hr.openSession(spec: writeSpec(f), sessionID: "../evil")
        }
        do { try await hr.openSession(spec: HarnessJobSpec(task: "", cwd: "relative"), sessionID: "x1"); Issue.record("should throw") }
        catch let ChatError.openFailed(m) { #expect(m.contains("invalid cwd")) }
        #expect(f.worktrees == 0)
        try await hr.openSession(spec: writeSpec(f), sessionID: "dup")
        await #expect(throws: ChatError.openFailed("session exists")) { try await hr.openSession(spec: writeSpec(f), sessionID: "dup") }
        await hr.closeSession(sessionID: "dup")
    }

    @Test func closeAllSessions() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let hr = runner(FakeEngine(), f)
        try await hr.openSession(spec: writeSpec(f), sessionID: "m1")
        try await hr.openSession(spec: writeSpec(f), sessionID: "m2")
        #expect(f.worktrees == 2)
        await hr.closeAllSessions()
        #expect(f.worktrees == 0)
    }
}

// MARK: - compaction across turns (AgentLoop level)

private struct FakeTool: HarnessTool {
    let name: String
    var spec: ToolSpec {
        ToolSpec(name: name, description: "fake", parameters: .ordered([("type", .string("object")), ("properties", .ordered([]))]))
    }
    func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult { ToolResult(output: "ok") }
}

@Suite struct ConversationLoopTests {
    private let ws = Workspace(root: "/tmp/ws", base: "abc")

    @Test func compactionKeepsConversationAcrossTurns() async {
        let e = FakeEngine()
        e.script(gen([.event(.tokens([1], "first answer"))], prompt: 50, completion: 5))                  // turn 1
        e.script(gen(call("read_file", [("path", .string("a"))]), prompt: 500, completion: 10))           // turn 2 step 1 (over threshold)
        e.script(gen([.event(.tokens([1], "second answer"))], prompt: 60, completion: 5))                 // turn 2 step 2, new session
        let loop = AgentLoop(engine: e, tools: [FakeTool(name: "read_file")], systemPrompt: "SYS", date: "2026-10-27",
                             compactionThreshold: 100)
        let conv = loop.openConversation(spec: HarnessJobSpec(task: "", cwd: "/tmp/p", access: .write), workspace: ws)
        let r1 = await loop.runUserTurn(conv, text: "first request about alpha", onEvent: { _ in })
        #expect(r1.status == .done && r1.summary == "first answer")
        let r2 = await loop.runUserTurn(conv, text: "second request about beta", onEvent: { _ in })
        #expect(r2.status == .done && r2.summary == "second answer")
        #expect(conv.userTurns == 2 && conv.totalUsage.turns == 3)
        e.snapshot { f in
            #expect(f.opened.count == 2, "compaction opened a fresh engine session")
            let seed: [String] = f.appends.filter { $0.0 == f.opened[1].0 }.compactMap {
                if case let .messages(m) = $0.1, m.count == 2, case let .text(t) = m[1].content { return t } else { return nil }
            }
            #expect(seed.count == 1)
            let t = seed.first ?? ""
            #expect(t.contains("# Task\nfirst request about alpha"))
            #expect(t.contains("# Conversation so far") && t.contains("<conversation untrusted=\"true\">"))
            #expect(t.contains("user: first request about alpha") && t.contains("assistant (done): first answer"))
            #expect(t.contains("user: second request about beta"), "the in-flight request survives the compaction")
            #expect(t.contains("Continue from the latest user message"))
        }
        await loop.closeConversation(conv)
        await loop.closeConversation(conv)
        #expect(e.snapshot { $0.closed.count } == 2, "old session closed at compaction, current one at close, each once")
    }

    @Test func delegatedCompactionTextIsUnchanged() async {
        let e = FakeEngine()
        e.script(gen(call("read_file", [("path", .string("a"))]), prompt: 500, completion: 10))
        e.script(gen(call("finish", [("summary", .string("done"))])))
        let loop = AgentLoop(engine: e, tools: [FakeTool(name: "read_file")], systemPrompt: "SYS", compactionThreshold: 100)
        _ = await loop.run(spec: HarnessJobSpec(task: "do it", cwd: "/tmp/p"), workspace: ws, onEvent: { _ in })
        e.snapshot { f in
            guard case let .messages(m) = f.appends[2].1, case let .text(t) = m[1].content else { Issue.record("seed"); return }
            #expect(!t.contains("Conversation so far") && t.hasSuffix("Continue the task above from here; do not redo finished work."))
        }
    }
}
