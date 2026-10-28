import Foundation
import Testing
import StrimHTTP
import StrimTemplate
@testable import StrimMCP

private struct FakeProvider: MCPToolProvider {
    func definitions() -> [MCPToolDefinition] {
        ["echo", "fail", "slow", "burst"].map {
            MCPToolDefinition(name: $0, description: "d-\($0)", inputSchema: .ordered([("type", .string("object"))]))
        }
    }

    func call(name: String, arguments: OrderedJSON, progress: @Sendable (Double, String) -> Void) async -> MCPToolResult {
        switch name {
        case "echo":
            return MCPToolResult(text: arguments["text"]?.stringValue ?? "", structured: .ordered([("ok", .bool(true))]))
        case "fail":
            return MCPToolResult(text: "boom", structured: nil, isError: true)
        case "slow":
            for i in 1...4 {
                progress(Double(i) / 4, "step \(i)")
                try? await Task.sleep(for: .milliseconds(150))
            }
            return MCPToolResult(text: "done")
        case "burst":
            for i in 1...10 { progress(Double(i), "b\(i)") }
            try? await Task.sleep(for: .milliseconds(400))
            return MCPToolResult(text: "burst-done")
        default:
            return MCPToolResult(text: "?", isError: true)
        }
    }
}

private struct Harness {
    let server: HTTPServer
    let port: UInt16

    static func start() async throws -> Harness {
        let route = MCPRoute(provider: FakeProvider(), serverName: "strim-test", version: "9.9",
                             instructions: "use me", progressInterval: .milliseconds(100))
        let server = HTTPServer(port: 0)
        for m in ["POST", "GET", "DELETE"] {
            server.route(m, "/mcp") { req, r in try await route.handle(request: req, responder: r) }
        }
        server.route("POST", prefix: "/") { _, r in try await r.text(404, "catch-all") }
        return Harness(server: server, port: try await server.start())
    }

    func raw(_ method: String, _ body: String? = nil, version: String? = nil, extra: [String] = []) async throws -> RawClient.Response {
        let c = RawClient(port: port)
        defer { c.cancel() }
        var head = "\(method) /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
        if let version { head += "MCP-Protocol-Version: \(version)\r\n" }
        for e in extra { head += e + "\r\n" }
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        } else {
            head += "\r\n"
        }
        try await c.send(head)
        return try #require(await c.readResponse())
    }

    func rpc(_ body: String, version: String? = nil) async throws -> (RawClient.Response, Any?) {
        let r = try await raw("POST", body, version: version)
        return (r, r.body.isEmpty ? nil : try? JSONSerialization.jsonObject(with: Data(r.body)))
    }
}

private func dict(_ x: Any?) -> [String: Any] { (x as? [String: Any]) ?? [:] }
private func errCode(_ x: Any?) -> Int? { dict(dict(x)["error"])["code"] as? Int }
private func sse(_ r: RawClient.Response) -> [[String: Any]] {
    String(decoding: r.body, as: UTF8.self).components(separatedBy: "\n\n").compactMap { chunk in
        let line = chunk.split(separator: "\n").first { $0.hasPrefix("data: ") }
        return line.flatMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any] }
    }
}

@Suite("MCP protocol", .serialized)
struct ProtocolTests {
    @Test("initialize negotiates versions")
    func initialize() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        for (asked, expect) in [("2025-03-26", "2025-03-26"), ("2025-06-18", "2025-06-18"),
                                ("2025-11-25", "2025-11-25"), ("1999-01-01", "2025-06-18")] {
            let (r, j) = try await h.rpc(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(asked)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
            #expect(r.status == 200)
            #expect(r.headers["content-type"] == "application/json")
            let res = dict(dict(j)["result"])
            #expect(res["protocolVersion"] as? String == expect)
            #expect(dict(dict(res["capabilities"])["tools"])["listChanged"] as? Bool == false)
            #expect(dict(res["serverInfo"])["name"] as? String == "strim-test")
            #expect(res["instructions"] as? String == "use me")
            let sid = try #require(r.headers["mcp-session-id"])
            #expect(sid.count == 32 && sid.allSatisfy { $0.isHexDigit })
        }
    }

    @Test("notifications and responses get 202 with empty body")
    func accepted() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        for body in [#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                     #"{"jsonrpc":"2.0","id":7,"result":{}}"#] {
            let (r, _) = try await h.rpc(body)
            #expect(r.status == 202 && r.body.isEmpty)
        }
    }

    @Test("ping, list, unknown method")
    func basics() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        var (r, j) = try await h.rpc(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#)
        #expect(r.status == 200 && dict(j)["id"] as? String == "a" && (dict(dict(j)["result"])).isEmpty)
        (r, j) = try await h.rpc(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = dict(dict(j)["result"])["tools"] as? [[String: Any]] ?? []
        #expect(tools.map { $0["name"] as? String } == ["echo", "fail", "slow", "burst"])
        #expect(tools[0]["description"] as? String == "d-echo" && tools[0]["inputSchema"] != nil)
        (_, j) = try await h.rpc(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
        #expect(errCode(j) == -32601)
    }

    @Test("tools/call ok, tool error, unknown tool, bad params")
    func calls() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        var (_, j) = try await h.rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        var res = dict(dict(j)["result"])
        #expect((res["content"] as? [[String: Any]])?.first?["text"] as? String == "hi")
        #expect((res["content"] as? [[String: Any]])?.first?["type"] as? String == "text")
        #expect(dict(res["structuredContent"])["ok"] as? Bool == true)
        #expect(res["isError"] as? Bool == false)
        (_, j) = try await h.rpc(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fail"}}"#)
        res = dict(dict(j)["result"])
        #expect(res["isError"] as? Bool == true && res["structuredContent"] == nil)
        (_, j) = try await h.rpc(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope"}}"#)
        #expect(errCode(j) == -32602)
        (_, j) = try await h.rpc(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":[1]}}"#)
        #expect(errCode(j) == -32602)
    }

    @Test("batches only for 2025-03-26")
    func batches() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        let batch = #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"tools/list"}]"#
        var (r, j) = try await h.rpc(batch, version: "2025-03-26")
        #expect(r.status == 200 && (j as? [[String: Any]])?.count == 2)
        (r, j) = try await h.rpc(batch) // absent header = 2025-03-26
        #expect(r.status == 200 && (j as? [Any])?.count == 2)
        (r, j) = try await h.rpc(#"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#, version: "2025-03-26")
        #expect(r.status == 202)
        for v in ["2025-06-18", "2025-11-25"] {
            (r, j) = try await h.rpc(batch, version: v)
            #expect(r.status == 400 && errCode(j) == -32600)
        }
        (r, j) = try await h.rpc("[]", version: "2025-03-26")
        #expect(errCode(j) == -32600)
        (r, j) = try await h.rpc(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, version: "2030-01-01")
        #expect(r.status == 400)
    }

    @Test("parse errors and invalid requests")
    func parseErrors() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        var (r, j) = try await h.rpc("{not json")
        #expect(r.status == 400 && errCode(j) == -32700 && dict(j)["id"] is NSNull)
        (r, j) = try await h.rpc("42")
        #expect(errCode(j) == -32600 && dict(j)["id"] is NSNull)
        (r, j) = try await h.rpc(#"{"id":5,"method":"ping"}"#)
        #expect(errCode(j) == -32600 && dict(j)["id"] as? Int == 5)
    }

    @Test("GET 405, DELETE 200")
    func methods() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        var r = try await h.raw("GET")
        #expect(r.status == 405 && r.headers["allow"] == "POST, DELETE")
        r = try await h.raw("DELETE", nil, extra: ["Mcp-Session-Id: abc"])
        #expect(r.status == 200)
    }

    @Test("body over 1 MB gets 413")
    func sizeLimit() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        let pad = String(repeating: "a", count: MCPRoute.maxBodyBytes)
        let r = try await h.raw("POST", #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"p":"\#(pad)"}}"#)
        #expect(r.status == 413)
    }

    @Test("progressToken switches to SSE: ordered progress then final response")
    func sseProgress() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        let r = try await h.raw("POST", #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"slow","arguments":{},"_meta":{"progressToken":"tok"}}}"#)
        #expect(r.status == 200 && r.headers["content-type"] == "text/event-stream")
        let events = sse(r)
        let final = try #require(events.last)
        #expect(final["id"] as? Int == 9 && dict(final["result"])["isError"] as? Bool == false)
        let progress = events.dropLast()
        #expect(progress.count >= 2)
        var last = -1.0
        for e in progress {
            #expect(e["method"] as? String == "notifications/progress")
            let p = dict(e["params"])
            #expect(p["progressToken"] as? String == "tok")
            #expect((p["message"] as? String)?.hasPrefix("step") == true)
            let v = try #require(p["progress"] as? Double)
            #expect(v > last)
            last = v
        }
    }

    @Test("rapid progress is coalesced to the latest report")
    func coalesce() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        let r = try await h.raw("POST", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"burst","_meta":{"progressToken":4}}}"#)
        let events = sse(r)
        let progress = events.dropLast()
        #expect(progress.count >= 1 && progress.count <= 4)
        #expect(dict(progress.first?["params"])["message"] as? String == "b10")
        #expect(dict(progress.first?["params"])["progressToken"] as? Int == 4)
        #expect(dict(events.last?["result"])["isError"] as? Bool == false)
    }

    @Test("unknown tool with progressToken is a plain JSON error")
    func sseUnknown() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        let (r, j) = try await h.rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zzz","_meta":{"progressToken":"t"}}}"#)
        #expect(r.headers["content-type"] == "application/json" && errCode(j) == -32602)
    }

    @Test("exact /mcp route wins over catch-all prefix")
    func precedence() async throws {
        let h = try await Harness.start(); defer { h.server.stop() }
        let (r, j) = try await h.rpc(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(r.status == 200 && dict(j)["result"] != nil)
    }
}
