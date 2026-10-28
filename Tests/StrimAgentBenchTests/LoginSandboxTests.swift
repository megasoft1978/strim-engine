import Foundation
import Testing
@testable import StrimAgentBench

/// The paid client finds its login in the macOS Keychain. The profile re-allows exactly the login keychain database file,
/// never the Keychains directory, and the shared temp areas (including the user's own /tmp/claude-<uid>) stay unreadable.
@Suite struct LoginSandboxTests {
    func profile(keychain: String?) -> (profile: String, work: URL, scratch: URL) {
        let root = tempDir("login")
        let work = root.appendingPathComponent("work"), runDir = root.appendingPathComponent("run"), scratch = root.appendingPathComponent("scratch")
        for d in [work, runDir, scratch, runDir.appendingPathComponent("tmp")] { try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let p = ClaudeSandbox.profile(workdir: work.path, runDir: runDir.path, net: .anthropic,
                                      claudeBin: NSHomeDirectory() + "/.local/bin/claude", keychainFile: keychain)
        return (p, work, scratch)
    }

    @Test func keychainAllowIsOneLiteralFile() {
        let k = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        let on = profile(keychain: k).profile, off = profile(keychain: nil).profile
        #expect(on.contains("(allow file-read* (literal \"\(k)\"))"))
        #expect(!off.contains("login.keychain-db"))
        // the secret deny of the Keychains directory is still emitted, before the single-file allow
        let deny = on.range(of: "/Library/Keychains\")")?.lowerBound, allow = on.range(of: "(allow file-read* (literal \"\(k)\"))")?.lowerBound
        #expect(deny != nil && allow != nil && deny! < allow!)
    }

    @Test func liveSandboxReadsOnlyTheLoginKeychainFile() throws {
        guard let k = ClaudeSandbox.loginKeychain() else { return }
        let s = profile(keychain: k)
        func canRead(_ path: String) -> Bool {
            Proc.capture(ClaudeSandbox.wrap(["/bin/dd", "if=\(path)", "of=/dev/null", "bs=16", "count=1"], profile: s.profile),
                         cwd: s.work.path, scratch: s.scratch).code == 0
        }
        #expect(canRead(k))
        // other users' / the host's temp content stays unreadable, including the user's own interactive-session dir
        let probe = "/tmp/strim-login-probe-\(UUID().uuidString)"
        try "x".write(toFile: probe, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: probe) }
        #expect(!canRead(probe))
        #expect(!canRead("/tmp/claude-\(getuid())"))
    }

    @Test func loginEnvCarriesUserAndHostConfigDirOnly() {
        let e = ClaudeSandbox.loginEnv(host: ["USER": "u", "CLAUDE_CONFIG_DIR": "/h/.claude-work", "ANTHROPIC_API_KEY": "k", "CLAUDE_CODE_OAUTH_TOKEN": "t"])
        #expect(e == ["USER": "u", "LOGNAME": "u", "CLAUDE_CONFIG_DIR": "/h/.claude-work"])
    }

    /// Pilot 2: with only `(remote ip)` allowed, DNS failed inside the sandbox (ENOTFOUND) and every paid run was an infra row.
    @Test func paidProfileResolvesNamesLoopbackProfileDoesNot() throws {
        let paid = profile(keychain: nil)
        #expect(paid.profile.contains("mDNSResponder"))
        let root = tempDir("dns")
        let loop = ClaudeSandbox.profile(workdir: root.path, runDir: root.path, net: .loopback(port: 9), claudeBin: "/bin/echo")
        #expect(!loop.contains("mDNSResponder"))
        let probe = ["/usr/bin/python3", "-c", "import socket,sys; socket.getaddrinfo('api.anthropic.com', 443)"]
        guard Proc.capture(probe, cwd: root.path, scratch: root).code == 0 else { return }  // offline host: nothing to check
        #expect(Proc.capture(ClaudeSandbox.wrap(probe, profile: paid.profile), cwd: paid.work.path, scratch: paid.scratch).code == 0)
        #expect(Proc.capture(ClaudeSandbox.wrap(probe, profile: loop), cwd: root.path, scratch: root).code != 0)
    }
}
