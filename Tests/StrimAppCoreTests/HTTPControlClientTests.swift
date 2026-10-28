import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

/// URLProtocol stub. Tests in this suite are serialized because the handler is global.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case response(status: Int, body: String, headers: [String: String])
        case sse(chunks: [String], failAfter: Error?)
        case fail(Error)
    }
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    nonisolated(unsafe) static var seenBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); body = d
        }
        Self.seen.append(request); Self.seenBodies.append(body ?? Data())
        let url = request.url!
        switch Self.handler!(request) {
        case .response(let status, let body, let headers):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .sse(let chunks, let fail):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
            for c in chunks { client?.urlProtocol(self, didLoad: Data(c.utf8)) }
            if let fail { client?.urlProtocol(self, didFailWithError: fail) } else { client?.urlProtocolDidFinishLoading(self) }
        case .fail(let e):
            client?.urlProtocol(self, didFailWithError: e)
        }
    }
}

private func makeClient(token: String? = "sekret") throws -> (HTTPControlClient, String) {
    let path = NSTemporaryDirectory() + "tok-\(UUID().uuidString)"
    if let token { try token.write(toFile: path, atomically: true, encoding: .utf8) }
    StubProtocol.seen = []; StubProtocol.seenBodies = []
    return (HTTPControlClient(baseURL: URL(string: "http://127.0.0.1:8203")!, token: TokenReader(path: path, home: NSTemporaryDirectory()), session: HTTPControlClient.hardenedSession(extraProtocols: [StubProtocol.self])), path)
}

private let statusJSON = #"{"state":"ready","model":"m","memory":{"weights_gb":1,"prefix_trie_gb":0,"mlx_cache_gb":0,"headroom_gb":1},"decode_tps":40,"prefill_tps":0,"mtp_acceptance":0,"mtp_depth":0,"prefix_hit_rate":0,"saved_prefill_seconds":0,"active_jobs":0,"queued_jobs":0,"tokens_today":0,"local_tokens_generated":0,"uptime_seconds":1}"#

@Suite(.serialized) struct HTTPControlClientTests {
    @Test func statusSendsBearerAndDecodes() async throws {
        let (c, p) = try makeClient(); defer { try? FileManager.default.removeItem(atPath: p) }
        StubProtocol.handler = { _ in .response(status: 200, body: statusJSON, headers: [:]) }
        let s = try await c.status()
        #expect(s.state == .ready && s.decodeTPS == 40)
        let r = StubProtocol.seen[0]
        #expect(r.url?.path == "/v1/strim/status")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sekret")
        #expect(r.httpMethod == "GET")
    }
    @Test func noTokenFileSendsNoHeaderAnd401ExplainsIt() async throws {
        let (c, _) = try makeClient(token: nil)
        StubProtocol.handler = { _ in .response(status: 401, body: #"{"error":{"code":"unauthorized","message":"no"}}"#, headers: [:]) }
        await #expect(throws: ControlClientError.unauthorized(tokenPresent: false)) { _ = try await c.status() }
        #expect(StubProtocol.seen[0].value(forHTTPHeaderField: "Authorization") == nil)
    }
    @Test func unauthorizedWithToken() async throws {
        let (c, p) = try makeClient(); defer { try? FileManager.default.removeItem(atPath: p) }
        StubProtocol.handler = { _ in .response(status: 401, body: "", headers: [:]) }
        await #expect(throws: ControlClientError.unauthorized(tokenPresent: true)) { _ = try await c.jobs() }
    }
    @Test func notImplementedMaps501() async throws {
        let (c, p) = try makeClient(); defer { try? FileManager.default.removeItem(atPath: p) }
        StubProtocol.handler = { _ in .response(status: 501, body: #"{"error":{"code":"not_implemented","message":"chat"}}"#, headers: [:]) }
        do { _ = try await c.chatOpen(ChatOpenRequest(cwd: "/x")); Issue.record("expected throw") }
        catch { #expect(isNotImplemented(error)) }
    }
    @Test func apiErrorEnvelopeIsSurfaced() async throws {
        let (c, p) = try makeClient(); defer { try? FileManager.default.removeItem(atPath: p) }
        StubProtocol.handler = { _ in .response(status: 409, body: #"{"error":{"code":"conflict","message":"loading"}}"#, headers: [:]) }
        do { try await c.load(LoadRequest(model: "m")); Issue.record("expected throw") }
        catch let e as ControlClientError {
            #expect(e == .http(status: 409, api: APIError(code: "conflict", message: "loading")))
            #expect(e.localizedDescription == "conflict: loading (409)")
        }
    }
    @Test func postBodiesAndRoutes() async throws {
        let (c, p) = try makeClient(); defer { try? FileManager.default.removeItem(atPath: p) }
        StubProtocol.handler = { r in
            r.url!.path.hasSuffix("/open")
                ? .response(status: 200, body: #"{"session_id":"s","job_id":"j","cwd":"/x","profile":"interactive"}"#, headers: [:])
                : .response(status: 200, body: "{}", headers: [:])
        }
        try await c.load(LoadRequest(model: "m", mtp: "h"))
        try await c.approve(PatchApproval(jobID: "j1", action: .apply))
        let s = try await c.chatOpen(ChatOpenRequest(cwd: "/x"))
        try await c.unload()
        #expect(s.sessionID == "s")
        #expect(StubProtocol.seen.map { $0.url!.path } == ["/v1/strim/load", "/v1/strim/jobs/approve", "/v1/strim/chat/open", "/v1/strim/unload"])
        #expect(StubProtocol.seen.allSatisfy { $0.httpMethod == "POST" })
        #expect(String(decoding: StubProtocol.seenBodies[1], as: UTF8.self).contains(#""job_id":"j1""#))
        #expect(String(decoding: StubProtocol.seenBodies[0], as: UTF8.self).contains(#""model":"m""#))
    }
    @Test func jobDetailRoute() async throws {
        let (c, p) = try makeClient(); defer { try? FileManager.default.removeItem(atPath: p) }
        StubProtocol.handler = { _ in .response(status: 200, body: #"{"summary":{"id":"a1","source":"mcp","status":"done","started":1},"turns":3,"local_tokens":9}"#, headers: [:]) }
        let d = try await c.job(id: "a1")
        #expect(d.turns == 3 && d.summary.status == .done)
        #expect(StubProtocol.seen[0].url?.path == "/v1/strim/jobs/a1")
    }
    @Test func transportFailureAndTimeoutAreTyped() async throws {
        let (c, p) = try makeClient(); defer { try? FileManager.default.removeItem(atPath: p) }
        StubProtocol.handler = { _ in .fail(URLError(.cannotConnectToHost)) }
        do { _ = try await c.status(); Issue.record("expected throw") }
        catch let e as ControlClientError { if case .hostUnreachable = e {} else { Issue.record("wrong \(e)") } }
        StubProtocol.handler = { _ in .fail(URLError(.timedOut)) }
        await #expect(throws: ControlClientError.timeout) { _ = try await c.status() }
    }
    @Test func garbageBodyIsDecodingError() async throws {
        let (c, p) = try makeClient(); defer { try? FileManager.default.removeItem(atPath: p) }
        StubProtocol.handler = { _ in .response(status: 200, body: "<html>", headers: [:]) }
        do { _ = try await c.status(); Issue.record("expected throw") }
        catch let e as ControlClientError { if case .decoding = e {} else { Issue.record("wrong \(e)") } }
    }

    @Test func sseParsesFramesSplitAcrossChunks() async throws {
        let (c, p) = try makeClient(); defer { try? FileManager.default.removeItem(atPath: p) }
        let st = #"{"type":"status","data":\#(statusJSON)}"#
        let job = #"{"type":"job_event","data":{"job_id":"j","status":"done","verify":"verified"}}"#
        let unknown = #"{"type":"future_thing","data":{}}"#
        StubProtocol.handler = { _ in .sse(chunks: [
            ": ping\n\n", "event: status\nda", "ta: \(st)\n", "\n",
            "event: future_thing\ndata: \(unknown)\n\n",
            "event: job_event\r\ndata: \(job)\r\n\r\n",
        ], failAfter: nil) }
        var got: [StrimEvent] = []
        for try await e in c.events() { got.append(e) }
        #expect(got.count == 2)
        #expect(got[0].typeName == "status")
        #expect(got[1] == .jobEvent(JobEvent(jobID: "j", status: .done, verify: .verified)))
        #expect(StubProtocol.seen[0].value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(StubProtocol.seen[0].value(forHTTPHeaderField: "Authorization") == "Bearer sekret")
    }
    @Test func sseInterruptionThrowsTyped() async throws {
        let (c, p) = try makeClient(); defer { try? FileManager.default.removeItem(atPath: p) }
        let job = #"{"type":"job_event","data":{"job_id":"j","status":"running"}}"#
        StubProtocol.handler = { _ in .sse(chunks: ["data: \(job)\n\n"], failAfter: URLError(.networkConnectionLost)) }
        var got = 0
        do { for try await _ in c.events() { got += 1 }; Issue.record("expected throw") }
        catch let e as ControlClientError { if case .hostUnreachable = e {} else { Issue.record("wrong \(e)") } }
        _ = got
    }
    @Test func sseNon200Throws() async throws {
        let (c, p) = try makeClient(); defer { try? FileManager.default.removeItem(atPath: p) }
        StubProtocol.handler = { _ in .response(status: 401, body: "", headers: [:]) }
        do { for try await _ in c.events() {}; Issue.record("expected throw") }
        catch { #expect(error as? ControlClientError == .unauthorized(tokenPresent: true)) }
    }

    @Test func clientRefusesInvalidBaseURLWithoutNetwork() async throws {
        let c = HTTPControlClient(baseURL: URL(string: "http://evil.com:80")!, token: TokenReader(path: "/nonexistent"), session: HTTPControlClient.hardenedSession(extraProtocols: [StubProtocol.self]))
        StubProtocol.seen = []
        do { _ = try await c.status(); Issue.record("expected throw") }
        catch let e as ControlClientError { if case .invalidConfig = e {} else { Issue.record("wrong \(e)") } }
        var n = 0
        do { for try await _ in c.events() { n += 1 } } catch {}
        #expect(StubProtocol.seen.isEmpty && n == 0)
    }

    @Test func a302ResponseIsAnErrorNotFollowed() async throws {
        let cfgPath = NSTemporaryDirectory() + "t-\(UUID().uuidString)"
        let c = HTTPControlClient(baseURL: URL(string: "http://127.0.0.1:8203")!, token: TokenReader(path: cfgPath, home: NSTemporaryDirectory()),
                                  session: HTTPControlClient.hardenedSession(extraProtocols: [StubProtocol.self]))
        StubProtocol.seen = []; StubProtocol.seenBodies = []
        StubProtocol.handler = { _ in .response(status: 302, body: "", headers: ["Location": "http://evil.com/x"]) }
        await #expect(throws: ControlClientError.redirectRefused) { _ = try await c.status() }
        do { for try await _ in c.events() {}; Issue.record("expected throw") }
        catch { #expect(error as? ControlClientError == .redirectRefused) }
        #expect(StubProtocol.seen.allSatisfy { $0.url?.host == "127.0.0.1" })
    }

}

@Suite struct SSEParserTests {
    @Test func framing() {
        var p = SSEParser()
        #expect(p.feed(line: ": hi") == nil)
        #expect(p.feed(line: "event: a") == nil)
        #expect(p.feed(line: "data: 1") == nil)
        #expect(p.feed(line: "data:2") == nil)
        #expect(p.feed(line: "") == SSEParser.Frame(event: "a", data: "1\n2"))
        #expect(p.feed(line: "") == nil)   // blank without data
        #expect(p.feed(line: "data: x") == nil)
        #expect(p.feed(line: "") == SSEParser.Frame(event: nil, data: "x"))
    }
}
