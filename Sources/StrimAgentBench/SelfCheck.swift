import Foundation
import StrimHarness

/// Per-language startup check run inside the same kind of sandbox the agents use. A failure is an infra error,
/// never a model failure.
public enum SelfCheck {
    /// Harness-style job sandbox (default PATH, no extra readable roots) as `strim serve` builds it for arm H.
    static func harnessProfile(work: URL, tmp: URL) -> String {
        SandboxProfile(access: .write, writableRoots: [work.path], jobTmp: tmp.path).profile
    }

    public static func command(for language: String) -> String? {
        switch language {
        case "go": return "go version"
        case "swift": return "swift --version"
        default: return nil
        }
    }

    /// nil when fine, else a one-line reason.
    public static func check(language: String, scratch: URL) -> String? {
        guard let cmd = command(for: language) else { return nil }
        let fm = FileManager.default
        let work = scratch.appendingPathComponent("selfcheck-work"), tmp = scratch.appendingPathComponent("selfcheck-tmp")
        for d in [work, tmp, tmp.appendingPathComponent("home")] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        var env = scrubbedEnvironment()
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["TMPDIR"] = tmp.path; env["HOME"] = tmp.path + "/home"
        guard fm.isExecutableFile(atPath: Verifier.sandboxExec) else { return "sandbox-exec missing" }
        for (name, profile) in [("job sandbox", harnessProfile(work: work, tmp: tmp)),
                                ("verify sandbox", Verifier.sandboxProfile(work: work, scratch: scratch, home: NSHomeDirectory()))] {
            guard let c = try? Proc.runCaptured(argv: [Verifier.sandboxExec, "-p", profile, "/bin/sh", "-c", cmd], env: env,
                                                cwd: work.path, timeout: 60, maxBytes: 2048, mergeStderr: true) else { return "\(name): cannot start" }
            if c.result.exitCode != 0 {
                return "\(language) self-check failed in the \(name) (`\(cmd)` exit \(c.result.exitCode)): "
                    + String(decoding: c.stdout, as: UTF8.self).suffix(160).replacingOccurrences(of: "\n", with: " | ")
            }
        }
        return nil
    }
}
