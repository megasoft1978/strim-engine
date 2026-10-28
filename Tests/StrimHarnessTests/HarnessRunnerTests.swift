import Testing
import Foundation
import StrimAdmission
import StrimEngine
import StrimTemplate
@testable import StrimHarness

private final class CheckpointHits: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HarnessEvent] = []
    func add(_ e: HarnessEvent) { lock.withLock { items.append(e) } }
    var toolResults: [(String, String, Bool)] {
        lock.withLock { items.compactMap { if case let .toolResult(n, o, e) = $0 { return (n, o, e) } else { return nil } } }
    }
    var finished: [HarnessStatus] {
        lock.withLock { items.compactMap { if case let .finished(s) = $0 { return s } else { return nil } } }
    }
}

private func call(_ name: String, _ args: [(String, OrderedJSON)] = []) -> [FakeEngine.Step] {
    var s: [FakeEngine.Step] = [.event(.toolCallBegin(name: name))]
    for (k, v) in args { s.append(.event(.toolCallArg(key: k, value: v))) }
    s.append(.event(.toolCallEnd))
    return s
}
private func turn(_ steps: [FakeEngine.Step]) -> [FakeEngine.Step] {
    steps + [.event(.finished(.stop, makeUsage(prompt: 100, completion: 10)))]
}
private func finishTurn(_ summary: String = "all done") -> [FakeEngine.Step] {
    turn(call("finish", [("summary", .string(summary)), ("status", .string("done"))]))
}
private func editTurn(_ path: String = "a.txt", old: String = "one", new: String = "two") -> [FakeEngine.Step] {
    turn(call("edit_file", [("path", .string(path)), ("old", .string(old)), ("new", .string(new))]))
}

private func mode(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Suite struct HarnessRunnerTests {
    private struct Fixture {
        let root: URL, repo: String, wtDir: URL, jobs: URL
        var iso: GitWorktreeIsolation { GitWorktreeIsolation(baseDir: wtDir) }
        func jobDir(_ id: String) -> String { jobs.appendingPathComponent(id).path }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func git(_ args: [String], in dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try GitWorktreeIsolation.gitExecutable())
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_TERMINAL_PROMPT": "0"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "git", code: Int(p.terminationStatus)) }
        return String(decoding: data, as: UTF8.self)
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hr-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["config", "user.name", "Test"], in: repo)
        try git(["config", "user.email", "test@example.com"], in: repo)
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "# Rules\nUse tabs.\n".write(toFile: repo + "/AGENTS.md", atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        return Fixture(root: root, repo: repo, wtDir: root.appendingPathComponent("wt"), jobs: root.appendingPathComponent("jobs"))
    }

    private func runner(_ e: FakeEngine, _ f: Fixture, keep: Bool = false, sandboxed: Bool = false) -> HarnessRunner {
        HarnessRunner(engine: e, isolation: f.iso, sandboxed: sandboxed, keepWorkspace: keep, jobsDir: f.jobs,
                      now: { Date(timeIntervalSince1970: 1_793_000_000) })  // 2026-10-26 UTC
    }

    private func snapshot(_ dir: String) throws -> String {
        try git(["status", "--porcelain"], in: dir) + git(["rev-parse", "HEAD"], in: dir)
            + (try String(contentsOfFile: dir + "/a.txt", encoding: .utf8))
    }

    private func worktreeCount(_ f: Fixture) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: f.wtDir.path)) ?? []).count
    }

    @Test func writeJobProducesApplicablePatchAndLeavesParentUntouched() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(editTurn()); e.script(finishTurn())
        let before = try snapshot(f.repo)
        let ev = Events()
        let r = await runner(e, f).run(spec: HarnessJobSpec(task: "change one to two", cwd: f.repo, access: .write),
                                       jobID: "job1", onEvent: { ev.add($0) })
        #expect(r.status == .done)
        #expect(r.summary == "all done")
        #expect(r.filesChanged == [FileChange(path: "a.txt", added: 1, removed: 1)])
        let patch = try #require(r.patch)
        #expect(patch.contains("+two") && patch.contains("-one"))
        let head = try git(["rev-parse", "HEAD"], in: f.repo).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(r.base == head)
        #expect(ev.finished == [.done])

        // Patch applies to the parent, which is itself unchanged.
        let jd = f.jobDir("job1")
        #expect(r.patchPath == jd + "/patch.diff")
        try git(["apply", "--check", jd + "/patch.diff"], in: f.repo)
        #expect(try snapshot(f.repo) == before)

        // Job dir artifacts and modes.
        #expect(mode(jd) == 0o700)
        for name in ["patch.diff", "result.json", "events.jsonl"] {
            #expect(FileManager.default.fileExists(atPath: jd + "/" + name), "\(name) missing")
            #expect(mode(jd + "/" + name) == 0o600, "\(name) mode")
        }
        #expect(!FileManager.default.fileExists(atPath: jd + "/tmp"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: jd + "/result.json"))) as? [String: Any]
        #expect(json?["status"] as? String == "done" && json?["base"] as? String == head)
        // Workspace removed.
        #expect(worktreeCount(f) == 0)
    }

    @Test func promptCarriesProjectContextEnvAndDate() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(finishTurn())
        _ = await runner(e, f).run(spec: HarnessJobSpec(task: "look around", cwd: f.repo, context: "extra ctx", files: [], access: .write),
                                   jobID: "job-ctx", onEvent: { _ in })
        let (sys, user): (String, String) = e.snapshot { fe in
            guard case let .messages(m) = fe.appends[0].1, m.count == 2,
                  case let .text(s) = m[0].content, case let .text(u) = m[1].content else { return ("", "") }
            return (s, u)
        }
        #expect(sys == PackLoader.builtin().systemPrompt)
        #expect(user.contains("<project_context untrusted=\"true\">") && user.contains("Use tabs."))
        #expect(user.contains("branch: main") && user.contains("access: write") && user.contains("date: 2026-10-26"))
        #expect(user.contains("limits: 40 turns") && user.contains("look around") && user.contains("extra ctx"))
        // All seven tools, in order, with the fixed reasoning policy.
        let names = e.snapshot { $0.opened[0].1.tools.count }
        #expect(names == 7)
    }

    @Test func readAccessIsIsolatedAndProducesNoPatch() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(editTurn()); e.script(finishTurn())
        let ev = Events()
        let before = try snapshot(f.repo)
        let r = await runner(e, f).run(spec: HarnessJobSpec(task: "t", cwd: f.repo, access: .read), jobID: "job-ro", onEvent: { ev.add($0) })
        #expect(r.status == .done)
        #expect(r.patch == nil && r.patchPath == nil && r.filesChanged.isEmpty)
        #expect(ev.toolResults.first { $0.0 == "edit_file" }?.2 == true)  // refused
        #expect(!FileManager.default.fileExists(atPath: f.jobDir("job-ro") + "/patch.diff"))
        #expect(try snapshot(f.repo) == before)
        #expect(worktreeCount(f) == 0)
    }

    @Test func invalidCwdIsRejected() async throws {
        let f = try makeFixture(); defer { f.remove() }
        try "x".write(toFile: f.root.path + "/file.txt", atomically: true, encoding: .utf8)
        let home = NSHomeDirectory()
        let cases = [home, home + "/", "/", (home as NSString).deletingLastPathComponent, "relative/dir", "",
                     f.root.path + "/missing", f.root.path + "/file.txt"]
        for (i, cwd) in cases.enumerated() {
            let e = FakeEngine()
            let ev = Events()
            let r = await runner(e, f).run(spec: HarnessJobSpec(task: "t", cwd: cwd), jobID: "bad\(i)", onEvent: { ev.add($0) })
            #expect(r.status == .failed && r.summary.hasPrefix("invalid cwd"), "cwd=\(cwd): \(r.summary)")
            #expect(e.snapshot { $0.opened.isEmpty }, "engine must not be used for cwd=\(cwd)")
            #expect(ev.finished == [.failed])
        }
        #expect(worktreeCount(f) == 0)
        // A subdirectory of $HOME-like paths is fine: a temp repo works (covered by the other tests).
    }

    @Test func invalidJobIdRejected() async throws {
        let f = try makeFixture(); defer { f.remove() }
        for id in ["", "../x", "a/b", "a b", String(repeating: "a", count: 200)] {
            let r = await runner(FakeEngine(), f).run(spec: HarnessJobSpec(task: "t", cwd: f.repo), jobID: id, onEvent: { _ in })
            #expect(r.status == .failed, "id=\(id)")
        }
        #expect(!FileManager.default.fileExists(atPath: f.jobs.path))
    }

    @Test func eventsAndResultContainNoPlantedSecret() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let secret = "ghp_" + "Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Ji1Hg0FeDcBa"
        let e = FakeEngine()
        e.script(turn([.event(.tokens([1], "thinking about \(secret) now"))]
                      + call("write_file", [("path", .string("n.txt")), ("content", .string("token=\(secret)\n"))])))
        e.script(turn(call("bash", [("command", .string("cat n.txt"))])))
        e.script(finishTurn("done; leaked \(secret)"))
        let r = await runner(e, f).run(spec: HarnessJobSpec(task: "t", cwd: f.repo, access: .write), jobID: "job-sec", onEvent: { _ in })
        #expect(!r.summary.contains(secret) && r.summary.contains("[REDACTED]"))
        let jd = f.jobDir("job-sec")
        for name in ["events.jsonl", "result.json"] {
            let text = try String(contentsOfFile: jd + "/" + name, encoding: .utf8)
            #expect(!text.contains(secret), "\(name) leaks the secret")
        }
        let events = try String(contentsOfFile: jd + "/events.jsonl", encoding: .utf8)
        #expect(events.contains("[REDACTED]"))
        // patch.diff is deliberately left untouched (it must still apply); modes stay private.
        let patchFile = try String(contentsOfFile: jd + "/patch.diff", encoding: .utf8)
        #expect(patchFile.contains(secret))
        #expect(mode(jd) == 0o700 && mode(jd + "/patch.diff") == 0o600)
        #expect(mode(jd + "/result.json") == 0o600 && mode(jd + "/events.jsonl") == 0o600)
        for line in events.split(separator: "\n") {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil, "bad jsonl line")
        }
    }

    @Test func hostileReadOfSshIsRefused() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        let ssh = NSHomeDirectory() + "/.ssh/id_ed25519"
        e.script(turn(call("read_file", [("path", .string(ssh))])))
        e.script(turn(call("read_file", [("path", .string("../../../../../../.." + ssh))])))
        e.script(turn(call("list_files", [("path", .string(NSHomeDirectory() + "/.ssh"))])))
        e.script(finishTurn())
        let ev = Events()
        let r = await runner(e, f).run(spec: HarnessJobSpec(task: "t", cwd: f.repo), jobID: "job-ssh", onEvent: { ev.add($0) })
        let reads = ev.toolResults.filter { $0.0 == "read_file" || $0.0 == "list_files" }
        #expect(reads.count == 3 && reads.allSatisfy { $0.2 }, "every ~/.ssh access must be an error")
        #expect(!reads.contains { $0.1.contains("PRIVATE KEY") })
        #expect(r.status == .done)
    }

    @Test func bashRunsSandboxedInWorktreeAndShowsUpInPatch() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(turn(call("bash", [("command", .string("echo hello > made.txt && git status --short && git add -A && echo ok"))])))
        e.script(finishTurn())
        let ev = Events()
        let r = await runner(e, f, sandboxed: true).run(spec: HarnessJobSpec(task: "t", cwd: f.repo, access: .write),
                                                        jobID: "job-bash", onEvent: { ev.add($0) })
        let bash = try #require(ev.toolResults.first { $0.0 == "bash" })
        #expect(bash.1.hasSuffix("[exit code: 0]"), "bash output: \(bash.1)")
        #expect(r.commands.count == 1 && r.commands[0].exit == 0)
        #expect(r.filesChanged.map(\.path) == ["made.txt"])
        #expect(!FileManager.default.fileExists(atPath: f.repo + "/made.txt"))
    }

    @Test func keepWorkspaceRetainsUntilDiscarded() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(editTurn()); e.script(finishTurn())
        let hr = runner(e, f, keep: true)
        _ = await hr.run(spec: HarnessJobSpec(task: "t", cwd: f.repo, access: .write), jobID: "job-keep", onEvent: { _ in })
        let ws = try #require(await hr.keptWorkspace(jobID: "job-keep"))
        #expect(FileManager.default.fileExists(atPath: ws.root + "/a.txt"))
        #expect(worktreeCount(f) == 1)
        await hr.discardWorkspace(jobID: "job-keep")
        #expect(await hr.keptWorkspace(jobID: "job-keep") == nil)
        #expect(worktreeCount(f) == 0)
    }

    @Test func cancellationCleansUp() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(editTurn())
        e.script([.hang])
        let hr = runner(e, f)
        let repo = f.repo
        let task = Task { await hr.run(spec: HarnessJobSpec(task: "t", cwd: repo, access: .write), jobID: "job-cancel", onEvent: { _ in }) }
        // Wait until the second generate (the hanging one) has started.
        for _ in 0..<200 {
            if e.snapshot({ $0.generates.count }) >= 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(e.snapshot { $0.generates.count } >= 2)
        task.cancel()
        let r = await task.value
        #expect(r.status == .cancelled)
        #expect(r.patch == nil && r.patchPath == nil)
        #expect(worktreeCount(f) == 0)
        #expect(!FileManager.default.fileExists(atPath: f.jobDir("job-cancel") + "/tmp"))
        #expect(FileManager.default.fileExists(atPath: f.jobDir("job-cancel") + "/result.json"))
        #expect(e.snapshot { $0.closed.count == $0.opened.count })
        #expect(try String(contentsOfFile: f.repo + "/a.txt", encoding: .utf8) == "one\n")
    }

    /// Cancelling a delegated run while it waits at a turn-boundary checkpoint ends it like a cancelled generate.
    @Test func cancellationAtCheckpointCleansUp() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(editTurn())
        e.script(finishTurn())
        let hr = runner(e, f)
        let repo = f.repo
        let waits = CheckpointHits()
        let task = Task {
            await AdmissionCheckpoint.$current.withValue({ waits.bump(); try await Task.sleep(for: .seconds(60)) }) {
                await hr.run(spec: HarnessJobSpec(task: "t", cwd: repo, access: .write), jobID: "job-ckpt", onEvent: { _ in })
            }
        }
        for _ in 0..<200 where waits.value < 1 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(waits.value == 1, "checkpoint must run before the second turn")
        task.cancel()
        let r = await task.value
        #expect(r.status == .cancelled)
        #expect(r.patch == nil && r.patchPath == nil)
        #expect(e.snapshot { $0.generates.count } == 1)
        #expect(worktreeCount(f) == 0)
        #expect(e.snapshot { $0.closed.count == $0.opened.count })
        #expect(try String(contentsOfFile: f.repo + "/a.txt", encoding: .utf8) == "one\n")
    }

    @Test func largePatchIsNotInlined() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let big = String(repeating: "line of generated content\n", count: 1500)  // ~39 KB
        let e = FakeEngine()
        e.script(turn(call("write_file", [("path", .string("big.txt")), ("content", .string(big))])))
        e.script(finishTurn())
        let r = await runner(e, f).run(spec: HarnessJobSpec(task: "t", cwd: f.repo, access: .write), jobID: "job-big", onEvent: { _ in })
        #expect(r.patch == nil)
        let path = try #require(r.patchPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count > 16 * 1024)
        try git(["apply", "--check", path], in: f.repo)
    }

    @Test func agentMadeUnremovableTmpTreeIsCleanedUp() async throws {
        let f = try makeFixture(); defer {
            _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+rwx", f.root.path])
            f.remove()
        }
        let e = FakeEngine()
        e.script(turn(call("bash", [("command", .string("mkdir -p $TMPDIR/d/e && touch $TMPDIR/d/e/f && chmod 000 $TMPDIR/d/e $TMPDIR/d"))])))
        e.script(finishTurn())
        let ev = Events()
        _ = await runner(e, f, sandboxed: true).run(spec: HarnessJobSpec(task: "t", cwd: f.repo, access: .write),
                                                    jobID: "job-chmod", onEvent: { ev.add($0) })
        #expect(ev.toolResults.first { $0.0 == "bash" }?.1.hasSuffix("[exit code: 0]") == true)
        #expect(!FileManager.default.fileExists(atPath: f.jobDir("job-chmod") + "/tmp"))
    }

    @Test func nothingRemainsInHostObjectsAndWorktreeIsGone() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let hostObjects = f.wtDir.resolvingSymlinksInPath().path + "-host-objects"
        func remaining() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: hostObjects)) ?? [] }
        let e = FakeEngine()
        e.script(editTurn()); e.script(finishTurn())
        let r = await runner(e, f).run(spec: HarnessJobSpec(task: "t", cwd: f.repo, access: .write), jobID: "job-host", onEvent: { _ in })
        #expect(r.status == .done && r.patch != nil)
        #expect(remaining().isEmpty, "host objects left: \(remaining())")
        #expect(worktreeCount(f) == 0)
        // Also on the read path.
        let e2 = FakeEngine(); e2.script(finishTurn())
        _ = await runner(e2, f).run(spec: HarnessJobSpec(task: "t", cwd: f.repo, access: .read), jobID: "job-host2", onEvent: { _ in })
        #expect(remaining().isEmpty && worktreeCount(f) == 0)
    }

    /// Counts cleanup calls and forwards to a real isolation.
    private final class CountingIsolation: WorkspaceIsolation, @unchecked Sendable {
        let inner: GitWorktreeIsolation
        private let lock = NSLock()
        private var n = 0
        var cleanups: Int { lock.withLock { n } }
        init(_ inner: GitWorktreeIsolation) { self.inner = inner }
        func prepare(cwd: String, access: AccessLevel, files: [String]) async throws -> Workspace {
            try await inner.prepare(cwd: cwd, access: access, files: files)
        }
        func collectPatch(_ w: Workspace) async throws -> String { try await inner.collectPatch(w) }
        func cleanup(_ w: Workspace) async { lock.withLock { n += 1 }; await inner.cleanup(w) }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_793_000_000)
        func now() -> Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    @Test func externalWallClockCancellationReachesLoopAndCleansUpOnce() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        e.script(editTurn())
        e.script([.hang])
        let iso = CountingIsolation(f.iso)
        let hr = HarnessRunner(engine: e, isolation: iso, sandboxed: false, jobsDir: f.jobs)
        var limits = HarnessLimits(); limits.maxSeconds = 1
        let spec = HarnessJobSpec(task: "t", cwd: f.repo, access: .write, limits: limits)
        let ev = Events()
        let started = Date()
        let task = Task { await hr.run(spec: spec, jobID: "job-wall", onEvent: { ev.add($0) }) }
        // Stand-in for JobManager's wall-clock limit: cancel the executor task once the agent is inside the hanging
        // generate (its 2nd call). A fixed sleep could fire earlier under load, before the workspace exists.
        for _ in 0..<500 where e.snapshot({ $0.generates.count }) < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(e.snapshot { $0.generates.count } >= 2, "agent never reached the hanging generate")
        task.cancel()
        let r = await task.value
        // engine.cancel is sent from an unstructured task spawned by the cancellation handler; wait until it lands.
        for _ in 0..<500 where e.snapshot({ $0.cancels.count }) < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(Date().timeIntervalSince(started) < 10, "cancellation must reach a hanging generate")
        #expect(r.status == .cancelled)
        #expect(ev.finished == [.cancelled])
        #expect(iso.cleanups == 1)
        #expect(e.snapshot { $0.cancels.count >= 1 && $0.closed.count == $0.opened.count })
        #expect(worktreeCount(f) == 0)
    }

    @Test func jobMaxSecondsIsHonouredByTheLoop() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let clock = TestClock()
        let e = FakeEngine()
        e.script([.event(.tokens([1], "working")), .wait(.milliseconds(800)),
                  .event(.finished(.stop, makeUsage(prompt: 10, completion: 2)))])
        let iso = CountingIsolation(f.iso)
        let hr = HarnessRunner(engine: e, isolation: iso, sandboxed: false, jobsDir: f.jobs, now: { clock.now() })
        var limits = HarnessLimits(); limits.maxSeconds = 30
        let spec = HarnessJobSpec(task: "t", cwd: f.repo, access: .write, limits: limits)
        let task = Task { await hr.run(spec: spec, jobID: "job-limit", onEvent: { _ in }) }
        for _ in 0..<200 where e.snapshot({ $0.generates.count }) < 1 { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        clock.advance(60)  // past the job's maxSeconds while generating
        let r = await task.value
        #expect(r.status == .limit, "summary: \(r.summary)")
        #expect(r.summary.contains("time limit (30s)"))
        #expect(iso.cleanups == 1 && worktreeCount(f) == 0)
    }
}
