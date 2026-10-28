import Foundation
import StrimAgentBench
import Testing
@testable import StrimSoak

@Suite struct SoakClientsTests {
    @Test func claudeArgvHasNoBashAndNoPrefixAllowlist() {
        let argv = SoakArgvs.claudeArgv(prompt: "P", modelId: "qwen38-4bit")
        #expect(argv.starts(with: ["-p", "P", "--model", "qwen38-4bit"]))
        let tools = argv[(argv.firstIndex(of: "--tools") ?? 0) + 1]
        #expect(tools == "Read,Edit,Write,Glob,Grep")
        let allowed = argv[(argv.firstIndex(of: "--allowedTools") ?? 0) + 1 ..< (argv.firstIndex(of: "--disallowedTools") ?? 0)]
        #expect(!allowed.contains { $0.hasPrefix("Bash") })
        #expect(argv.contains("Bash") && argv.contains("Read(~/**)"))
        #expect(!argv.contains { $0.lowercased().contains("python") || $0.contains("git") })
    }

    @Test func clientEnvIsExplicitAndInheritsNothing() {
        setenv("ANTHROPIC_API_KEY", "host-secret", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        let fg = SoakArgvs.claudeEnv(port: 8203, configDir: "/iso/claude", token: "tok-1", background: false, scratch: "/s")
        #expect(fg["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:8203")
        #expect(fg["ANTHROPIC_AUTH_TOKEN"] == "tok-1")
        #expect(fg["CLAUDE_CONFIG_DIR"] == "/iso/claude")
        #expect(fg["HOME"] == "/s/home" && fg["TMPDIR"] == "/s/tmp")
        #expect(fg["ANTHROPIC_CUSTOM_HEADERS"] == nil && fg["ANTHROPIC_API_KEY"] == nil)
        #expect(Set(fg.keys).isSubset(of: ["PATH", "HOME", "TMPDIR", "LANG", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN",
                                           "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
                                           "DISABLE_TELEMETRY", "DISABLE_AUTOUPDATER"]))
        let bg = SoakArgvs.claudeEnv(port: 8203, configDir: "/iso/claude", token: "tok-1", background: true, scratch: "/s")
        #expect(bg["ANTHROPIC_CUSTOM_HEADERS"] == "x-strim-priority: background")
    }

    @Test func codexArgvDisablesShellAndPassesTokenByEnvOnly() {
        let argv = SoakArgvs.codexArgv(port: 8203, repo: "/r", prompt: "P", modelId: "m", background: true)
        #expect(argv.contains("workspace-write"))
        #expect(argv.contains("features.shell_tool=false") && argv.contains("features.unified_exec=false"))
        #expect(argv.contains { $0.contains("base_url=\"http://127.0.0.1:8203/v1\"") })
        #expect(argv.contains { $0.contains("http_headers={\"x-strim-priority\"=\"background\"}") })
        #expect(argv.last == "P")
        let fg = SoakArgvs.codexArgv(port: 8203, repo: "/r", prompt: "P", modelId: "m", background: false)
        #expect(!fg.contains { $0.contains("http_headers") })
        let env = SoakArgvs.codexEnv(codexHome: "/iso/codex", token: "tok-2", scratch: "/s")
        #expect(env["CODEX_HOME"] == "/iso/codex" && env[SoakArgvs.tokenEnv] == "tok-2" && env["HOME"] == "/s/home")
        #expect(!fg.contains("tok-2"))
    }

    func launcher(home: String, sandboxExec: String = Verifier.sandboxExec) -> CLIClientLauncher {
        CLIClientLauncher(port: 8203, modelId: "m", claudeBin: "/bin/echo", codexBin: "/bin/echo",
                          claudeConfigDir: home + "/cfg-c", codexHome: home + "/cfg-x", token: "tok", home: home,
                          sandboxExec: sandboxExec)
    }

    @Test func launcherPlanIsSandboxedWithMinimalEnv() throws {
        let home = realPath(NSTemporaryDirectory()) + "/soak-home-\(UUID().uuidString)"
        let l = launcher(home: home)
        let req = ClientRequest(client: "claude", prompt: "P", repo: "/tmp/repo", background: false, timeout: 5,
                                logBase: "/tmp/x", scratch: "/tmp/scr")
        let p = l.plan(req)
        #expect(p.argv.starts(with: [Verifier.sandboxExec, "-p", p.profile, "/bin/echo"]))
        #expect(p.profile.contains("(deny network*)") || p.profile.contains("deny network"))
        #expect(p.profile.contains("localhost:8203"))
        #expect(!p.env.keys.contains("SSH_AUTH_SOCK") && p.env["HOME"] == "/tmp/scr/home")
        #expect(!p.argv.joined(separator: " ").lowercased().contains("python"))
    }

    @Test func launcherFailsClosedWithoutSandboxExec() throws {
        let l = launcher(home: "/nonexistent-home", sandboxExec: "/nonexistent/sandbox-exec")
        let req = ClientRequest(client: "claude", prompt: "P", repo: "/tmp", background: false, timeout: 5,
                                logBase: "/tmp/soak-nolaunch", scratch: NSTemporaryDirectory() + "soak-nolaunch-\(UUID().uuidString)")
        #expect(throws: SoakError.self) { _ = try l.launch(req) }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/soak-nolaunch.stdout"))
    }

    @Test func sandboxedClientCannotReadFakeHomeToken() throws {
        let base = realPath(NSTemporaryDirectory()) + "soak-probe-\(UUID().uuidString)"
        let home = base + "/home", repo = base + "/repo", scratch = base + "/scr"
        for d in [home + "/.strim", repo, scratch + "/tmp", base + "/cfg-c"] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(atPath: base) }
        try "SECRET-TOKEN".write(toFile: home + "/.strim/token", atomically: false, encoding: .utf8)
        try "visible".write(toFile: repo + "/f.txt", atomically: false, encoding: .utf8)
        let l = launcher(home: home)
        let p = l.plan(ClientRequest(client: "claude", prompt: "P", repo: repo, background: false, timeout: 5,
                                     logBase: base + "/log", scratch: scratch))
        func run(_ args: [String]) throws -> Proc.Captured {
            try Proc.runCaptured(argv: [Verifier.sandboxExec, "-p", p.profile] + args, env: p.env, cwd: repo,
                                 timeout: 20, mergeStderr: true)
        }
        let read = try run(["/bin/cat", home + "/.strim/token"])
        #expect(read.result.exitCode != 0 && !read.text.contains("SECRET-TOKEN"))
        let own = try run(["/bin/cat", repo + "/f.txt"])
        #expect(own.result.exitCode == 0 && own.text == "visible")
        let write = try run(["/usr/bin/touch", base + "/outside"])
        #expect(write.result.exitCode != 0 && !FileManager.default.fileExists(atPath: base + "/outside"))
        let net = try run(["/usr/bin/nc", "-z", "-w", "2", "127.0.0.1", "9"])
        #expect(net.result.exitCode != 0)
    }

    @Test func claudeOutputParses() {
        let out = #"{"num_turns":4,"is_error":false,"subtype":"success","result":"All tests pass"}"#
        let info = SoakClientOutput.parse(client: "claude", stdout: out)
        #expect(info["client_turns"] as? Int == 4)
        #expect(info["client_is_error"] as? Bool == false)
        #expect(info["client_subtype"] as? String == "success")
        #expect(info["result_snippet"] as? String == "All tests pass")
        let bad = SoakClientOutput.parse(client: "claude", stdout: "not json")
        #expect(bad["client_turns"] is NSNull)
        #expect(bad["result_snippet"] is NSNull)
    }

    @Test func codexEventsParse() {
        let out = """
        {"type":"item.completed","item":{"type":"agent_message","text":"done"}}
        {"type":"turn.completed"}
        {"type":"turn.completed"}
        {"type":"turn.failed","error":"boom"}
        """
        let info = SoakClientOutput.parse(client: "codex", stdout: out)
        #expect(info["client_turns"] as? Int == 2)
        #expect(info["result_snippet"] as? String == "done")
        #expect((info["client_error_events"] as? [String])?.count == 1)
    }

    @Test func childExitCodeAndKill() throws {
        let dir = NSTemporaryDirectory() + "soak-child-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ok = try SoakChild.spawn(argv: ["/bin/sh", "-c", "exit 3"], env: [:], cwd: dir,
                                     stdoutPath: dir + "/o", stderrPath: dir + "/e", append: false)
        #expect(ok.wait(timeout: 10) == 3)
        let slow = try SoakChild.spawn(argv: ["/bin/sleep", "30"], env: [:], cwd: dir,
                                       stdoutPath: dir + "/o2", stderrPath: dir + "/e2", append: false)
        #expect(slow.wait(timeout: 0.2) == nil)
        #expect(slow.kill() == -9)
        let perm = try FileManager.default.attributesOfItem(atPath: dir + "/o2")[.posixPermissions] as? Int
        #expect(perm == 0o600)
    }
}

@Suite struct SoakConfigIsolationTests {
    @Test func perRunConfigDirsDifferAndTamperIsInvisibleToTheNextRun() throws {
        let base = realPath(NSTemporaryDirectory()) + "soak-cfg-\(UUID().uuidString)"
        let template = base + "/template"
        try FileManager.default.createDirectory(atPath: template, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try "orig".write(toFile: template + "/settings.json", atomically: false, encoding: .utf8)
        let l = CLIClientLauncher(port: 8203, modelId: "m", claudeBin: "/bin/echo", codexBin: "/bin/echo",
                                  claudeConfigDir: template, codexHome: template, token: "t", home: base + "/home")
        func req(_ n: Int, _ client: String) -> ClientRequest {
            ClientRequest(client: client, prompt: "P", repo: base + "/r\(n)", background: false, timeout: 5,
                          logBase: base + "/l\(n)", scratch: base + "/scr\(n)")
        }
        let d1 = try l.prepareConfig(req(1, "claude"))
        try "tampered".write(toFile: d1 + "/settings.json", atomically: false, encoding: .utf8)
        try "hook".write(toFile: d1 + "/hooks.json", atomically: false, encoding: .utf8)
        let d2 = try l.prepareConfig(req(2, "claude"))
        #expect(d1 != d2)
        #expect(try String(contentsOfFile: d2 + "/settings.json", encoding: .utf8) == "orig")
        #expect(!FileManager.default.fileExists(atPath: d2 + "/hooks.json"))
        #expect(try String(contentsOfFile: template + "/settings.json", encoding: .utf8) == "orig")
        // The profile mounts nothing shared writable: the template is not named, the run config dir is inside scratch.
        let p = l.plan(req(2, "claude"))
        #expect(!p.profile.contains(template))
        #expect(p.env["CLAUDE_CONFIG_DIR"] == d2 && d2.hasPrefix(realPath(base + "/scr2")))
    }
}
