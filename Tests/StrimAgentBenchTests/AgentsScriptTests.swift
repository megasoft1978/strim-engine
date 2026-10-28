import Foundation
import Testing

/// M4 (security review 2026-10-28): `scripts/agents.sh claude` must not bypass permissions unless explicitly told to.
@Suite struct AgentsScriptTests {
    /// Runs `agents.sh claude hi` with stub `curl` (health ok) and `claude` (prints its argv and config dir).
    private func run(unsafe: Bool) throws -> (out: String, err: String) {
        let root = tempDir("agents")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in [("curl", "exit 0"), ("claude", "echo \"ARGS:$*\"; echo \"CFG:$CLAUDE_CONFIG_DIR\"")] {
            let p = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: p, atomically: true, encoding: .utf8)
            chmod(p.path, 0o755)
        }
        let tok = root.appendingPathComponent("token")
        try "tok\n".write(to: tok, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [repoRoot().appendingPathComponent("scripts/agents.sh").path, "claude", "hi"]
        var env = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": root.path, "STRIM_TOKEN_FILE": tok.path, "TMPDIR": root.path + "/"]
        if unsafe { env["STRIM_UNSAFE_LOCAL_AGENT"] = "1" }
        p.environment = env
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        try p.run()
        let out = o.fileHandleForReading.readDataToEndOfFile(), err = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    @Test func defaultDoesNotSkipPermissions() throws {
        let r = try run(unsafe: false)
        #expect(r.out.contains("ARGS:-p hi"), "\(r.out) \(r.err)")
        #expect(!r.out.contains("dangerously"), "\(r.out)")
        #expect(!r.err.contains("WARNING"))
    }

    @Test func unsafeModeNeedsExplicitEnvWarnsAndUsesThrowawayConfig() throws {
        let r = try run(unsafe: true)
        #expect(r.out.contains("--dangerously-skip-permissions"), "\(r.out) \(r.err)")
        #expect(r.err.contains("WARNING") && r.err.contains("STRIM_UNSAFE_LOCAL_AGENT"))
        #expect(r.out.contains("strim-claude-cfg."), "unsafe mode must not use the real ~/.claude: \(r.out)")
    }
}
