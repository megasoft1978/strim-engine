import Foundation
import Testing
@testable import StrimAgentBench

func listener() -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    listen(fd, 8)
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return (fd, UInt16(bigEndian: addr.sin_port))
}

@Suite struct SandboxTests {
    let claudeBin = NSHomeDirectory() + "/.local/bin/claude"

    func run(_ cmd: String, profile: String, cwd: URL, scratch: URL) -> Int32 {
        let argv = ClaudeSandbox.wrap(["/bin/sh", "-c", cmd], profile: profile)
        return Proc.capture(argv, cwd: cwd.path, scratch: scratch).code
    }

    func setup(net: ClaudeSandbox.Net) -> (profile: String, work: URL, runDir: URL, scratch: URL) {
        let root = tempDir("sbx")
        let work = root.appendingPathComponent("work"), runDir = root.appendingPathComponent("run"), scratch = root.appendingPathComponent("scratch")
        for d in [work, runDir, scratch, runDir.appendingPathComponent("tmp")] { try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        return (ClaudeSandbox.profile(workdir: work.path, runDir: runDir.path, net: net, claudeBin: claudeBin), work, runDir, scratch)
    }

    @Test func argvIsWrappedWithSandboxExec() {
        // Local arm (loopback-only sandbox): Bash stays, but only as the prefix allowlist.
        let arm = ClaudeArm(mode: .local(ServerEndpoint(port: 8299, token: "t", modelId: "m")), claudeBin: "/bin/claude", model: "sonnet")
        let task = TaskSpec(id: "x", taskClass: "test-fix", prompt: "p", verifyCmd: "go test -count=1 ./...")
        let prof = "(version 1)(allow default)"
        let argv = arm.buildArgv(prompt: "p", mcpConfig: nil, repo: "/r", task: task, sandboxProfile: prof)
        #expect(Array(argv.prefix(3)) == ["/usr/bin/sandbox-exec", "-p", prof])
        #expect(argv[3] == "/bin/claude")
        #expect(!argv.contains("Bash"))  // bare Bash is not in the allow list
        #expect(argv.contains("Bash(go test:*)") && argv.contains("Bash(git apply:*)"))
        #expect(argv.contains("Bash(rm -rf:*)") && argv.contains("Bash(git push:*)") && argv.contains("Bash(sudo:*)"))
    }

    /// M2 (security review 2026-10-28), superseded by owner decision: paid arms get a scoped Bash (see PaidBashTests), never a bare one.
    @Test func paidArmsHaveOnlyScopedBash() {
        let task = TaskSpec(id: "x", taskClass: "test-fix", prompt: "p", verifyCmd: "go test -count=1 ./...")
        for mode in [ClaudeArm.Mode.paid, .paidWithMCP(ServerEndpoint(port: 8299, token: "t", modelId: "m"))] {
            let arm = ClaudeArm(mode: mode, claudeBin: "/bin/claude", model: "sonnet")
            let argv = arm.buildArgv(prompt: "p", mcpConfig: "/x/mcp.json", repo: "/r", task: task, language: "go", sandboxProfile: nil)
            func section(_ flag: String) -> [String] {
                guard let i = argv.firstIndex(of: flag) else { return [] }
                return Array(argv[(i + 1)...].prefix { !$0.hasPrefix("--") })
            }
            #expect(!section("--allowedTools").contains("Bash"), "\(section("--allowedTools"))")
            #expect(section("--allowedTools").contains("Bash(runtests:*)"))
            for runner in ["sed", "awk", "find", "cp", "mv", "go", "swift", "rg", "curl"] {
                #expect(!section("--allowedTools").contains { $0.hasPrefix("Bash(\(runner)") }, "\(runner)")
            }
        }
    }

    /// M3: the paid MCP arm's config file must not contain the bearer token.
    @Test func paidMcpConfigReferencesTokenThroughEnvOnly() throws {
        let data = try ClaudeArm.mcpConfigJSON(baseURL: "http://127.0.0.1:8299")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Bearer ${STRIM_MCP_TOKEN}"), "\(text)")
        #expect(!text.contains("tok-SECRET"))
    }

    @Test func prefixesDerivedFromSampleTask() throws {
        let tasks = TaskLoader.load(root: repoRoot().appendingPathComponent("bench/agenttasks"))
        let tf = try #require(tasks.first { $0.spec.taskClass == "test-fix" && ["go", "swift"].contains($0.language ?? "") })
        let allowed = BashAllow.allowedPrefixes(for: tf.spec, language: tf.language)
        #expect(allowed.contains("Bash(go:*)") || allowed.contains("Bash(swift:*)"))
        let qa = try #require(tasks.first { $0.spec.taskClass == "repo-qa" })
        #expect(!BashAllow.allowedPrefixes(for: qa.spec, language: "go").contains("Bash(go:*)"))
        // verify commands can never widen into dangerous binaries
        #expect(BashAllow.verifyBinaries("curl http://x && rm -rf / ; sudo ls ; go test ./...") == ["go"])
        #expect(BashAllow.verifyBinaries("FOO=1 BAR=2 cargo test && ! grep -r x .") == ["cargo", "grep"])
    }

    @Test func allowlistAdmitsVerifyForms() {
        let t = TaskSpec(id: "x", taskClass: "test-fix", prompt: "p", verifyCmd: "GOFLAGS=-mod=mod go test -count=1 ./... && ! grep -rn old .")
        let rules = BashAllow.allowedPrefixes(for: t, language: "go")
        for ok in ["GOFLAGS=-mod=mod go test -count=1 ./... && ! grep -rn old .", "go test ./... > out.txt 2>&1",
                   "swift test 2>&1", "git diff --stat"] {
            #expect(BashAllow.permits(ok, rules: rules + BashAllow.allowedPrefixes(for: TaskSpec(id: "s", taskClass: "test-fix", prompt: "p", verifyCmd: "swift test"), language: "swift")), "\(ok)")
        }
        for bad in ["curl http://x", "rm -rf /", "go test ./... && curl http://x", "/usr/bin/ruby -e 1"] { #expect(!BashAllow.permits(bad, rules: rules), "\(bad)") }
        #expect(!rules.contains("Bash"))
    }

    @Test func profileDeniesSecretsAndOutsideWrites() throws {
        let s = setup(net: .loopback(port: 9))
        // secret-like file in the real home
        let secret = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agentbench-probe-\(UUID().uuidString)")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }
        #expect(run("cat '\(secret.path)' >/dev/null", profile: "(version 1)(allow default)", cwd: s.work, scratch: s.scratch) == 0)  // control
        #expect(run("cat '\(secret.path)' >/dev/null", profile: s.profile, cwd: s.work, scratch: s.scratch) != 0)
        #expect(run("ls ~/.ssh >/dev/null 2>&1; ls ~/.strim >/dev/null 2>&1; ls ~/.claude >/dev/null 2>&1", profile: s.profile, cwd: s.work, scratch: s.scratch) != 0)
        // writes: workdir and run dir yes; elsewhere no
        #expect(run("echo x > '\(s.work.path)/ok.txt'", profile: s.profile, cwd: s.work, scratch: s.scratch) == 0)
        #expect(run("echo x > '\(s.runDir.path)/tmp/ok.txt'", profile: s.profile, cwd: s.work, scratch: s.scratch) == 0)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentbench-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(run("echo x > '\(outside.path)'", profile: s.profile, cwd: s.work, scratch: s.scratch) != 0)
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(run("echo x > '\(NSHomeDirectory())/.agentbench-write-probe'", profile: s.profile, cwd: s.work, scratch: s.scratch) != 0)
        #expect(!FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.agentbench-write-probe"))
    }

    @Test func armCIsLoopbackOnlyToTheStrimPort() throws {
        let allowed = listener(), other = listener()
        defer { close(allowed.fd); close(other.fd) }
        let c = setup(net: .loopback(port: allowed.port))
        let connect = { (port: UInt16, profile: String) in
            self.run("/usr/bin/nc -z -w 2 127.0.0.1 \(port)", profile: profile, cwd: c.work, scratch: c.scratch)
        }
        #expect(connect(allowed.port, "(version 1)(allow default)") == 0)  // control: nc works unsandboxed
        #expect(connect(allowed.port, c.profile) == 0)
        #expect(connect(other.port, c.profile) != 0)  // loopback, but not the strim port
        #expect(run("/usr/bin/nc -z -w 2 93.184.216.34 80", profile: c.profile, cwd: c.work, scratch: c.scratch) != 0)
        // an unrelated unix socket (outside the workdir) is not reachable from arm C
        let sock = "/tmp/abs-\(getpid()).sock"  // short: sun_path is 104 bytes
        unlink(sock)
        defer { unlink(sock) }
        let ufd = socket(AF_UNIX, SOCK_STREAM, 0)
        var ua = sockaddr_un()
        ua.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &ua.sun_path) { buf in
            for (i, b) in sock.utf8.enumerated() { buf[i] = b }
        }
        let brc = withUnsafePointer(to: &ua) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(ufd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(brc == 0)
        listen(ufd, 4)
        defer { close(ufd) }
        #expect(run("/usr/bin/nc -U -w 2 '\(sock)'", profile: "(version 1)(allow default)", cwd: c.work, scratch: c.scratch) == 0)  // control
        #expect(run("/usr/bin/nc -U -w 2 '\(sock)'", profile: c.profile, cwd: c.work, scratch: c.scratch) != 0)
        #expect(!c.profile.contains("unix-socket"))
        // P/M profiles open IP networking only
        let p = setup(net: .anthropic)
        #expect(connect(other.port, p.profile) == 0)
        #expect(!p.profile.contains("unix-socket"))
        #expect(run("/usr/bin/nc -U -w 2 '\(sock)'", profile: p.profile, cwd: p.work, scratch: p.scratch) != 0)
    }

    @Test func claudeBinaryRunsInsideTheSandbox() throws {
        guard FileManager.default.isExecutableFile(atPath: claudeBin) else { return }
        for net in [ClaudeSandbox.Net.loopback(port: 8231), .anthropic] {
            let s = setup(net: net)
            let env = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": s.runDir.path,
                       "TMPDIR": s.runDir.path + "/tmp", "CLAUDE_CONFIG_DIR": s.runDir.path + "/cfg"]
            let out = s.scratch.appendingPathComponent("v.out").path
            let r = try Proc.run(argv: ClaudeSandbox.wrap([claudeBin, "--version"], profile: s.profile), env: env, cwd: s.work.path,
                                 stdout: out, stderr: out, timeout: 60)
            let text = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
            #expect(r.exitCode == 0, "\(text.prefix(300))")
            #expect(text.contains("Claude Code") || text.first?.isNumber == true)
        }
    }
}
