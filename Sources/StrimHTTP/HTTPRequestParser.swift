import Foundation

extension Request {
    /// Whether the connection stays open after this request's response (RFC 9112 section 9.3).
    public var keepAlive: Bool {
        let connection = (headers["Connection"] ?? "").lowercased()
        if version == "HTTP/1.0" {
            return connection.contains("keep-alive")
        }
        return !connection.contains("close")
    }
}

/// Incremental HTTP/1.x request parser. Feed raw bytes with `append`, then call `next()`
/// until it returns nil. Pipelined requests are returned one per call.
///
/// Malformed input yields `.failure(status)`; the caller must answer with that status and
/// close the connection, because framing can no longer be trusted after an error.
struct HTTPRequestParser {
    enum Event {
        case request(Request)
        case failure(Int)
    }

    private var buffer: [UInt8] = []
    /// Unconsumed bytes of a request still being received (head or body).
    var hasPartialRequest: Bool { pending != nil || buffer.contains(where: { $0 != 0x0D && $0 != 0x0A }) }
    /// Body length of a request whose head is parsed and whose body is still incomplete.
    var awaitingBodyLength: Int? { pending?.contentLength }
    /// Head parsed, waiting for `contentLength` body bytes.
    private var pending: (method: String, path: String, query: [String: String],
                          headers: HTTPHeaders, version: String, contentLength: Int)?
    /// Bytes buffered beyond which the connection is considered abusive (pipelining flood).
    private let maxBuffered = 2 * HTTPLimits.maxBodyBytes + 2 * HTTPLimits.maxHeadBytes

    mutating func append<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        buffer.append(contentsOf: bytes)
    }

    mutating func next() -> Event? {
        if buffer.count > maxBuffered {
            return .failure(413)
        }
        if pending == nil {
            // Tolerate stray empty lines before a request line (RFC 9112 section 2.2).
            while let first = buffer.first, first == 0x0D || first == 0x0A {
                buffer.removeFirst()
            }
            guard let end = Self.findHeadEnd(in: buffer) else {
                return buffer.count > HTTPLimits.maxHeadBytes ? .failure(431) : nil
            }
            guard end.total <= HTTPLimits.maxHeadBytes else { return .failure(431) }
            let headBytes = buffer[0..<end.lineBytes]
            buffer.removeFirst(end.total)
            switch Self.parseHead(headBytes) {
            case .failure(let error):
                return .failure(error.status)
            case .success(let head):
                pending = head
            }
        }
        guard let head = pending, buffer.count >= head.contentLength else { return nil }
        let body = Data(buffer[0..<head.contentLength])
        buffer.removeFirst(head.contentLength)
        pending = nil
        return .request(Request(method: head.method, path: head.path, query: head.query,
                                headers: head.headers, body: body, version: head.version))
    }

    // MARK: - Head

    /// Carries the HTTP status to answer with when a head is rejected.
private struct HeadError: Error {
    let status: Int
}

/// Position of the blank line terminating the head. `lineBytes` is the head without the
    /// terminating blank line; `total` also consumes the blank line.
    private static func findHeadEnd(in bytes: [UInt8]) -> (lineBytes: Int, total: Int)? {
        var lineStart = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                var lineLength = index - lineStart
                if lineLength > 0 && bytes[index - 1] == 0x0D { lineLength -= 1 }
                if lineLength == 0 {
                    return (lineStart, index + 1)
                }
                lineStart = index + 1
            }
            index += 1
        }
        return nil
    }

    private static func parseHead(_ bytes: ArraySlice<UInt8>) -> Result<
        (method: String, path: String, query: [String: String], headers: HTTPHeaders,
         version: String, contentLength: Int), HeadError
    > {
        let lines = splitLines(bytes)
        guard let requestLine = lines.first, !requestLine.isEmpty else { return .failure(HeadError(status: 400)) }
        for line in lines where line.contains(where: isControl) {
            return .failure(HeadError(status: 400))
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .failure(HeadError(status: 400)) }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])
        guard !method.isEmpty, method.allSatisfy(isTokenChar) else { return .failure(HeadError(status: 400)) }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { return .failure(HeadError(status: 400)) }
        guard target.hasPrefix("/"), !target.contains("#") else { return .failure(HeadError(status: 400)) }

        let path: String
        var query: [String: String] = [:]
        if let questionMark = target.firstIndex(of: "?") {
            path = String(target[..<questionMark])
            query = parseQuery(target[target.index(after: questionMark)...])
        } else {
            path = target
        }

        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            guard let first = line.first, first != " ", first != "\t" else {
                return .failure(HeadError(status: 400)) // obsolete line folding is rejected
            }
            guard let colon = line.firstIndex(of: ":") else { return .failure(HeadError(status: 400)) }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.allSatisfy(isTokenChar) else { return .failure(HeadError(status: 400)) }
            let value = trimOWS(line[line.index(after: colon)...])
            headers.append(name: name, value: value)
        }

        if !headers.values(for: "Transfer-Encoding").isEmpty {
            return .failure(HeadError(status: 501)) // chunked request bodies are not supported
        }
        if version == "HTTP/1.1" {
            let hosts = headers.values(for: "Host")
            guard hosts.count == 1, !hosts[0].isEmpty else { return .failure(HeadError(status: 400)) }
        }

        var contentLength = 0
        let lengths = headers.values(for: "Content-Length")
        if let first = lengths.first {
            guard lengths.allSatisfy({ $0 == first }) else { return .failure(HeadError(status: 400)) }
            guard !first.isEmpty, first.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return .failure(HeadError(status: 400)) }
            guard let parsed = Int(first) else { return .failure(HeadError(status: 413)) } // too big to represent
            guard parsed <= HTTPLimits.maxBodyBytes else { return .failure(HeadError(status: 413)) }
            contentLength = parsed
        }
        return .success((method, path, query, headers, version, contentLength))
    }

    /// Splits on LF, dropping one trailing CR per line. Bare CR inside a line is left in place
    /// and rejected by the control-character check.
    private static func splitLines(_ bytes: ArraySlice<UInt8>) -> [Substring] {
        var lines: [Substring] = []
        var start = bytes.startIndex
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == 0x0A {
                var end = index
                if end > start && bytes[end - 1] == 0x0D { end -= 1 }
                lines.append(Substring(String(decoding: bytes[start..<end], as: UTF8.self)))
                start = index + 1
            }
            index += 1
        }
        if start < bytes.endIndex {
            lines.append(Substring(String(decoding: bytes[start..<bytes.endIndex], as: UTF8.self)))
        }
        return lines
    }

    private static func parseQuery(_ raw: Substring) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") where !pair.isEmpty {
            let key: Substring
            let value: Substring
            if let equals = pair.firstIndex(of: "=") {
                key = pair[..<equals]
                value = pair[pair.index(after: equals)...]
            } else {
                key = pair
                value = ""
            }
            result[decodeComponent(key)] = decodeComponent(value)
        }
        return result
    }

    private static func decodeComponent(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    private static func trimOWS(_ text: Substring) -> String {
        var value = text
        while let first = value.first, first == " " || first == "\t" { value = value.dropFirst() }
        while let last = value.last, last == " " || last == "\t" { value = value.dropLast() }
        return String(value)
    }

    private static func isControl(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return true
        }
        return (scalar.value < 0x20 && scalar.value != 0x09) || scalar.value == 0x7F
    }

    private static func isTokenChar(_ character: Character) -> Bool {
        guard character.isASCII, let byte = character.asciiValue else { return false }
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }
}
