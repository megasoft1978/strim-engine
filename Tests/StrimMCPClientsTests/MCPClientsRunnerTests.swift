import Foundation
import Testing
@testable import StrimMCPClients
import StrimAgentBench

private let token = "tok-SECRET-runner-5d1e9a"

private func scratch(_ name: String) throws -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcpc-test-\(name)-\(UUID().uuidString.prefix(8).lowercased())")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func stub(_ dir: URL, _ name: String, _ body: String) throws -> String {
    let p = dir.appendingPathComponent(name)
    try Data("#!/bin/sh\nD='\(dir.path)'\n\(body)\n".utf8).write(to: p)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
    return p.path
}

/// Fake `claude`, run under the real sandbox-exec wrapper. It writes nothing; every observation goes to stderr,
/// which the harness stores redacted. It prints each argv element, the child's own token value, the mcp config and its
/// mode, a scan of the repo and secret dir for the token, and whether the home dir is readable from inside the sandbox.
private let claudeStub = #"""
for a in "$@"; do printf 'ARG %s\n' "$a" >&2; done
cfg=""; prev=""
for a in "$@"; do if [ "$prev" = "--mcp-config" ]; then cfg="$a"; fi; prev="$a"; done
printf 'CHILD_TOKEN=%s\n' "$STRIM_MCP_TOKEN" >&2
if [ -n "$cfg" ]; then
  printf 'CFG_MODE=%s\n' "$(stat -f %Lp "$cfg")" >&2
  cat "$cfg" >&2
  printf '\n' >&2
  grep -rlF "$STRIM_MCP_TOKEN" "$PWD" "$(dirname "$cfg")" 2>/dev/null | sed 's/^/SCAN_HIT /' >&2
fi
if ls "$HOME" >/dev/null 2>&1; then echo PROBE_HOME=readable >&2; else echo PROBE_HOME=denied >&2; fi
cat <<'EOF'
{"type":"system","subtype":"init","tools":["Read","mcp__strim__strim_job"],"mcp_servers":[{"name":"strim","status":"connected"}]}
{"type":"assistant","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":5,"cache_read_input_tokens":7},"content":[{"type":"tool_use","id":"t1","name":"mcp__strim__strim_job","input":{}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false}]}}
{"type":"result","num_turns":2,"result":"ok","usage":{"input_tokens":4,"output_tokens":9,"cache_creation_input_tokens":5,"cache_read_input_tokens":7},"total_cost_usd":0.01,"is_error":false}
EOF
echo "leak $STRIM_MCP_TOKEN"
"""#

/// Fake `codex`: `mcp list` prints a line; `exec` scans its repo and CODEX_HOME, records config and env.
private let codexStub = #"""
if [ "$1" = "mcp" ]; then echo "strim enabled"; exit 0; fi
printf '%s\n' "$@" > "$D/argv.txt"
printf '%s' "$STRIM_MCP_TOKEN" > "$D/child-token.txt"
cp "$CODEX_HOME/config.toml" "$D/config.toml"
grep -rlF "$STRIM_MCP_TOKEN" "$PWD" "$CODEX_HOME" > "$D/scan.txt" 2>/dev/null || true
cat <<'EOF'
{"type":"item.completed","item":{"type":"mcp_tool_call","server":"strim","tool":"strim_ask","status":"completed"}}
{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":3}}
EOF
printf '{"type":"item.completed","item":{"type":"agent_message","text":"token is %s"}}\n' "$STRIM_MCP_TOKEN"
"""#

private func readFile(_ dir: URL, _ name: String) throws -> String {
    try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
}

private func evidenceFiles(_ dir: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
}

@Test func claudeStubRunDeliversTokenOnlyToChildEnvironment() throws {
    let root = try scratch("claude")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = try stub(root, "claude", claudeStub)
    let runDir = root.appendingPathComponent("runs/claude_a_ask")
    let ep = ServerEndpoint(port: 8299, token: token, modelId: "stub")
    let bins = MCPClientsBins(claude: bin, codex: bin, codexHomeReal: root.path)

    let text = try MCPClientsRunner.runCase(MCPClientsCases.named("claude_a_ask")!, endpoint: ep, bins: bins, runDir: runDir)

    // stderr is stored redacted, so "<redacted>" in CHILD_TOKEN proves the child's environment held the token.
    let diag = try readFile(runDir, "stderr.txt")
    #expect(diag.contains("CHILD_TOKEN=<redacted>"), "token missing from the MCP arm's environment")
    #expect(!diag.contains("SCAN_HIT"), "token found in repo or secret dir during the run")
    #expect(diag.contains("CFG_MODE=600"))
    #expect(diag.contains("Bearer ${STRIM_MCP_TOKEN}"))
    #expect(diag.contains("ARG --mcp-config"))
    #expect(diag.contains("ARG Read(//"))
    #expect(!diag.contains("Bash"), "MCP arm must have no shell tool")
    // The client ran under sandbox-exec: the home dir was not readable from inside it.
    #expect(diag.contains("PROBE_HOME=denied"), "client could read the home dir")
    #expect(!diag.contains(token))
    // Evidence: no file under the run dir holds the token; the child's leak line is redacted in the stream.
    for f in try evidenceFiles(runDir) {
        #expect(!(try String(contentsOf: f, encoding: .utf8)).contains(token), "token leaked into \(f.lastPathComponent)")
    }
    #expect(try readFile(runDir, "stream.jsonl").contains("leak <redacted>"))
    #expect(!text.contains(token))

    let row = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(row["client"] as? String == "claude")
    #expect(row["mcp"] as? Bool == true)
    #expect(row["rc"] as? Int == 0)
    #expect(row["polls"] as? Int == 1)
    #expect(row["in"] as? Int == 4)
    #expect(row["out"] as? Int == 9)
    #expect(row["cache_read"] as? Int == 7)
    #expect(row["check_ok"] is NSNull)
    #expect(row["check_detail"] as? String == "n/a")
    #expect(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("repo_changes.txt").path))
}

@Test func codexStubRunIsolatesHomeAndRedactsTokenEcho() throws {
    let root = try scratch("codex")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = try stub(root, "codex", codexStub)
    try Data("{}".utf8).write(to: root.appendingPathComponent("auth.json"))
    let runDir = root.appendingPathComponent("runs/codex_a_ask")
    let ep = ServerEndpoint(port: 8299, token: token, modelId: "stub")
    let bins = MCPClientsBins(claude: bin, codex: bin, codexHomeReal: root.path)

    let text = try MCPClientsRunner.runCase(MCPClientsCases.named("codex_a_ask")!, endpoint: ep, bins: bins, runDir: runDir)

    #expect(try readFile(root, "child-token.txt") == token)
    #expect(try readFile(root, "scan.txt").isEmpty, "token found in repo or CODEX_HOME during the run")
    let argv = try readFile(root, "argv.txt")
    #expect(argv.contains("approval_policy=\"never\""))
    #expect(!argv.contains(token))
    let toml = try readFile(root, "config.toml")
    #expect(toml.contains("default_tools_approval_mode = \"approve\""))
    #expect(toml.contains("bearer_token_env_var = \"STRIM_MCP_TOKEN\""))
    #expect(!toml.contains(token))
    for f in try evidenceFiles(runDir) {
        #expect(!(try String(contentsOf: f, encoding: .utf8)).contains(token), "token leaked into \(f.lastPathComponent)")
    }
    #expect(!text.contains(token))
    let row = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(row["client"] as? String == "codex")
    #expect(row["polls"] as? Int == 0)
    #expect((row["agent_text"] as? [String])?.first == "token is <redacted>")
    let usage = try #require(row["usage"] as? [String: Any])
    #expect(usage["output_tokens"] as? Int == 3)
    let calls = try #require(row["calls"] as? [[String: Any]])
    #expect(calls.first?["tool"] as? String == "strim_ask")
}

@Test func fixtureTemplateIsGoAndOnlyTextGoMayChange() {
    #expect(MCPClientsFixture.template.map(\.path) == ["go.mod", "text.go", "text_test.go"])
    #expect(MCPClientsFixture.templateText("text_test.go")?.contains("func TestSlugifyPunctuation") == true)
    #expect(MCPClientsFixture.fixFile == "text.go")
    #expect(MCPClientsFixture.testFile == "text_test.go")
}

@Test func claudeNoMcpArmGetsNoTokenInItsEnvironment() throws {
    // Baseline arm: no shell either, but the token must still be absent from the client's environment.
    let root = try scratch("nomcp")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = try stub(root, "claude", claudeStub)
    let runDir = root.appendingPathComponent("runs/claude_d_nomcp_hello")
    let ep = ServerEndpoint(port: 8299, token: token, modelId: "stub")
    let bins = MCPClientsBins(claude: bin, codex: bin, codexHomeReal: root.path)

    let text = try MCPClientsRunner.runCase(MCPClientsCases.named("claude_d_nomcp_hello")!, endpoint: ep, bins: bins, runDir: runDir)

    let diag = try readFile(runDir, "stderr.txt")
    #expect(diag.contains("CHILD_TOKEN=\n"), "token reached the no-MCP arm environment")
    #expect(!diag.contains("--mcp-config"))
    #expect(!diag.contains("Bash"), "baseline arm must have no shell tool")
    #expect(diag.contains("PROBE_HOME=denied"))
    #expect(!text.contains(token))
    for f in try evidenceFiles(runDir) {
        #expect(!(try String(contentsOf: f, encoding: .utf8)).contains(token), "token leaked into \(f.lastPathComponent)")
    }
}

/// Secrets (mcp.json, Codex auth copy) live in mkdtemp(3) directories that only the owner can enter, and secret
/// files are 0600 (review 2026-10-28: the mode was never asserted).
@Test func workDirsAreOwnerOnly0700AndSecretFilesAre0600() throws {
    let fm = FileManager.default
    var dirs: [URL] = []
    defer { for d in dirs { try? fm.removeItem(at: d) } }
    for tag in ["secret", "repo", "scratch", "ctmp"] {
        let d = try MCPClientsRunner.makeWorkDir(tag)
        dirs.append(d)
        var st = stat()
        #expect(lstat(d.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700, "\(tag): mode \(String(st.st_mode & 0o777, radix: 8))")
        #expect(st.st_uid == getuid())
        #expect((st.st_mode & S_IFMT) == S_IFDIR)
    }
    #expect(Set(dirs.map(\.path)).count == dirs.count, "work dirs must be distinct")
    let f = dirs[0].appendingPathComponent("auth.json")
    try MCPClientsRunner.writeSecret(Data("x".utf8), to: f)
    var st = stat()
    #expect(lstat(f.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
}
