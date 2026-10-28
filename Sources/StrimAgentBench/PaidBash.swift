import Foundation
import StrimHarness

/// Scoped Bash for the paid arms (P, M). Owner decision 2026-10-28: without a shell the Claude parent cannot run the
/// task's tests (bench/results/agentbench-pilot2-20261028/followup.md), so P is a handicapped baseline.
///
/// What bounds it, and what does not:
/// - Filesystem: Bash children inherit the client's `sandbox-exec` profile (writes only in the task worktree and run
///   dir, reads of home/secret paths/other runs' dirs/temp areas denied, the task's `test_paths` write-denied on top).
///   `sandbox-exec` cannot be nested (sandbox_apply EPERM), so the Bash child cannot get a profile tighter than the client's.
/// - Code execution: the Bash child shares the client's network and can read its OAuth credential (no nesting, no split), so
///   Bash may NOT run `go test`/`swift test`. It may only call `runtests`, which asks the host to run the runner in the
///   verify sandbox (no network, no credentials, writes in the worktree). Test files are hash-checked and restored before grading.
/// - Env: the client gets an allow-listed environment (no inherited secrets); its subprocess scrub is turned on. The
///   Bash child still sees what the client needs (see `clientKeys`).
/// - Time/output: per-command timeout and output cap through Claude Code's own variables; total run bounded by the run timeout.
public enum PaidBash {
    public static let defaultTimeoutMs = 120_000
    public static let maxTimeoutMs = 300_000
    public static let maxOutputChars = 20_000
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"

    /// Environment variable names the paid client (and so its Bash children) may have. Everything else is dropped.
    static let clientKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "CLAUDE_CODE_TMPDIR", "CLAUDE_CONFIG_DIR", "LANG", "LC_ALL", "TERM",
        "PYTHONDONTWRITEBYTECODE", "CI",
        "DISABLE_TELEMETRY", "DISABLE_AUTOUPDATER", "STRIM_MCP_TOKEN",
    ]

    /// `host` is the env ClaudeArm assembled (already scrubbed). Result: allow-listed keys only, minimal PATH, Bash limits.
    public static func clientEnv(from host: [String: String], binDir: String? = nil) -> [String: String] {
        var env = host.filter { clientKeys.contains($0.key) }
        env["PATH"] = (binDir.map { $0 + ":" } ?? "") + path
        env["CI"] = "1"
        env["BASH_DEFAULT_TIMEOUT_MS"] = String(defaultTimeoutMs)
        env["BASH_MAX_TIMEOUT_MS"] = String(maxTimeoutMs)
        env["BASH_MAX_OUTPUT_LENGTH"] = String(maxOutputChars)
        env["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"
        return env
    }

    static let readOnlyTools = ["ls", "cat", "head", "tail", "wc", "grep", "diff", "pwd"]

    /// `Bash(<prefix>:*)` rules. Generic Bash is read-only and cannot execute repository code: no go/swift/rg (`rg --pre` runs
    /// commands)/git diff|log (`--ext-diff`, `--output`)/sed/awk/find/cp/mv/touch/mkdir. Tests run through `runtests`
    /// (host-side service, see RunTests.swift) for tasks that have a verify command.
    public static func allowedRules(for t: TaskSpec, language: String?) -> [String] {
        var p = readOnlyTools
        if !t.isAnswerTask { p.append("runtests") }
        return p.map { "Bash(\($0):*)" }
    }

    /// Conservative model of the allow-list match used by the tests: like `BashAllow.permits` but any command substitution,
    /// backtick, process substitution, background `&` or newline is refused outright. The real matcher is Claude Code's;
    /// this documents the forms the rule set must never admit.
    public static func strictPermits(_ command: String, rules: [String]) -> Bool {
        let stripped = command.replacingOccurrences(of: "&&", with: ";")
        if command.contains("`") || command.contains("$(") || command.contains("<(") || command.contains(">(") || command.contains("\n")
            || stripped.contains("&") || command.contains("${") { return false }
        return BashAllow.permits(command, rules: rules)
    }

    /// System prompt addition for the paid arms.
    public static let guidance = """
    You have a Bash tool restricted to read-only inspection (ls, cat, head, tail, wc, grep, diff) and `runtests`. \
    Run tests ONLY through `runtests`: `runtests go test ./...`, `runtests swift test --filter Name`, `runtests node --test`, `runtests bun test`, \
    `runtests deno test`, `runtests cargo test --offline`, `runtests ruby -Ilib -Itest test/x_test.rb`, `runtests javatest`, `runtests python3 -I -m unittest discover -s tests -t .`, `runtests tsc --noEmit -p .`, \
    `runtests npm test` (also `go vet`, `go build`, `swift build`): running the language tools directly is not available. runtests runs in an isolated sandbox without network and returns the (truncated) output.
    """

    /// On top of `BashAllow.denied`: direct runners (deny beats allow), env dumps, exec flags, credential dirs.
    public static let extraDenied = [
        "Bash(go:*)", "Bash(swift:*)", "Bash(gofmt:*)", "Bash(node:*)", "Bash(npm:*)", "Bash(npx:*)", "Bash(bun:*)", "Bash(deno:*)", "Bash(tsc:*)",
        "Bash(cargo:*)", "Bash(rustc:*)", "Bash(ruby:*)", "Bash(gem:*)", "Bash(bundle:*)", "Bash(java:*)", "Bash(javac:*)", "Bash(mvn:*)", "Bash(perl:*)", "Bash(rg:*)", "Bash(git:*)",
        "Bash(env:*)", "Bash(printenv:*)", "Bash(export:*)", "Bash(python:*)", "Bash(python3:*)", "Bash(bash:*)", "Bash(sh:*)", "Bash(zsh:*)",
        "Bash(cat ~/.ssh:*)", "Bash(cat ~/.aws:*)", "Bash(cat ~/.strim:*)", "Bash(cat ~/.claude:*)", "Bash(cat ~/.codex:*)",
        "Bash(ls ~/.ssh:*)", "Bash(ls ~/.strim:*)",
    ]

    /// Extra profile text for paid runs: the task's `test_paths` are write-denied (last match wins), so a Bash or Edit
    /// path cannot change them even before the harness hash check and restore. Reads stay allowed (the parent must read the tests).
    public static func profileSuffix(workdir: String, testPaths: [String]) -> String {
        var rules: [String] = []
        for tp in testPaths {
            guard let rel = Verifier.safeRel(tp) else { continue }
            for w in ClaudeSandbox.variants(workdir) { rules.append("(subpath \(ClaudeSandbox.quote(w + "/" + rel)))") }
        }
        return rules.isEmpty ? "" : "(deny file-write*\n  " + rules.joined(separator: "\n  ") + ")\n"
    }
}
