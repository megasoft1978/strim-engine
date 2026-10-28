import Testing
@testable import StrimHTTP

@Suite("HTTPReason")
struct HTTPReasonTests {
    @Test("status line phrases for 202 and 204")
    func statusLinePhrases() {
        #expect("HTTP/1.1 202 \(HTTPReason.phrase(for: 202))" == "HTTP/1.1 202 Accepted")
        #expect("HTTP/1.1 204 \(HTTPReason.phrase(for: 204))" == "HTTP/1.1 204 No Content")
    }

    @Test("every emitted status has a real reason phrase")
    func noUnknownPhrases() {
        let codes = [200, 201, 202, 204, 400, 401, 403, 404, 405, 408, 411, 413, 429, 431, 500, 501, 503]
        for code in codes {
            #expect(HTTPReason.phrase(for: code) != "Unknown", "status \(code) has no phrase")
        }
    }
}
