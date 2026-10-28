import Foundation
import Testing
import StrimEngine
import StrimHTTP
import StrimTemplate
@testable import StrimServer

private let token = "adapter-token"

private struct SSEEvent {
    let name: String
    let data: [String: Any]
    subscript(_ k: String) -> Any? { data[k] }
}

private struct H {
    let engine: FakeEngine
    let server: StrimOpenAIServer
    let port: UInt16

    static func start(token: String? = token) async throws -> H {
        let engine = FakeEngine()
        let server = StrimOpenAIServer(engine: engine, config: ServerConfig(modelId: "fake-model", bearerToken: token))
        return H(engine: engine, server: server, port: try await server.start(port: 0))
    }

    func req(_ path: String, body: String, headers: [String: String] = ["Authorization": "Bearer \(token)"]) -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        r.httpMethod = "POST"
        r.httpBody = Data(body.utf8)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    func json(_ path: String, _ body: String, headers: [String: String] = ["Authorization": "Bearer \(token)"]) async throws -> (Int, [String: Any]) {
        let s = URLSession(configuration: .ephemeral)
        defer { s.finishTasksAndInvalidate() }
        let (d, resp) = try await s.data(for: req(path, body: body, headers: headers))
        return ((resp as! HTTPURLResponse).statusCode, (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:])
    }

    func sse(_ path: String, _ body: String) async throws -> [SSEEvent] {
        let s = URLSession(configuration: .ephemeral)
        defer { s.finishTasksAndInvalidate() }
        let (bytes, resp) = try await s.bytes(for: req(path, body: body))
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        var out: [SSEEvent] = []
        var name = ""
        for try await line in bytes.lines {
            if line.hasPrefix("event: ") { name = String(line.dropFirst(7)) }
            else if line.hasPrefix("data: ") {
                let o = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any] ?? [:]
                out.append(SSEEvent(name: name, data: o))
            }
        }
        return out
    }

    func lastHistory() -> [Message] {
        engine.snapshot { e in
            for (_, i) in e.appends.reversed() { if case .history(let m) = i { return m } }
            return []
        }
    }
}

private func ant(_ messages: String = #"[{"role":"user","content":"hi"}]"#, _ extra: String = "") -> String {
    #"{"model":"claude-x","max_tokens":100,"messages":\#(messages)\#(extra.isEmpty ? "" : "," + extra)}"#
}

private let weatherTool = #""tools":[{"name":"get_weather","description":"w","input_schema":{"type":"object","properties":{"city":{"type":"string"}}}}]"#

@Suite("Anthropic + Responses adapters", .serialized)
struct AdapterTests {
    // MARK: Anthropic

    @Test("messages stream: thinking, text, exact event sequence and usage")
    func anthropicStream() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.reasoning("hmm ")), .event(.reasoning("ok")), .event(.tokens([1], "Hello")),
                         .event(.tokens([2], " there")), .event(.finished(.stop, makeUsage(prompt: 20, cached: 8, completion: 4)))])
        let ev = try await h.sse("/v1/messages", ant("[{\"role\":\"user\",\"content\":\"hi\"}]", #""stream":true,"thinking":{"type":"enabled","budget_tokens":1000}"#))
        #expect(ev.map(\.name) == ["message_start", "ping", "content_block_start", "content_block_delta", "content_block_delta",
                                   "content_block_stop", "content_block_start", "content_block_delta", "content_block_delta",
                                   "content_block_stop", "message_delta", "message_stop"])
        for e in ev { #expect(e["type"] as? String == e.name) }
        let msg = ev[0]["message"] as! [String: Any]
        #expect((msg["id"] as? String)?.hasPrefix("msg_") == true)
        #expect(msg["role"] as? String == "assistant" && msg["model"] as? String == "claude-x")
        #expect((msg["content"] as? [Any])?.isEmpty == true && msg["stop_reason"] is NSNull)
        #expect((msg["usage"] as! [String: Any])["input_tokens"] as? Int == 1)   // FakeEngine append count
        #expect((ev[2]["content_block"] as! [String: Any])["type"] as? String == "thinking")
        #expect(ev[2]["index"] as? Int == 0 && ev[6]["index"] as? Int == 1)
        let d = ev[3]["delta"] as! [String: Any]
        #expect(d["type"] as? String == "thinking_delta" && d["thinking"] as? String == "hmm ")
        #expect((ev[6]["content_block"] as! [String: Any])["type"] as? String == "text")
        let td = ev[8]["delta"] as! [String: Any]
        #expect(td["type"] as? String == "text_delta" && td["text"] as? String == " there")
        let md = ev[10]["delta"] as! [String: Any]
        #expect(md["stop_reason"] as? String == "end_turn" && md["stop_sequence"] is NSNull)
        let u = ev[10]["usage"] as! [String: Any]
        #expect(u["output_tokens"] as? Int == 4 && u["cache_read_input_tokens"] as? Int == 8)
        #expect(u["input_tokens"] as? Int == 12 && u["cache_creation_input_tokens"] as? Int == 0)
        // thinking enabled, no tools: enable_thinking reached the session config
        #expect(h.engine.snapshot { $0.opened.first?.1.enableThinking } == true)
    }

    @Test("tool_use stream: input_json_delta fragments, stop_reason tool_use")
    func anthropicToolStream() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "Checking.")), .event(.toolCallBegin(name: "get_weather")),
                         .event(.toolCallArg(key: "city", value: .string("Paris"))), .event(.toolCallEnd),
                         .event(.finished(.stop, makeUsage()))])
        let ev = try await h.sse("/v1/messages", ant(#"[{"role":"user","content":"w?"}]"#, weatherTool + #","stream":true"#))
        #expect(ev.map(\.name) == ["message_start", "ping", "content_block_start", "content_block_delta", "content_block_stop",
                                   "content_block_start", "content_block_delta", "content_block_delta", "content_block_stop",
                                   "message_delta", "message_stop"])
        let tb = ev[5]["content_block"] as! [String: Any]
        #expect(tb["type"] as? String == "tool_use" && tb["name"] as? String == "get_weather")
        #expect((tb["id"] as? String)?.hasPrefix("toolu_") == true)
        #expect((tb["input"] as? [String: Any])?.isEmpty == true)
        let frags = [ev[6], ev[7]].map { ($0["delta"] as! [String: Any]) }
        #expect(frags.allSatisfy { $0["type"] as? String == "input_json_delta" })
        let json = frags.compactMap { $0["partial_json"] as? String }.joined()
        #expect((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]) == ["city": "Paris"])
        #expect((ev[9]["delta"] as! [String: Any])["stop_reason"] as? String == "tool_use")
        // tools declared => thinking stays off even with thinking enabled (disableWhenTools)
        #expect(h.engine.snapshot { $0.opened.first?.1.tools.first?.name } == "get_weather")
        #expect(h.engine.snapshot { $0.opened.first?.1.enableThinking } == false)
    }

    @Test("non-stream shape, max_tokens, stop_sequences, empty output")
    func anthropicNonStream() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.reasoning("why")), .event(.tokens([1], "Hel")), .event(.tokens([2], "lo")),
                         .event(.finished(.length, makeUsage(prompt: 9, cached: 3, completion: 2)))])
        var (code, j) = try await h.json("/v1/messages", ant())
        #expect(code == 200)
        #expect(j["type"] as? String == "message" && j["role"] as? String == "assistant" && j["stop_reason"] as? String == "max_tokens")
        let content = j["content"] as! [[String: Any]]
        #expect(content.map { $0["type"] as? String } == ["thinking", "text"])
        #expect(content[0]["thinking"] as? String == "why" && content[1]["text"] as? String == "Hello")
        let u = j["usage"] as! [String: Any]
        #expect(u["input_tokens"] as? Int == 6 && u["cache_read_input_tokens"] as? Int == 3 && u["output_tokens"] as? Int == 2)

        h.engine.script([.event(.tokens([1], "ab")), .event(.tokens([2], "cSTOPxyz")), .hang])
        (code, j) = try await h.json("/v1/messages", ant("[{\"role\":\"user\",\"content\":\"x\"}]", #""stop_sequences":["STOP","ZZ"]"#))
        #expect((j["content"] as! [[String: Any]]).first?["text"] as? String == "abc")
        #expect(j["stop_reason"] as? String == "stop_sequence" && j["stop_sequence"] as? String == "STOP")

        h.engine.script([.event(.finished(.stop, makeUsage()))])
        (code, j) = try await h.json("/v1/messages", ant())
        #expect((j["content"] as! [[String: Any]]).first?["text"] as? String == "")
        #expect(j["stop_reason"] as? String == "end_turn" && j["stop_sequence"] is NSNull)
    }

    @Test("stop_sequences in a stream end with stop_sequence")
    func anthropicStopStream() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "Hello EN")), .event(.tokens([2], "D more")), .hang])
        let ev = try await h.sse("/v1/messages", ant("[{\"role\":\"user\",\"content\":\"x\"}]", #""stream":true,"stop_sequences":["END"]"#))
        let text = ev.filter { $0.name == "content_block_delta" }.compactMap { ($0["delta"] as? [String: Any])?["text"] as? String }.joined()
        #expect(text == "Hello ")
        let md = ev.first { $0.name == "message_delta" }!["delta"] as! [String: Any]
        #expect(md["stop_reason"] as? String == "stop_sequence" && md["stop_sequence"] as? String == "END")
        #expect(ev.last?.name == "message_stop")
        #expect(h.engine.snapshot { $0.cancels.count } == 1)
    }

    @Test("tool_use / tool_result roundtrip across two turns reaches the engine in template form")
    func anthropicRoundtrip() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.toolCallBegin(name: "get_weather")), .event(.toolCallArg(key: "city", value: .string("Paris"))),
                         .event(.toolCallEnd), .event(.finished(.stop, makeUsage()))])
        let (_, j1) = try await h.json("/v1/messages", ant(#"[{"role":"user","content":"weather in Paris?"}]"#, weatherTool))
        let block = (j1["content"] as! [[String: Any]]).first!
        #expect(block["type"] as? String == "tool_use" && (block["input"] as? [String: String]) == ["city": "Paris"])
        let tid = block["id"] as! String

        h.engine.script([.event(.tokens([1], "Sunny.")), .event(.finished(.stop, makeUsage()))])
        let turn2 = """
        [{"role":"user","content":"weather in Paris?"},
         {"role":"assistant","content":[{"type":"thinking","thinking":"need tool","signature":"sig"},{"type":"redacted_thinking","data":"x"},
            {"type":"text","text":"Let me check."},{"type":"tool_use","id":"\(tid)","name":"get_weather","input":{"city":"Paris"}}]},
         {"role":"user","content":[{"type":"tool_result","tool_use_id":"\(tid)","content":[{"type":"text","text":"18C"},{"type":"text","text":"sunny"}]},
            {"type":"text","text":"thanks"}]}]
        """
        let (code, j2) = try await h.json("/v1/messages", ant(turn2, weatherTool))
        #expect(code == 200 && (j2["content"] as! [[String: Any]]).first?["text"] as? String == "Sunny.")
        let hist = h.lastHistory()
        #expect(hist.map(\.role) == [.user, .assistant, .tool, .user])
        #expect(hist[1].content == .text("Let me check."))
        #expect(hist[1].reasoningContent == "need tool")
        #expect(hist[1].toolCalls == [ToolCall(name: "get_weather", arguments: [("city", .string("Paris"))])])
        #expect(hist[2].content == .text("18C\nsunny"))
        #expect(hist[3].content == .text("thanks"))
        // Same conversation fingerprint: one pooled session served both turns.
        #expect(h.engine.snapshot { $0.opened.count } == 1)
    }

    @Test("tool_result is_error, string content, system blocks, tool_choice")
    func anthropicMisc() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "ok")), .event(.finished(.stop, makeUsage()))])
        let msgs = """
        [{"role":"user","content":"go"},
         {"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}]},
         {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":true,"content":"boom"}]}]
        """
        let (code, _) = try await h.json("/v1/messages", ant(msgs, weatherTool + #","system":[{"type":"text","text":"A"},{"type":"text","text":"B","cache_control":{"type":"ephemeral"}}],"tool_choice":{"type":"any"}"#))
        #expect(code == 200)
        let hist = h.lastHistory()
        #expect(hist.map(\.role) == [.system, .user, .assistant, .tool])
        #expect(hist[0].content == .text("A\n\nB"))
        #expect(hist[3].content == .text("Error: boom"))
        #expect(h.engine.snapshot { $0.opened.first?.1.toolChoice } == "required")
        // role "system" inside messages (sent by Claude Code) merges into the leading system message
        h.engine.script([.event(.tokens([1], "ok")), .event(.finished(.stop, makeUsage()))])
        let sm = #"[{"role":"user","content":"u"},{"role":"system","content":[{"type":"text","text":"env info"}]}]"#
        let (c0, _) = try await h.json("/v1/messages", ant(sm, #""system":"base""#))
        #expect(c0 == 200)
        let h0 = h.lastHistory()
        #expect(h0.map(\.role) == [.system, .user] && h0[0].content == .text("base\n\nenv info"))
        // tool_choice none drops the tools from the template (and thinking stays per request)
        _ = try await h.json("/v1/messages", ant(#"[{"role":"user","content":"z"}]"#, weatherTool + #","tool_choice":{"type":"none"}"#))
        #expect(h.engine.snapshot { $0.opened.last?.1.toolChoice } == "none")
    }

    @Test("count_tokens returns the engine prompt token count and does not generate")
    func countTokens() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.appendCounter = { input in
            if case .history(let m) = input { return 1000 + m.count }
            return 0
        }
        let (code, j) = try await h.json("/v1/messages/count_tokens",
                                         #"{"model":"claude-x","system":"s","messages":[{"role":"user","content":"hi"}]}"#)
        #expect(code == 200 && j["input_tokens"] as? Int == 1002)   // system + user
        #expect(h.engine.snapshot { $0.generates.count } == 0)
        #expect(h.engine.snapshot { $0.closed.count } == 1)        // throwaway session closed
        let (c2, j2) = try await h.json("/v1/messages/count_tokens", #"{"messages":[]}"#)
        #expect(c2 == 400 && j2["type"] as? String == "error")
    }

    @Test("auth: x-api-key and bearer accepted; Anthropic error shape")
    func anthropicAuth() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "a")), .event(.finished(.stop, makeUsage()))])
        var (c, _) = try await h.json("/v1/messages", ant(), headers: ["x-api-key": token, "anthropic-version": "2023-06-01"])
        #expect(c == 200)
        (c, _) = try await h.json("/v1/messages", ant(), headers: ["Authorization": "Bearer \(token)"])
        #expect(c == 200)
        let (c3, j3) = try await h.json("/v1/messages", ant(), headers: ["x-api-key": "wrong"])
        #expect(c3 == 401 && j3["type"] as? String == "error")
        #expect((j3["error"] as? [String: Any])?["type"] as? String == "authentication_error")
        let (c4, _) = try await h.json("/v1/messages/count_tokens", ant(), headers: [:])
        #expect(c4 == 401)
        // The OpenAI routes accept x-api-key too and keep the OpenAI error shape.
        let (c5, j5) = try await h.json("/v1/responses", #"{"input":"x"}"#, headers: [:])
        #expect(c5 == 401 && j5["error"] != nil && j5["type"] == nil)
        h.engine.script([.event(.tokens([1], "a")), .event(.finished(.stop, makeUsage()))])
        let (c6, _) = try await h.json("/v1/chat/completions", #"{"messages":[{"role":"user","content":"x"}]}"#, headers: ["x-api-key": token])
        #expect(c6 == 200)
    }

    @Test("error shapes: images, missing max_tokens, bad JSON, engine failure")
    func anthropicErrors() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        func err(_ body: String) async throws -> (Int, String, String) {
            let (c, j) = try await h.json("/v1/messages", body)
            let e = j["error"] as? [String: Any]
            #expect(j["type"] as? String == "error")
            return (c, e?["type"] as? String ?? "", e?["message"] as? String ?? "")
        }
        var r = try await err(ant(#"[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]}]"#))
        #expect(r.0 == 400 && r.1 == "invalid_request_error" && r.2.contains("image"))
        r = try await err(ant(#"[{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"image","source":{}}]}]}]"#))
        #expect(r.0 == 400)
        r = try await err(#"{"model":"m","messages":[{"role":"user","content":"x"}]}"#)
        #expect(r.0 == 400 && r.2.contains("max_tokens"))
        r = try await err("{nope")
        #expect(r.0 == 400)
        r = try await err(ant(#"[{"role":"user","content":"x"}]"#, #""temperature":"hot""#))
        #expect(r.0 == 400)
        h.engine.openError = .insufficientMemory(needed: 1 << 30, available: 0)
        r = try await err(ant())
        #expect(r.0 == 503 && r.1 == "overloaded_error")
        h.engine.openError = nil
        h.engine.script([.fail(.mlx("kaput"))])
        r = try await err(ant())
        #expect(r.0 == 500 && r.1 == "api_error")
        // mid-stream failure after the SSE opened: event: error
        h.engine.script([.event(.tokens([1], "partial")), .fail(.mlx("kaput"))])
        let ev = try await h.sse("/v1/messages", ant("[{\"role\":\"user\",\"content\":\"x\"}]", #""stream":true"#))
        #expect(ev.last?.name == "error" && (ev.last?["error"] as? [String: Any])?["type"] as? String == "api_error")
    }

    @Test("thinking: absent or disabled => off; enabled => on without tools")
    func anthropicThinking() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "a")), .event(.finished(.stop, makeUsage()))])
        _ = try await h.json("/v1/messages", ant(#"[{"role":"user","content":"a"}]"#))
        _ = try await h.json("/v1/messages", ant(#"[{"role":"user","content":"b"}]"#, #""thinking":{"type":"disabled"}"#))
        _ = try await h.json("/v1/messages", ant(#"[{"role":"user","content":"c"}]"#, #""thinking":{"type":"enabled","budget_tokens":2048}"#))
        let th = h.engine.snapshot { $0.opened.map { $0.1.enableThinking } }
        #expect(th == [false, false, true])
    }

    // MARK: Responses

    private func respBody(_ input: String, _ extra: String = "") -> String {
        #"{"model":"m","input":\#(input)\#(extra.isEmpty ? "" : "," + extra)}"#
    }

    @Test("responses text stream: exact event sequence and usage")
    func responsesStream() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "Hi")), .event(.tokens([2], " you")),
                         .event(.finished(.stop, makeUsage(prompt: 11, cached: 4, completion: 3)))])
        let ev = try await h.sse("/v1/responses", respBody(#""hello""#, #""stream":true,"instructions":"be brief""#))
        #expect(ev.map(\.name) == ["response.created", "response.in_progress", "response.output_item.added",
                                   "response.content_part.added", "response.output_text.delta", "response.output_text.delta",
                                   "response.output_text.done", "response.content_part.done", "response.output_item.done",
                                   "response.completed"])
        for (i, e) in ev.enumerated() { #expect(e["type"] as? String == e.name && e["sequence_number"] as? Int == i) }
        let created = ev[0]["response"] as! [String: Any]
        #expect(created["status"] as? String == "in_progress" && (created["id"] as? String)?.hasPrefix("resp_") == true)
        let item = ev[2]["item"] as! [String: Any]
        #expect(item["type"] as? String == "message" && ev[2]["output_index"] as? Int == 0)
        #expect(ev[4]["delta"] as? String == "Hi" && ev[4]["item_id"] as? String == item["id"] as? String)
        #expect(ev[6]["text"] as? String == "Hi you")
        let done = ev[9]["response"] as! [String: Any]
        #expect(done["status"] as? String == "completed")
        let out = (done["output"] as! [[String: Any]]).first!
        #expect(((out["content"] as! [[String: Any]]).first)?["text"] as? String == "Hi you")
        let u = done["usage"] as! [String: Any]
        #expect(u["input_tokens"] as? Int == 11 && u["output_tokens"] as? Int == 3 && u["total_tokens"] as? Int == 14)
        #expect((u["input_tokens_details"] as! [String: Any])["cached_tokens"] as? Int == 4)
        // instructions became the system message
        let hist = h.lastHistory()
        #expect(hist.map(\.role) == [.system, .user] && hist[0].content == .text("be brief"))
    }

    @Test("responses reasoning + function_call stream")
    func responsesToolStream() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.reasoning("think")), .event(.toolCallBegin(name: "get_weather")),
                         .event(.toolCallArg(key: "city", value: .string("Paris"))), .event(.toolCallEnd),
                         .event(.finished(.stop, makeUsage()))])
        let tools = #""tools":[{"type":"function","name":"get_weather","description":"w","parameters":{"type":"object"}},{"type":"web_search"}],"stream":true"#
        let ev = try await h.sse("/v1/responses", respBody(#""w?""#, tools))
        #expect(ev.map(\.name) == ["response.created", "response.in_progress",
                                   "response.output_item.added", "response.reasoning_summary_part.added",
                                   "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done",
                                   "response.reasoning_summary_part.done", "response.output_item.done",
                                   "response.output_item.added", "response.function_call_arguments.delta",
                                   "response.function_call_arguments.delta", "response.function_call_arguments.done",
                                   "response.output_item.done", "response.completed"])
        #expect(ev[7]["output_index"] as? Int == 0 && ev[8]["output_index"] as? Int == 1)
        let fc = ev[8]["item"] as! [String: Any]
        #expect(fc["type"] as? String == "function_call" && fc["name"] as? String == "get_weather" && fc["arguments"] as? String == "")
        #expect((fc["call_id"] as? String)?.hasPrefix("call_") == true)
        #expect(ev[11]["arguments"] as? String == #"{"city": "Paris"}"#)
        let final = (ev[13]["response"] as! [String: Any])["output"] as! [[String: Any]]
        #expect(final.map { $0["type"] as? String } == ["reasoning", "function_call"])
        #expect(final[1]["arguments"] as? String == #"{"city": "Paris"}"#)
        // web_search ignored, function declared
        #expect(h.engine.snapshot { $0.opened.first?.1.tools.map { $0.name } } == ["get_weather"])
    }

    @Test("responses non-stream: shape, incomplete on length")
    func responsesNonStream() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "abc")), .event(.finished(.length, makeUsage(prompt: 5, completion: 1)))])
        var (c, j) = try await h.json("/v1/responses", respBody(#""x""#, #""max_output_tokens":1"#))
        #expect(c == 200 && j["object"] as? String == "response" && j["status"] as? String == "incomplete")
        #expect((j["incomplete_details"] as? [String: Any])?["reason"] as? String == "max_output_tokens")
        #expect(h.engine.snapshot { $0.generates.last?.params.maxTokens } == 1)
        h.engine.script([.event(.tokens([1], "ok")), .event(.finished(.stop, makeUsage()))])
        (c, j) = try await h.json("/v1/responses", respBody(#""x""#))
        #expect(j["status"] as? String == "completed" && (j["output"] as! [[String: Any]]).first?["type"] as? String == "message")
        #expect((j["usage"] as! [String: Any])["total_tokens"] as? Int == 13)
    }

    @Test("responses input items map to chat messages")
    func responsesInputItems() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "done")), .event(.finished(.stop, makeUsage()))])
        let input = """
        [{"type":"message","role":"developer","content":[{"type":"input_text","text":"dev rules"}]},
         {"type":"message","role":"user","content":[{"type":"input_text","text":"list files"}]},
         {"type":"reasoning","summary":[{"type":"summary_text","text":"plan"}]},
         {"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]},
         {"type":"function_call","call_id":"call_1","name":"shell","arguments":"{\\"cmd\\":\\"ls\\"}"},
         {"type":"function_call_output","call_id":"call_1","output":"a.txt"}]
        """
        let (c, _) = try await h.json("/v1/responses", respBody(input, #""instructions":"base","tools":[{"type":"function","name":"shell","parameters":{"type":"object"}}]"#))
        #expect(c == 200)
        let hist = h.lastHistory()
        #expect(hist.map(\.role) == [.system, .user, .assistant, .tool])
        #expect(hist[0].content == .text("base\n\ndev rules"))
        #expect(hist[2].content == .text("ok") && hist[2].reasoningContent == "plan")
        #expect(hist[2].toolCalls == [ToolCall(name: "shell", arguments: [("cmd", .string("ls"))])])
        #expect(hist[3].content == .text("a.txt"))
        // unsupported items and images are clear 400s
        let (c2, j2) = try await h.json("/v1/responses", respBody(#"[{"type":"computer_call","id":"x"}]"#))
        #expect(c2 == 400 && (j2["error"] as? [String: Any])?["message"] as? String != nil)
        let (c3, _) = try await h.json("/v1/responses", respBody(#"[{"type":"message","role":"user","content":[{"type":"input_image","image_url":"x"}]}]"#))
        #expect(c3 == 400)
    }

    @Test("previous_response_id continues the stored conversation; store=false and unknown ids are 400")
    func responsesPrevious() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.toolCallBegin(name: "shell")), .event(.toolCallArg(key: "cmd", value: .string("ls"))),
                         .event(.toolCallEnd), .event(.finished(.stop, makeUsage()))])
        let tools = #""instructions":"sys","tools":[{"type":"function","name":"shell","parameters":{"type":"object"}}]"#
        let (_, r1) = try await h.json("/v1/responses", respBody(#""list""#, tools))
        let id1 = r1["id"] as! String
        let call = (r1["output"] as! [[String: Any]]).first { $0["type"] as? String == "function_call" }!

        h.engine.script([.event(.tokens([1], "two files")), .event(.finished(.stop, makeUsage()))])
        let out = #"[{"type":"function_call_output","call_id":"\#(call["call_id"] as! String)","output":"a b"}]"#
        let (c2, r2) = try await h.json("/v1/responses", respBody(out, tools + #","previous_response_id":"\#(id1)""#))
        #expect(c2 == 200 && r2["previous_response_id"] as? String == id1)
        let hist = h.lastHistory()
        #expect(hist.map(\.role) == [.system, .user, .assistant, .tool])
        #expect(hist[2].toolCalls == [ToolCall(name: "shell", arguments: [("cmd", .string("ls"))])])
        #expect(hist[3].content == .text("a b"))
        #expect(h.engine.snapshot { $0.opened.count } == 1)   // same fingerprint: hot session reused

        // chain once more from the second response
        h.engine.script([.event(.tokens([1], "bye")), .event(.finished(.stop, makeUsage()))])
        let (c3, _) = try await h.json("/v1/responses", respBody(#""thanks""#, tools + #","previous_response_id":"\#(r2["id"] as! String)""#))
        #expect(c3 == 200)
        #expect(h.lastHistory().map(\.role) == [.system, .user, .assistant, .tool, .assistant, .user])

        let (c4, j4) = try await h.json("/v1/responses", respBody(#""x""#, #""previous_response_id":"resp_nope""#))
        #expect(c4 == 400 && ((j4["error"] as? [String: Any])?["message"] as? String)?.contains("resp_nope") == true)

        h.engine.script([.event(.tokens([1], "q")), .event(.finished(.stop, makeUsage()))])
        let (_, r5) = try await h.json("/v1/responses", respBody(#""secret""#, #""store":false"#))
        let (c6, _) = try await h.json("/v1/responses", respBody(#""x""#, #""previous_response_id":"\#(r5["id"] as! String)""#))
        #expect(c6 == 400)
    }

    @Test("responses stream with previous_response_id stores the streamed output")
    func responsesStreamStored() async throws {
        let h = try await H.start(); defer { h.server.stop() }
        h.engine.script([.event(.reasoning("r")), .event(.tokens([1], "first")), .event(.finished(.stop, makeUsage()))])
        let ev = try await h.sse("/v1/responses", respBody(#""a""#, #""stream":true"#))
        let id = (ev.last!["response"] as! [String: Any])["id"] as! String
        h.engine.script([.event(.tokens([1], "second")), .event(.finished(.stop, makeUsage()))])
        let (c, _) = try await h.json("/v1/responses", respBody(#""b""#, #""previous_response_id":"\#(id)""#))
        #expect(c == 200)
        let hist = h.lastHistory()
        #expect(hist.map(\.role) == [.user, .assistant, .user])
        #expect(hist[1].content == .text("first") && hist[1].reasoningContent == "r")
    }
}
