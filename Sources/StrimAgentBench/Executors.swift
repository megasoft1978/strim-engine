import Foundation

public struct RunContext: Sendable {
    public var task: LoadedTask
    public var arm: Arm
    public var rep: Int
    /// Fresh copy of the base snapshot (a git repo) the agent works in.
    public var workdir: URL
    /// Logs and scratch for this run (outside the workdir).
    public var runDir: URL
    public var timeout: TimeInterval
    public var seed: UInt64
}

public protocol ArmExecutor: AnyObject {
    func execute(_ ctx: RunContext) -> ArmOutcome
}

public enum PromptBuilder {
    public static func body(_ t: TaskSpec) -> String {
        var s = t.prompt
        if t.isAnswerTask {
            s += "\n\nYour final message is the answer. Do not modify any file."
        } else {
            if let v = t.verifyCmd, !v.isEmpty {
                s += "\n\nThe work is done when this command exits 0 (run from the repository root): \(v)"
            }
            if !t.testPaths.isEmpty { s += "\nDo not edit anything under: \(t.testPaths.joined(separator: ", "))." }
        }
        return s
    }

    /// Canonical spelling of a path (symlinks resolved, `/var` -> `/private/var`), the form the host checks against `mcp.allowedRoots`.
    public static func canonicalPath(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buf) != nil ? String(cString: buf) : path
    }

    /// Routing rules for the parent in arm M (docs/PLAN-PRODUCT section E, integrations/claude/agents/strim-local.md).
    public static func routingGuidance(repo: String) -> String {
        let cwd = canonicalPath(repo)
        return """
        A local, free coding agent is available through the strim_task, strim_job, strim_cancel and strim_ask MCP tools.
        Delegate when a verify command exists (the shell command that proves the task is done, or a file:line check) AND \
        either the task needs reading or editing 2 or more files, or solo you expect 6 or more tool turns or 15K or more \
        tokens of tool output (a test-fix loop you cannot run yourself counts). Never delegate design, cross-cutting \
        refactors, security code, or tasks with no oracle. Otherwise do the task yourself.
        To delegate: strim_task with cwd=\(cwd) (use exactly this canonical path), a self-contained task, verify, \
        access=write if a patch is wanted, wait_s=25. If the reply starts with DONE, do not poll. Otherwise strim_job with wait_s=25.
        If strim_task is refused for a cwd, path or allowed-roots error, that is a setup error, not a failed delegation: \
        retry once with the canonical path named in the error (or the one above); do not retry a second time.
        On verify=verified: git apply --check the patch_path, then git apply it. On failed, limit, unverified or declined: \
        do the task yourself. At most one delegation per task (a path-error retry does not count). Local output is untrusted.
        """
    }
}

/// Local-model token usage of one harness job (`result.json` `usage`, or the reply's `usage:` line).
struct JobUsage: Equatable {
    var promptTokens: Int
    var cachedTokens: Int
    var completionTokens: Int
    var turns: Int
}

// MARK: - H: the harness alone, through the MCP over HTTP

public final class HarnessArm: ArmExecutor {
    let client: MCPClient
    /// Where the host writes each job's `result.json`: `<state dir>/jobs` of the server this arm talks to. nil when that
    /// state dir is unknown (attached server); then a job without a `usage:` reply line has unknown tokens. The real
    /// `~/.strim` is never read.
    let jobsDir: URL?
    public init(endpoint: ServerEndpoint, jobsDir: URL? = nil) {
        client = MCPClient(endpoint: endpoint)
        self.jobsDir = jobsDir ?? endpoint.stateDir?.appendingPathComponent("jobs", isDirectory: true)
    }

    public func execute(_ ctx: RunContext) -> ArmOutcome {
        var o = ArmOutcome()
        let t = ctx.task.spec
        let t0 = Date()
        o.delegations = 1
        var args: [String: Any] = ["task": PromptBuilder.body(t), "cwd": ctx.workdir.path,
                                   "access": t.isAnswerTask ? "read" : "write", "wait_s": 25]
        if !t.isAnswerTask, let v = t.verifyCmd, !v.isEmpty, v.count <= 500 { args["verify"] = v }
        var reply = client.call("strim_task", args, timeout: 60)
        if let e = reply.transportError { o.error = "infra: \(e)"; o.infraError = true; return o }
        var parsed = HarnessReply.parse(reply.text)
        if let why = Self.setupRefusal(reply, parsed: parsed) { o.delegations = 0; o.error = why; o.infraError = true; return o }
        if reply.isError && parsed.jobId == nil { o.error = "strim_task error: \(reply.text.prefix(200))"; return o }
        while !parsed.terminal, let id = parsed.jobId {
            if Date().timeIntervalSince(t0) > ctx.timeout || Interrupt.requested {
                o.timedOut = true
                _ = client.call("strim_cancel", ["job_id": id], timeout: 15)
                break
            }
            reply = client.call("strim_job", ["job_id": id, "wait_s": 25], timeout: 60)
            o.polls += 1
            if let e = reply.transportError { o.error = "infra: \(e)"; o.infraError = true; return o }
            parsed = HarnessReply.parse(reply.text)
        }
        o.harnessStatus = o.timedOut ? "timeout" : parsed.status
        o.harnessVerifyStatus = HarnessReply.verifyLabel(parsed)
        o.harnessVerifyExit = parsed.patchPath.flatMap(HarnessReply.verifyExit(besidePatch:))
        let usage = Self.resolvedUsage(parsed, jobsDir: jobsDir)
        o.localPromptTokens = usage?.promptTokens
        o.localCachedTokens = usage?.cachedTokens
        o.localCompletionTokens = usage?.completionTokens
        o.localTurns = usage?.turns ?? parsed.turns
        o.turns = usage?.turns ?? parsed.turns
        guard parsed.done else {
            if !o.timedOut { o.error = "job ended \(parsed.status ?? "unknown")" }
            return o
        }
        if t.isAnswerTask {
            o.answer = parsed.summary ?? parsed.answer
            o.claimedDone = !(o.answer ?? "").isEmpty
            return o
        }
        o.claimedDone = parsed.verify != "failed"
        var patchFile: String? = parsed.patchPath
        if patchFile == nil, let inline = parsed.inlinePatch {
            let p = ctx.runDir.appendingPathComponent("h.patch")
            try? inline.write(to: p, atomically: true, encoding: .utf8)
            patchFile = p.path
        }
        if let p = patchFile {
            let check = Proc.capture(["/usr/bin/git", "apply", "--check", p], cwd: ctx.workdir.path, scratch: ctx.runDir)
            if check.code == 0 {
                o.patchApplied = Proc.capture(["/usr/bin/git", "apply", p], cwd: ctx.workdir.path, scratch: ctx.runDir).code == 0
            } else { o.patchApplied = false }
        } else {
            o.patchApplied = nil // no patch produced
        }
        return o
    }

    /// Local-model usage of a job. The reply text carries a `usage:` line only for a DONE job, so a job that ended
    /// limit, failed or cancelled reports none there: its usage comes from the job's `result.json`.
    static func resolvedUsage(_ parsed: HarnessReply, jobsDir: URL?, waitS: TimeInterval = 15) -> JobUsage? {
        if let p = parsed.promptTokens {
            return JobUsage(promptTokens: p, cachedTokens: parsed.cachedTokens ?? 0,
                            completionTokens: parsed.completionTokens ?? 0, turns: parsed.turns ?? 0)
        }
        guard let id = parsed.jobId, parsed.status != "declined", let jobsDir else { return nil }
        return jobUsage(jobId: id, jobsDir: jobsDir, waitS: waitS)
    }

    /// `usage` of `<jobsDir>/<jobId>/result.json`. The host writes it when the run concludes, which can lag the terminal
    /// status (a wall-clock limit finalizes the job first, then cancels the run), so this polls for up to `waitS`.
    static func jobUsage(jobId: String, jobsDir: URL, waitS: TimeInterval = 15) -> JobUsage? {
        guard !jobId.isEmpty, !jobId.contains("/"), jobId != ".", jobId != ".." else { return nil }
        let url = jobsDir.appendingPathComponent(jobId).appendingPathComponent("result.json")
        let t0 = Date()
        while true {
            if let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let u = o["usage"] as? [String: Any] {
                func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                return JobUsage(promptTokens: n("prompt_tokens"), cachedTokens: n("cached_tokens"),
                                completionTokens: n("completion_tokens"), turns: n("turns"))
            }
            if Date().timeIntervalSince(t0) >= waitS { return nil }
            usleep(250_000)
        }
    }

    /// A `strim_task` the host refused for its cwd, path or allowed-roots policy never started a job: setup, not a task
    /// outcome. The row is infrastructure (rerun on resume), never a failed fitness row.
    static func setupRefusal(_ reply: ToolReply, parsed: HarnessReply) -> String? {
        guard parsed.jobId == nil, ClaudeParser.isPathRefusal(reply.text) else { return nil }
        return "infra: strim_task refused: \(reply.text.prefix(200))"
    }
}

// MARK: - C, P, M: Claude Code

public final class ClaudeArm: ArmExecutor {
    public enum Mode: Sendable { case local(ServerEndpoint), paid, paidWithMCP(ServerEndpoint) }
    let mode: Mode
    let claudeBin: String
    let model: String

    /// `model`: the served model id for local mode, the parent alias (e.g. "sonnet") for paid modes.
    public init(mode: Mode, claudeBin: String, model: String) { self.mode = mode; self.claudeBin = claudeBin; self.model = model }

    static let mcpTokenEnvVar = "STRIM_MCP_TOKEN"

    /// Client MCP config for the M arm. The bearer token is referenced through the environment, never written.
    static func mcpConfigJSON(baseURL: String) throws -> Data {
        let cfg: [String: Any] = ["mcpServers": ["strim": ["type": "http", "url": "\(baseURL)/mcp",
                                                          "headers": ["Authorization": "Bearer ${\(mcpTokenEnvVar)}"]]]]
        return try JSONSerialization.data(withJSONObject: cfg)
    }

    static let allowedBuiltin = ["Read", "Edit", "Write", "Glob", "Grep"]
    static let denied = ["WebFetch", "WebSearch", "Read(~/.ssh/**)", "Read(~/.aws/**)", "Read(~/.strim/**)", "Read(~/.claude*/**)",
                         "Read(~/.codex/**)", "Read(~/.config/**)", "Edit(~/**)", "Write(~/**)"] + BashAllow.denied

    func buildArgv(prompt: String, mcpConfig: String?, repo: String, task: TaskSpec, language: String? = nil,
                   sandboxProfile: String? = nil) -> [String] {
        let paid: Bool
        if case .local = mode { paid = false } else { paid = true }
        var a = [claudeBin, "-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose",
                 "--permission-mode", "dontAsk", "--no-session-persistence", "--setting-sources", "",
                 "--strict-mcp-config"]
        // Every Claude arm gets Bash, always as a prefix allow list. Local (loopback-only sandbox): `BashAllow`. Paid (owner
        // decision 2026-10-28, the parent must be able to run tests): the stricter `PaidBash` list, inside the same
        // sandbox profile; the paid Bash child keeps the client's network (see PaidBash). The harness still re-verifies.
        var allowed = Self.allowedBuiltin
        allowed += paid ? PaidBash.allowedRules(for: task, language: language) : BashAllow.allowedPrefixes(for: task, language: language)
        if paid && mcpConfig == nil { a += ["--append-system-prompt", PaidBash.guidance] }
        if let mcpConfig {
            a += ["--mcp-config", mcpConfig, "--append-system-prompt", PromptBuilder.routingGuidance(repo: repo) + (paid ? "\n" + PaidBash.guidance : "")]
            allowed += ["mcp__strim__strim_task", "mcp__strim__strim_job", "mcp__strim__strim_cancel", "mcp__strim__strim_ask"]
        }
        a += ["--tools", (Self.allowedBuiltin + ["Bash"]).joined(separator: ",")]
        a += ["--allowedTools"] + allowed
        a += ["--disallowedTools"] + Self.denied + (paid ? PaidBash.extraDenied : [])
        if let p = sandboxProfile { return ClaudeSandbox.wrap(a, profile: p) }
        return a
    }

    public func execute(_ ctx: RunContext) -> ArmOutcome {
        var o = ArmOutcome()
        let t = ctx.task.spec
        guard FileManager.default.isExecutableFile(atPath: claudeBin) else {
            o.error = "infra: claude binary not found at \(claudeBin)"; o.infraError = true; return o
        }
        var env = scrubbedEnvironment()
        env["DISABLE_TELEMETRY"] = "1"
        env["DISABLE_AUTOUPDATER"] = "1"
        var token = ""
        var mcpPath: String?
        switch mode {
        case .local(let ep):
            token = ep.token
            env["ANTHROPIC_BASE_URL"] = ep.baseURL
            env["ANTHROPIC_AUTH_TOKEN"] = ep.token
            env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            let cfg = ctx.runDir.appendingPathComponent("claude-config")
            try? FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            env["CLAUDE_CONFIG_DIR"] = cfg.path
        case .paid:
            break // auth comes from the user's login; nothing in the user config is written (no persistence, no setting sources)
        case .paidWithMCP(let ep):
            token = ep.token
            // The file holds no secret: the client expands the header from its own environment (like the mcp-clients lane).
            env[Self.mcpTokenEnvVar] = ep.token
            let p = ctx.runDir.appendingPathComponent("mcp.json")
            if let d = try? Self.mcpConfigJSON(baseURL: ep.baseURL),
               FileManager.default.createFile(atPath: p.path, contents: d, attributes: [.posixPermissions: 0o600]) {
                mcpPath = p.path
            } else { o.error = "infra: cannot write mcp config"; o.infraError = true; return o }
        }
        defer { if let m = mcpPath { try? FileManager.default.removeItem(atPath: m) } }

        let tmp = ctx.runDir.appendingPathComponent("tmp")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        env["TMPDIR"] = tmp.path
        env[ClaudeSandbox.claudeTmpEnvVar] = ClaudeSandbox.prepareClaudeTmp(runDir: ctx.runDir.path)
        defer { try? FileManager.default.removeItem(atPath: ctx.runDir.path + "/claude-tmp") }
        env["GOCACHE"] = ctx.runDir.appendingPathComponent("gocache").path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        var net = ClaudeSandbox.Net.anthropic
        var authFile: String?
        switch mode {
        case .local(let ep):
            net = .loopback(port: ep.port)
            let home = ctx.runDir.appendingPathComponent("home")
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            env["HOME"] = home.path
        case .paid, .paidWithMCP:
            let cred = NSHomeDirectory() + "/.claude/.credentials.json"
            if FileManager.default.fileExists(atPath: cred) { authFile = cred }
            for (k, v) in ClaudeSandbox.loginEnv() { env[k] = v }
        }
        var testService: RunTestsService?
        if case .local = mode {} else {
            // Host-side test runner for the paid Bash (see RunTests.swift); the client only gets the `runtests` script.
            let binDir = ctx.runDir.appendingPathComponent("bin").path
            if !t.isAnswerTask {
                guard let svc = RunTestsService(workdir: ctx.workdir.path, scratch: ctx.runDir.path + "/runtests-scratch") else {
                    o.error = "infra: cannot start runtests service"; o.infraError = true; return o
                }
                svc.writeScript(dir: binDir)
                testService = svc
            }
            env = PaidBash.clientEnv(from: env, binDir: testService == nil ? nil : binDir)
        }
        defer { testService?.stop() }
        let profile = ClaudeSandbox.profile(workdir: ctx.workdir.path, runDir: ctx.runDir.path, net: net, claudeBin: claudeBin, authFile: authFile,
                                            keychainFile: net == .anthropic ? ClaudeSandbox.loginKeychain() : nil,
                                            readOnlyPaths: net == .anthropic ? t.testPaths : [])
        let argv = buildArgv(prompt: PromptBuilder.body(t), mcpConfig: mcpPath, repo: ctx.workdir.path, task: t,
                             language: ctx.task.language, sandboxProfile: profile)
        // stdout/stderr come back through host-held fds; the sandboxed child never gets a path the host later reads.
        let cap: Proc.Captured
        do { cap = try Proc.runCaptured(argv: argv, env: env, cwd: ctx.workdir.path, timeout: ctx.timeout) }
        catch { o.error = "infra: \(error)"; o.infraError = true; return o }
        let r = cap.result
        func scrub(_ d: Data) -> Data {
            guard !token.isEmpty else { return d }
            return Data(String(decoding: d, as: UTF8.self).replacingOccurrences(of: token, with: "<redacted>").utf8)
        }
        let outData = scrub(cap.stdout), errData = scrub(cap.stderr)
        Proc.writeLog(ctx.runDir.appendingPathComponent("stream.jsonl").path, outData)
        Proc.writeLog(ctx.runDir.appendingPathComponent("stderr.txt").path, errData)
        o.timedOut = r.timedOut
        let text = String(decoding: outData, as: UTF8.self)
        let run = ClaudeParser.parse(text)
        o.turns = run.turns
        o.delegations = run.delegations
        o.polls = run.polls
        o.pathRefusals = run.pathRefusals
        o.patchApplied = run.patchApplied
        o.redo = run.redo
        o.claimedDone = ClaudeParser.claimsDone(run) && !r.timedOut
        if t.isAnswerTask { o.answer = run.resultText }
        switch mode {
        case .local:
            // Everything Claude Code reports is local-model usage here; there is no paid parent.
            o.localPromptTokens = (run.inputUncached ?? 0) + (run.cacheCreate ?? 0) + (run.cacheRead ?? 0)
            o.localCachedTokens = run.cacheRead
            o.localCompletionTokens = run.output
            o.localTurns = run.turns
        case .paid, .paidWithMCP:
            o.parentInUncached = run.inputUncached
            o.parentCacheCreate = run.cacheCreate
            o.parentCacheRead = run.cacheRead
            o.parentOut = run.output
            o.parentCostUsd = run.costUsd
            if run.sawLocalUsage {
                o.localPromptTokens = run.localPrompt; o.localCachedTokens = run.localCached
                o.localCompletionTokens = run.localCompletion; o.localTurns = run.localTurns
            }
        }
        if !run.sawResult && !r.timedOut {
            let tail = String(decoding: errData, as: UTF8.self).suffix(200)
            o.error = "claude exit \(r.exitCode) without a result: \(tail.replacingOccurrences(of: "\n", with: " | "))"
            o.infraError = !r.interrupted
        } else if run.failedBeforeModel {
            o.error = "infra: claude failed before any model usage: \(run.resultText.prefix(120))"
            o.infraError = !r.interrupted
        } else if run.isError { o.error = "claude reported an error" }
        return o
    }
}

// MARK: - dry run

/// Fake engine for `--dry-run`: no model, no network. Applies the task's `solution.patch` (when present and the
/// arm "succeeds") so the real verification path is exercised; arm C never fixes anything.
public final class FakeExecutor: ArmExecutor {
    public init() {}

    public func execute(_ ctx: RunContext) -> ArmOutcome {
        var rng = SplitMix64(seed: ctx.seed ^ fnv1a("\(ctx.task.id)/\(ctx.arm.rawValue)/\(ctx.rep)"))
        func n(_ lo: Int, _ hi: Int) -> Int { lo + Int(rng.next() % UInt64(hi - lo + 1)) }
        var o = ArmOutcome()
        o.turns = n(2, 8)
        o.claimedDone = true
        let fixes = ctx.arm != .C
        if fixes {
            if ctx.task.spec.isAnswerTask { o.answer = ctx.task.spec.knownAnswer ?? "" }
            else {
                let patch = ctx.task.dir.appendingPathComponent("solution.patch")
                if FileManager.default.fileExists(atPath: patch.path) {
                    o.patchApplied = Proc.capture(["/usr/bin/git", "apply", patch.path], cwd: ctx.workdir.path, scratch: ctx.runDir).code == 0
                }
            }
        } else if ctx.task.spec.isAnswerTask { o.answer = "I could not find it." }
        switch ctx.arm {
        case .P, .M:
            o.parentInUncached = n(2, 12); o.parentCacheCreate = n(3000, 9000); o.parentCacheRead = n(10_000, 60_000)
            o.parentOut = n(300, 2500)
            o.parentCostUsd = Double(n(150, 900)) / 10_000.0 * (ctx.arm == .M ? 0.6 : 1.0)
            if ctx.arm == .M { o.delegations = 1; o.localPromptTokens = n(8000, 20_000); o.localCompletionTokens = n(200, 900) }
        case .H:
            o.delegations = 1
            o.localPromptTokens = n(8000, 40_000); o.localCompletionTokens = n(200, 1500); o.localTurns = o.turns
        case .C:
            o.localPromptTokens = n(8000, 40_000); o.localCompletionTokens = n(200, 1500); o.localTurns = o.turns
        }
        return o
    }
}
