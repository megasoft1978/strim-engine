import Foundation
import StrimHarness

/// Per-language startup check run inside the same kind of sandbox the agents use. A failure is an infra error,
/// never a model failure.
public enum SelfCheck {
    /// The harness job sandbox exactly as `strim serve` builds it for arm H (`BashTool.jobProfile`: toolchain read grants, nothing else added).
    static func harnessProfile(work: URL, tmp: URL) -> String {
        BashTool.jobProfile(workspaceRoot: work.path, access: .write, jobTmp: tmp.path).profile
    }

    public static func command(for language: String) -> String? {
        switch language {
        case "go": return "go version"
        case "swift": return "swift --version"
        case "typescript", "javascript", "react": return "node --version && bun --version"
        case "rust": return "cargo --version && rustc --version"
        case "java": return "javac -version && java -version"
        case "ruby": return "ruby --version"
        case "python": return "python3 -I --version"
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
        Toolchains.apply(to: &env, home: NSHomeDirectory(), scratch: tmp.path)
        guard fm.isExecutableFile(atPath: Verifier.sandboxExec) else { return "sandbox-exec missing" }
        // Both sandboxes run every language: the harness job sandbox (arm H, `BashTool.jobProfile` + `Toolchains` env) and the verify sandbox
        // (grader, runtests, arm C/P/M).
        let profiles = [("job sandbox", harnessProfile(work: work, tmp: tmp)), ("verify sandbox", Verifier.sandboxProfile(work: work, scratch: scratch, home: NSHomeDirectory()))]
        for (name, profile) in profiles {
            guard let c = try? Proc.runCaptured(argv: [Verifier.sandboxExec, "-p", profile, "/bin/sh", "-c", cmd], env: env,
                                                cwd: work.path, timeout: 60, maxBytes: 2048, mergeStderr: true) else { return "\(name): cannot start" }
            if c.result.exitCode != 0 {
                return "\(language) self-check failed in the \(name) (`\(cmd)` exit \(c.result.exitCode)): "
                    + String(decoding: c.stdout, as: UTF8.self).suffix(160).replacingOccurrences(of: "\n", with: " | ")
            }
        }
        return nil
    }

    /// Preflight for the paid arms' Bash (P, M): runs real probe commands under the paid profile and checks the argv rules.
    /// nil when fine, else a one-line reason. No model, no network.
    public static func checkPaidBash(scratch: URL, claudeBin: String) -> String? {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Verifier.sandboxExec) else { return "paid Bash: sandbox-exec missing" }
        let root = scratch.appendingPathComponent("paidbash")
        let work = root.appendingPathComponent("work"), run = root.appendingPathComponent("run")
        let outside = root.appendingPathComponent("outside")
        for d in [work.appendingPathComponent("tests"), run.appendingPathComponent("tmp"), outside] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try? "x".write(to: work.appendingPathComponent("tests/t_test.txt"), atomically: true, encoding: .utf8)
        try? "secret".write(to: outside.appendingPathComponent("hidden.txt"), atomically: true, encoding: .utf8)
        let profile = ClaudeSandbox.profile(workdir: work.path, runDir: run.path, net: .anthropic, claudeBin: claudeBin, readOnlyPaths: ["tests"])
        func sh(_ cmd: String) -> Int32 {
            Proc.capture(ClaudeSandbox.wrap(["/bin/sh", "-c", cmd], profile: profile), cwd: work.path, env: PaidBash.clientEnv(from: [:]), timeout: 30, scratch: root).code
        }
        let home = NSHomeDirectory()
        let probes: [(String, Bool, String)] = [
            ("write in worktree", true, "echo ok > '\(work.path)/p.txt'"),
            ("write outside worktree", false, "echo no > '\(outside.path)/w.txt'"),
            ("read outside worktree", false, "cat '\(outside.path)/hidden.txt'"),
            ("write test path", false, "echo no > '\(work.path)/tests/t_test.txt'"),
            ("read ~/.ssh", false, "ls '\(home)/.ssh'"),
            ("read ~/.strim/token", false, "cat '\(home)/.strim/token'"),
        ]
        for (name, shouldPass, cmd) in probes where (sh(cmd) == 0) != shouldPass {
            return "paid Bash sandbox probe failed: \(name) was \(shouldPass ? "denied" : "allowed")"
        }
        // The Bash rule itself: runners allowed, network/destructive tools and env dumps denied.
        let arm = ClaudeArm(mode: .paid, claudeBin: claudeBin, model: "sonnet")
        let task = TaskSpec(id: "preflight", taskClass: "test-fix", prompt: "p", verifyCmd: "go test -count=1 ./...")
        let argv = arm.buildArgv(prompt: "p", mcpConfig: nil, repo: work.path, task: task, language: "go")
        func section(_ flag: String) -> [String] {
            guard let i = argv.firstIndex(of: flag) else { return [] }
            return Array(argv[(i + 1)...].prefix { !$0.hasPrefix("--") })
        }
        let allowed = section("--allowedTools"), denied = section("--disallowedTools")
        guard allowed.contains("Bash(runtests:*)"), allowed.contains("Bash(cat:*)"), denied.contains("Bash(curl:*)"), denied.contains("Bash(go:*)"),
              denied.contains("Bash(rg:*)"), denied.contains("Bash(env:*)"), !allowed.contains("Bash(go:*)"), !allowed.contains("Bash(rg:*)"),
              !allowed.contains("Bash(sed:*)"), !allowed.contains("Bash"), section("--tools").flatMap({ $0.split(separator: ",") }).contains("Bash")
        else { return "paid Bash rule set is wrong" }
        // The host-side runtests service: refuses foreign programs and a wrong token, runs the runner (when installed) with no network.
        guard let svc = RunTestsService(workdir: work.path, scratch: run.path + "/runtests-scratch") else { return "paid Bash: runtests service cannot start" }
        defer { svc.stop() }
        let script = svc.writeScript(dir: run.path + "/bin")
        func rt(_ args: [String]) -> Int32 {
            Proc.capture(ClaudeSandbox.wrap([script] + args, profile: profile), cwd: work.path, env: PaidBash.clientEnv(from: [:], binDir: run.path + "/bin"), timeout: 60, scratch: root).code
        }
        if rt(["curl", "http://example.com"]) != 64 { return "paid Bash: runtests accepted a foreign program" }
        if rt(["go", "test", "-exec", "sh"]) != 64 { return "paid Bash: runtests accepted -exec" }
        for bad in [["npm", "install"], ["npx", "cowsay"], ["node", "-e", "1"], ["bun", "x", "cowsay"], ["cargo", "install", "x"], ["cargo", "test"],
                    ["ruby", "-e", "1"], ["python3", "-c", "1"], ["python3", "-m", "pip", "install", "x"], ["pip", "install", "x"], ["java", "-jar", "x.jar"]]
        where rt(bad) != 64 { return "paid Bash: runtests accepted `\(bad.joined(separator: " "))`" }
        if fm.isExecutableFile(atPath: "/opt/homebrew/bin/go") || fm.isExecutableFile(atPath: "/usr/local/go/bin/go"), rt(["go", "version"]) != 0 {
            return "paid Bash: runtests could not run `go version` through the test sandbox"
        }
        let env = PaidBash.clientEnv(from: ["SECRET_KEY": "x", "AWS_PROFILE": "p", "HOME": home])
        guard env["SECRET_KEY"] == nil, env["AWS_PROFILE"] == nil, env["BASH_MAX_OUTPUT_LENGTH"] != nil else { return "paid Bash env is not cleared" }
        return nil
    }
}
