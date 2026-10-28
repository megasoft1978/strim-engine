import Foundation
import StrimAgentBench

public enum MCPClientKind: String, Sendable { case claude, codex }

/// One real-client case (the RUNS / CODEX_RUNS tables of the retired driver).
public struct MCPClientsCase: Equatable, Sendable {
    public let name: String
    public let client: MCPClientKind
    public let useMCP: Bool
    public let prompt: String

    /// Cases whose name contains "fix" are verified against the fixture after the client exits.
    public var checksFix: Bool { name.contains("fix") }
}

public enum MCPClientsCases {
    static let fixText = "text_test.go has a failing test for punctuation in Slugify. Fix text.go so that `go test ./...` "
        + "passes. Do not edit the tests."
    static let fixDelegated = "Delegate to the strim_task tool (access=write, cwd=<REPO>) the task: \"" + fixText + "\" "
        + "Poll with strim_job until done. Then apply the returned patch in <REPO> with git apply (use patch_path), "
        + "run `go test ./...` in <REPO>, and report PASS or FAIL."
    static let ask = "Use the strim_ask tool (cwd=<REPO>) to ask what the function Slugify does in text.go; "
        + "report its answer in one sentence."

    public static let all: [MCPClientsCase] = [
        MCPClientsCase(name: "claude_a_ask", client: .claude, useMCP: true, prompt: ask),
        MCPClientsCase(name: "claude_b_fix_delegated", client: .claude, useMCP: true, prompt: fixDelegatedClaude),
        MCPClientsCase(name: "claude_c_fix_alone", client: .claude, useMCP: false,
                       prompt: fixText + " Work in the current directory <REPO> with the Read, Edit, Write, Glob and Grep "
                           + "tools only; you have no shell, so do not try to run tests. Reply DONE when text.go is fixed."),
        MCPClientsCase(name: "claude_d_nomcp_hello", client: .claude, useMCP: false, prompt: "Reply with the single word ok."),
        MCPClientsCase(name: "claude_e_mcp_hello", client: .claude, useMCP: true, prompt: "Reply with the single word ok."),
        MCPClientsCase(name: "codex_a_ask", client: .codex, useMCP: true,
                       prompt: "Use the strim_ask MCP tool (cwd=<REPO>) to ask what the function Slugify does in text.go; "
                           + "report its answer in one sentence. First list which strim tools you can see."),
        MCPClientsCase(name: "codex_b_fix", client: .codex, useMCP: true, prompt: fixDelegated),
    ]

    /// Claude MCP arm has no shell: the patch is applied with Edit and the harness runs the tests afterwards.
    static let fixDelegatedClaude = "Delegate to the strim_task tool (access=write, cwd=<REPO>) the task: \"" + fixText + "\" "
        + "Poll with strim_job until done. Then apply the returned patch to text.go with the Edit tool and reply DONE. "
        + "Do not run any commands; the harness runs the tests."

    public static func named(_ name: String) -> MCPClientsCase? { all.first { $0.name == name } }
}

/// Resolved binaries and knobs for one invocation.
public struct MCPClientsBins: Sendable {
    public var claude: String
    public var codex: String
    /// Directory holding `auth.json` (read only; copied into the isolated CODEX_HOME).
    public var codexHomeReal: String
    public var parentModel: String
    public var timeoutS: TimeInterval

    public init(claude: String, codex: String, codexHomeReal: String, parentModel: String = "sonnet", timeoutS: TimeInterval = 1500) {
        self.claude = claude
        self.codex = codex
        self.codexHomeReal = codexHomeReal
        self.parentModel = parentModel
        self.timeoutS = timeoutS
    }
}

/// Runs one case against a running strim endpoint. Evidence goes to `runDir`; the token is never written anywhere.
public enum MCPClientsRunner {
    struct ClientRun {
        var repo: URL
        var cap: Proc.Captured
        var fields: [String: Any]
        var register: String
    }

    /// Returns the row JSON (token redacted) and writes `row.json`, `stream.jsonl`, `stderr.txt`, `register.txt`,
    /// `repo_changes.txt` into `runDir` (recreated).
    @discardableResult
    public static func runCase(_ c: MCPClientsCase, endpoint: ServerEndpoint, bins: MCPClientsBins, runDir: URL) throws -> String {
        let fm = FileManager.default
        try? fm.removeItem(at: runDir)
        try fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        // Secrets (mcp.json, auth copy), fixture, the Claude client's private TMPDIR and the check scratch live in separate
        // mkdtemp(3) 0700 dirs outside the repo; all removed on exit.
        let secrets = try makeWorkDir("secret")
        let repoRoot = try makeWorkDir("repo")
        let scratch = try makeWorkDir("scratch")
        let clientTmp = try makeWorkDir("ctmp")
        defer { for d in [secrets, repoRoot, scratch, clientTmp] { try? fm.removeItem(at: d) } }
        let token = endpoint.token

        let run: ClientRun
        switch c.client {
        case .claude: run = try runClaude(c, endpoint: endpoint, bins: bins, secrets: secrets, repoRoot: repoRoot,
                                          clientTmp: clientTmp, runDir: runDir)
        case .codex: run = try runCodex(c, endpoint: endpoint, bins: bins, secrets: secrets, repoRoot: repoRoot)
        }
        // The client has exited: its config and auth copy are no longer needed and must not be visible to check code.
        try? fm.removeItem(at: secrets)
        try writeEvidence(runDir, cap: run.cap, register: run.register, token: token)

        var check: (ok: Bool?, detail: String) = (nil, "n/a")
        if c.checksFix {
            let r = try MCPClientsFixture.checkSlugifyFix(repo: run.repo, scratch: scratch)
            check = (r.ok, r.detail)
            try Data(MCPClientsConfig.redact(r.output, token: token).utf8).write(to: runDir.appendingPathComponent("check_output.txt"))
        }
        try Data(repoChanges(run.repo).utf8).write(to: runDir.appendingPathComponent("repo_changes.txt"))

        var row = run.fields
        row.merge([
            "run": c.name, "client": c.client.rawValue, "rc": Int(run.cap.result.exitCode), "wall_s": round1(run.cap.result.wallS),
            "check_ok": orNull(check.ok), "check_detail": check.detail,
        ]) { a, _ in a }
        let redacted = MCPClientsConfig.redact(try jsonText(row), token: token)
        try Data(redacted.utf8).write(to: runDir.appendingPathComponent("row.json"))
        return redacted
    }

    static func runClaude(_ c: MCPClientsCase, endpoint: ServerEndpoint, bins: MCPClientsBins, secrets: URL, repoRoot: URL,
                          clientTmp: URL, runDir: URL) throws -> ClientRun {
        let repo = try MCPClientsFixture.makeRepo(in: repoRoot)
        let prompt = c.prompt.replacingOccurrences(of: "<REPO>", with: repo.path)
        var register = "client: claude (parent model \(bins.parentModel)), mcp: \(c.useMCP), sandbox: client under sandbox-exec\n"
        var mcpPath: String?
        if c.useMCP {
            let cfg = secrets.appendingPathComponent("mcp.json")
            try writeSecret(try MCPClientsConfig.claudeConfigJSON(port: endpoint.port), to: cfg)
            mcpPath = cfg.path
            register += "--mcp-config <0600 file in private temp dir>: \(MCPClientsConfig.url(port: endpoint.port)), "
                + "Authorization: Bearer ${\(MCPClientsConfig.tokenEnvVar)} (value only in the child environment)\n"
        }
        let argv = MCPClientsArgv.claude(prompt: prompt, model: bins.parentModel, mcpConfig: mcpPath, repo: repo.path,
                                         home: NSHomeDirectory(),
                                         denyDirs: [secrets.path, runDir.deletingLastPathComponent().path])
        // Sandbox is the boundary: writes only in the fixture and the client's private tmp; reads of the home denied;
        // outbound network only (the real client needs Anthropic, so its network is not narrowed to loopback).
        // The sandbox denies the shared temp areas, so the one config file the client must read is re-allowed by itself.
        let profile = ClaudeSandbox.profile(workdir: repo.path, runDir: clientTmp.path, net: .anthropic, claudeBin: bins.claude,
                                            extraReadable: mcpPath.map { [$0] } ?? [], keychainFile: ClaudeSandbox.loginKeychain())
        let tmp = clientTmp.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // The token is in the client's environment only on MCP arms (Claude's header expansion needs it there).
        var extra = ["TMPDIR": tmp.path, ClaudeSandbox.claudeTmpEnvVar: ClaudeSandbox.prepareClaudeTmp(runDir: clientTmp.path)]
        if c.useMCP { extra[MCPClientsConfig.tokenEnvVar] = endpoint.token }
        let env = MCPClientsConfig.cleanEnvironment(extra: extra)
        let cap = try Proc.runCaptured(argv: ClaudeSandbox.wrap([bins.claude] + argv, profile: profile), env: env,
                                       cwd: repo.path, timeout: bins.timeoutS)
        let st = ClaudeStreamStats.parse(cap.text)
        return ClientRun(repo: repo, cap: cap, fields: claudeStreamFields(st, token: endpoint.token, parentModel: bins.parentModel,
                                                                           mcp: c.useMCP), register: register)
    }

    static func runCodex(_ c: MCPClientsCase, endpoint: ServerEndpoint, bins: MCPClientsBins, secrets: URL,
                         repoRoot: URL) throws -> ClientRun {
        let repo = try MCPClientsFixture.makeRepo(in: repoRoot)
        let prompt = c.prompt.replacingOccurrences(of: "<REPO>", with: repo.path)
        // Isolated CODEX_HOME: auth copied in, config written directly (same content as `codex mcp add` + the approve line).
        let home = secrets.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let auth = try Data(contentsOf: URL(fileURLWithPath: bins.codexHomeReal).appendingPathComponent("auth.json"))
        try writeSecret(auth, to: home.appendingPathComponent("auth.json"))
        let toml = MCPClientsConfig.codexConfigTOML(port: endpoint.port)
        try Data(toml.utf8).write(to: home.appendingPathComponent("config.toml"))
        let env = MCPClientsConfig.cleanEnvironment(extra: ["CODEX_HOME": home.path,
                                                            MCPClientsConfig.tokenEnvVar: endpoint.token])
        let list = try Proc.runCaptured(argv: [bins.codex, "mcp", "list"], env: env, cwd: secrets.path, timeout: 60, mergeStderr: true)
        let register = "--- config.toml\n\(toml)--- codex mcp list (rc \(list.result.exitCode))\n\(list.text)"
        let cap = try Proc.runCaptured(argv: [bins.codex] + MCPClientsArgv.codex(prompt: prompt, repo: repo.path), env: env,
                                       cwd: repo.path, timeout: bins.timeoutS)
        let st = CodexStreamStats.parse(cap.text, token: endpoint.token)
        return ClientRun(repo: repo, cap: cap, fields: codexStreamFields(st), register: register)
    }

    /// Row fields that come from a Claude stream (the committed row.json schema, minus run-level fields).
    public static func claudeStreamFields(_ st: ClaudeStreamStats, token: String, parentModel: String, mcp: Bool) -> [String: Any] {
        let res = st.result ?? [:]
        let u = (res["usage"] as? [String: Any]) ?? [:]
        let resultText = MCPClientsConfig.redact((res["result"] as? String) ?? "None", token: token)
        return [
            "model_alias": parentModel, "mcp": mcp,
            "polls": st.polls, "task_calls": st.taskCalls, "ask_calls": st.askCalls,
            "apply_ok": orNull(st.applyOK), "turns": orNull(res["num_turns"]),
            "in": orNull(u["input_tokens"]), "out": orNull(u["output_tokens"]),
            "cache_create": orNull(u["cache_creation_input_tokens"]), "cache_read": orNull(u["cache_read_input_tokens"]),
            "cost_usd": orNull(res["total_cost_usd"]), "first_turn": st.firstTurn, "tools_used": st.tools,
            "init_mcp": st.initMCP, "n_init_tools": st.initToolCount,
            "result_text": String(resultText.prefix(600)), "is_error": orNull(res["is_error"]),
            "model_usage": orNull(res["modelUsage"]),
        ]
    }

    /// Row fields that come from a Codex stream.
    public static func codexStreamFields(_ st: CodexStreamStats) -> [String: Any] {
        ["polls": st.polls, "usage": st.usage, "calls": st.calls, "errors": st.errors, "agent_text": st.agentText]
    }

    /// Changed or unexpected files in the fixture, by name only (no `git` run: a model-written .git/config could execute code).
    static func repoChanges(_ repo: URL) -> String {
        let v = MCPClientsFixture.allowlistViolations(repo: repo)
        return v.isEmpty ? "allowlist: clean (only \(MCPClientsFixture.fixFile) may change)\n"
            : "allowlist violations:\n" + v.map { "  \($0)\n" }.joined()
    }

    /// Stream, stderr and the registration text, all redacted.
    static func writeEvidence(_ runDir: URL, cap: Proc.Captured, register: String, token: String) throws {
        let red = { (s: String) in MCPClientsConfig.redact(s, token: token) }
        try Data(red(cap.text).utf8).write(to: runDir.appendingPathComponent("stream.jsonl"))
        try Data(red(String(decoding: cap.stderr, as: UTF8.self)).utf8).write(to: runDir.appendingPathComponent("stderr.txt"))
        try Data(red(register).utf8).write(to: runDir.appendingPathComponent("register.txt"))
    }

    /// Fresh 0700 directory from mkdtemp(3), outside the repo.
    static func makeWorkDir(_ tag: String) throws -> URL {
        var tmpl = Array((NSTemporaryDirectory() + "mcpc-\(tag)-XXXXXXXX").utf8CString)
        guard mkdtemp(&tmpl) != nil else { throw MCPClientsError.failed("mkdtemp failed for \(tag)") }
        return URL(fileURLWithPath: String(cString: tmpl))
    }

    static func writeSecret(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw MCPClientsError.failed("cannot write \(url.lastPathComponent)")
        }
    }

    static func jsonText(_ row: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
