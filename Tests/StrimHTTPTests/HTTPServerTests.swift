import Foundation
import Testing
@testable import StrimHTTP

/// Starts a server on an ephemeral loopback port. Callers must `stop()` it.
private func startServer(token: String? = nil, _ configure: (HTTPServer) -> Void) async throws -> (HTTPServer, UInt16) {
    let server = HTTPServer(port: 0, bearerToken: token)
    configure(server)
    let port = try await server.start()
    return (server, port)
}

private func post(_ port: UInt16, _ path: String, body: String, headers: [String: String] = [:]) async throws -> (Int, [String: String], Data) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    let http = response as! HTTPURLResponse
    var fields: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
        fields[String(describing: key).lowercased()] = String(describing: value)
    }
    return (http.statusCode, fields, data)
}

@Suite("HTTPServer")
struct HTTPServerTests {
    @Test("JSON POST roundtrip")
    func jsonRoundtrip() async throws {
        let (server, port) = try await startServer { server in
            server.route("POST", "/echo") { request, responder in
                let object = try JSONSerialization.jsonObject(with: request.body)
                let reply = try JSONSerialization.data(withJSONObject: ["echo": object, "method": request.method])
                try await responder.json(200, reply)
            }
        }
        defer { server.stop() }

        let (status, headers, data) = try await post(port, "/echo", body: #"{"text":"hi"}"#,
                                                    headers: ["Content-Type": "application/json"])
        #expect(status == 200)
        #expect(headers["content-type"] == "application/json")
        #expect(headers["content-length"] == String(data.count))
        let echoed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((echoed?["echo"] as? [String: String])?["text"] == "hi")
        #expect(echoed?["method"] as? String == "POST")
    }

    @Test("SSE events arrive incrementally, not buffered to the end")
    func sseIncremental() async throws {
        let pause: Duration = .milliseconds(150)
        let (server, port) = try await startServer { server in
            server.route("GET", "/events") { _, responder in
                try await responder.startSSE()
                for index in 0..<4 {
                    try await responder.sseWrite("event \(index)")
                    try await Task.sleep(for: pause)
                }
                try await responder.finish()
            }
        }
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/events")!)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")

        let clock = ContinuousClock()
        let started = clock.now
        var arrivals: [ContinuousClock.Instant] = []
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            arrivals.append(clock.now)
            #expect(line == "data: event \(arrivals.count - 1)")
        }
        #expect(arrivals.count == 4)
        // Each gap must reflect the server-side sleep; a buffered stream would show ~0 gaps.
        for (previous, next) in zip(arrivals, arrivals.dropFirst()) {
            let gap = next - previous
            #expect(gap >= pause * 0.9)
        }
        #expect(arrivals.first.map { $0 - started < .milliseconds(400) } == true)
    }

    @Test("client disconnect fires onClose within 200 ms")
    func disconnectFiresOnClose() async throws {
        let (closedStream, closedContinuation) = AsyncStream<ContinuousClock.Instant>.makeStream()
        let (server, port) = try await startServer { server in
            server.route("GET", "/stream") { _, responder in
                responder.onClose { closedContinuation.yield(ContinuousClock().now) }
                try await responder.startSSE()
                while true {
                    try await responder.sseComment("keep-alive")
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        defer { server.stop() }

        let client = RawClient(port: port)
        try await client.send("GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let head = await client.readHead()
        #expect(head?.status == 200)

        let cancelledAt = ContinuousClock().now
        client.cancel()

        var closedAt: ContinuousClock.Instant?
        for await instant in closedStream {
            closedAt = instant
            break
        }
        let elapsed = try #require(closedAt) - cancelledAt
        #expect(elapsed < .milliseconds(200), "onClose took \(elapsed)")
    }

    @Test("8 concurrent connections all succeed")
    func concurrentConnections() async throws {
        let (server, port) = try await startServer { server in
            server.route("POST", "/slow") { request, responder in
                try await Task.sleep(for: .milliseconds(50))
                try await responder.text(200, String(decoding: request.body, as: UTF8.self))
            }
        }
        defer { server.stop() }

        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<8 {
                group.addTask {
                    let (status, _, data) = try await post(port, "/slow", body: "request-\(index)")
                    return (status, String(decoding: data, as: UTF8.self))
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0.0 == 200 })
        #expect(Set(results.map(\.1)).count == 8)
    }

    @Test("malformed requests get 400 and the server keeps serving", arguments: [
        "GARBAGE\r\nHost: localhost\r\n\r\n",
        "GET x HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /x HTTP/1.1\r\nHost: localhost\r\nBad Header\r\n\r\n",
        "GET /x HTTP/1.1\r\nHost: localhost\r\nContent-Length: abc\r\n\r\n",
        "GET /x HTTP/1.1\r\nHost: localhost\r\n Folded: line\r\n\r\n",
        "GET /x HTTP/1.1\r\n\r\n",
        "GET /x HTTP/9.9\r\nHost: localhost\r\n\r\n",
        "POST /x HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nabc",
    ])
    func malformedRequest(raw: String) async throws {
        let (server, port) = try await startServer { server in
            server.route("GET", "/x") { _, responder in try await responder.text(200, "ok") }
        }
        defer { server.stop() }

        let bad = RawClient(port: port)
        try await bad.send(raw)
        let response = await bad.readResponse()
        bad.cancel()
        #expect(response?.status == 400)
        #expect(response?.headers["connection"] == "close")

        let good = RawClient(port: port)
        try await good.send("GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(await good.readResponse()?.status == 200)
        good.cancel()
    }

    @Test("oversized body gets 413 before the body is sent")
    func oversizedBody() async throws {
        let (server, port) = try await startServer { server in
            server.route("POST", "/upload") { _, responder in try await responder.text(200, "ok") }
        }
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.cancel() }
        let length = HTTPLimits.maxBodyBytes + 1
        try await client.send("POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(length)\r\n\r\n")
        #expect(await client.readResponse()?.status == 413)
    }

    @Test("request with Transfer-Encoding gets 501")
    func transferEncodingUnsupported() async throws {
        let (server, port) = try await startServer { server in
            server.route("POST", "/upload") { _, responder in try await responder.text(200, "ok") }
        }
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.cancel() }
        try await client.send("POST /upload HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n")
        #expect(await client.readResponse()?.status == 501)
    }

    @Test("keep-alive reuses one connection for sequential requests")
    func keepAlive() async throws {
        let (server, port) = try await startServer { server in
            server.route("GET", "/n") { request, responder in
                try await responder.text(200, request.query["i"] ?? "none")
            }
        }
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.cancel() }
        for index in 0..<3 {
            try await client.send("GET /n?i=\(index) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let response = await client.readResponse()
            #expect(response?.status == 200)
            #expect(response?.headers["connection"] == "keep-alive")
            #expect(String(decoding: response?.body ?? [], as: UTF8.self) == "\(index)")
        }
    }

    @Test("pipelined requests are answered in order")
    func pipelining() async throws {
        let (server, port) = try await startServer { server in
            server.route("POST", "/p") { request, responder in
                try await Task.sleep(for: .milliseconds(30))
                try await responder.text(200, String(decoding: request.body, as: UTF8.self))
            }
        }
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.cancel() }
        let first = "POST /p HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nfirst"
        let second = "POST /p HTTP/1.1\r\nHost: localhost\r\nContent-Length: 6\r\n\r\nsecond"
        try await client.send(first + second)
        #expect(String(decoding: await client.readResponse()?.body ?? [], as: UTF8.self) == "first")
        #expect(String(decoding: await client.readResponse()?.body ?? [], as: UTF8.self) == "second")
    }

    @Test("request split across partial reads is reassembled")
    func partialReads() async throws {
        let (server, port) = try await startServer { server in
            server.route("POST", "/split") { request, responder in
                try await responder.text(200, String(decoding: request.body, as: UTF8.self))
            }
        }
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.cancel() }
        let pieces = ["POST /spl", "it HTTP/1.1\r\nHost: localhost\r\nContent-Le", "ngth: 11\r\n\r", "\nhello", " world"]
        for piece in pieces {
            try await client.send(piece)
            try await Task.sleep(for: .milliseconds(30))
        }
        let response = await client.readResponse()
        #expect(response?.status == 200)
        #expect(String(decoding: response?.body ?? [], as: UTF8.self) == "hello world")
    }

    @Test("bearer token is enforced; preflight passes without it")
    func bearerToken() async throws {
        let (server, port) = try await startServer(token: "s3cret") { server in
            server.route("GET", "/secure") { _, responder in try await responder.text(200, "ok") }
        }
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/secure")!)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let (_, noTokenResponse) = try await session.data(for: request)
        #expect((noTokenResponse as? HTTPURLResponse)?.statusCode == 401)
        #expect((noTokenResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate") == "Bearer")

        request.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, wrongResponse) = try await session.data(for: request)
        #expect((wrongResponse as? HTTPURLResponse)?.statusCode == 401)

        request.setValue("bearer s3cret", forHTTPHeaderField: "Authorization")
        let (body, okResponse) = try await session.data(for: request)
        #expect((okResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == "ok")

        let client = RawClient(port: port)
        defer { client.cancel() }
        try await client.send("OPTIONS /secure HTTP/1.1\r\nHost: localhost\r\nOrigin: http://localhost:3000\r\n"
                              + "Access-Control-Request-Method: GET\r\n\r\n")
        #expect(await client.readResponse()?.status == 204)
    }

    @Test("CORS: localhost origins are echoed, other origins are not")
    func corsOrigins() async throws {
        let (server, port) = try await startServer { server in
            server.route("GET", "/cors") { _, responder in try await responder.text(200, "ok") }
        }
        defer { server.stop() }

        let allowed = RawClient(port: port)
        defer { allowed.cancel() }
        try await allowed.send("OPTIONS /cors HTTP/1.1\r\nHost: localhost\r\nOrigin: http://localhost:5173\r\n"
                               + "Access-Control-Request-Method: POST\r\n"
                               + "Access-Control-Request-Headers: content-type\r\n\r\n")
        let preflight = await allowed.readResponse()
        #expect(preflight?.status == 204)
        #expect(preflight?.headers["access-control-allow-origin"] == "http://localhost:5173")
        #expect(preflight?.headers["access-control-allow-methods"]?.contains("POST") == true)
        #expect(preflight?.headers["access-control-allow-headers"] == "content-type")

        let denied = RawClient(port: port)
        defer { denied.cancel() }
        try await denied.send("GET /cors HTTP/1.1\r\nHost: localhost\r\nOrigin: https://evil.example\r\n\r\n")
        let response = await denied.readResponse()
        #expect(response?.status == 403)
        #expect(response?.headers["access-control-allow-origin"] == nil)
    }

    @Test("DNS rebinding: non-loopback Host is rejected, loopback hosts with ports pass")
    func hostValidation() async throws {
        let (server, port) = try await startServer { server in
            server.route("GET", "/h") { _, responder in try await responder.text(200, "ok") }
        }
        defer { server.stop() }

        for (host, expected) in [("evil.example", 403), ("evil.example:\(port)", 403), ("localhost.evil.example", 403),
                                 ("127.0.0.1:\(port)", 200), ("LOCALHOST:\(port)", 200),
                                 ("[::1]:\(port)", 200)] {
            let client = RawClient(port: port)
            defer { client.cancel() }
            try await client.send("GET /h HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            #expect(await client.readResponse()?.status == expected, "Host: \(host)")
        }

        // An empty Host never reaches routing (parser 400 or dispatch 403).
        let empty = RawClient(port: port)
        defer { empty.cancel() }
        try await empty.send("GET /h HTTP/1.1\r\nHost: \r\n\r\n")
        #expect([400, 403].contains(await empty.readResponse()?.status ?? 0))
    }

    @Test("routing: exact beats prefix, unknown path 404, wrong method 405")
    func routing() async throws {
        let (server, port) = try await startServer { server in
            server.route("GET", "/api/status") { _, responder in try await responder.text(200, "exact") }
            server.route("GET", prefix: "/api/") { _, responder in try await responder.text(200, "prefix") }
            server.route("GET", "/boom") { _, _ in throw HTTPServerError.invalidState("test failure") }
        }
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.cancel() }
        try await client.send("GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(String(decoding: await client.readResponse()?.body ?? [], as: UTF8.self) == "exact")
        try await client.send("GET /api/other HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(String(decoding: await client.readResponse()?.body ?? [], as: UTF8.self) == "prefix")

        let missing = RawClient(port: port)
        defer { missing.cancel() }
        try await missing.send("GET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(await missing.readResponse()?.status == 404)

        let wrongMethod = RawClient(port: port)
        defer { wrongMethod.cancel() }
        try await wrongMethod.send("POST /api/status HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n")
        let rejected = await wrongMethod.readResponse()
        #expect(rejected?.status == 405)
        #expect(rejected?.headers["allow"] == "GET")

        let failing = RawClient(port: port)
        defer { failing.cancel() }
        try await failing.send("GET /boom HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(await failing.readResponse()?.status == 500)
    }
}

/// Example, CLI-free: an OpenAI-style streamed chat completion. Each delta is one
/// `chat.completion.chunk` SSE event, and the stream ends with `data: [DONE]`.
@Suite("OpenAI-style SSE example")
struct OpenAIStreamExampleTests {
    @Test("chat completion chunks followed by [DONE]")
    func chatCompletionStream() async throws {
        let pieces = ["Hello", ", ", "world", "!"]
        let (server, port) = try await startServer { server in
            server.route("POST", "/v1/chat/completions") { _, responder in
                try await responder.startSSE()
                for piece in pieces {
                    let chunk: [String: Any] = [
                        "id": "chatcmpl-example",
                        "object": "chat.completion.chunk",
                        "choices": [["index": 0, "delta": ["content": piece], "finish_reason": NSNull()]],
                    ]
                    let json = try JSONSerialization.data(withJSONObject: chunk)
                    try await responder.sseWrite(String(decoding: json, as: UTF8.self))
                }
                try await responder.sseWrite("[DONE]")
                try await responder.finish()
            }
        }
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"example","stream":true}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, _) = try await session.bytes(for: request)

        var text = ""
        var sawDone = false
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" {
                sawDone = true
                break
            }
            #expect(!sawDone, "no events may follow [DONE]")
            let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            let choices = object?["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            text += delta?["content"] as? String ?? ""
        }
        #expect(text == "Hello, world!")
        #expect(sawDone)
    }
}
