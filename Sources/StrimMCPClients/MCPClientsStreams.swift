import Foundation

/// Stream parsers. Values are passed through as parsed JSON (`Any`), NSNull where the client omitted a field, so the
/// rows keep the committed `row.json` shape. Callers redact the final text; Codex text fields are redacted here
/// before truncation so a token cannot survive as a prefix.

func jsonObject(_ line: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
}

func orNull(_ v: Any?) -> Any { v ?? NSNull() }

func dicts(_ v: Any?) -> [[String: Any]] {
    ((v as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
}

/// Facts from `claude -p --output-format stream-json --verbose`.
public struct ClaudeStreamStats {
    public var polls = 0
    public var taskCalls = 0
    public var askCalls = 0
    public var tools: [String] = []
    public var firstTurn: Any = NSNull()
    public var initMCP: Any = NSNull()
    public var initToolCount = 0
    /// nil until a `git apply` (not `--check`) tool result is seen.
    public var applyOK: Bool?
    /// The last `type: result` event.
    public var result: [String: Any]?

    public init() {}

    public static func parse(_ text: String) -> ClaudeStreamStats {
        var st = ClaudeStreamStats()
        var pending: [String: (name: String, command: String)] = [:]
        var firstSeen = false
        for line in text.split(whereSeparator: \.isNewline) {
            guard let ev = jsonObject(String(line)) else { continue }
            let type = ev["type"] as? String
            if type == "system", ev["subtype"] as? String == "init" {
                st.initMCP = orNull(ev["mcp_servers"])
                st.initToolCount = (ev["tools"] as? [Any])?.count ?? 0
            } else if type == "assistant" {
                let msg = (ev["message"] as? [String: Any]) ?? [:]
                if !firstSeen, let u = msg["usage"] as? [String: Any], !u.isEmpty {
                    firstSeen = true
                    var first: [String: Any] = [:]
                    for k in ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] { first[k] = orNull(u[k]) }
                    st.firstTurn = first
                }
                for b in dicts(msg["content"]) where b["type"] as? String == "tool_use" {
                    let name = (b["name"] as? String) ?? ""
                    let input = (b["input"] as? [String: Any]) ?? [:]
                    if let id = b["id"] as? String { pending[id] = (name, (input["command"] as? String) ?? "") }
                    st.tools.append(name)
                    if name == "mcp__strim__strim_job" { st.polls += 1 }
                    if name == "mcp__strim__strim_task" { st.taskCalls += 1 }
                    if name == "mcp__strim__strim_ask" { st.askCalls += 1 }
                }
            } else if type == "user" {
                let msg = (ev["message"] as? [String: Any]) ?? [:]
                for b in dicts(msg["content"]) where b["type"] as? String == "tool_result" {
                    guard let id = b["tool_use_id"] as? String, let p = pending[id] else { continue }
                    if p.name == "Bash", p.command.contains("git apply"), !p.command.contains("--check") {
                        st.applyOK = (b["is_error"] as? Bool) != true
                    }
                }
            } else if type == "result" {
                st.result = ev
            }
        }
        return st
    }
}

/// Facts from `codex exec --json`.
public struct CodexStreamStats {
    /// The last `turn.completed` usage object, passed through.
    public var usage: Any = NSNull()
    public var polls = 0
    public var calls: [[String: Any]] = []
    public var errors: [String] = []
    public var agentText: [String] = []

    public init() {}

    public static func parse(_ text: String, token: String) -> CodexStreamStats {
        var st = CodexStreamStats()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let ev = jsonObject(String(line)) else { continue }
            let type = (ev["type"] as? String) ?? ""
            if type == "turn.completed" { st.usage = orNull(ev["usage"]) }
            let it = (ev["item"] as? [String: Any]) ?? [:]
            let itType = (it["type"] as? String) ?? ""
            if ["mcp_tool_call", "tool_call", "command_execution"].contains(itType), type == "item.completed" {
                var call: [String: Any] = ["type": itType]
                for k in ["server", "tool", "name", "status", "command", "error"] { call[k] = orNull(it[k]) }
                st.calls.append(call)
                let tool = truthy(it["tool"]) ? it["tool"]! : orNull(it["name"])
                if String(describing: tool).contains("strim_job") { st.polls += 1 }
            }
            if type == "error" || type == "turn.failed" {
                st.errors.append(String(MCPClientsConfig.redact(String(line), token: token).prefix(300)))
            }
            if itType == "agent_message" {
                let t = MCPClientsConfig.redact((it["text"] as? String) ?? "None", token: token)
                st.agentText.append(String(t.prefix(400)))
            }
        }
        return st
    }

    /// Python-style truthiness for the `tool or name` lookup: empty string and null are false.
    static func truthy(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return false }
        if let s = v as? String { return !s.isEmpty }
        return true
    }
}
