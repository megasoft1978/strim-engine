import Foundation
import Testing
@testable import StrimHTTP

@Suite("HTTPRequestParser")
struct HTTPRequestParserTests {
    private func events(_ parser: inout HTTPRequestParser) -> [HTTPRequestParser.Event] {
        var out: [HTTPRequestParser.Event] = []
        while let event = parser.next() {
            out.append(event)
        }
        return out
    }

    @Test("header lookup is case-insensitive and query is decoded")
    func headersAndQuery() {
        var parser = HTTPRequestParser()
        parser.append(Array("GET /v1/models?name=a%20b&flag&x=1&x=2 HTTP/1.1\r\nhost: h\r\nX-Token: t\r\n\r\n".utf8))
        guard case .request(let request)? = parser.next() else {
            Issue.record("expected a request")
            return
        }
        #expect(request.path == "/v1/models")
        #expect(request.query["name"] == "a b")
        #expect(request.query["flag"] == "")
        #expect(request.query["x"] == "2")
        #expect(request.headers["X-TOKEN"] == "t")
        #expect(request.keepAlive)
    }

    @Test("incomplete head or body waits for more bytes")
    func waitsForMore() {
        var parser = HTTPRequestParser()
        parser.append(Array("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\nab".utf8))
        #expect(parser.next() == nil)
        parser.append(Array("cd".utf8))
        guard case .request(let request)? = parser.next() else {
            Issue.record("expected a request")
            return
        }
        #expect(String(decoding: request.body, as: UTF8.self) == "abcd")
    }

    @Test("pipelined requests come out one per call, leftovers stay buffered")
    func pipelined() {
        var parser = HTTPRequestParser()
        parser.append(Array("GET /1 HTTP/1.1\r\nHost: h\r\n\r\nGET /2 HTTP/1.0\r\nConnection: keep-alive\r\n\r\nGET /3".utf8))
        let all = events(&parser)
        #expect(all.count == 2)
        if case .request(let second)? = all.last {
            #expect(second.path == "/2")
            #expect(second.keepAlive)
        }
    }

    @Test("Connection: close and HTTP/1.0 default to not keeping alive")
    func keepAliveRules() {
        var closing = HTTPRequestParser()
        closing.append(Array("GET / HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n".utf8))
        guard case .request(let first)? = closing.next() else {
            Issue.record("expected a request")
            return
        }
        #expect(!first.keepAlive)

        var legacy = HTTPRequestParser()
        legacy.append(Array("GET / HTTP/1.0\r\nHost: h\r\n\r\n".utf8))
        guard case .request(let second)? = legacy.next() else {
            Issue.record("expected a request")
            return
        }
        #expect(!second.keepAlive)
    }

    @Test("bare LF line endings are accepted")
    func bareLF() {
        var parser = HTTPRequestParser()
        parser.append(Array("GET /lf HTTP/1.1\nHost: h\n\n".utf8))
        guard case .request(let request)? = parser.next() else {
            Issue.record("expected a request")
            return
        }
        #expect(request.path == "/lf")
    }

    @Test("oversized head yields 431, oversized body length yields 413")
    func limits() {
        var longHead = HTTPRequestParser()
        longHead.append(Array(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPLimits.maxHeadBytes) + "\r\n").utf8))
        guard case .failure(let headStatus)? = longHead.next() else {
            Issue.record("expected a failure")
            return
        }
        #expect(headStatus == 431)

        var bigBody = HTTPRequestParser()
        bigBody.append(Array("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: \(HTTPLimits.maxBodyBytes + 1)\r\n\r\n".utf8))
        guard case .failure(let bodyStatus)? = bigBody.next() else {
            Issue.record("expected a failure")
            return
        }
        #expect(bodyStatus == 413)
    }
}
