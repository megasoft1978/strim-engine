import Foundation
import Testing
@testable import StrimAgentBench

@Suite struct VerifierSandboxTests {
    /// Runs `cmd` as a verify_cmd in a fresh workdir; `home` is a fake HOME with a planted token.
    func verify(_ cmd: String, sandboxExec: String = Verifier.sandboxExec) throws -> (VerifyOutcome, URL, URL) {
        let d = tempDir("vsb")
        let home = d.appendingPathComponent("fakehome")
        write(home.appendingPathComponent(".strim/token"), "SECRET")
        write(home.appendingPathComponent(".ssh/id_rsa"), "KEY")
        let base = d.appendingPathComponent("base"), work = d.appendingPathComponent("work")
        write(base.appendingPathComponent("src.txt"), "x\n"); write(work.appendingPathComponent("src.txt"), "x\n")
        let task = TaskSpec(id: "v", taskClass: "test-fix", prompt: "p", verifyCmd: cmd.replacingOccurrences(of: "$HOME_", with: home.path))
        let out = Verifier.verify(task: task, base: base, work: work, answer: nil, scratch: d.appendingPathComponent("scratch"),
                                  home: home.path, sandboxExecPath: sandboxExec)
        return (out, work, d)
    }

    @Test func cannotReadHomeSecrets() throws {
        let (o, _, _) = try verify("! cat '$HOME_/.strim/token' 2>/dev/null && ! cat '$HOME_/.ssh/id_rsa' 2>/dev/null && ! ls '$HOME_/.strim' 2>/dev/null && test -f src.txt")
        #expect(o.success, "\(o.note)")
    }

    /// The `! cat` pattern passes if `cat` fails for any reason. This one proves `cat` ran, read a normal file fine,
    /// and was refused (not "No such file") on the planted secrets, which do exist outside the sandbox.
    @Test func catRanAndWasDeniedOnExistingSecrets() throws {
        let (o, work, d) = try verify("cat src.txt > got.txt; cat '$HOME_/.strim/token' > leak.txt 2> err.txt; echo $? > rc.txt; "
                                      + "test \"$(cat rc.txt)\" != 0")
        #expect(o.success, "\(o.note)")
        func read(_ n: String) -> String { (try? String(contentsOf: work.appendingPathComponent(n), encoding: .utf8)) ?? "<missing>" }
        #expect(read("got.txt") == "x\n", "cat of a workdir file must work: \(read("got.txt"))")
        #expect(read("leak.txt") == "" && !read("leak.txt").contains("SECRET"))
        let err = read("err.txt")
        #expect(err.contains("cat:") && err.contains("not permitted") && !err.contains("No such file"), "err: \(err)")
        #expect(read("rc.txt").trimmingCharacters(in: .whitespacesAndNewlines) != "0")
        let secret = d.appendingPathComponent("fakehome/.strim/token")
        #expect((try? String(contentsOf: secret, encoding: .utf8)) == "SECRET", "the planted secret must exist")
    }

    @Test func cannotWriteOutsideWorkdir() throws {
        let outside = "/tmp/agentbench-vout-\(UUID().uuidString)"
        defer { unlink(outside) }
        let (o, work, d) = try verify("! sh -c 'echo x > \(outside)' 2>/dev/null && ! sh -c 'echo x > $HOME_/planted' 2>/dev/null && echo ok > inside.txt")
        #expect(o.success, "\(o.note)")
        #expect(!FileManager.default.fileExists(atPath: outside))
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("fakehome/planted").path))
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("inside.txt").path))
    }

    @Test func cannotConnectToLoopback() throws {
        let l = listener()
        defer { close(l.fd) }
        let (o, _, _) = try verify("! /usr/bin/nc -z -w 2 127.0.0.1 \(l.port) 2>/dev/null && test -f src.txt")
        #expect(o.success, "\(o.note)")
        // control: the listener is reachable without a sandbox
        let c = Proc.capture(["/usr/bin/nc", "-z", "-w", "2", "127.0.0.1", String(l.port)], cwd: "/tmp", scratch: tempDir("c"))
        #expect(c.code == 0)
    }

    @Test func normalToolsStillWork() throws {
        let (o, _, _) = try verify("awk 'BEGIN{exit 0}' && test -f src.txt && git --version >/dev/null")
        #expect(o.success, "\(o.note)")
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/go") {
            let (g, _, _) = try verify("PATH=/opt/homebrew/bin:$PATH go version")
            #expect(g.success, "\(g.note)")
        }
    }

    @Test func failsClosedWithoutSandbox() throws {
        let marker = "/tmp/agentbench-marker-\(UUID().uuidString)"
        defer { unlink(marker) }
        for bad in ["/nonexistent/sandbox-exec", "/usr/bin/false"] {
            let (o, _, _) = try verify("touch \(marker)", sandboxExec: bad)
            #expect(o.infra && !o.success, "\(bad)")
            #expect(!FileManager.default.fileExists(atPath: marker))
        }
    }

    @Test func runnerTurnsSandboxFailureIntoInfraRow() throws {
        let d = tempDir("vinfra")
        let task = makeTask(d)
        let cfg = RunnerConfig(arms: [.H], ledgerURL: d.appendingPathComponent("l.jsonl"), eventsURL: d.appendingPathComponent("e"),
                               outDir: d.appendingPathComponent("out"), workRoot: d.appendingPathComponent("work"))
        // sanity: with the real sandbox the normal path still produces a non-infra row
        let ex = ScriptExecutor { _ in ArmOutcome() }
        _ = try BenchRunner(config: cfg, tasks: [task], executors: [.H: ex]).run()
        #expect(Ledger(url: cfg.ledgerURL).read().first?.infraError == false)
    }
}

@Suite struct FileSafetyTests {
    @Test func lockRefusesSymlinkAndCreates0600() throws {
        let d = tempDir("lock")
        let real = d.appendingPathComponent("real"), link = d.appendingPathComponent("link.lock")
        write(real, "")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: FileLockError.self) { try FileLock.acquire(path: link.path, timeout: 0) }
        let p = d.appendingPathComponent("new.lock").path
        let l = try FileLock.acquire(path: p, timeout: 0)
        var st = stat(); stat(p, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(throws: FileLockError.self) { try FileLock.acquire(path: p, timeout: 0) }  // contended
        l.release()
        _ = try FileLock.acquire(path: p, timeout: 0)
        // a directory is not a lock file
        #expect(throws: FileLockError.self) { try FileLock.acquire(path: d.path, timeout: 0) }
    }

    @Test func lockFdIsCloseOnExec() throws {
        let p = tempDir("cx").appendingPathComponent("l").path
        let fd = try openSafe(p, flags: O_RDWR | O_CREAT)
        defer { close(fd) }
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test func ledgerRefusesSymlink() throws {
        let d = tempDir("lsym")
        let victim = d.appendingPathComponent("victim.txt")
        write(victim, "precious")
        let link = d.appendingPathComponent("ledger.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        #expect(throws: LedgerError.self) { try Ledger(url: link).append(row("a", "c", .H)) }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "precious")
        let ok = Ledger(url: d.appendingPathComponent("fresh.jsonl"))
        try ok.append(row("a", "c", .H))
        var st = stat(); stat(ok.url.path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
    }

    @Test func procLogThroughSymlinkDoesNotTruncateTarget() throws {
        let d = tempDir("plog")
        let victim = d.appendingPathComponent("victim.txt")
        write(victim, "precious")
        let log = d.appendingPathComponent("out.log")
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: victim)
        let r = try Proc.run(argv: ["/bin/echo", "hi"], env: [:], cwd: d.path, stdout: log.path, stderr: log.path, timeout: 10)
        #expect(r.exitCode == 0)
        #expect(try String(contentsOf: victim, encoding: .utf8) == "precious")
        #expect(try String(contentsOf: log, encoding: .utf8) == "hi\n")  // replaced by a fresh regular file
    }

    @Test func signalNeverHitsAReusedPid() throws {
        // forged identity for our own pid: must not signal (the test process would die)
        let h = ProcHandle(pid: getpid(), forgedStart: 1)
        #expect(!h.identityMatches())
        #expect(!h.signalGroup(SIGKILL))
        // a reaped child is never signalled
        let d = tempDir("reap")
        let c = try Proc.start(argv: ["/usr/bin/true"], env: [:], cwd: d.path, stdout: d.appendingPathComponent("o").path, stderr: d.appendingPathComponent("e").path)
        while c.poll() == nil { usleep(10_000) }
        #expect(!c.signalGroup(SIGKILL))
        // live child: identity matches and terminate works
        let l = try Proc.start(argv: ["/bin/sleep", "30"], env: [:], cwd: d.path, stdout: d.appendingPathComponent("o2").path, stderr: d.appendingPathComponent("e2").path)
        #expect(l.identityMatches())
        #expect(l.terminate(grace: 2) != 0)
    }

    @Test func stragglersKilledBeforeReap() throws {
        let d = tempDir("strag")
        let pidFile = d.appendingPathComponent("pid").path
        let r = try Proc.run(argv: ["/bin/sh", "-c", "sleep 60 & echo $! > '\(pidFile)'"], env: ["PATH": "/bin:/usr/bin"], cwd: d.path,
                             stdout: d.appendingPathComponent("o").path, stderr: d.appendingPathComponent("e").path, timeout: 10)
        #expect(r.exitCode == 0)
        let pid = Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        var gone = false
        for _ in 0..<60 where !gone { gone = kill(pid, 0) != 0; if !gone { usleep(50_000) } }  // zombie until launchd reaps it
        #expect(gone)  // the leftover sleep was killed with its group
    }
}

@Suite struct ConfusedDeputyTests {
    @Test func verifyCannotRelinkOutputToASecret() throws {
        let d = tempDir("deputy")
        let home = d.appendingPathComponent("fakehome")
        write(home.appendingPathComponent(".strim/control-token"), "TOPSECRETXYZ")
        let base = d.appendingPathComponent("base"), work = d.appendingPathComponent("work")
        write(base.appendingPathComponent("a.txt"), "x"); write(work.appendingPathComponent("a.txt"), "x")
        let secret = home.appendingPathComponent(".strim/control-token").path
        let cmd = "ln -sf '\(secret)' \"$ANSWER_FILE\"; ln -sf '\(secret)' \"$(dirname \"$ANSWER_FILE\")/verify.out\"; ln -sf '\(secret)' ./answer.txt; echo visible-output; exit 1"
        var spec = TaskSpec(id: "q", taskClass: "repo-qa", prompt: "?", verifyCmd: cmd, noEdit: false)
        spec.expectedAnswer = nil
        let scratch = d.appendingPathComponent("scratch")
        let o = Verifier.verify(task: spec, base: base, work: work, answer: "an answer", scratch: scratch, home: home.path)
        #expect(!o.success)
        #expect(o.note.contains("visible-output"))
        #expect(!o.note.contains("TOPSECRETXYZ"))
        var r = row("q", "repo-qa", .H, ok: false); r.verifyNote = o.note
        let json = String(decoding: try JSONL.encoder().encode(r), as: UTF8.self)
        #expect(!json.contains("TOPSECRETXYZ"))
        #expect(!Reporter.render(Reporter.build([r])).contains("TOPSECRETXYZ"))
    }

    @Test func outputTailStillCaptured() throws {
        let d = tempDir("tail")
        let base = d.appendingPathComponent("base"), work = d.appendingPathComponent("work")
        write(base.appendingPathComponent("a.txt"), "x"); write(work.appendingPathComponent("a.txt"), "x")
        let spec = TaskSpec(id: "t", taskClass: "test-fix", prompt: "?", verifyCmd: "awk 'BEGIN{for(i=0;i<500;i++) printf \"A\"; print \"END-MARK\"}'; echo err-line >&2; exit 3")
        let o = Verifier.verify(task: spec, base: base, work: work, answer: nil, scratch: d.appendingPathComponent("s"))
        #expect(o.verifyExit == 3)
        #expect(o.note.contains("END-MARK") && o.note.contains("err-line"))
        #expect(o.note.count < 300)
    }

    @Test func claudeArmOutputNotReadableThroughRelinkedPaths() throws {
        let d = tempDir("carm")
        let home = d.appendingPathComponent("fakehome")
        write(home.appendingPathComponent("secret.txt"), "TOPSECRETXYZ")
        let secret = home.appendingPathComponent("secret.txt").path
        let work = d.appendingPathComponent("work"), run = d.appendingPathComponent("run")
        for u in [work, run] { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
        // fake claude: tries to relink the host's log paths to a secret, then prints a result event
        let fake = d.appendingPathComponent("fakeclaude")
        write(fake, """
        #!/bin/sh
        ln -sf '\(secret)' '\(run.path)/stream.jsonl' 2>/dev/null
        ln -sf '\(secret)' '\(run.path)/stderr.txt' 2>/dev/null
        echo '{"type":"result","is_error":false,"num_turns":1,"total_cost_usd":0.5,"result":"all done","usage":{"input_tokens":1,"output_tokens":2}}'
        echo 'oops' >&2
        """)
        chmod(fake.path, 0o755)
        let spec = TaskSpec(id: "c", taskClass: "test-fix", prompt: "p", verifyCmd: "true")
        let ctx = RunContext(task: LoadedTask(spec: spec, dir: d), arm: .P, rep: 1, workdir: work, runDir: run, timeout: 60, seed: 1)
        let o = ClaudeArm(mode: .paid, claudeBin: fake.path, model: "sonnet").execute(ctx)
        #expect(o.parentCostUsd == 0.5)
        #expect(o.claimedDone)
        for name in ["stream.jsonl", "stderr.txt"] {
            let t = (try? String(contentsOf: run.appendingPathComponent(name), encoding: .utf8)) ?? ""
            #expect(!t.contains("TOPSECRETXYZ"))
        }
        #expect((try? String(contentsOf: run.appendingPathComponent("stream.jsonl"), encoding: .utf8))?.contains("all done") == true)
    }
}
