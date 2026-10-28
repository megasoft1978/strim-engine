import Foundation
import StrimEngine
import StrimHTTP
import StrimTemplate

/// Bounded response id -> conversation map backing `previous_response_id` (non-system chat messages up to and
/// including the assistant output of that response). FIFO eviction, bounded by entry count and by the serialized
/// size of the retained conversations (`STRIM_RESPONSE_STORE_MB`, default 64); one conversation larger than the
/// byte budget is not stored.
final class ResponseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: [OrderedJSON]] = [:]
    private var order: [String] = []
    private var sizes: [String: Int] = [:]
    private var totalBytes = 0
    private let capacity: Int
    private let maxBytes: Int
    init(capacity: Int = 256, maxBytes: Int = ServerLimits.responseStoreBytes) {
        self.capacity = capacity; self.maxBytes = maxBytes
    }

    var byteCount: Int { lock.withLock { totalBytes } }

    func put(_ id: String, _ messages: [OrderedJSON]) {
        let size = messages.reduce(0) { $0 + $1.serialized().utf8.count }
        lock.withLock {
            if map[id] != nil { drop(id) }
            guard size <= maxBytes else { return }
            order.append(id)
            map[id] = messages; sizes[id] = size; totalBytes += size
            while order.count > capacity || totalBytes > maxBytes, let oldest = order.first { drop(oldest) }
        }
    }

    private func drop(_ id: String) {
        map[id] = nil
        order.removeAll { $0 == id }
        totalBytes -= sizes.removeValue(forKey: id) ?? 0
    }

    func get(_ id: String) -> [OrderedJSON]? { lock.withLock { map[id] } }
}

/// OpenAI Responses API (POST /v1/responses), translated to the same chat body path as the other endpoints.
///
/// Built-in tool types (web_search, file_search, local_shell, custom/freeform, ...) are ignored: only
/// `function` tools are declared to the model. Unknown input item types are a 400. `instructions`, tools and
/// reasoning settings are not inherited through `previous_response_id` (as in the public API); only the
/// conversation is.
enum ResponsesAdapter {
    struct Translated {
        var chat: OrderedJSON
        var stream: Bool
        var model: String?
        var store: Bool
        /// Non-system chat messages of the request (previous conversation + this input).
        var convo: [OrderedJSON]
        var instructions: String?
        var previousId: String?
        var maxOutputTokens: Int?
    }

    private struct Msg {
        var role: String
        var content: String?
        var reasoning: String?
        var calls: [OrderedJSON] = []
        var callId: String?
        var json: OrderedJSON {
            var m: [(String, OrderedJSON)] = [("role", .string(role))]
            if role == "tool" { m.append(("tool_call_id", .string(callId ?? ""))) }
            m.append(("content", content.map { .string($0) } ?? .null))
            if let r = reasoning, !r.isEmpty { m.append(("reasoning_content", .string(r))) }
            if !calls.isEmpty { m.append(("tool_calls", .array(calls))) }
            return .ordered(m)
        }
    }

    static func translate(_ body: Data, store: ResponseStore) throws -> Translated {
        guard let text = String(data: body, encoding: .utf8), let root = try? OrderedJSON.parse(text),
              case .object = root else { throw APIError.badRequest("body is not a JSON object") }

        var system: [String] = []
        if let i = root["instructions"]?.stringValue, !i.isEmpty { system.append(i) }

        var prior: [OrderedJSON] = []
        var previousId: String?
        if let p = root["previous_response_id"], !p.isNull {
            guard let pid = p.stringValue else { throw APIError.badRequest("previous_response_id must be a string") }
            guard let h = store.get(pid) else {
                throw APIError.badRequest("Previous response with id '\(pid)' not found (it was never stored, was created with store=false, or has been evicted).")
            }
            prior = h
            previousId = pid
        }

        var items: [Msg] = prior.compactMap { m in
            guard let role = m["role"]?.stringValue else { return nil }
            return Msg(role: role, content: m["content"]?.stringValue, reasoning: m["reasoning_content"]?.stringValue,
                       calls: m["tool_calls"]?.arrayValue ?? [], callId: m["tool_call_id"]?.stringValue)
        }
        var pendingReasoning: String?

        func addAssistantCall(_ call: OrderedJSON) {
            if let last = items.last, last.role == "assistant" {
                items[items.count - 1].calls.append(call)
            } else {
                items.append(Msg(role: "assistant", content: nil, reasoning: pendingReasoning, calls: [call]))
                pendingReasoning = nil
            }
        }

        let input = root["input"]
        if let s = input?.stringValue {
            items.append(Msg(role: "user", content: s))
        } else if let arr = input?.arrayValue {
            for it in arr {
                let ty = it["type"]?.stringValue ?? (it["role"] != nil ? "message" : nil)
                switch ty {
                case "message":
                    let role = it["role"]?.stringValue ?? "user"
                    let t = try contentText(it["content"])
                    switch role {
                    case "system", "developer": if !t.isEmpty { system.append(t) }
                    case "user": items.append(Msg(role: "user", content: t))
                    case "assistant":
                        items.append(Msg(role: "assistant", content: t, reasoning: pendingReasoning))
                        pendingReasoning = nil
                    default: throw APIError.badRequest("input: unsupported message role '\(role)'")
                    }
                case "reasoning":
                    var parts: [String] = []
                    for key in ["content", "summary"] {
                        for p in it[key]?.arrayValue ?? [] { if let t = p["text"]?.stringValue, !t.isEmpty { parts.append(t) } }
                        if !parts.isEmpty { break }
                    }
                    if !parts.isEmpty { pendingReasoning = (pendingReasoning.map { $0 + "\n" } ?? "") + parts.joined(separator: "\n") }
                case "function_call":
                    guard let name = it["name"]?.stringValue else { throw APIError.badRequest("input: function_call.name is required") }
                    let cid = it["call_id"]?.stringValue ?? it["id"]?.stringValue ?? "call_" + OutputTranslator.randomId()
                    addAssistantCall(.ordered([("id", .string(cid)), ("type", .string("function")), ("function", .ordered([
                        ("name", .string(name)), ("arguments", .string(it["arguments"]?.stringValue ?? "")),
                    ]))]))
                case "function_call_output":
                    let cid = it["call_id"]?.stringValue ?? it["id"]?.stringValue ?? ""
                    items.append(Msg(role: "tool", content: try contentText(it["output"]), callId: cid))
                default:
                    throw APIError.badRequest("input: unsupported item type '\(ty ?? "?")'")
                }
            }
        } else if input == nil || input!.isNull {
            if items.isEmpty { throw APIError.badRequest("input: Field required") }
        } else {
            throw APIError.badRequest("input must be a string or a list of items")
        }

        let convo = items.map(\.json)
        var msgs: [OrderedJSON] = []
        if !system.isEmpty { msgs.append(.ordered([("role", .string("system")), ("content", .string(system.joined(separator: "\n\n")))])) }
        msgs += convo
        var chat: [(String, OrderedJSON)] = [("messages", .array(msgs)), ("stream", .bool(root["stream"]?.boolValue ?? false))]

        var tools: [OrderedJSON] = []
        for t in root["tools"]?.arrayValue ?? [] {
            if let ty = t["type"]?.stringValue, ty != "function" { continue }
            let f = t["function"] ?? t
            guard let name = f["name"]?.stringValue, !name.isEmpty else { continue }
            tools.append(.ordered([("type", .string("function")), ("function", .ordered([
                ("name", .string(name)), ("description", .string(f["description"]?.stringValue ?? "")),
                ("parameters", f["parameters"] ?? .ordered([("type", .string("object")), ("properties", .object([]))])),
            ]))]))
        }
        if !tools.isEmpty { chat.append(("tools", .array(tools))) }
        if let tc = root["tool_choice"], !tc.isNull {
            if let s = tc.stringValue {
                guard ["auto", "none", "required"].contains(s) else { throw APIError.badRequest("tool_choice: unsupported value '\(s)'") }
                chat.append(("tool_choice", .string(s)))
            } else if tc["type"]?.stringValue == "function" {
                guard let n = (tc["name"] ?? tc["function"]?["name"])?.stringValue, !n.isEmpty else { throw APIError.badRequest("tool_choice.name: Field required") }
                chat.append(("tool_choice", .ordered([("type", .string("function")), ("function", .ordered([("name", .string(n))]))])))
            } else {
                throw APIError.badRequest("tool_choice: unsupported value (use auto, none, required or {\"type\":\"function\",\"name\":...})")
            }
        }
        if let p = root["parallel_tool_calls"], !p.isNull { chat.append(("parallel_tool_calls", p)) }
        for k in ["thinking_budget", "thinking_token_budget"] { if let v = root[k], !v.isNull { chat.append((k, v)) } }
        if let f = root["text"]?["format"], !f.isNull {
            switch f["type"]?.stringValue {
            case "text"?: break
            case "json_object"?: chat.append(("response_format", .ordered([("type", .string("json_object"))])))
            case "json_schema"?:
                guard let schema = f["schema"], case .object = schema else { throw APIError.badRequest("text.format.schema: Field required") }
                chat.append(("response_format", .ordered([("type", .string("json_schema")), ("json_schema", .ordered([
                    ("name", .string(f["name"]?.stringValue ?? "output")), ("schema", schema)]))])))
            default: throw APIError.badRequest("text.format.type: unsupported value '\(f["type"]?.stringValue ?? "?")'")
            }
        }

        var kwargs: [(String, OrderedJSON)] = []
        if let eff = root["reasoning"]?["effort"]?.stringValue {
            switch eff {
            case "none": kwargs.append(("enable_thinking", .bool(false)))
            case "minimal", "low": chat.append(("reasoning_effort", .string("low")))
            case "medium": chat.append(("reasoning_effort", .string("medium")))
            default: chat.append(("reasoning_effort", .string("xhigh")))
            }
        }
        if !kwargs.isEmpty { chat.append(("chat_template_kwargs", .ordered(kwargs))) }

        var maxOut: Int?
        if let mo = root["max_output_tokens"], !mo.isNull {
            guard let n = mo.intValue, n >= 1 else { throw APIError.badRequest("max_output_tokens must be a positive integer") }
            chat.append(("max_tokens", .int(n)))
            maxOut = min(n, ServerLimits.maxOutputTokens)
        }
        for k in ["temperature", "top_p"] { if let v = root[k], !v.isNull { chat.append((k, v)) } }
        return Translated(chat: .ordered(chat), stream: root["stream"]?.boolValue ?? false, model: root["model"]?.stringValue,
                          store: root["store"]?.boolValue ?? true, convo: convo, instructions: root["instructions"]?.stringValue,
                          previousId: previousId, maxOutputTokens: maxOut)
    }

    /// Text of message `content` / function output: string, or a list of text-bearing parts.
    private static func contentText(_ c: OrderedJSON?) throws -> String {
        guard let c, !c.isNull else { return "" }
        if let s = c.stringValue { return s }
        guard let parts = c.arrayValue else { throw APIError.badRequest("content must be a string or a list of parts") }
        var out = ""
        for p in parts {
            switch p["type"]?.stringValue {
            case "input_text", "output_text", "text", "refusal", "summary_text": out += p["text"]?.stringValue ?? p["refusal"]?.stringValue ?? ""
            case "input_image", "image", "input_file", "image_url": throw APIError.badRequest("image and file inputs are not supported by this model")
            default: break
            }
        }
        return out
    }

    static func usage(_ u: Usage) -> OrderedJSON {
        .ordered([
            ("input_tokens", .int(u.promptTokens)),
            ("input_tokens_details", .ordered([("cached_tokens", .int(u.cachedTokens))])),
            ("output_tokens", .int(u.completionTokens)),
            ("output_tokens_details", .ordered([("reasoning_tokens", .int(0))])),
            ("total_tokens", .int(u.promptTokens + u.completionTokens)),
        ])
    }

    /// Chat-style assistant message for the continuation store.
    static func assistantMessage(_ c: Collected) -> OrderedJSON {
        var m: [(String, OrderedJSON)] = [("role", .string("assistant"))]
        m.append(("content", c.content.isEmpty && !c.calls.isEmpty ? .null : .string(c.content)))
        if !c.reasoning.isEmpty { m.append(("reasoning_content", .string(c.reasoning))) }
        if !c.calls.isEmpty {
            m.append(("tool_calls", .array(c.calls.map {
                .ordered([("id", .string($0.id)), ("type", .string("function")),
                          ("function", .ordered([("name", .string($0.name)), ("arguments", .string($0.args))]))])
            })))
        }
        return .ordered(m)
    }
}

/// Per-request context for building Response objects.
private struct RespCtx {
    let id: String
    let model: String
    let created: Int
    let t: ResponsesAdapter.Translated

    func object(status: String, output: [OrderedJSON], usage: Usage?, incomplete: String? = nil) -> OrderedJSON {
        .ordered([
            ("id", .string(id)), ("object", .string("response")), ("created_at", .int(created)), ("status", .string(status)),
            ("error", .null),
            ("incomplete_details", incomplete.map { .ordered([("reason", .string($0))]) } ?? .null),
            ("instructions", t.instructions.map { .string($0) } ?? .null),
            ("max_output_tokens", t.maxOutputTokens.map { .int($0) } ?? .null),
            ("model", .string(model)), ("output", .array(output)), ("parallel_tool_calls", .bool(true)),
            ("previous_response_id", t.previousId.map { .string($0) } ?? .null),
            ("store", .bool(t.store)), ("tool_choice", .string("auto")), ("tools", .array([])),
            ("usage", usage.map(ResponsesAdapter.usage) ?? .null),
        ])
    }
}

extension StrimOpenAIServer {
    func responses(_ req: Request, _ r: Responder) async throws {
        let t = try ResponsesAdapter.translate(req.body, store: responseStore)
        let creq = try parseChat(t.chat, priorityHeader: req.headers["x-strim-priority"])
        let rid = "resp_" + OutputTranslator.randomId()
        let ctx = RespCtx(id: rid, model: t.model ?? config.modelId, created: Int(Date().timeIntervalSince1970), t: t)
        try await runTurn(creq, id: rid, responder: r) { [self] lease, _ in
            t.stream
                ? try await responsesStream(creq, lease, r, ctx)
                : try await responsesCollect(creq, lease, r, ctx)
        }
    }

    private func remember(_ ctx: RespCtx, assistant: OrderedJSON) {
        if ctx.t.store { responseStore.put(ctx.id, ctx.t.convo + [assistant]) }
    }

    private func responsesCollect(_ creq: ChatRequest, _ lease: SessionTable.Lease, _ r: Responder, _ ctx: RespCtx) async throws -> Bool {
        let c = try await collect(creq, lease, logId: ctx.id)
        guard let (reason, usage) = c.done else { return true }
        var out: [OrderedJSON] = []
        if !c.reasoning.isEmpty {
            out.append(.ordered([("id", .string("rs_" + OutputTranslator.randomId())), ("type", .string("reasoning")),
                                 ("summary", .array([.ordered([("type", .string("summary_text")), ("text", .string(c.reasoning))])]))]))
        }
        if !c.content.isEmpty || c.calls.isEmpty {
            out.append(.ordered([("id", .string("msg_" + OutputTranslator.randomId())), ("type", .string("message")),
                                 ("status", .string("completed")), ("role", .string("assistant")),
                                 ("content", .array([.ordered([("type", .string("output_text")), ("text", .string(c.content)),
                                                               ("annotations", .array([]))])]))]))
        }
        for call in c.calls {
            out.append(.ordered([("id", .string("fc_" + OutputTranslator.randomId())), ("type", .string("function_call")),
                                 ("status", .string("completed")), ("call_id", .string(call.id)), ("name", .string(call.name)),
                                 ("arguments", .string(call.args))]))
        }
        let truncated = reason == "length"
        remember(ctx, assistant: ResponsesAdapter.assistantMessage(c))
        let body = ctx.object(status: truncated ? "incomplete" : "completed", output: out, usage: usage,
                              incomplete: truncated ? "max_output_tokens" : nil)
        try await r.json(200, Data(body.serialized().utf8))
        return true
    }

    private func responsesStream(_ creq: ChatRequest, _ lease: SessionTable.Lease, _ r: Responder, _ ctx: RespCtx) async throws -> Bool {
        enum Kind: Equatable { case reasoning, message, call(Int) }
        struct Open { var kind: Kind; var index: Int; var id: String; var text = ""; var callId = ""; var name = "" }
        var open: Open?
        var finishedItems: [OrderedJSON] = []
        var acc = Collected()
        var seq = 0
        func send(_ name: String, _ fields: [(String, OrderedJSON)]) async throws {
            let d = OrderedJSON.ordered([("type", .string(name)), ("sequence_number", .int(seq))] + fields)
            seq += 1
            try await r.sseEvent(name, d.serialized())
        }
        func summaryPart(_ t: String) -> OrderedJSON { .ordered([("type", .string("summary_text")), ("text", .string(t))]) }
        func textPart(_ t: String) -> OrderedJSON {
            .ordered([("type", .string("output_text")), ("text", .string(t)), ("annotations", .array([]))])
        }
        func messageItem(_ o: Open, done: Bool) -> OrderedJSON {
            .ordered([("id", .string(o.id)), ("type", .string("message")), ("status", .string(done ? "completed" : "in_progress")),
                      ("role", .string("assistant")), ("content", .array(done ? [textPart(o.text)] : []))])
        }
        func callItem(_ o: Open, done: Bool) -> OrderedJSON {
            .ordered([("id", .string(o.id)), ("type", .string("function_call")), ("status", .string(done ? "completed" : "in_progress")),
                      ("call_id", .string(o.callId)), ("name", .string(o.name)), ("arguments", .string(done ? o.text : ""))])
        }
        func close() async throws {
            guard let o = open else { return }
            let item: OrderedJSON
            switch o.kind {
            case .reasoning:
                try await send("response.reasoning_summary_text.done", [("item_id", .string(o.id)), ("output_index", .int(o.index)),
                                                                        ("summary_index", .int(0)), ("text", .string(o.text))])
                try await send("response.reasoning_summary_part.done", [("item_id", .string(o.id)), ("output_index", .int(o.index)),
                                                                        ("summary_index", .int(0)), ("part", summaryPart(o.text))])
                item = .ordered([("id", .string(o.id)), ("type", .string("reasoning")), ("summary", .array([summaryPart(o.text)]))])
            case .message:
                try await send("response.output_text.done", [("item_id", .string(o.id)), ("output_index", .int(o.index)),
                                                             ("content_index", .int(0)), ("text", .string(o.text))])
                try await send("response.content_part.done", [("item_id", .string(o.id)), ("output_index", .int(o.index)),
                                                              ("content_index", .int(0)), ("part", textPart(o.text))])
                item = messageItem(o, done: true)
            case .call:
                try await send("response.function_call_arguments.done", [("item_id", .string(o.id)), ("output_index", .int(o.index)),
                                                                         ("arguments", .string(o.text))])
                item = callItem(o, done: true)
            }
            try await send("response.output_item.done", [("output_index", .int(o.index)), ("item", item)])
            finishedItems.append(item)
            open = nil
        }
        func begin(_ kind: Kind, prefix: String, callId: String = "", name: String = "") async throws {
            try await close()
            let o = Open(kind: kind, index: finishedItems.count, id: prefix + OutputTranslator.randomId(), callId: callId, name: name)
            open = o
            switch kind {
            case .reasoning:
                try await send("response.output_item.added", [("output_index", .int(o.index)), ("item", .ordered([
                    ("id", .string(o.id)), ("type", .string("reasoning")), ("summary", .array([]))]))])
                try await send("response.reasoning_summary_part.added", [("item_id", .string(o.id)), ("output_index", .int(o.index)),
                                                                         ("summary_index", .int(0)), ("part", summaryPart(""))])
            case .message:
                try await send("response.output_item.added", [("output_index", .int(o.index)), ("item", messageItem(o, done: false))])
                try await send("response.content_part.added", [("item_id", .string(o.id)), ("output_index", .int(o.index)),
                                                               ("content_index", .int(0)), ("part", textPart(""))])
            case .call:
                try await send("response.output_item.added", [("output_index", .int(o.index)), ("item", callItem(o, done: false))])
            }
        }
        return try await driveStream(creq, lease, r, logId: ctx.id, start: {
            let base = ctx.object(status: "in_progress", output: [], usage: nil)
            try await send("response.created", [("response", base)])
            try await send("response.in_progress", [("response", base)])
        }, emit: { o, _ in
            switch o {
            case .reasoning(let t):
                if open?.kind != .reasoning { try await begin(.reasoning, prefix: "rs_") }
                open!.text += t; acc.reasoning += t
                try await send("response.reasoning_summary_text.delta", [("item_id", .string(open!.id)), ("output_index", .int(open!.index)),
                                                                         ("summary_index", .int(0)), ("delta", .string(t))])
            case .content(let t):
                if open?.kind != .message { try await begin(.message, prefix: "msg_") }
                open!.text += t; acc.content += t
                try await send("response.output_text.delta", [("item_id", .string(open!.id)), ("output_index", .int(open!.index)),
                                                              ("content_index", .int(0)), ("delta", .string(t))])
            case let .toolStart(i, tid, name):
                try await begin(.call(i), prefix: "fc_", callId: tid, name: name)
                acc.calls.append((tid, name, ""))
            case let .toolArgs(i, frag):
                if open?.kind == .call(i) {
                    open!.text += frag; acc.calls[i].args += frag
                    try await send("response.function_call_arguments.delta", [("item_id", .string(open!.id)), ("output_index", .int(open!.index)),
                                                                              ("delta", .string(frag))])
                }
            case let .done(reason, usage):
                if finishedItems.isEmpty && open == nil { try await begin(.message, prefix: "msg_") }
                try await close()
                remember(ctx, assistant: ResponsesAdapter.assistantMessage(acc))
                let truncated = reason == "length"
                let obj = ctx.object(status: truncated ? "incomplete" : "completed", output: finishedItems, usage: usage,
                                     incomplete: truncated ? "max_output_tokens" : nil)
                try await send(truncated ? "response.incomplete" : "response.completed", [("response", obj)])
            }
        }, fail: { api in
            let e = OrderedJSON.ordered([("type", .string("error")), ("sequence_number", .int(seq)),
                                         ("code", .string(api.type)), ("message", .string(api.message)), ("param", .null)])
            try? await r.sseEvent("error", e.serialized())
        })
    }
}
