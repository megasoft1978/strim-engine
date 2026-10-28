import Foundation
import StrimEngine
import StrimHTTP
import StrimTemplate

/// Anthropic Messages API (POST /v1/messages, /v1/messages/count_tokens) over the same engine/session table.
///
/// Request translation goes Anthropic -> OpenAI-style chat body -> `ChatRequest.parse`, so sampling defaults,
/// tool parsing, template kwargs and the conversation fingerprint are shared with /v1/chat/completions.
///
/// Thinking policy: `thinking.type` enabled/adaptive => enable_thinking=true; disabled or absent => false
/// (Anthropic's default is no thinking). The session's reasoning policy is `.disableWhenTools` (the rapid-mlx
/// rule), so a request that declares tools never thinks even when enabled (Claude Code always declares tools).
/// `budget_tokens` is not enforced.
enum AnthropicAdapter {
    struct Translated {
        var chat: OrderedJSON
        var stream: Bool
        var model: String?
    }

    static func translate(_ body: Data, requireMaxTokens: Bool) throws -> Translated {
        guard let text = String(data: body, encoding: .utf8), let root = try? OrderedJSON.parse(text),
              case .object = root else { throw APIError.badRequest("body is not a JSON object") }
        guard let raw = root["messages"]?.arrayValue, !raw.isEmpty else {
            throw APIError.badRequest("messages: Field required (a non-empty list)")
        }

        // System text: the top-level `system` plus any role "system" messages (Claude Code sends some inside
        // `messages`); all merged into one leading system message, since the template wants a single header.
        var systemParts: [String] = []
        if let sys = root["system"], !sys.isNull {
            let t = try systemText(sys)
            if !t.isEmpty { systemParts.append(t) }
        }
        var msgs: [OrderedJSON] = []
        for m in raw {
            if m["role"]?.stringValue == "system", let c = m["content"] {
                let t = try systemText(c)
                if !t.isEmpty { systemParts.append(t) }
                continue
            }
            try convert(m, into: &msgs)
        }
        if !systemParts.isEmpty {
            msgs.insert(.ordered([("role", .string("system")), ("content", .string(systemParts.joined(separator: "\n\n")))]), at: 0)
        }
        guard msgs.contains(where: { $0["role"]?.stringValue != "system" }) else {
            throw APIError.badRequest("messages: at least one user or assistant message is required")
        }

        var chat: [(String, OrderedJSON)] = [("messages", .array(msgs)), ("stream", .bool(root["stream"]?.boolValue ?? false))]

        // tools
        var tools: [OrderedJSON] = []
        for t in root["tools"]?.arrayValue ?? [] {
            guard let name = t["name"]?.stringValue, !name.isEmpty else { continue }
            let ty = t["type"]?.stringValue
            // Client tools: type absent or "custom". Typed server tools (bash_2025..., web_search_...) carry no
            // schema and cannot run here; they are skipped.
            if let ty, ty != "custom", t["input_schema"] == nil { continue }
            tools.append(.ordered([("type", .string("function")), ("function", .ordered([
                ("name", .string(name)), ("description", .string(t["description"]?.stringValue ?? "")),
                ("parameters", t["input_schema"] ?? .ordered([("type", .string("object")), ("properties", .object([]))])),
            ]))]))
        }
        if !tools.isEmpty { chat.append(("tools", .array(tools))) }
        if let tc = root["tool_choice"], let ty = tc["type"]?.stringValue {
            switch ty {
            case "auto": chat.append(("tool_choice", .string("auto")))
            case "any": chat.append(("tool_choice", .string("required")))
            case "tool":
                guard let n = tc["name"]?.stringValue, !n.isEmpty else { throw APIError.badRequest("tool_choice.name: Field required") }
                chat.append(("tool_choice", .ordered([("type", .string("function")), ("function", .ordered([("name", .string(n))]))])))
            case "none": chat.append(("tool_choice", .string("none")))
            default: throw APIError.badRequest("tool_choice.type: unsupported value '\(ty)'")
            }
            if tc["disable_parallel_tool_use"]?.boolValue == true { chat.append(("parallel_tool_calls", .bool(false))) }
        }

        // thinking
        var enable = false
        if let th = root["thinking"], let ty = th["type"]?.stringValue {
            switch ty {
            case "enabled", "adaptive":
                enable = true
                if let b = th["budget_tokens"], !b.isNull {
                    guard let n = b.intValue, n >= 0 else { throw APIError.badRequest("thinking.budget_tokens: must be a non-negative integer") }
                    chat.append(("thinking_budget", .int(n)))
                }
            case "disabled": enable = false
            default: throw APIError.badRequest("thinking.type: unsupported value '\(ty)'")
            }
        }
        chat.append(("chat_template_kwargs", .ordered([("enable_thinking", .bool(enable))])))

        // structured output (Messages API `output_config.format`, legacy `output_format`)
        if let f = root["output_config"]?["format"] ?? root["output_format"], !f.isNull {
            switch f["type"]?.stringValue {
            case "json_schema"?:
                guard let schema = f["schema"], case .object = schema else { throw APIError.badRequest("output_config.format.schema: Field required") }
                chat.append(("response_format", .ordered([("type", .string("json_schema")), ("json_schema", .ordered([("name", .string("output")), ("schema", schema)]))])))
            default: throw APIError.badRequest("output_config.format.type: unsupported value (use json_schema)")
            }
        }

        // sampling
        if let mt = root["max_tokens"], !mt.isNull {
            guard let n = mt.intValue, n >= 1 else { throw APIError.badRequest("max_tokens: must be a positive integer") }
            chat.append(("max_tokens", .int(n)))
        } else if requireMaxTokens {
            throw APIError.badRequest("max_tokens: Field required")
        }
        for k in ["temperature", "top_p", "top_k"] { if let v = root[k], !v.isNull { chat.append((k, v)) } }
        if let ss = root["stop_sequences"], !ss.isNull {
            guard let arr = ss.arrayValue, arr.allSatisfy({ $0.stringValue != nil }) else {
                throw APIError.badRequest("stop_sequences: must be a list of strings")
            }
            chat.append(("stop", ss))
        }
        return Translated(chat: .ordered(chat), stream: root["stream"]?.boolValue ?? false, model: root["model"]?.stringValue)
    }

    private static func unsupportedImage() -> APIError {
        .badRequest("image and document content blocks are not supported by this model")
    }

    private static func systemText(_ sys: OrderedJSON) throws -> String {
        if let s = sys.stringValue { return s }
        guard let blocks = sys.arrayValue else { throw APIError.badRequest("system: must be a string or a list of text blocks") }
        var parts: [String] = []
        for b in blocks {
            switch b["type"]?.stringValue {
            case "text": if let t = b["text"]?.stringValue, !t.isEmpty { parts.append(t) }
            case "image", "document": throw unsupportedImage()
            default: throw APIError.badRequest("system: unsupported block type")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Text of a tool_result `content` (string or list of blocks).
    private static func resultText(_ c: OrderedJSON?) throws -> String {
        guard let c, !c.isNull else { return "" }
        if let s = c.stringValue { return s }
        guard let blocks = c.arrayValue else { throw APIError.badRequest("tool_result.content: must be a string or a list of blocks") }
        var parts: [String] = []
        for b in blocks {
            switch b["type"]?.stringValue {
            case "text": parts.append(b["text"]?.stringValue ?? "")
            case "image", "document": throw unsupportedImage()
            default: break
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func convert(_ m: OrderedJSON, into out: inout [OrderedJSON]) throws {
        guard case .object = m, let role = m["role"]?.stringValue, role == "user" || role == "assistant" else {
            throw APIError.badRequest("messages: each message needs role 'user' or 'assistant'")
        }
        if let s = m["content"]?.stringValue {
            out.append(.ordered([("role", .string(role)), ("content", .string(s))]))
            return
        }
        guard let blocks = m["content"]?.arrayValue else { throw APIError.badRequest("messages.content: must be a string or a list of blocks") }
        var texts: [String] = [], thinking: [String] = []
        var calls: [OrderedJSON] = []
        var results: [OrderedJSON] = []
        for b in blocks {
            let ty = b["type"]?.stringValue
            switch ty {
            case "text": texts.append(b["text"]?.stringValue ?? "")
            case "image", "document": throw unsupportedImage()
            case "thinking":
                if role == "assistant", let t = b["thinking"]?.stringValue, !t.isEmpty { thinking.append(t) }
            case "redacted_thinking": break   // opaque to this model
            case "tool_use":
                guard role == "assistant" else { throw APIError.badRequest("tool_use blocks are only valid in assistant messages") }
                guard let name = b["name"]?.stringValue else { throw APIError.badRequest("tool_use.name: Field required") }
                let id = b["id"]?.stringValue ?? "toolu_" + OutputTranslator.randomId()
                calls.append(.ordered([("id", .string(id)), ("type", .string("function")), ("function", .ordered([
                    ("name", .string(name)), ("arguments", b["input"] ?? .object([])),
                ]))]))
            case "tool_result":
                guard role == "user" else { throw APIError.badRequest("tool_result blocks are only valid in user messages") }
                var t = try resultText(b["content"])
                if b["is_error"]?.boolValue == true { t = t.isEmpty ? "Error" : "Error: " + t }
                results.append(.ordered([("role", .string("tool")), ("tool_call_id", .string(b["tool_use_id"]?.stringValue ?? "")),
                                         ("content", .string(t))]))
            default:
                throw APIError.badRequest("messages.content: unsupported block type '\(ty ?? "")'")
            }
        }
        out += results   // tool results first (Anthropic requires them at the head of the user turn)
        if role == "user" {
            if !texts.isEmpty { out.append(.ordered([("role", .string("user")), ("content", .string(texts.joined(separator: "\n\n")))])) }
        } else if !texts.isEmpty || !calls.isEmpty {
            var msg: [(String, OrderedJSON)] = [("role", .string("assistant")), ("content", .string(texts.joined()))]
            if !thinking.isEmpty { msg.append(("reasoning_content", .string(thinking.joined(separator: "\n")))) }
            if !calls.isEmpty { msg.append(("tool_calls", .array(calls))) }
            out.append(.ordered(msg))
        }
    }

    static func stopReason(_ finish: String, stopMatched: String?) -> (String, String?) {
        switch finish {
        case "tool_calls": return ("tool_use", nil)
        case "length": return ("max_tokens", nil)
        default: return stopMatched != nil ? ("stop_sequence", stopMatched) : ("end_turn", nil)
        }
    }

    /// Anthropic accounting: input_tokens excludes cache reads (total prompt = input + cache_read + creation).
    static func usage(_ u: Usage, includeInput: Bool = true) -> OrderedJSON {
        var m: [(String, OrderedJSON)] = []
        if includeInput { m.append(("input_tokens", .int(max(u.promptTokens - u.cachedTokens, 0)))) }
        m += [("cache_creation_input_tokens", .int(0)), ("cache_read_input_tokens", .int(u.cachedTokens)),
              ("output_tokens", .int(u.completionTokens))]
        return .ordered(m)
    }

    static func toolId(_ id: String) -> String { id.hasPrefix("call_") ? "toolu_" + id.dropFirst(5) : id }
}

extension StrimOpenAIServer {
    func anthropicCountTokens(_ req: Request, _ r: Responder) async throws {
        let t = try AnthropicAdapter.translate(req.body, requireMaxTokens: false)
        let creq = try parseChat(t.chat, priorityHeader: nil)
        let sid: SessionID
        do { sid = try await engine.openSession(creq.config) } catch { throw APIError.from(error) }
        let n: Int
        do { n = try await engine.append(sid, .history(creq.messages)) } catch {
            await engine.close(sid)
            throw APIError.from(error)
        }
        await engine.close(sid)
        try await sendJSON(r, .ordered([("input_tokens", .int(n))]))
    }

    func anthropicMessages(_ req: Request, _ r: Responder) async throws {
        let t = try AnthropicAdapter.translate(req.body, requireMaxTokens: true)
        let creq = try parseChat(t.chat, priorityHeader: req.headers["x-strim-priority"])
        let mid = "msg_" + OutputTranslator.randomId()
        let model = t.model ?? config.modelId
        try await runTurn(creq, id: mid, responder: r) { [self] lease, promptIds in
            t.stream
                ? try await anthropicStream(creq, lease, r, id: mid, model: model, promptIds: promptIds)
                : try await anthropicCollect(creq, lease, r, id: mid, model: model)
        }
    }

    private func anthropicStream(_ creq: ChatRequest, _ lease: SessionTable.Lease, _ r: Responder, id: String,
                                 model: String, promptIds: Int) async throws -> Bool {
        enum Kind: Equatable { case thinking, text, tool(Int) }
        var open: (kind: Kind, index: Int)?
        var next = 0
        func send(_ name: String, _ fields: [(String, OrderedJSON)]) async throws {
            try await r.sseEvent(name, OrderedJSON.ordered([("type", .string(name))] + fields).serialized())
        }
        func close() async throws {
            if let o = open { try await send("content_block_stop", [("index", .int(o.index))]); open = nil }
        }
        func begin(_ kind: Kind, _ block: OrderedJSON) async throws {
            try await close()
            open = (kind, next)
            try await send("content_block_start", [("index", .int(next)), ("content_block", block)])
            next += 1
        }
        func delta(_ d: OrderedJSON) async throws {
            try await send("content_block_delta", [("index", .int(open!.index)), ("delta", d)])
        }
        return try await driveStream(creq, lease, r, logId: id, start: {
            try await send("message_start", [("message", .ordered([
                ("id", .string(id)), ("type", .string("message")), ("role", .string("assistant")),
                ("model", .string(model)), ("content", .array([])), ("stop_reason", .null), ("stop_sequence", .null),
                ("usage", .ordered([("input_tokens", .int(promptIds)), ("cache_creation_input_tokens", .int(0)),
                                    ("cache_read_input_tokens", .int(0)), ("output_tokens", .int(1))])),
            ]))])
            try await r.sseEvent("ping", #"{"type": "ping"}"#)
        }, emit: { o, stopMatched in
            switch o {
            case .reasoning(let t):
                if open?.kind != .thinking {
                    try await begin(.thinking, .ordered([("type", .string("thinking")), ("thinking", .string("")), ("signature", .string(""))]))
                }
                try await delta(.ordered([("type", .string("thinking_delta")), ("thinking", .string(t))]))
            case .content(let t):
                if open?.kind != .text {
                    try await begin(.text, .ordered([("type", .string("text")), ("text", .string(""))]))
                }
                try await delta(.ordered([("type", .string("text_delta")), ("text", .string(t))]))
            case let .toolStart(i, tid, name):
                try await begin(.tool(i), .ordered([("type", .string("tool_use")), ("id", .string(AnthropicAdapter.toolId(tid))),
                                                    ("name", .string(name)), ("input", .object([]))]))
            case let .toolArgs(i, frag):
                if open?.kind == .tool(i) {
                    try await delta(.ordered([("type", .string("input_json_delta")), ("partial_json", .string(frag))]))
                }
            case let .done(reason, usage):
                if next == 0 { try await begin(.text, .ordered([("type", .string("text")), ("text", .string(""))])) }
                try await close()
                let (sr, ss) = AnthropicAdapter.stopReason(reason, stopMatched: stopMatched)
                try await send("message_delta", [
                    ("delta", .ordered([("stop_reason", .string(sr)), ("stop_sequence", ss.map { .string($0) } ?? .null)])),
                    ("usage", AnthropicAdapter.usage(usage)),
                ])
                try await send("message_stop", [])
            }
        }, fail: { api in
            try? await r.sseEvent("error", api.anthropicJSON.serialized())
        })
    }

    private func anthropicCollect(_ creq: ChatRequest, _ lease: SessionTable.Lease, _ r: Responder, id: String,
                                  model: String) async throws -> Bool {
        let c = try await collect(creq, lease, logId: id)
        guard let (reason, usage) = c.done else { return true }   // cancelled by a disconnect
        var blocks: [OrderedJSON] = []
        if !c.reasoning.isEmpty {
            blocks.append(.ordered([("type", .string("thinking")), ("thinking", .string(c.reasoning)), ("signature", .string(""))]))
        }
        if !c.content.isEmpty { blocks.append(.ordered([("type", .string("text")), ("text", .string(c.content))])) }
        for call in c.calls {
            blocks.append(.ordered([("type", .string("tool_use")), ("id", .string(AnthropicAdapter.toolId(call.id))),
                                    ("name", .string(call.name)), ("input", Self.argsObject(call.args))]))
        }
        if blocks.isEmpty { blocks.append(.ordered([("type", .string("text")), ("text", .string(""))])) }
        let (sr, ss) = AnthropicAdapter.stopReason(reason, stopMatched: c.stopMatched)
        let body: OrderedJSON = .ordered([
            ("id", .string(id)), ("type", .string("message")), ("role", .string("assistant")), ("model", .string(model)),
            ("content", .array(blocks)), ("stop_reason", .string(sr)), ("stop_sequence", ss.map { .string($0) } ?? .null),
            ("usage", AnthropicAdapter.usage(usage)),
        ])
        try await r.json(200, Data(body.serialized().utf8))
        return true
    }
}
