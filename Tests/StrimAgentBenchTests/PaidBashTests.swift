import Foundation
import Testing
@testable import StrimAgentBench

/// Paid arms (P, M) get a scoped Bash inside the per-run sandbox profile. Real commands run under the real profile;
/// no model, no client, no network.
@Suite struct PaidBashTests {
    let claudeBin = NSHomeDirectory() + "/.local/bin/claude"

    struct Fixture { var profile: String; var work: URL; var run: URL; var scratch: URL; var outside: URL; var env: [String: String] }

    func fixture(testPaths: [String] = ["tests"]) -> Fixture {
        let root = tempDir("paidbash")
        let work = root.appendingPathComponent("work"), run = root.appendingPathComponent("run")
        let scratch = root.appendingPathComponent("scratch"), outside = root.appendingPathComponent("other-run")
        for d in [work.appendingPathComponent("tests"), run.appendingPathComponent("tmp"), run.appendingPathComponent("home"), scratch, outside] {
            try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        write(work.appendingPathComponent("tests/hidden_test.txt"), "hidden-expected")
        write(outside.appendingPathComponent("secret.txt"), "another run's data")
        let p = ClaudeSandbox.profile(workdir: work.path, runDir: run.path, net: .anthropic, claudeBin: claudeBin, readOnlyPaths: testPaths)
        var env = PaidBash.clientEnv(from: ["HOME": run.path + "/home", "TMPDIR": run.path + "/tmp", "OPENAI_API_KEY": "leak"])
        env["TMPDIR"] = run.path + "/tmp"
        return Fixture(profile: p, work: work, run: run, scratch: scratch, outside: outside, env: env)
    }

    func sh(_ f: Fixture, _ cmd: String, env: [String: String]? = nil) -> (code: Int32, text: String) {
        Proc.capture(ClaudeSandbox.wrap(["/bin/sh", "-c", cmd], profile: f.profile), cwd: f.work.path, env: env ?? f.env, scratch: f.scratch)
    }

    static var goBin: String? { ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/bin/go"].first { FileManager.default.isExecutableFile(atPath: $0) } }

    func goModule(_ f: Fixture, body: String) {
        write(f.work.appendingPathComponent("go.mod"), "module fix\n\ngo 1.21\n")
        write(f.work.appendingPathComponent("a_test.go"), "package fix\n\nimport (\n\t\"net\"\n\t\"os\"\n\t\"testing\"\n\t\"time\"\n)\n\nvar _ = net.Dial\nvar _ = os.Stat\nvar _ = time.Second\n\n" + body)
    }

    /// The client's Bash can only call `runtests`; the host runs the runner in a no-network, no-credential sandbox.
    @Test func runtestsRunsGoTestEndToEndFromTheClientSandbox() throws {
        guard Self.goBin != nil else { return }
        let f = fixture()
        goModule(f, body: "func TestOK(t *testing.T) {}\n")
        let svc = try #require(RunTestsService(workdir: f.work.path, scratch: f.run.path + "/runtests-scratch"))
        defer { svc.stop() }
        let script = svc.writeScript(dir: f.run.path + "/bin")
        var env = f.env; env["PATH"] = f.run.path + "/bin:" + PaidBash.path
        func rt(_ args: String) -> (code: Int32, text: String) { sh(f, "runtests \(args)", env: env) }
        let ok = rt("go test -count=1 ./...")
        #expect(ok.code == 0 && ok.text.contains("ok"), "\(ok.text)")
        goModule(f, body: "func TestBad(t *testing.T) { t.Fatal(\"boom\") }\n")
        let bad = rt("go test -count=1 ./...")
        #expect(bad.code != 0 && bad.text.contains("boom"))
        // refused requests never run anything
        for args in ["curl http://example.com", "go run main.go", "go test -exec sh ./...", "go test -toolexec=sh ./...", "sh -c id", "swift package plugin x"] {
            #expect(rt(args).code == 64, "\(args)")
        }
        // wrong token
        let wrong = f.run.path + "/bin/wrong"
        try (String(contentsOfFile: script, encoding: .utf8)).replacingOccurrences(of: svc.token, with: "nope").write(toFile: wrong, atomically: true, encoding: .utf8)
        chmod(wrong, 0o700)
        #expect(sh(f, "\(wrong) go version", env: env).code == 77)
        // output cap
        goModule(f, body: "func TestLoud(t *testing.T) { for i := 0; i < 5000; i++ { t.Log(\"line line line line line\", i) }; t.Fatal(\"end\") }\n")
        let loud = rt("go test -count=1 -v ./...")
        #expect(loud.text.count < PaidBash.maxOutputChars + 200 && loud.text.contains("truncated"))
    }

    /// A test program run through runtests cannot read credentials, other runs, hidden files or the network, nor write outside.
    @Test func testProgramUnderRuntestsIsIsolated() throws {
        guard Self.goBin != nil else { return }
        let f = fixture()
        let fm = FileManager.default
        let canary = NSHomeDirectory() + "/.claude-paidbash-canary-\(UUID().uuidString)"   // stands in for the OAuth credential file
        try "oauth-secret".write(toFile: canary, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: canary) }
        #expect((try? String(contentsOfFile: canary, encoding: .utf8)) == "oauth-secret")   // control: the host can read it
        let hidden = f.outside.appendingPathComponent("hidden-tests.txt"); write(hidden, "h")
        let outsideWrite = f.outside.path + "/pwned.txt"
        let (lfd, lport) = listener()
        defer { close(lfd) }
        let marker = f.work.path + "/ran.marker"
        goModule(f, body: """
        func TestIsolated(t *testing.T) {
        \tfor _, p := range []string{"\(canary)", "\(NSHomeDirectory())/.claude/.credentials.json", "\(NSHomeDirectory())/Library/Keychains/login.keychain-db", "\(f.outside.path)/secret.txt", "\(hidden.path)", "\(NSHomeDirectory())/.ssh/known_hosts"} {
        \t\tif b, err := os.ReadFile(p); err == nil && len(b) > 0 { t.Fatalf("read %s", p) }
        \t}
        \tif c, err := net.DialTimeout("tcp", "127.0.0.1:\(lport)", 2*time.Second); err == nil { c.Close(); t.Fatal("loopback dial worked") }
        \tif c, err := net.DialTimeout("tcp", "1.1.1.1:443", 2*time.Second); err == nil { c.Close(); t.Fatal("internet dial worked") }
        \tif err := os.WriteFile("\(outsideWrite)", []byte("x"), 0o644); err == nil { t.Fatal("wrote outside") }
        \tif err := os.WriteFile("\(marker)", []byte("x"), 0o644); err != nil { t.Fatal(err) }
        }

        """)
        let svc = try #require(RunTestsService(workdir: f.work.path, scratch: f.run.path + "/runtests-scratch"))
        defer { svc.stop() }
        svc.writeScript(dir: f.run.path + "/bin")
        var env = f.env; env["PATH"] = f.run.path + "/bin:" + PaidBash.path
        let r = sh(f, "runtests go test -count=1 -run TestIsolated ./...", env: env)
        #expect(r.code == 0, "\(r.text)")
        #expect(fm.fileExists(atPath: marker), "test program did not run")          // control: it ran, in the worktree
        #expect(!fm.fileExists(atPath: outsideWrite))
    }

    @Test func runtestsValidation() {
        #expect(RunTestsService.validate(["go", "test", "./..."]) == nil)
        #expect(RunTestsService.validate(["go", "test", "-run", "X", "-count=1", "./pkg"]) == nil)
        #expect(RunTestsService.validate(["swift", "test", "--filter", "Foo"]) == nil)
        for bad in [["go"], ["go", "run", "x.go"], ["go", "generate"], ["go", "test", "-exec=sh"], ["go", "vet", "-vettool", "/x"], ["swift", "package", "init"],
                    ["swift", "run"], ["swift", "test", "--scratch-path", "/tmp/x"], ["sh", "-c", "id"], ["/usr/bin/curl", "x"], ["go", "test", "-overlay", "o.json"]] {
            #expect(RunTestsService.validate(bad) != nil, "\(bad)")
        }
    }

    @Test func readOnlyInspectionAndWorktreeWritesWork() {
        let f = fixture()
        write(f.work.appendingPathComponent("x.txt"), "needle")
        #expect(sh(f, "cat x.txt && ls . && grep needle x.txt").code == 0)
        #expect(sh(f, "echo edit > x.txt && cat x.txt").code == 0)
    }

    @Test func writesOutsideTheWorktreeAreDenied() {
        let f = fixture()
        #expect(sh(f, "echo no > '\(f.outside.path)/w.txt'").code != 0)
        #expect(!FileManager.default.fileExists(atPath: f.outside.path + "/w.txt"))
        #expect(sh(f, "echo no > '\(NSHomeDirectory())/strim-paidbash-probe-\(UUID().uuidString)'").code != 0)
        #expect(sh(f, "echo no > /tmp/strim-paidbash-probe-\(UUID().uuidString)").code != 0)
        #expect(sh(f, "echo no > '\(f.work.path)/../escape.txt'").code != 0)
    }

    @Test func credentialAndOtherRunReadsAreDenied() {
        let f = fixture()
        let home = NSHomeDirectory()
        #expect(sh(f, "ls '\(home)/.ssh'").code != 0)
        #expect(sh(f, "cat '\(home)/.ssh/id_ed25519'").code != 0)
        #expect(sh(f, "cat '\(home)/.strim/token'").code != 0)
        #expect(sh(f, "ls '\(home)/.aws'").code != 0)
        #expect(sh(f, "ls '\(home)/.claude'").code != 0)
        #expect(sh(f, "ls '\(home)/Library/Keychains'").code != 0)
        // another run's dir (a sibling in the same temp root) and the shared temp areas
        let r = sh(f, "cat '\(f.outside.path)/secret.txt'")
        #expect(r.code != 0 && !r.text.contains("another run"))
        let probe = "/tmp/strim-paidbash-read-\(UUID().uuidString)"
        write(URL(fileURLWithPath: probe), "x")
        defer { try? FileManager.default.removeItem(atPath: probe) }
        #expect(sh(f, "cat \(probe)").code != 0)
    }

    @Test func taskTestFilesCannotBeWrittenButCanBeRead() {
        let f = fixture()
        #expect(sh(f, "cat tests/hidden_test.txt").code == 0)
        #expect(sh(f, "echo tamper > tests/hidden_test.txt").code != 0)
        #expect(sh(f, "rm tests/hidden_test.txt").code != 0)
        #expect(sh(f, "echo new > tests/new_test.txt").code != 0)
        #expect((try? String(contentsOfFile: f.work.path + "/tests/hidden_test.txt", encoding: .utf8)) == "hidden-expected")
        // the local arm's profile is unchanged: no test-path deny
        #expect(!ClaudeSandbox.profile(workdir: f.work.path, runDir: f.run.path, net: .loopback(port: 9), claudeBin: claudeBin).contains("/tests"))
    }

    @Test func harnessRestoresTamperedTestsBeforeGrading() throws {
        let root = tempDir("restore")
        let base = root.appendingPathComponent("base"), work = root.appendingPathComponent("work")
        write(base.appendingPathComponent("tests/t.txt"), "orig")
        write(work.appendingPathComponent("tests/t.txt"), "tampered")
        let spec = TaskSpec(id: "t", taskClass: "test-fix", prompt: "p", verifyCmd: "grep -q orig tests/t.txt", testPaths: ["tests"])
        let o = Verifier.verify(task: spec, base: base, work: work, answer: nil, scratch: root.appendingPathComponent("s"))
        #expect(o.testsTampered && !o.success)
        #expect((try? String(contentsOf: work.appendingPathComponent("tests/t.txt"), encoding: .utf8)) == "orig")
    }

    @Test func environmentIsCleared() {
        let host = ["PATH": "/Users/x/bin:/usr/bin", "HOME": "/h", "OPENAI_API_KEY": "k", "AWS_SECRET_ACCESS_KEY": "s", "GITHUB_TOKEN": "g",
                    "SSH_AUTH_SOCK": "/s", "STRIM_MCP_TOKEN": "m", "TMPDIR": "/t", "USER": "u"]
        let e = PaidBash.clientEnv(from: host)
        #expect(e["PATH"] == PaidBash.path)
        for k in ["OPENAI_API_KEY", "AWS_SECRET_ACCESS_KEY", "GITHUB_TOKEN", "SSH_AUTH_SOCK"] { #expect(e[k] == nil, "\(k)") }
        #expect(e["HOME"] == "/h" && e["USER"] == "u" && e["TMPDIR"] == "/t" && e["STRIM_MCP_TOKEN"] == "m")
        #expect(e["BASH_DEFAULT_TIMEOUT_MS"] == "120000" && e["BASH_MAX_TIMEOUT_MS"] == "300000" && e["BASH_MAX_OUTPUT_LENGTH"] == "20000")
        #expect(e["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == "1")
        // and a child under the profile really sees only that
        let f = fixture()
        let r = sh(f, "/usr/bin/env", env: PaidBash.clientEnv(from: ["OPENAI_API_KEY": "leak", "HOME": f.run.path + "/home"]))
        #expect(r.code == 0 && !r.text.contains("leak") && !r.text.contains("OPENAI") && r.text.contains("PATH=\(PaidBash.path)"))
    }

    @Test func bashRulesAdmitOnlyReadOnlyToolsAndRuntests() {
        // Documented limit: the paid profile keeps the client's egress; code execution is therefore kept out of Bash entirely.
        #expect(ClaudeSandbox.profile(workdir: "/w", runDir: "/r", net: .anthropic, claudeBin: claudeBin).contains("(allow network-outbound (remote ip))"))
        let task = TaskSpec(id: "x", taskClass: "test-fix", prompt: "p", verifyCmd: "go test -count=1 ./...")
        let rules = PaidBash.allowedRules(for: task, language: "go")
        for ok in ["runtests go test ./...", "runtests swift test --filter X", "cat a.go", "ls -la", "grep -rn foo .", "head -20 a.go", "cat a | head -3", "diff a b"] {
            #expect(PaidBash.strictPermits(ok, rules: rules), "\(ok)")
        }
        for bad in ["go test ./...", "swift test", "rg foo", "rg --pre 'sh -c id' x .", "rg --pre=./x foo", "rg --pre-glob '*' foo", "curl http://x", "wget http://x", "go run main.go",
                    "python3 -c 1", "sed -i s/a/b/ f", "awk 'BEGIN{system(\"id\")}'", "find . -exec sh -c id ;", "ssh h", "nc h 1", "rm -rf .", "cp a b", "env", "git diff --ext-diff", "git log --output=x", "git status", "git -c core.fsmonitor=x status",
                    // shell metacharacters and indirection
                    "cat a; curl http://x", "cat a && go test ./...", "cat a || curl x", "cat a | sh", "cat `curl x`", "cat $(curl x)", "cat a & curl x", "cat a\ncurl x",
                    "cat <(curl x)", "FOO=1 curl x", "FOO=1 go test ./...", "/usr/bin/curl x", "/bin/sh -c id", "env cat a", "command curl x", "exec go test", "cat ${HOME}/.ssh/id_rsa",
                    "runtests go test ./... ; curl x", "runtests go test ./... && go test ./...", "bash -c id", "sh runtests"] {
            #expect(!PaidBash.strictPermits(bad, rules: rules), "\(bad)")
        }
        // the explicit deny list covers the direct runners and exec-capable readers as well (deny beats allow)
        for d in ["Bash(go:*)", "Bash(swift:*)", "Bash(rg:*)", "Bash(git:*)", "Bash(env:*)", "Bash(bash:*)", "Bash(sh:*)"] { #expect(PaidBash.extraDenied.contains(d), "\(d)") }
        // no bare Bash and no answer-task runner
        let qa = TaskSpec(id: "q", taskClass: "qa", prompt: "p")
        #expect(!PaidBash.allowedRules(for: qa, language: "go").contains("Bash(runtests:*)"))
    }

    @Test func paidArgvHasBashRulesDeniesAndTheTool() {
        let task = TaskSpec(id: "x", taskClass: "test-fix", prompt: "p", verifyCmd: "swift test --filter Foo")
        for mode in [ClaudeArm.Mode.paid, .paidWithMCP(ServerEndpoint(port: 8299, token: "t", modelId: "m"))] {
            let arm = ClaudeArm(mode: mode, claudeBin: "/bin/claude", model: "sonnet")
            let argv = arm.buildArgv(prompt: "p", mcpConfig: nil, repo: "/r", task: task, language: "swift", sandboxProfile: nil)
            func section(_ flag: String) -> [String] {
                guard let i = argv.firstIndex(of: flag) else { return [] }
                return Array(argv[(i + 1)...].prefix { !$0.hasPrefix("--") })
            }
            #expect(section("--tools").flatMap { $0.split(separator: ",").map(String.init) }.contains("Bash"))
            let allowed = section("--allowedTools"), denied = section("--disallowedTools")
            #expect(allowed.contains("Bash(runtests:*)") && allowed.contains("Bash(cat:*)"))
            #expect(!allowed.contains("Bash") && !allowed.contains("Bash(swift:*)") && !allowed.contains("Bash(swift test:*)") && !allowed.contains("Bash(sed:*)") && !allowed.contains("Bash(rg:*)"))
            #expect(!denied.contains("Bash"))
            for d in ["Bash(curl:*)", "Bash(wget:*)", "Bash(ssh:*)", "Bash(rm -rf:*)", "Bash(git push:*)", "Bash(env:*)", "Bash(swift:*)", "Bash(go:*)", "Read(~/.ssh/**)", "Read(~/.strim/**)"] {
                #expect(denied.contains(d), "\(d)")
            }
            #expect(argv.contains { $0.contains("runtests") })   // system prompt tells the model how to run tests
        }
    }

    @Test func preflightPassesOnThisHost() {
        let scratch = tempDir("pre")
        #expect(SelfCheck.checkPaidBash(scratch: scratch, claudeBin: claudeBin) == nil)
    }
}
