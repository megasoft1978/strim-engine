import Foundation
import Testing
import StrimEngine
import StrimHTTP
import StrimTemplate
@testable import StrimServer

private let token = "test-token-123"

private struct Harness {
    let engine: FakeEngine
    let server: StrimOpenAIServer
    let port: UInt16

    static func start(token: String? = token, maxSessions: Int = 8) async throws -> Harness {
        let engine = FakeEngine()
        let server = StrimOpenAIServer(engine: engine, config: ServerConfig(
            modelId: "fake-model", maxSessions: maxSessions, bearerToken: token))
        let port = try await server.start(port: 0)
        return Harness(engine: engine, server: server, port: port)
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func request(_ path: String, method: String = "POST", body: String? = nil, auth: String? = "Bearer \(token)",
                 headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        if let body { r.httpBody = Data(body.utf8) }
        if let auth { r.setValue(auth, forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    func send(_ r: URLRequest) async throws -> (Int, Data) {
        let s = URLSession(configuration: .ephemeral)
        defer { s.finishTasksAndInvalidate() }
        let (data, resp) = try await s.data(for: r)
        return ((resp as! HTTPURLResponse).statusCode, data)
    }

    func json(_ r: URLRequest) async throws -> (Int, [String: Any]) {
        let (c, d) = try await send(r)
        return (c, (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:])
    }

    /// Streaming chat; returns the data payloads (JSON objects, plus "[DONE]" as a string marker).
    func stream(_ body: String, headers: [String: String] = [:]) async throws -> [Any] {
        let s = URLSession(configuration: .ephemeral)
        defer { s.finishTasksAndInvalidate() }
        let (bytes, resp) = try await s.bytes(for: request("/v1/chat/completions", body: body, headers: headers))
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        var out: [Any] = []
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            let p = String(line.dropFirst(6))
            if p == "[DONE]" { out.append("[DONE]") } else { out.append(try JSONSerialization.jsonObject(with: Data(p.utf8))) }
        }
        return out
    }
}

private func chatBody(_ messages: String = #"[{"role":"user","content":"hi"}]"#, extra: String = "") -> String {
    #"{"model":"fake-model","messages":\#(messages)\#(extra.isEmpty ? "" : "," + extra)}"#
}

private func delta(_ chunk: Any) -> [String: Any] {
    let c = ((chunk as? [String: Any])?["choices"] as? [[String: Any]])?.first
    return (c?["delta"] as? [String: Any]) ?? [:]
}

private func finish(_ chunk: Any) -> String? {
    (((chunk as? [String: Any])?["choices"] as? [[String: Any]])?.first)?["finish_reason"] as? String
}

@Suite("StrimServer", .serialized)
struct ServerTests {
    @Test("stream chunk shapes, reasoning, usage chunk, [DONE]")
    func streamShapes() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([
            .event(.reasoning("think ")), .event(.reasoning("hard")),
            .event(.tokens([1], "Hello")), .event(.tokens([2, 3], " world")),
            .event(.finished(.stop, makeUsage(prompt: 12, cached: 5, completion: 3))),
        ])
        let chunks = try await h.stream(chatBody(extra: #""stream":true,"stream_options":{"include_usage":true}"#))
        #expect(chunks.count == 8)
        #expect(delta(chunks[0])["role"] as? String == "assistant")
        #expect((chunks[0] as? [String: Any])?["object"] as? String == "chat.completion.chunk")
        #expect((chunks[0] as? [String: Any])?["model"] as? String == "fake-model")
        #expect(((chunks[0] as? [String: Any])?["id"] as? String)?.hasPrefix("chatcmpl-") == true)
        #expect(delta(chunks[1])["reasoning_content"] as? String == "think ")
        #expect(delta(chunks[2])["reasoning_content"] as? String == "hard")
        #expect(delta(chunks[3])["content"] as? String == "Hello")
        #expect(delta(chunks[4])["content"] as? String == " world")
        #expect(finish(chunks[5]) == "stop")
        let usageChunk = chunks[6] as? [String: Any]
        #expect((usageChunk?["choices"] as? [Any])?.isEmpty == true)
        let usage = usageChunk?["usage"] as? [String: Any]
        #expect(usage?["prompt_tokens"] as? Int == 12)
        #expect(usage?["completion_tokens"] as? Int == 3)
        #expect(usage?["total_tokens"] as? Int == 15)
        #expect((usage?["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int == 5)
        #expect(chunks[7] as? String == "[DONE]")
    }

    @Test("no usage chunk unless include_usage")
    func noUsageByDefault() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "a")), .event(.finished(.stop, makeUsage()))])
        let chunks = try await h.stream(chatBody(extra: #""stream":true"#))
        #expect(chunks.count == 4)   // role, content, finish, [DONE]
        #expect(chunks.last as? String == "[DONE]")
    }

    @Test("non-stream response shape")
    func nonStream() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.event(.reasoning("why")), .event(.tokens([1], "Hel")), .event(.tokens([2], "lo")),
                         .event(.finished(.length, makeUsage(prompt: 7, cached: 2, completion: 2)))])
        let (code, j) = try await h.json(h.request("/v1/chat/completions", body: chatBody()))
        #expect(code == 200)
        #expect(j["object"] as? String == "chat.completion")
        let choice = (j["choices"] as? [[String: Any]])?.first
        #expect(choice?["finish_reason"] as? String == "length")
        let msg = choice?["message"] as? [String: Any]
        #expect(msg?["role"] as? String == "assistant")
        #expect(msg?["content"] as? String == "Hello")
        #expect(msg?["reasoning_content"] as? String == "why")
        let usage = j["usage"] as? [String: Any]
        #expect(usage?["prompt_tokens"] as? Int == 7)
        #expect((usage?["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int == 2)
    }

    @Test("tool call streaming: name first, then argument fragments; finish tool_calls")
    func toolCallStream() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([
            .event(.tokens([1], "Checking.")),
            .event(.toolCallBegin(name: "get_weather")),
            .event(.toolCallArg(key: "city", value: .string("Paris"))),
            .event(.toolCallArg(key: "days", value: .int(2))),
            .event(.toolCallEnd),
            .event(.toolCallBegin(name: "noargs")), .event(.toolCallEnd),
            .event(.finished(.stop, makeUsage())),
        ])
        let tools = #""tools":[{"type":"function","function":{"name":"get_weather","description":"w","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}],"stream":true"#
        let chunks = try await h.stream(chatBody(extra: tools))
        var calls: [Int: (id: String?, name: String?, args: String)] = [:]
        var order: [String] = []
        for c in chunks {
            guard let tcs = delta(c)["tool_calls"] as? [[String: Any]] else {
                if let t = delta(c)["content"] as? String { order.append("content:" + t) }
                continue
            }
            for tc in tcs {
                let i = tc["index"] as! Int
                var e = calls[i] ?? (nil, nil, "")
                if let id = tc["id"] as? String { e.id = id; order.append("start\(i)") }
                let fn = tc["function"] as? [String: Any]
                if let n = fn?["name"] as? String { e.name = n }
                e.args += (fn?["arguments"] as? String) ?? ""
                calls[i] = e
            }
        }
        #expect(order == ["content:Checking.", "start0", "start1"])
        #expect(calls[0]?.name == "get_weather")
        #expect(calls[0]?.id?.hasPrefix("call_") == true)
        #expect(calls[0]?.args == #"{"city": "Paris", "days": 2}"#)
        #expect(calls[1]?.args == "{}")
        // The name chunk carries empty arguments; the arguments come in later chunks.
        let firstTool = chunks.compactMap { (delta($0)["tool_calls"] as? [[String: Any]])?.first }.first
        #expect((firstTool?["function"] as? [String: Any])?["arguments"] as? String == "")
        #expect(chunks.compactMap(finish).last == "tool_calls")
        // The declared tool reached the session config.
        let cfg = h.engine.snapshot { $0.opened.first?.1 }
        #expect(cfg?.tools.first?.name == "get_weather")
    }

    @Test("tool call non-stream: null content, tool_calls array, finish tool_calls")
    func toolCallNonStream() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.event(.toolCallBegin(name: "f")), .event(.toolCallArg(key: "x", value: .bool(true))),
                         .event(.toolCallEnd), .event(.finished(.stop, makeUsage()))])
        let (_, j) = try await h.json(h.request("/v1/chat/completions", body: chatBody(extra: #""tools":[{"type":"function","function":{"name":"f"}}]"#)))
        let choice = (j["choices"] as? [[String: Any]])?.first
        #expect(choice?["finish_reason"] as? String == "tool_calls")
        let msg = choice?["message"] as? [String: Any]
        #expect(msg?["content"] is NSNull)
        let call = (msg?["tool_calls"] as? [[String: Any]])?.first
        #expect(call?["type"] as? String == "function")
        let fn = call?["function"] as? [String: Any]
        #expect(fn?["name"] as? String == "f")
        #expect(fn?["arguments"] as? String == #"{"x": true}"#)
    }

    @Test("tool_choice none drops tools")
    func toolChoiceNone() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "x")), .event(.finished(.stop, makeUsage()))])
        _ = try await h.send(h.request("/v1/chat/completions", body: chatBody(extra: #""tool_choice":"none","tools":[{"type":"function","function":{"name":"f"}}]"#)))
        let cfg = h.engine.snapshot { $0.opened.first?.1 }
        #expect(cfg?.tools.isEmpty == true)
        #expect(cfg?.toolChoice == "none")
    }

    @Test("stop string cuts the text, cancels the engine, finish stop")
    func stopStrings() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "Hello EN")), .event(.tokens([2], "D and more")), .hang])
        let chunks = try await h.stream(chatBody(extra: #""stream":true,"stop":["END"]"#))
        let text = chunks.compactMap { delta($0)["content"] as? String }.joined()
        #expect(text == "Hello ")
        #expect(chunks.compactMap(finish).last == "stop")
        #expect(chunks.last as? String == "[DONE]")
        #expect(h.engine.snapshot { $0.cancels.count } == 1)
        // Non-stream, stop split across events, single string form.
        h.engine.script([.event(.tokens([1], "ab")), .event(.tokens([2], "cSTOPxyz")), .hang])
        let (_, j) = try await h.json(h.request("/v1/chat/completions", body: chatBody(extra: #""stop":"STOP""#)))
        let msg = ((j["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
        #expect(msg?["content"] as? String == "abc")
        #expect(((j["choices"] as? [[String: Any]])?.first)?["finish_reason"] as? String == "stop")
    }

    @Test("client disconnect cancels the engine request")
    func disconnectCancels() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "partial")), .hang])
        let s = URLSession(configuration: .ephemeral)
        let (bytes, _) = try await s.bytes(for: h.request("/v1/chat/completions", body: chatBody(extra: #""stream":true"#)))
        var it = bytes.lines.makeAsyncIterator()
        var gotContent = false
        while let line = try await it.next() {
            if line.contains("partial") { gotContent = true; break }
        }
        #expect(gotContent)
        s.invalidateAndCancel()
        var cancelled = false
        for _ in 0 ..< 100 {
            if h.engine.snapshot({ $0.terminatedCancelled }) >= 1 { cancelled = true; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(cancelled)
    }

    @Test("non-stream disconnect also cancels")
    func disconnectNonStream() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.hang])
        let s = URLSession(configuration: .ephemeral)
        let t = Task { try? await s.data(for: h.request("/v1/chat/completions", body: chatBody())) }
        for _ in 0 ..< 100 where h.engine.snapshot({ $0.generates.count }) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        s.invalidateAndCancel()
        _ = await t.value
        var cancelled = false
        for _ in 0 ..< 100 {
            if h.engine.snapshot({ $0.terminatedCancelled }) >= 1 { cancelled = true; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(cancelled)
    }

    @Test("auth: bearer required by default; /health open; no-auth mode")
    func auth() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        for auth in [nil, "Bearer wrong", "Basic abc", "Bearer"] as [String?] {
            let (code, j) = try await h.json(h.request("/v1/models", method: "GET", auth: auth))
            #expect(code == 401)
            #expect((j["error"] as? [String: Any])?["type"] as? String == "authentication_error")
            #expect(((j["error"] as? [String: Any])?["message"] as? String)?.isEmpty == false)
        }
        let (c1, _) = try await h.json(h.request("/v1/chat/completions", body: chatBody(), auth: nil))
        #expect(c1 == 401)
        let (c2, _) = try await h.json(h.request("/v1/models", method: "GET"))
        #expect(c2 == 200)
        let (c3, _) = try await h.json(h.request("/health", method: "GET", auth: nil))
        #expect(c3 == 200)
        let (c4, _) = try await h.json(h.request("/metrics", method: "GET", auth: nil))
        #expect(c4 == 401)
        #expect(h.engine.snapshot { $0.generates.count } == 0)

        let open = try await Harness.start(token: nil); defer { open.server.stop() }
        let (c5, _) = try await open.json(open.request("/v1/models", method: "GET", auth: nil))
        #expect(c5 == 200)
    }

    @Test("models, health, metrics, cancel endpoint, 404")
    func misc() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        let (_, m) = try await h.json(h.request("/v1/models", method: "GET"))
        #expect(m["object"] as? String == "list")
        #expect(((m["data"] as? [[String: Any]])?.first)?["id"] as? String == "fake-model")
        let (hc, hj) = try await h.json(h.request("/health", method: "GET", auth: nil))
        #expect(hc == 200 && hj["status"] as? String == "ok" && hj["engine"] as? String == "up")
        let (_, mj) = try await h.json(h.request("/metrics", method: "GET"))
        #expect((mj["engine"] as? [String: Any])?["healthy"] as? Bool == true)
        #expect(mj["server"] != nil)
        h.engine.unhealthy = "gpu hung"
        let (uc, uj) = try await h.json(h.request("/health", method: "GET", auth: nil))
        #expect(uc == 503 && uj["status"] as? String == "unhealthy")
        let (nc, nj) = try await h.json(h.request("/v1/nope", method: "GET"))
        #expect(nc == 404)
        #expect((nj["error"] as? [String: Any])?["type"] as? String == "not_found")
        let (cc, _) = try await h.json(h.request("/v1/strim/cancel/chatcmpl-unknown"))
        #expect(cc == 404)
    }

    @Test("cancel endpoint cancels an active request")
    func cancelEndpoint() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "go")), .hang])
        let s = URLSession(configuration: .ephemeral); defer { s.finishTasksAndInvalidate() }
        let (bytes, _) = try await s.bytes(for: h.request("/v1/chat/completions", body: chatBody(extra: #""stream":true"#)))
        var it = bytes.lines.makeAsyncIterator()
        var id = ""
        while let line = try await it.next() {
            if line.hasPrefix("data: {"), let o = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
               let i = o["id"] as? String { id = i; break }
        }
        let (code, j) = try await h.json(h.request("/v1/strim/cancel/\(id)"))
        #expect(code == 200 && j["cancelled"] as? Bool == true)
        var last = ""
        while let line = try await it.next() { last = line; if line == "data: [DONE]" { break } }
        #expect(last == "data: [DONE]")
    }

    @Test("history resend maps to the same session; different conversation gets a new one")
    func sessionMapping() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "A1")), .event(.finished(.stop, makeUsage()))])
        let sys = #"{"role":"system","content":"be brief"}"#
        let t1 = "[\(sys),{\"role\":\"user\",\"content\":\"q1\"}]"
        let t2 = "[\(sys),{\"role\":\"user\",\"content\":\"q1\"},{\"role\":\"assistant\",\"content\":\"A1\"},{\"role\":\"user\",\"content\":\"q2\"}]"
        _ = try await h.send(h.request("/v1/chat/completions", body: chatBody(t1)))
        _ = try await h.send(h.request("/v1/chat/completions", body: chatBody(t2)))
        #expect(h.engine.snapshot { $0.opened.count } == 1)
        let appends = h.engine.snapshot { $0.appends }
        #expect(appends.count == 2)
        #expect(appends[0].0 == appends[1].0)
        if case .history(let m) = appends[1].1 { #expect(m.count == 4) } else { Issue.record("expected .history") }
        #expect(h.engine.snapshot { $0.generates.map(\.session) }.count == 2)
        // Different system prompt: new conversation.
        let other = #"[{"role":"system","content":"other"},{"role":"user","content":"q1"}]"#
        _ = try await h.send(h.request("/v1/chat/completions", body: chatBody(other)))
        #expect(h.engine.snapshot { $0.opened.count } == 2)
        // Different tools: new conversation too.
        _ = try await h.send(h.request("/v1/chat/completions", body: chatBody(t1, extra: #""tools":[{"type":"function","function":{"name":"f"}}]"#)))
        #expect(h.engine.snapshot { $0.opened.count } == 3)
        let (_, mj) = try await h.json(h.request("/metrics", method: "GET"))
        #expect((mj["server"] as? [String: Any])?["session_reuses"] as? Int == 1)
    }

    @Test("session cap closes the least recently used idle session")
    func sessionCap() async throws {
        let h = try await Harness.start(maxSessions: 2); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "x")), .event(.finished(.stop, makeUsage()))])
        for n in 1 ... 3 {
            _ = try await h.send(h.request("/v1/chat/completions", body: chatBody("[{\"role\":\"user\",\"content\":\"c\(n)\"}]")))
        }
        let (opened, closed) = h.engine.snapshot { ($0.opened.map(\.0), $0.closed) }
        #expect(opened.count == 3)
        #expect(closed == [opened[0]])
        // Conversation 1 was evicted, so it opens a fresh session; conversation 3 still reuses.
        _ = try await h.send(h.request("/v1/chat/completions", body: chatBody("[{\"role\":\"user\",\"content\":\"c3\"}]")))
        #expect(h.engine.snapshot { $0.opened.count } == 3)
        _ = try await h.send(h.request("/v1/chat/completions", body: chatBody("[{\"role\":\"user\",\"content\":\"c1\"}]")))
        #expect(h.engine.snapshot { $0.opened.count } == 4)
    }

    @Test("concurrent request on a busy conversation uses a throwaway session")
    func busyConversation() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.hang])
        h.engine.script([.event(.tokens([1], "ok")), .event(.finished(.stop, makeUsage()))])
        let s = URLSession(configuration: .ephemeral)
        let first = Task { try? await s.data(for: h.request("/v1/chat/completions", body: chatBody())) }
        for _ in 0 ..< 100 where h.engine.snapshot({ $0.generates.count }) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let (code, _) = try await h.json(h.request("/v1/chat/completions", body: chatBody()))
        #expect(code == 200)
        #expect(h.engine.snapshot { $0.opened.count } == 2)
        #expect(h.engine.snapshot { $0.closed.count } == 1)   // the throwaway one
        s.invalidateAndCancel()
        _ = await first.value
    }

    @Test("request fields reach the engine")
    func paramMapping() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.event(.finished(.stop, makeUsage()))])
        let extra = #""temperature":0.3,"top_p":0.8,"top_k":7,"seed":42,"max_completion_tokens":33,"max_tokens":99,"ignore_eos":true,"chat_template_kwargs":{"enable_thinking":false}"#
        _ = try await h.send(h.request("/v1/chat/completions", body: chatBody(extra: extra), headers: ["x-strim-priority": "background"]))
        let g = h.engine.snapshot { $0.generates.first }
        #expect(g?.params.maxTokens == 33)
        #expect(abs((g?.params.temperature ?? 0) - 0.3) < 1e-6)
        #expect(abs((g?.params.topP ?? 0) - 0.8) < 1e-6)
        #expect(g?.params.topK == 7)
        #expect(g?.params.seed == 42)
        #expect(g?.params.ignoreEOS == true)
        #expect(g?.params.priority == .background)
        #expect(h.engine.snapshot { $0.opened.first?.1.enableThinking } == false)
        // Defaults: interactive, EOS honoured, generation_config sampling.
        _ = try await h.send(h.request("/v1/chat/completions", body: chatBody("[{\"role\":\"user\",\"content\":\"other\"}]")))
        let g2 = h.engine.snapshot { $0.generates.last }
        #expect(g2?.params.priority == .interactive)
        #expect(g2?.params.ignoreEOS == false)
        #expect(g2?.params.maxTokens == 4096)
    }

    @Test("message conversion: developer role, content parts, tool messages and tool_calls")
    func messageConversion() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.event(.finished(.stop, makeUsage()))])
        let msgs = #"""
        [{"role":"developer","content":"d"},
         {"role":"user","content":[{"type":"text","text":"hello"}]},
         {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"f","arguments":"{\"a\": 1}"}}]},
         {"role":"tool","tool_call_id":"c1","content":"result"},
         {"role":"user","content":"next"}]
        """#
        let (code, _) = try await h.send(h.request("/v1/chat/completions", body: chatBody(msgs)))
        #expect(code == 200)
        guard case .history(let m)? = h.engine.snapshot({ $0.appends.first?.1 }) else { Issue.record("no append"); return }
        #expect(m.map(\.role) == [.system, .user, .assistant, .tool, .user])
        #expect(m[2].toolCalls.first?.name == "f")
        #expect(m[2].toolCalls.first?.arguments?.first?.key == "a")
        if case .parts = m[1].content {} else { Issue.record("expected parts") }
    }

    @Test("error shapes")
    func errors() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        func err(_ body: String, headers: [String: String] = [:]) async throws -> (Int, String?, String?) {
            let (c, j) = try await h.json(h.request("/v1/chat/completions", body: body, headers: headers))
            let e = j["error"] as? [String: Any]
            return (c, e?["type"] as? String, e?["message"] as? String)
        }
        let bad: [String] = [
            "not json", "[]", #"{"messages":[]}"#, #"{"messages":"x"}"#,
            chatBody(#"[{"role":"wizard","content":"x"}]"#),
            chatBody(extra: #""n":2"#), chatBody(extra: #""max_tokens":0"#), chatBody(extra: #""temperature":"hot""#),
            chatBody(extra: #""stop":[1]"#), chatBody(extra: #""top_p":0"#),
            chatBody(#"[{"role":"user","content":[{"type":"image_url","image_url":{"url":"x"}}]}]"#),
        ]
        for b in bad {
            let (c, t, m) = try await err(b)
            #expect(c == 400, "body: \(b)")
            #expect(t == "invalid_request")
            #expect(m?.isEmpty == false)
        }
        let (pc, _, pm) = try await err(chatBody(), headers: ["x-strim-priority": "urgent"])
        #expect(pc == 400 && pm?.contains("priority") == true)
        #expect(h.engine.snapshot { $0.generates.count } == 0)

        // Engine failures before any output become HTTP errors, streaming or not.
        h.engine.script([.fail(.unhealthy("gpu hung"))])
        let (c1, t1, _) = try await err(chatBody())
        #expect(c1 == 503 && t1 == "engine_unavailable")
        h.engine.script([.fail(.insufficientMemory(needed: 10 << 30, available: 1 << 30))])
        let (c2, t2, m2) = try await err(chatBody(extra: #""stream":true"#))
        #expect(c2 == 503 && t2 == "engine_unavailable" && m2?.contains("insufficient memory") == true)
        h.engine.openError = .shutdown
        let (c3, _, _) = try await err(chatBody("[{\"role\":\"user\",\"content\":\"zz\"}]"))
        #expect(c3 == 503)
    }

    @Test("engine failure mid-stream sends an error event then [DONE]")
    func midStreamError() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        h.engine.script([.event(.tokens([1], "part")), .fail(.mlx("boom"))])
        let chunks = try await h.stream(chatBody(extra: #""stream":true"#))
        let err = chunks.compactMap { ($0 as? [String: Any])?["error"] as? [String: Any] }.first
        #expect(err?["type"] as? String == "engine_error")
        #expect(chunks.last as? String == "[DONE]")
    }

    @Test("token store creates a 0600 file once and reuses it")
    func tokenStore() throws {
        let dir = NSTemporaryDirectory() + "strim-tok-\(UUID().uuidString)"
        let path = dir + "/sub/token"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = try TokenStore.loadOrCreate(path: path)
        #expect(a.count == 64)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect(try TokenStore.loadOrCreate(path: path) == a)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        _ = try TokenStore.loadOrCreate(path: path)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test("stop scanner holds back partial matches")
    func stopScanner() {
        var s = StopScanner(["STOP", "\n\n"])
        #expect(s.feed("abcST").0 == "ab")
        #expect(s.feed("OxSTOP").1 == true)
        var t = StopScanner(["END"])
        let (o, hit) = t.feed("fine EN")
        #expect(o == "fine " && !hit)
        #expect(t.flush() == "EN")
        var u = StopScanner([])
        #expect(u.feed("anything").0 == "anything")
    }

    @Test("fingerprint ignores later turns, tracks system, first user, tools, template config")
    func fingerprint() throws {
        func fp(_ messages: String, extra: String = "") throws -> UInt64 {
            try ChatRequest.parse(Data(chatBody(messages, extra: extra).utf8), headerPriority: nil, defaults: SamplingDefaults()).fingerprint
        }
        let base = try fp(#"[{"role":"system","content":"s"},{"role":"user","content":"a"}]"#)
        #expect(base == (try fp(#"[{"role":"system","content":"s"},{"role":"user","content":"a"},{"role":"assistant","content":"r"},{"role":"user","content":"b"}]"#)))
        #expect(base != (try fp(#"[{"role":"system","content":"t"},{"role":"user","content":"a"}]"#)))
        #expect(base != (try fp(#"[{"role":"system","content":"s"},{"role":"user","content":"c"}]"#)))
        #expect(base != (try fp(#"[{"role":"system","content":"s"},{"role":"user","content":"a"}]"#, extra: #""chat_template_kwargs":{"enable_thinking":false}"#)))
    }
}
