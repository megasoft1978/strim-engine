import Foundation
import Testing
@testable import StrimMCPClients

private let secretToken = "tok-SECRET-test-9f3a2c7e1b"

private func tempDir(_ name: String) throws -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcpc-cfg-\(name)-\(UUID().uuidString.prefix(8).lowercased())")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func value(_ argv: [String], after flag: String) -> [String] {
    guard let i = argv.firstIndex(of: flag) else { return [] }
    return Array(argv[(i + 1)...].prefix { !$0.hasPrefix("--") })
}

private func claudeArgv(mcp: Bool, repo: String = "/var/folders/r/repo", denyDirs: [String] = ["/var/folders/s/secret", "/var/folders/s/runs"]) -> [String] {
    MCPClientsArgv.claude(prompt: "p", model: "sonnet", mcpConfig: mcp ? "/var/folders/s/mcp.json" : nil,
                          repo: repo, home: "/Users/tester", denyDirs: denyDirs)
}

@Test func claudeConfigReferencesTokenThroughEnvOnly() throws {
    let data = try MCPClientsConfig.claudeConfigJSON(port: 8212)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("tok-"))
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let servers = try #require(obj["mcpServers"] as? [String: Any])
    let strim = try #require(servers["strim"] as? [String: Any])
    #expect(strim["type"] as? String == "http")
    #expect(strim["url"] as? String == "http://127.0.0.1:8212/mcp")
    let headers = try #require(strim["headers"] as? [String: Any])
    #expect(headers["Authorization"] as? String == "Bearer ${STRIM_MCP_TOKEN}")
}

@Test func codexConfigReferencesTokenByEnvVarOnlyAndExcludesItFromShell() {
    let toml = MCPClientsConfig.codexConfigTOML(port: 8299)
    #expect(toml.contains("[mcp_servers.strim]"))
    #expect(toml.contains("url = \"http://127.0.0.1:8299/mcp\""))
    #expect(toml.contains("bearer_token_env_var = \"STRIM_MCP_TOKEN\""))
    #expect(toml.contains("default_tools_approval_mode = \"approve\""))
    #expect(toml.contains("[shell_environment_policy]\nexclude = [\"STRIM_MCP_TOKEN\"]"))
    #expect(!toml.contains("Bearer"))
    #expect(!toml.contains(secretToken))
}

@Test func claudeArgvHasNoShellOnEitherArm() {
    for mcp in [true, false] {
        let argv = claudeArgv(mcp: mcp)
        #expect(!argv.contains { $0.contains("Bash") }, "a shell tool or Bash rule leaked into argv (mcp: \(mcp))")
        #expect(!argv.contains { $0.hasPrefix("git ") || $0.hasPrefix("Bash") }, "a git command rule leaked (mcp: \(mcp))")
    }
    #expect(value(claudeArgv(mcp: true), after: "--tools") == ["Read,Edit"])
    #expect(value(claudeArgv(mcp: false), after: "--tools") == ["Read,Edit,Write,Glob,Grep"])
}

@Test func mcpArmHasOnlyStrimToolsAndRepoScopedReadEditOfTheFixFile() {
    let argv = claudeArgv(mcp: true)
    let allowed = value(argv, after: "--allowedTools")
    #expect(allowed.contains("mcp__strim__strim_job"))
    #expect(!allowed.contains("Read"), "bare Read would allow every path")
    #expect(!allowed.contains("Edit"), "bare Edit would allow every path")
    #expect(!allowed.contains { $0.hasPrefix("Write") || $0.hasPrefix("Glob") || $0.hasPrefix("Grep") })
    for spelling in ["/var/folders/r/repo", "/private/var/folders/r/repo"] {
        #expect(allowed.contains("Read(/\(spelling)/**)"), "missing \(spelling) read scope")
        #expect(allowed.contains("Edit(/\(spelling)/text.go)"), "missing \(spelling) edit scope")
    }
    #expect(allowed.allSatisfy { !$0.contains("Edit(/") || $0.hasSuffix("/text.go)") }, "edit scope wider than text.go")
    #expect(!argv.joined(separator: " ").contains("Bearer"))
}

@Test func baselineArmIsRepoScopedWithoutTokenOrMcp() {
    let argv = claudeArgv(mcp: false)
    #expect(!argv.contains("--mcp-config"))
    #expect(!argv.contains { $0.hasPrefix("mcp__strim") })
    let allowed = value(argv, after: "--allowedTools")
    for spelling in ["/var/folders/r/repo", "/private/var/folders/r/repo"] {
        #expect(allowed.contains("Read(/\(spelling)/**)"))
        #expect(allowed.contains("Edit(/\(spelling)/**)"))
        #expect(allowed.contains("Write(/\(spelling)/**)"))
    }
}

@Test func denyRulesCoverHomeSecretRunsAndGitInBothSpellings() {
    let deny = value(claudeArgv(mcp: true), after: "--disallowedTools")
    #expect(deny.contains("Read(~/**)"))
    #expect(deny.contains("Read(//Users/tester/**)"))
    for spelling in ["/var/folders/s/secret", "/private/var/folders/s/secret"] {
        #expect(deny.contains("Read(/\(spelling)/**)"), "secret dir \(spelling) readable")
        #expect(deny.contains("Edit(/\(spelling)/**)"))
        #expect(deny.contains("Write(/\(spelling)/**)"))
    }
    for spelling in ["/var/folders/s/runs", "/private/var/folders/s/runs"] {
        #expect(deny.contains("Read(/\(spelling)/**)"), "runs dir \(spelling) readable")
    }
    for spelling in ["/var/folders/r/repo", "/private/var/folders/r/repo"] {
        #expect(deny.contains("Edit(/\(spelling)/.git/**)"))
        #expect(deny.contains("Write(/\(spelling)/.git/**)"))
    }
}

@Test func pathSpellingsContainOriginalAndPrivateVariants() {
    let v = MCPClientsConfig.pathSpellings("/var/folders/x/secret")
    #expect(v.contains("/var/folders/x/secret"))
    #expect(v.contains("/private/var/folders/x/secret"))
    let p = MCPClientsConfig.pathSpellings("/private/tmp/runs/")
    #expect(p.contains("/private/tmp/runs"))
    #expect(p.contains("/tmp/runs"))
}

@Test func symlinkedSecretDirIsDeniedUnderItsRealPathToo() throws {
    let root = try tempDir("symlink")
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real-secret")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("link-secret")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let realResolved = try #require(MCPClientsConfig.pathSpellings(real.path).first { $0.hasSuffix("real-secret") && $0.hasPrefix("/private/") })

    let argv = MCPClientsArgv.claude(prompt: "p", model: "sonnet", mcpConfig: "\(link.path)/mcp.json", repo: "/var/folders/r/repo",
                                     home: "/Users/tester", denyDirs: [link.path])
    let deny = value(argv, after: "--disallowedTools")
    #expect(deny.contains("Read(/\(link.path)/**)"), "symlink path not denied")
    #expect(deny.contains("Read(/\(realResolved)/**)"), "resolved real path not denied")
    for t in ["Read", "Edit", "Write"] {
        #expect(deny.contains("\(t)(/\(realResolved)/**)"))
    }
}

@Test func codexArgvHasApprovalPolicyAndNoToken() {
    let argv = MCPClientsArgv.codex(prompt: "do it", repo: "/tmp/r")
    #expect(argv.contains("approval_policy=\"never\""))
    #expect(argv.last == "do it")
    #expect(!argv.joined(separator: " ").contains(secretToken))
}

@Test func cleanEnvironmentStripsClientAuthVarsAndAddsExtras() {
    let env = MCPClientsConfig.cleanEnvironment(extra: ["CODEX_HOME": "/h", "STRIM_MCP_TOKEN": secretToken])
    #expect(env["CODEX_HOME"] == "/h")
    #expect(env["STRIM_MCP_TOKEN"] == secretToken)
    #expect(!env.keys.contains { $0.hasPrefix("ANTHROPIC_") || $0.hasPrefix("OPENAI_") || $0 == "CLAUDECODE" })
}

@Test func redactReplacesEveryOccurrenceAndNoopsOnEmptyToken() {
    let s = "a \(secretToken) b \(secretToken)"
    #expect(MCPClientsConfig.redact(s, token: secretToken) == "a <redacted> b <redacted>")
    #expect(MCPClientsConfig.redact(s, token: "") == s)
}

@Test func caseTableMatchesRetiredDriver() {
    let names = MCPClientsCases.all.map(\.name)
    #expect(names == ["claude_a_ask", "claude_b_fix_delegated", "claude_c_fix_alone", "claude_d_nomcp_hello",
                      "claude_e_mcp_hello", "codex_a_ask", "codex_b_fix"])
    #expect(MCPClientsCases.named("claude_c_fix_alone")?.useMCP == false)
    #expect(MCPClientsCases.named("claude_d_nomcp_hello")?.useMCP == false)
    #expect(MCPClientsCases.all.filter(\.checksFix).map(\.name) == ["claude_b_fix_delegated", "claude_c_fix_alone", "codex_b_fix"])
    #expect(MCPClientsCases.named("claude_b_fix_delegated")?.prompt.contains("cwd=<REPO>") == true)
    // Claude arms have no shell: prompts must not ask them to run commands, and the MCP patch is inline (no file reads).
    #expect(MCPClientsCases.named("claude_c_fix_alone")?.prompt.contains("no shell") == true)
    #expect(MCPClientsCases.named("claude_b_fix_delegated")?.prompt.contains("Do not run any commands") == true)
    #expect(MCPClientsCases.named("nope") == nil)
}

@Test func optionsParseRunAndList() throws {
    let o = try MCPClientsOptions.parse(["run", "claude_a_ask", "--model", "/m", "--port=8213", "--rerun", "--timeout-s", "60"])
    #expect(o.command == .run("claude_a_ask"))
    #expect(o.model == "/m")
    #expect(o.port == 8213)
    #expect(o.rerun)
    #expect(o.timeoutS == 60)
    #expect(try MCPClientsOptions.parse(["list"]).command == .list)
}

@Test func optionsRejectBadInput() {
    #expect(throws: MCPClientsError.self) { try MCPClientsOptions.parse(["run"]) }
    #expect(throws: MCPClientsError.self) { try MCPClientsOptions.parse(["run", "x", "--bogus", "1"]) }
    #expect(throws: MCPClientsError.self) { try MCPClientsOptions.parse(["run", "x", "--port", "0"]) }
    #expect(throws: MCPClientsError.self) { try MCPClientsOptions.parse(["run", "x", "--model"]) }
    #expect(throws: MCPClientsError.self) { try MCPClientsOptions.parse(["frobnicate"]) }
}

/// Review 2026-10-28 (weak tests): structural, not substring, checks of what each arm may use.
@Test func noArmGrantsAShellOrAnyNonFileBuiltinTool() {
    let fileTools: Set<String> = ["Read", "Edit", "Write", "Glob", "Grep"]
    for mcp in [true, false] {
        let argv = claudeArgv(mcp: mcp)
        let tools = Set(value(argv, after: "--tools").flatMap { $0.split(separator: ",").map(String.init) })
        #expect(tools.isSubset(of: fileTools), "unexpected built-in tools \(tools.subtracting(fileTools)) (mcp: \(mcp))")
        let allowed = value(argv, after: "--allowedTools")
        #expect(!allowed.isEmpty)
        for rule in allowed {
            let name = rule.split(separator: "(", maxSplits: 1).first.map(String.init) ?? rule
            #expect(fileTools.contains(name) || MCPClientsArgv.strimTools.contains(name), "allow rule outside the closed set: \(rule)")
            for banned in ["Bash", "Task", "WebFetch", "WebSearch", "NotebookEdit", "KillShell", "BashOutput"] {
                #expect(!name.hasPrefix(banned), "banned tool in allow rules: \(rule)")
            }
        }
        // Every allow rule that names a path must stay inside the fixture.
        for rule in allowed where rule.contains("(") {
            #expect(rule.contains("/var/folders/r/repo") || rule.contains("/private/var/folders/r/repo"), "path rule outside fixture: \(rule)")
        }
        #expect(!argv.contains("--dangerously-skip-permissions") && !argv.contains("bypassPermissions"))
        #expect(value(argv, after: "--permission-mode") == ["dontAsk"])
    }
}

@Test func codexArgvIsWorkspaceWriteWithoutBypass() {
    let argv = MCPClientsArgv.codex(prompt: "p", repo: "/var/folders/r/repo")
    let i = try? #require(argv.firstIndex(of: "-s"))
    #expect(i.map { argv[$0 + 1] } == "workspace-write")
    #expect(!argv.contains { $0.contains("danger") || $0.contains("bypass") })
}
