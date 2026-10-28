import Foundation
import Testing
@testable import StrimMCPClients

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
}

private func fixtureText(_ name: String) throws -> String {
    try String(contentsOf: fixtureURL(name), encoding: .utf8)
}

private func fixtureRow(_ name: String) throws -> [String: Any] {
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL(name)))
    return try #require(obj as? [String: Any])
}

/// Canonical JSON text of one value, so NSNull, numbers and nested objects compare exactly.
private func canon(_ v: Any?) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["v": v ?? NSNull()], options: [.sortedKeys, .fragmentsAllowed])
    return String(decoding: data, as: UTF8.self)
}

// Golden: the parser + row builder must reproduce the committed rows (rerun/runs, stock release build) field by field.

@Test(arguments: ["claude_a_ask", "claude_b_fix_delegated"])
func claudeStreamReproducesCommittedRow(name: String) throws {
    let stream = try fixtureText("\(name).stream.jsonl")
    let row = try fixtureRow("\(name).row.json")
    let fields = MCPClientsRunner.claudeStreamFields(ClaudeStreamStats.parse(stream), token: "", parentModel: "sonnet", mcp: true)
    #expect(!fields.isEmpty)
    for (k, v) in fields {
        #expect(row[k] != nil, "committed row lacks \(k)")
        #expect(canon(v) == canon(row[k]), "\(name).\(k): got \(canon(v)) want \(canon(row[k]))")
    }
}

@Test(arguments: ["codex_a_ask", "codex_b_fix"])
func codexStreamReproducesCommittedRow(name: String) throws {
    let stream = try fixtureText("\(name).stream.jsonl")
    let row = try fixtureRow("\(name).row.json")
    let fields = MCPClientsRunner.codexStreamFields(CodexStreamStats.parse(stream, token: ""))
    #expect(!fields.isEmpty)
    for (k, v) in fields {
        #expect(canon(v) == canon(row[k]), "\(name).\(k): got \(canon(v)) want \(canon(row[k]))")
    }
}

@Test func claudeCountsPollsAndTasksFromToolUse() {
    let s = """
    {"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"mcp__strim__strim_task","input":{}}]}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","id":"b","name":"mcp__strim__strim_job","input":{}}]}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","id":"c","name":"mcp__strim__strim_job","input":{}}]}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","id":"d","name":"mcp__strim__strim_ask","input":{}}]}}
    not json at all
    """
    let st = ClaudeStreamStats.parse(s)
    #expect(st.taskCalls == 1)
    #expect(st.polls == 2)
    #expect(st.askCalls == 1)
    #expect(st.tools.count == 4)
    #expect(st.applyOK == nil)
}

@Test func gitApplyVerdictIgnoresCheckAndTracksErrors() {
    func result(_ cmd: String, isError: Bool) -> String {
        """
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"x\(cmd.count)","name":"Bash","input":{"command":"\(cmd)"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x\(cmd.count)","is_error":\(isError)}]}}
        """
    }
    #expect(ClaudeStreamStats.parse(result("git apply --check p.diff", isError: true)).applyOK == nil)
    #expect(ClaudeStreamStats.parse(result("git apply p.diff", isError: false)).applyOK == true)
    #expect(ClaudeStreamStats.parse(result("git apply p.diff", isError: true)).applyOK == false)
}

@Test func codexRedactsTokenBeforeTruncating() {
    let token = "tok-SECRET-abcdef-0123456789"
    let long = String(repeating: "x", count: 390) + token + String(repeating: "y", count: 50)
    let line = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"\(long)\"}}"
    let st = CodexStreamStats.parse(line, token: token)
    let text = st.agentText.first ?? ""
    #expect(!text.contains("tok-SECRET"))
    #expect(text.count <= 400)
}

@Test func codexErrorLinesAreRedactedAndCapped() {
    let token = "tok-SECRET-err-77"
    let line = "{\"type\":\"error\",\"message\":\"bad \(token)\"}"
    let st = CodexStreamStats.parse(line, token: token)
    #expect(st.errors.count == 1)
    #expect(st.errors.first?.contains(token) == false)
    #expect(st.errors.first?.contains("<redacted>") == true)
}
