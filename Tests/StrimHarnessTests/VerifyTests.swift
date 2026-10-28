import Testing
import Foundation
import Darwin
import StrimEngine
import StrimTemplate
@testable import StrimHarness

private func call(_ name: String, _ args: [(String, OrderedJSON)] = []) -> [FakeEngine.Step] {
    var s: [FakeEngine.Step] = [.event(.toolCallBegin(name: name))]
    for (k, v) in args { s.append(.event(.toolCallArg(key: k, value: v))) }
    s.append(.event(.toolCallEnd))
    return s
}
private func turn(_ steps: [FakeEngine.Step]) -> [FakeEngine.Step] {
    steps + [.event(.finished(.stop, makeUsage(prompt: 100, completion: 10)))]
}
private func finishTurn(status: String = "done") -> [FakeEngine.Step] {
    turn(call("finish", [("summary", .string("all done")), ("status", .string(status))]))
}
private func editTurn() -> [FakeEngine.Step] {
    turn(call("edit_file", [("path", .string("a.txt")), ("old", .string("one")), ("new", .string("two"))]))
}

@Suite struct VerifyTests {
    private struct Fixture {
        let root: URL, repo: String, wtDir: URL, jobs: URL
        func jobDir(_ id: String) -> String { jobs.appendingPathComponent(id).path }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func git(_ args: [String], in dir: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try GitWorktreeIsolation.gitExecutable())
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_TERMINAL_PROMPT": "0"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        _ = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "git", code: Int(p.terminationStatus)) }
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vf-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["config", "user.name", "Test"], in: repo)
        try git(["config", "user.email", "test@example.com"], in: repo)
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        return Fixture(root: root, repo: repo, wtDir: root.appendingPathComponent("wt"), jobs: root.appendingPathComponent("jobs"))
    }

    private func runner(_ e: FakeEngine, _ f: Fixture, sandboxed: Bool = false, timeout: TimeInterval = 120) -> HarnessRunner {
        HarnessRunner(engine: e, isolation: GitWorktreeIsolation(baseDir: f.wtDir), sandboxed: sandboxed, jobsDir: f.jobs,
                      now: { Date(timeIntervalSince1970: 1_793_000_000) }, verifyTimeout: timeout)
    }

    private func resultJSON(_ f: Fixture, _ id: String) throws -> [String: Any] {
        let d = try Data(contentsOf: URL(fileURLWithPath: f.jobDir(id) + "/result.json"))
        return try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    private func run(_ f: Fixture, _ e: FakeEngine, verify: String?, id: String, access: AccessLevel = .write,
                     sandboxed: Bool = false, timeout: TimeInterval = 120) async -> HarnessJobResult {
        await runner(e, f, sandboxed: sandboxed, timeout: timeout)
            .run(spec: HarnessJobSpec(task: "change one to two", cwd: f.repo, access: access, verify: verify),
                 jobID: id, onEvent: { _ in })
    }

    @Test func verifyPassesAfterEditsAndIsRecorded() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine(); e.script(editTurn()); e.script(finishTurn())
        // Only passes if the harness runs it in the edited worktree.
        let r = await run(f, e, verify: "grep -q two *.txt && echo VERIFY-OK", id: "v-pass")
        #expect(r.status == .done)
        #expect(r.verify.status == .verified && r.verify.exitCode == 0)
        #expect(r.verify.outputTail.contains("VERIFY-OK"))
        #expect(r.patch?.contains("+two") == true)
        let v = try #require(try resultJSON(f, "v-pass")["verify"] as? [String: Any])
        #expect(v["status"] as? String == "verified" && v["exit_code"] as? Int == 0)
        #expect((v["output_tail"] as? String)?.contains("VERIFY-OK") == true)
    }

    @Test func verifyFailureKeepsStatusDoneAndReportsExit() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine(); e.script(editTurn()); e.script(finishTurn())
        let r = await run(f, e, verify: "echo broken-test; exit 3", id: "v-fail")
        #expect(r.status == .done)
        #expect(r.verify.status == .failed && r.verify.exitCode == 3 && r.verify.outputTail.contains("broken-test"))
        #expect(try (resultJSON(f, "v-fail")["verify"] as? [String: Any])?["status"] as? String == "failed")
    }

    @Test func noVerifyArgIsUnverifiedAndNothingRuns() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine(); e.script(finishTurn())
        let r = await run(f, e, verify: nil, id: "v-none")
        #expect(r.verify == .unverified && r.verify.exitCode == nil)
        let v = try #require(try resultJSON(f, "v-none")["verify"] as? [String: Any])
        #expect(v["status"] as? String == "unverified" && v["exit_code"] == nil)
        // Whitespace-only is the same as absent.
        let e2 = FakeEngine(); e2.script(finishTurn())
        #expect(await run(f, e2, verify: "   ", id: "v-blank").verify == .unverified)
    }

    @Test func verifyRunsAtLimitAndForReadAccessButNotAfterFailure() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let marker = f.root.path + "/ran-\(UUID().uuidString)"
        let cmd = "echo x >> \(marker)"
        // limit: the loop hits the turn limit
        var limits = HarnessLimits(); limits.maxTurns = 1
        let e = FakeEngine(); e.script(editTurn())
        let r = await runner(e, f).run(spec: HarnessJobSpec(task: "t", cwd: f.repo, access: .write, limits: limits, verify: cmd),
                                       jobID: "v-limit", onEvent: { _ in })
        #expect(r.status == .limit && r.verify.status == .verified)
        // read access
        let e2 = FakeEngine(); e2.script(finishTurn())
        #expect(await run(f, e2, verify: cmd, id: "v-read", access: .read).verify.status == .verified)
        #expect((try? String(contentsOfFile: marker, encoding: .utf8))?.count == 4)
        // agent-declared failure: no verify run
        let e3 = FakeEngine(); e3.script(finishTurn(status: "failed"))
        let r3 = await run(f, e3, verify: cmd, id: "v-agentfail")
        #expect(r3.status == .failed && r3.verify == .unverified)
        #expect((try? String(contentsOfFile: marker, encoding: .utf8))?.count == 4, "verify must not run after a failed job")
    }

    @Test func verifyOutputIsRedactedAndClipped() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let secret = "ghp_" + "Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Ji1Hg0FeDcBa"
        let e = FakeEngine(); e.script(finishTurn())
        let r = await run(f, e, verify: "echo \(secret); seq 1 5000; echo END-MARK; echo token=\(secret) >&2", id: "v-red")
        #expect(r.verify.outputTail.count <= VerifyResult.maxTailChars)
        #expect(r.verify.outputTail.contains("END-MARK") && !r.verify.outputTail.contains("seq"))
        #expect(!r.verify.outputTail.contains(secret))
        // secret in the visible tail is redacted, not merely clipped
        let e2 = FakeEngine(); e2.script(finishTurn())
        let r2 = await run(f, e2, verify: "echo \(secret)", id: "v-red2")
        #expect(r2.verify.outputTail.contains("[REDACTED]") && !r2.verify.outputTail.contains(secret))
        let raw = try String(contentsOfFile: f.jobDir("v-red2") + "/result.json", encoding: .utf8)
        #expect(!raw.contains(secret))
    }

    @Test func verifyCommandIsSandboxedLikeBash() async throws {
        let f = try makeFixture(); defer { f.remove() }
        // A live loopback listener the sandbox must keep unreachable.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian; addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(bound == 0 && listen(fd, 8) == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)
        defer { close(fd) }

        let outside = f.root.path + "/outside-\(UUID().uuidString)"
        let probe = "ls /Users >/dev/null 2>&1; echo users=$?; touch \(outside) 2>/dev/null; echo write=$?; "
            + "(exec 3<>/dev/tcp/127.0.0.1/\(port)) 2>/dev/null; echo net=$?; exit 0"
        // Control: unsandboxed, every probe succeeds.
        let c = FakeEngine(); c.script(finishTurn())
        let rc = await run(f, c, verify: probe, id: "v-open", sandboxed: false)
        #expect(rc.verify.outputTail.contains("users=0") && rc.verify.outputTail.contains("write=0") && rc.verify.outputTail.contains("net=0"),
                "control: \(rc.verify.outputTail)")
        try? FileManager.default.removeItem(atPath: outside)
        // Sandboxed: reads of /Users, writes outside the worktree and network all fail.
        let s = FakeEngine(); s.script(finishTurn())
        let rs = await run(f, s, verify: probe, id: "v-sbx", sandboxed: true)
        let t = rs.verify.outputTail
        #expect(t.contains("users=1") || t.contains("users=2") || t.contains("users=126"), "users: \(t)")
        #expect(t.contains("write=1") && !t.contains("write=0"), "write: \(t)")
        #expect(t.contains("net=1") && !t.contains("net=0"), "net: \(t)")
        #expect(!FileManager.default.fileExists(atPath: outside))
    }

    @Test func verifyTimeoutIsFailedAndFast() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine(); e.script(finishTurn())
        let t0 = Date()
        let r = await run(f, e, verify: "echo started; sleep 30", id: "v-to", timeout: 1)
        #expect(Date().timeIntervalSince(t0) < 10)
        #expect(r.status == .done && r.verify.status == .failed && r.verify.outputTail.contains("timed out"))
    }

    @Test func cancellationMidVerifyKillsItAndIsUnverified() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let started = f.root.path + "/verify-started"
        let e = FakeEngine(); e.script(editTurn()); e.script(finishTurn())
        let hr = runner(e, f)
        let spec = HarnessJobSpec(task: "t", cwd: f.repo, access: .write, verify: "touch \(started); sleep 30")
        let task = Task { await hr.run(spec: spec, jobID: "v-cancel", onEvent: { _ in }) }
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: started) { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(FileManager.default.fileExists(atPath: started))
        let t0 = Date()
        task.cancel()
        let r = await task.value
        #expect(Date().timeIntervalSince(t0) < 5)
        #expect(r.status == .cancelled && r.verify == .unverified && r.patch == nil)
        #expect(try resultJSON(f, "v-cancel")["status"] as? String == "cancelled")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.wtDir.path)) ?? []).isEmpty)
    }

    @Test func declinedFinishSkipsVerifyAndPatch() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let marker = f.root.path + "/should-not-exist"
        let e = FakeEngine()
        e.script(editTurn())
        e.script(turn(call("finish", [("summary", .string("n/a")), ("declined", .bool(true)), ("reason", .string("task too vague"))])))
        let r = await run(f, e, verify: "touch \(marker)", id: "v-decl")
        #expect(r.status == .declined && r.summary == "task too vague")
        #expect(r.verify == .unverified && r.patch == nil && r.patchPath == nil && r.filesChanged.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(try resultJSON(f, "v-decl")["status"] as? String == "declined")
    }

    @Test func verifyCommandIsShownToAgentButNotAgentControlled() async throws {
        let f = try makeFixture(); defer { f.remove() }
        // The agent calls bash with its own idea of a verify command; the harness still runs the caller's.
        let e2 = FakeEngine()
        e2.script(turn(call("bash", [("command", .string("echo FAKE-VERIFY"))])))
        e2.script(finishTurn())
        let r = await run(f, e2, verify: "echo REAL-VERIFY", id: "v-ctl")
        #expect(r.verify.outputTail.contains("REAL-VERIFY") && !r.verify.outputTail.contains("FAKE-VERIFY"))
        let user: String = e2.snapshot { fe in
            guard case let .messages(m) = fe.appends[0].1, case let .text(u) = m[1].content else { return "" }
            return u
        }
        #expect(user.contains("verify (Strim runs this after you finish; exit 0 = verified): echo REAL-VERIFY"))
    }

    // MARK: integrity (touched sensitive paths, fresh env, leftover processes)

    private func patchFor(_ paths: [String]) -> String {
        paths.map { "diff --git a/\($0) b/\($0)\n--- a/\($0)\n+++ b/\($0)\n@@ -1 +1 @@\n-x\n+y\n" }.joined()
    }

    @Test func sensitivePathClassification() {
        let sensitive = ["tests/a.py", "Tests/StrimXTests/FooTests.swift", "src/test_utils.py", "pkg/foo_test.go", "web/a.test.ts",
                         "web/a.spec.ts", "spec/x.rb", "test_data/x.json", "Makefile", "sub/Makefile", "package.json", "Package.swift",
                         "pytest.ini", "setup.cfg", "pyproject.toml", "tox.ini", "pkg/conftest.py", ".github/workflows/ci.yml",
                         "scripts/run.sh", "app/FooTests.swift"]
        for p in sensitive { #expect(HarnessRunner.isSensitive(p), "\(p) should be sensitive") }
        for p in ["src/main.swift", "lib/util.py", "README.md", "a.txt", "docs/latest.md"] {
            #expect(!HarnessRunner.isSensitive(p), "\(p) should not be sensitive")
        }
        // Paths named in the verify command count, as do renames (old side) and deletions; capped at 5, sorted.
        #expect(HarnessRunner.sensitivePaths(in: patchFor(["src/a.swift", "src/b.swift"]), verifyCommand: "swift build && ./src/a.swift") == ["src/a.swift"])
        #expect(HarnessRunner.sensitivePaths(in: patchFor(["src/a.swift"]), verifyCommand: "swift test").isEmpty)
        #expect(HarnessRunner.sensitivePaths(in: patchFor(["lib/x.py"]), verifyCommand: "python lib") == ["lib/x.py"])
        let rename = "diff --git a/tests/old.py b/src/new.py\nsimilarity index 90%\nrename from tests/old.py\nrename to src/new.py\n"
        #expect(HarnessRunner.sensitivePaths(in: rename, verifyCommand: "true") == ["tests/old.py"])
        let many = (0..<9).map { "tests/t\($0).py" }
        let cap = HarnessRunner.sensitivePaths(in: patchFor(many), verifyCommand: "true")
        #expect(cap == Array(many.prefix(5)))
        #expect(HarnessRunner.sensitivePaths(in: "", verifyCommand: "true").isEmpty)
    }

    @Test func editingTestsDowngradesVerifiedAndIsRecorded() async throws {
        let f = try makeFixture(); defer { f.remove() }
        // Agent adds a (weak) test file; the verify command passes on it.
        let e = FakeEngine()
        e.script(turn(call("write_file", [("path", .string("tests/test_x.py")), ("content", .string("assert True\n"))])))
        e.script(finishTurn())
        let r = await run(f, e, verify: "true", id: "v-mod")
        #expect(r.status == .done)
        #expect(r.verify.status == .verifiedModifiedTests && r.verify.exitCode == 0)
        #expect(r.verify.touchedSensitive == ["tests/test_x.py"])
        #expect(r.patch?.contains("tests/test_x.py") == true)
        let v = try #require(try resultJSON(f, "v-mod")["verify"] as? [String: Any])
        #expect(v["status"] as? String == "verified_modified_tests")
        #expect(v["touched_sensitive"] as? [String] == ["tests/test_x.py"])
        // A failing verify stays failed (not upgraded or masked), but still lists the touched files.
        let e2 = FakeEngine()
        e2.script(turn(call("write_file", [("path", .string("Makefile")), ("content", .string("all:\n"))])))
        e2.script(finishTurn())
        let r2 = await run(f, e2, verify: "false", id: "v-mod2")
        #expect(r2.verify.status == .failed && r2.verify.touchedSensitive == ["Makefile"])
        // Ordinary edits that the command does not mention stay verified with an empty list.
        let e3 = FakeEngine(); e3.script(editTurn()); e3.script(finishTurn())
        let r3 = await run(f, e3, verify: "true", id: "v-mod3")
        #expect(r3.verify.status == .verified && r3.verify.touchedSensitive.isEmpty)
        #expect(try (resultJSON(f, "v-mod3")["verify"] as? [String: Any])?["touched_sensitive"] as? [String] == [])
    }

    @Test func fileMentionedInVerifyCommandDowngrades() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine(); e.script(editTurn()); e.script(finishTurn())
        let r = await run(f, e, verify: "grep -q two a.txt", id: "v-ment")
        #expect(r.verify.status == .verifiedModifiedTests && r.verify.touchedSensitive == ["a.txt"])
    }

    @Test func verifyRunsWithFreshHomeAndTmpdirAndPatchExcludesVerifyArtifacts() async throws {
        let f = try makeFixture(); defer { f.remove() }
        // Agent plants dotfiles/caches in the HOME and TMPDIR its own commands see.
        let e = FakeEngine()
        e.script(turn(call("bash", [("command", .string("mkdir -p \"$HOME\" && echo evil > \"$HOME/.planted\"; echo evil > \"$TMPDIR/planted\""))])))
        e.script(editTurn()); e.script(finishTurn())
        let probe = "[ ! -e \"$HOME/.planted\" ] && [ ! -e \"$TMPDIR/planted\" ] && case \"$HOME\" in */verify-*/home) ;; *) exit 7;; esac "
            + "&& case \"$TMPDIR\" in */verify-*/tmp) ;; *) exit 8;; esac && echo ok > build-artifact.out && echo FRESH"
        let sandboxed = await run(f, e, verify: probe, id: "v-env", sandboxed: true)
        #expect(sandboxed.verify.status == .verified && sandboxed.verify.outputTail.contains("FRESH"), "\(sandboxed.verify)")
        // Verify side effects are not part of the patch (it is collected before verify).
        #expect(sandboxed.patch?.contains("build-artifact.out") == false && sandboxed.patch?.contains("+two") == true)
    }

    /// Production always runs sandboxed, where every process of the job is found by its sandbox tag and killed when
    /// the command that spawned it ends. (The unsandboxed test-only runner misses some setsid survivors; not covered.)
    @Test func agentBackgroundProcessesAreGoneBeforeVerify() async throws {
        let f = try makeFixture(); defer { f.remove() }
        let e = FakeEngine()
        // A setsid'd background writer that would keep running (and could flip state during verify).
        e.script(turn(call("bash", [("command", .string(
            "perl -e 'use POSIX; fork or do { setsid(); exec(\"sh\", \"-c\", \"while true; do echo x >> bg.log; sleep 0.05; done\") }'; sleep 0.3; echo started"))])))
        e.script(finishTurn())
        let probe = "sleep 0.3; a=$(wc -c < bg.log); sleep 0.6; b=$(wc -c < bg.log); [ \"$a\" -gt 0 ] && [ \"$a\" = \"$b\" ]"
        let r = await run(f, e, verify: probe, id: "v-bg", sandboxed: true)
        // bg.log is mentioned in the command, so the status is downgraded; the point is exit 0: the writer ran, then was gone.
        #expect(r.verify.exitCode == 0 && r.verify.status == .verifiedModifiedTests, "\(r.verify)")
    }

    // MARK: git-backed integrity scan (NUL-separated, no header parsing)

    private func commit(_ f: Fixture, _ files: [String: String]) throws {
        for (path, content) in files {
            let full = f.repo + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try content.write(toFile: full, atomically: true, encoding: .utf8)
        }
        try git(["add", "-A"], in: f.repo)
        try git(["commit", "-q", "-m", "more"], in: f.repo)
    }

    private func bash(_ cmd: String) -> [FakeEngine.Step] { turn(call("bash", [("command", .string(cmd))])) }

    @Test func parseIntegrityIsNulBasedAndFailsClosed() {
        let ok = GitWorktreeIsolation.parseIntegrity(nameStatus: "M\0src/a.swift\0R100\0tests/old b/x.py\0src/new.py\0A\0\"q\".txt\0",
                                                     ignored: "out.log\0__pycache__/\0")
        #expect(ok.changedPaths == ["src/a.swift", "tests/old b/x.py", "src/new.py", "\"q\".txt"])
        #expect(ok.ignoredPaths == ["out.log", "__pycache__/"] && !ok.suspicious)
        for bad in ["M\0", "R100\0only-one\0", "??\0x\0", "M\0/abs\0", "M\0a/../b\0", "M\0.git/config\0", "M\0a\nb\0", "M\0bad\u{FFFD}\0", "M\0\0"] {
            #expect(GitWorktreeIsolation.parseIntegrity(nameStatus: bad, ignored: "").suspicious, "\(bad.debugDescription)")
        }
        #expect(GitWorktreeIsolation.parseIntegrity(nameStatus: "", ignored: "x\0../y\0").suspicious)
        // Odd paths are never echoed raw; the marker is.
        let t = HarnessRunner.touchedSensitive(integrity: .init(changedPaths: ["a\nb"], suspicious: true), patch: "", verifyCommand: "true")
        #expect(t == ["unverifiable:odd or unreadable path list"])
    }

    @Test func nameWithSpaceBSlashDoesNotEvadeClassification() async throws {
        let f = try makeFixture(); defer { f.remove() }
        // Header text `diff --git a/tests/ b/z.py b/tests/ b/z.py` splits wrongly at the inner " b/" (suffix `z.py`).
        let e = FakeEngine()
        e.script(turn(call("write_file", [("path", .string("tests/ b/z.py")), ("content", .string("x = 1\n"))])))
        e.script(turn(call("write_file", [("path", .string("tests/\u{e9}.py")), ("content", .string("y = 1\n"))])))
        e.script(finishTurn())
        let r = await run(f, e, verify: "true", id: "v-b")
        #expect(r.verify.status == .verifiedModifiedTests)
        #expect(r.verify.touchedSensitive.contains("tests/ b/z.py") && r.verify.touchedSensitive.contains("tests/\u{e9}.py"),
                "\(r.verify.touchedSensitive)")
    }

    @Test func renamesIntoAndOutOfTestsAreCaught() async throws {
        let f = try makeFixture(); defer { f.remove() }
        try commit(f, ["tests/t.py": "print('t')\nprint('t2')\nprint('t3')\n", "src/m.py": "print('m')\nprint('m2')\nprint('m3')\n"])
        // Out of tests/ (old side sensitive) and into tests/ (new side sensitive).
        let e = FakeEngine()
        e.script(bash("mv tests/t.py moved_t.py && mv src/m.py tests/m_moved.py"))
        e.script(finishTurn())
        let r = await run(f, e, verify: "true", id: "v-ren")
        #expect(r.verify.status == .verifiedModifiedTests)
        #expect(r.verify.touchedSensitive.contains("tests/t.py") && r.verify.touchedSensitive.contains("tests/m_moved.py"),
                "\(r.verify.touchedSensitive)")
    }

    @Test func ignoredFilesAreReportedAndDowngrade() async throws {
        let f = try makeFixture(); defer { f.remove() }
        try commit(f, [".gitignore": "secret.out\n"])
        // Pre-existing ignore rule: the planted file never appears in the patch.
        let e = FakeEngine()
        e.script(bash("echo evil > secret.out"))
        e.script(finishTurn())
        let r = await run(f, e, verify: "true", id: "v-ign")
        #expect(r.patch == nil)
        #expect(r.verify.status == .verifiedModifiedTests && r.verify.touchedSensitive == ["ignored:secret.out"], "\(r.verify)")
        // The agent edits .gitignore itself to hide a file next to the code: both are reported.
        let e2 = FakeEngine()
        e2.script(turn(call("write_file", [("path", .string(".gitignore")), ("content", .string("secret.out\nhidden_conftest.py\n"))])))
        e2.script(bash("echo evil > hidden_conftest.py"))
        e2.script(finishTurn())
        let r2 = await run(f, e2, verify: "true", id: "v-ign2")
        #expect(r2.patch?.contains("diff --git a/hidden_conftest.py") == false)
        #expect(r2.verify.status == .verifiedModifiedTests)
        #expect(r2.verify.touchedSensitive.contains(".gitignore") && r2.verify.touchedSensitive.contains("ignored:hidden_conftest.py"), "\(r2.verify.touchedSensitive)")
        // Failed verify with ignored files: still failed, list kept.
        let e3 = FakeEngine(); e3.script(bash("echo evil > secret.out")); e3.script(finishTurn())
        let r3 = await run(f, e3, verify: "false", id: "v-ign3")
        #expect(r3.verify.status == .failed && r3.verify.touchedSensitive == ["ignored:secret.out"])
    }

    @Test func regenerableCachesArePurgedBeforeVerifyAndDoNotDowngrade() async throws {
        let f = try makeFixture(); defer { f.remove() }
        try commit(f, [".gitignore": "__pycache__/\n.pytest_cache/\nnode_modules/\n.build/\n"])
        let e = FakeEngine()
        e.script(bash("mkdir -p pkg/__pycache__ .pytest_cache && echo evil > pkg/__pycache__/evil.pyc && echo c > .pytest_cache/v"))
        e.script(editTurn()); e.script(finishTurn())
        // The planted files must be gone by the time verify runs (so nothing can import them).
        let r = await run(f, e, verify: "test ! -e pkg/__pycache__/evil.pyc && test ! -e .pytest_cache && grep -q two *.txt && echo NOT-IMPORTED", id: "v-cache")
        #expect(r.verify.status == .verified && r.verify.touchedSensitive.isEmpty, "\(r.verify)")
        #expect(r.verify.outputTail.contains("NOT-IMPORTED"))
        #expect(HarnessRunner.isAllowedCache("pkg/__pycache__/m.pyc") && HarnessRunner.isAllowedCache(".build/") && !HarnessRunner.isAllowedCache("conftest.py"))
    }

    @Test func newDependencyDirDowngradesButPreExistingUnchangedDoesNot() async throws {
        let f = try makeFixture(); defer { f.remove() }
        try commit(f, [".gitignore": "node_modules/\n"])
        // Newly created (ignored) node_modules: files in it never show up in the patch.
        let e = FakeEngine()
        e.script(bash("mkdir -p node_modules/pkg && echo 'throw 1' > node_modules/pkg/index.js"))
        e.script(finishTurn())
        let r = await run(f, e, verify: "true", id: "v-dep")
        #expect(r.patch == nil)
        #expect(r.verify.status == .verifiedModifiedTests && r.verify.touchedSensitive == ["ignored:node_modules/ (new)"], "\(r.verify)")

        // Pre-existing dir (tracked in the base commit) left alone: still verified.
        let g = try makeFixture(); defer { g.remove() }
        try commit(g, ["node_modules/pkg/index.js": "ok\n", "node_modules/pkg/package.json.txt": "{}\n"])
        let e2 = FakeEngine(); e2.script(editTurn()); e2.script(finishTurn())
        let r2 = await run(g, e2, verify: "grep -q two *.txt", id: "v-dep2")
        #expect(r2.verify.status == .verified && r2.verify.touchedSensitive.isEmpty, "\(r2.verify)")

        // A new entry inside the pre-existing dir changes the top-two-level count.
        let e3 = FakeEngine(); e3.script(bash("echo evil > node_modules/pkg/extra.js")); e3.script(finishTurn())
        let r3 = await run(g, e3, verify: "true", id: "v-dep3")
        #expect(r3.verify.status == .verifiedModifiedTests && r3.verify.touchedSensitive == ["ignored:node_modules/ (entries changed)"], "\(r3.verify)")
    }

    @Test func workspaceScanIsSymlinkSafeAndBounded() throws {
        let base = NSTemporaryDirectory() + "ws-\(UUID().uuidString)"
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: base) }
        try fm.createDirectory(atPath: base + "/root/a/__pycache__", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/outside/__pycache__", withIntermediateDirectories: true)
        try "keep".write(toFile: base + "/outside/__pycache__/keep.pyc", atomically: true, encoding: .utf8)
        try "x".write(toFile: base + "/root/a/__pycache__/x.pyc", atomically: true, encoding: .utf8)
        // A symlink named like a cache, and a symlinked dir that contains one: neither is followed.
        try fm.createSymbolicLink(atPath: base + "/root/__pycache__", withDestinationPath: base + "/outside/__pycache__")
        try fm.createSymbolicLink(atPath: base + "/root/link", withDestinationPath: base + "/outside")
        // Unreadable dir and a node_modules (not descended into).
        try fm.createDirectory(atPath: base + "/root/b/__pycache__/deep", withIntermediateDirectories: true)
        chmod(base + "/root/b/__pycache__/deep", 0o000)
        try fm.createDirectory(atPath: base + "/root/node_modules/p/__pycache__", withIntermediateDirectories: true)
        let r = WorkspaceScan.purgeCaches(root: base + "/root")
        #expect(r.complete && r.removed == 2)
        #expect(!fm.fileExists(atPath: base + "/root/a/__pycache__") && !fm.fileExists(atPath: base + "/root/b/__pycache__"))
        #expect(fm.fileExists(atPath: base + "/outside/__pycache__/keep.pyc"), "symlink target must survive")
        #expect(fm.fileExists(atPath: base + "/root/node_modules/p/__pycache__"))
        let snap = WorkspaceScan.dependencySnapshot(root: base + "/root")
        #expect(snap.counts == ["node_modules": 2] && !snap.truncated)
        var big = snap; big.truncated = true
        #expect(WorkspaceScan.dependencyChanges(before: snap, after: big).first?.hasPrefix("unverifiable:") == true)
        #expect(WorkspaceScan.dependencyChanges(before: snap, after: snap).isEmpty)
    }

    @Test func gitConfigLikeFilesAreSensitive() {
        for p in [".gitignore", "sub/.gitattributes", ".gitmodules", ".npmrc", ".env", ".env.local", "app/.env.test"] {
            #expect(HarnessRunner.isSensitive(p), Comment(rawValue: p))
        }
    }
}
