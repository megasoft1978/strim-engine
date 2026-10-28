import Foundation

/// Isolated client registration for the strim MCP server. The bearer token is never written to a file: Claude's
/// config references it as `${STRIM_MCP_TOKEN}` and Codex names the env var; the value only exists in the child's
/// environment (Claude's Read tool can read the config file, so it must not contain the token).
public enum MCPClientsConfig {
    public static let serverName = "strim"
    public static let tokenEnvVar = "STRIM_MCP_TOKEN"
    public static let redacted = "<redacted>"

    public static func url(port: UInt16) -> String { "http://127.0.0.1:\(port)/mcp" }

    /// Claude `--mcp-config` document. Claude Code expands `${VAR}` in headers from its own environment.
    public static func claudeConfigJSON(port: UInt16) throws -> Data {
        let server: [String: Any] = [
            "type": "http",
            "url": url(port: port),
            "headers": ["Authorization": "Bearer ${\(tokenEnvVar)}"],
        ]
        return try JSONSerialization.data(withJSONObject: ["mcpServers": [serverName: server]], options: [.sortedKeys])
    }

    /// Codex `config.toml` for an isolated CODEX_HOME. The token is referenced by env var name only.
    public static func codexConfigTOML(port: UInt16) -> String {
        """
        [mcp_servers.strim]
        url = "\(url(port: port))"
        bearer_token_env_var = "\(tokenEnvVar)"
        default_tools_approval_mode = "approve"

        [shell_environment_policy]
        exclude = ["\(tokenEnvVar)"]

        """
    }

    /// Replaces every occurrence of the token. Applied to every stream, log, row and register file before it is written.
    public static func redact(_ s: String, token: String) -> String {
        token.isEmpty ? s : s.replacingOccurrences(of: token, with: redacted)
    }

    /// Every spelling a permission rule may see for `path`: as given (trailing slash dropped), its realpath(3) form when
    /// it exists, and the /var, /tmp and /etc <-> /private pairs of each. Rules match the spelling the tool used, so all
    /// of them are emitted. (`URL.resolvingSymlinksInPath()` does not map /var to /private/var, so it is not used.)
    public static func pathSpellings(_ path: String) -> [String] {
        var base = path
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        var out = [base]
        if let r = realpath(base, nil) {
            let resolved = String(cString: r)
            free(r)
            if !out.contains(resolved) { out.append(resolved) }
        }
        let pairs = [("/var", "/private/var"), ("/tmp", "/private/tmp"), ("/etc", "/private/etc")]
        var i = 0
        while i < out.count {
            let p = out[i]
            for (a, b) in pairs {
                for (from, to) in [(a, b), (b, a)] where p == from || p.hasPrefix(from + "/") {
                    let alt = to + String(p.dropFirst(from.count))
                    if !out.contains(alt) { out.append(alt) }
                }
            }
            i += 1
        }
        return out
    }

    /// Parent environment minus the vars that would change how the clients authenticate or pick a session.
    public static func cleanEnvironment(extra: [String: String] = [:]) -> [String: String] {
        let stripped = ["CLAUDE_CODE_", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "ANTHROPIC_", "CODEX_", "OPENAI_"]
        var env = ProcessInfo.processInfo.environment.filter { k, _ in !stripped.contains { k.hasPrefix($0) } }
        for (k, v) in extra { env[k] = v }
        return env
    }
}

/// Client argv. Prompts are the only user text; no token is ever formatted into these.
///
/// Neither Claude arm has a shell tool. Bash prefix rules were bypassable (`go test` runs arbitrary code through
/// TestMain, go:generate, cgo, GOFLAGS and -exec), so the harness runs the fixture check after the client exits.
/// Permission rules below are defense in depth; the sandbox around the client is the boundary.
public enum MCPClientsArgv {
    public static let strimTools = ["mcp__strim__strim_task", "mcp__strim__strim_job", "mcp__strim__strim_cancel", "mcp__strim__strim_ask"]
    /// MCP arm: the only built-ins are Read and Edit, scoped to the fixture below.
    public static let mcpTools = "Read,Edit"
    /// Baseline arm: file tools only, scoped to the fixture below.
    public static let baselineTools = "Read,Edit,Write,Glob,Grep"

    /// `claude -p` with the same flags as the retired driver.
    /// `repo`: the fixture (every realpath spelling is emitted). `home`: the user's home (never readable by the client).
    /// `denyDirs`: secret dir and evidence runs dir (never readable, editable or writable by the client).
    /// MCP arm allows Read of the repo and Edit of only `text.go`; baseline allows Read/Edit/Write under the repo.
    public static func claude(prompt: String, model: String, mcpConfig: String?, repo: String, home: String,
                              denyDirs: [String] = []) -> [String] {
        let mcp = mcpConfig != nil
        var argv = ["-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose",
                    "--permission-mode", "dontAsk", "--no-session-persistence", "--setting-sources", "",
                    "--tools", mcp ? mcpTools : baselineTools]
        var deny = ["Read(~/**)"]
        for d in denyDirs + [home] {
            for s in MCPClientsConfig.pathSpellings(d) { for t in ["Read", "Edit", "Write"] { deny.append("\(t)(/\(s)/**)") } }
        }
        for s in MCPClientsConfig.pathSpellings(repo + "/.git") { for t in ["Edit", "Write"] { deny.append("\(t)(/\(s)/**)") } }
        argv += ["--disallowedTools"] + deny
        if let mcpConfig {
            var allow = strimTools
            for s in MCPClientsConfig.pathSpellings(repo) {
                allow += ["Read(/\(s)/**)", "Edit(/\(s)/\(MCPClientsFixture.fixFile))"]
            }
            argv += ["--strict-mcp-config", "--mcp-config", mcpConfig, "--allowedTools"] + allow
        } else {
            var allow = ["Glob", "Grep"]
            for s in MCPClientsConfig.pathSpellings(repo) {
                for t in ["Read", "Edit", "Write"] { allow.append("\(t)(/\(s)/**)") }
            }
            argv += ["--strict-mcp-config", "--allowedTools"] + allow
        }
        return argv
    }

    /// `codex exec` in workspace-write with approval_policy=never (the MCP approval line lives in the isolated config).
    public static func codex(prompt: String, repo: String) -> [String] {
        ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "-C", repo, "-s", "workspace-write",
         "-c", "approval_policy=\"never\"", "--", prompt]
    }
}
