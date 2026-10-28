import Foundation
import Testing
@testable import StrimSoak

/// Startup-only regression for the sandboxed real clients: no model server, no network call that leaves the machine,
/// no paid call (dummy token, loopback port 1 refuses). Skipped when the client is not installed.
/// Pilot 2026-10-28: Claude Code died in under a second with `EPERM ... mkdir '/tmp/claude-<uid>'` once the sandbox
/// denied /tmp; Codex died with `Failed to synchronize managed preferences` once mach-lookup was denied.
@Suite struct SoakClientStartupTests {
    func launch(client: String, bin: String) throws -> (ClientOutcome, scratch: String) {
        let base = realPath(NSTemporaryDirectory()) + "/soak-startup-\(UUID().uuidString)"
        let repo = base + "/repo", scratch = base + "/scr"
        for d in [repo, scratch, base + "/logs"] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let l = CLIClientLauncher(port: 1, modelId: "m", claudeBin: client == "claude" ? bin : "/bin/echo",
                                  codexBin: client == "codex" ? bin : "/bin/echo",
                                  claudeConfigDir: base + "/tpl-c", codexHome: base + "/tpl-x", token: "dummy-not-a-credential")
        let req = ClientRequest(client: client, prompt: "say hi", repo: repo, background: false, timeout: 12,
                                logBase: base + "/logs/run", scratch: scratch)
        let out = try l.launch(req)
        return (out, scratch)
    }

    @Test func sandboxedClaudeGetsPastStartup() throws {
        let bin = NSHomeDirectory() + "/.local/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: bin) else { return }
        let (o, scratch) = try launch(client: "claude", bin: bin)
        let text = o.stdout + o.stderr
        #expect(!text.contains("EPERM") && !text.contains("operation not permitted"), "\(text.prefix(300))")
        // It got far enough to create its scratch dir, and that dir lives in the run's own scratch (not /tmp).
        let made = (try? FileManager.default.contentsOfDirectory(atPath: scratch + "/claude-tmp")) ?? []
        #expect(made.contains { $0.hasPrefix("claude-") }, "claude-tmp holds \(made); exit \(o.exitCode) after \(o.wall)s: \(text.prefix(300))")
    }

    @Test func sandboxedCodexGetsPastStartup() throws {
        let bin = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bin else { return }
        let (o, _) = try launch(client: "codex", bin: bin)
        #expect(o.stdout.contains("thread.started"), "exit \(o.exitCode): \((o.stdout + o.stderr).prefix(300))")
        #expect(!(o.stdout + o.stderr).contains("managed preferences"))
    }
}
