import Foundation
import Network

/// Minimal HTTP/1.1 client over NWConnection for tests that need exact bytes on the wire
/// (malformed requests, pipelining, partial writes, abrupt disconnects).
/// Tests drive it sequentially, so the mutable buffer is never touched concurrently.
final class RawClient: @unchecked Sendable {
    struct Head {
        let status: Int
        /// Header names lowercased.
        let headers: [String: String]
    }

    struct Response {
        let status: Int
        let headers: [String: String]
        let body: [UInt8]
    }

    private let connection: NWConnection
    private var buffer: [UInt8] = []

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "strim.http.tests.raw"))
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ text: String) async throws {
        try await send(Array(text.utf8))
    }

    func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Reads the status line and headers, leaving any following bytes buffered.
    func readHead() async -> Head? {
        guard let headBytes = await readUntilCRLFCRLF() else { return nil }
        let text = String(decoding: headBytes, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return Head(status: status, headers: headers)
    }

    /// Reads a complete response (Content-Length or chunked body, or no body for 204/304).
    func readResponse() async -> Response? {
        guard let head = await readHead() else { return nil }
        if head.headers["transfer-encoding"]?.lowercased() == "chunked" {
            var body: [UInt8] = []
            while true {
                guard let sizeLine = await readLine(), let size = Int(sizeLine, radix: 16) else { return nil }
                guard let chunk = await readExactly(size) else { return nil }
                body += chunk
                _ = await readExactly(2) // CRLF after the chunk data
                if size == 0 { break }
            }
            return Response(status: head.status, headers: head.headers, body: body)
        }
        if let length = head.headers["content-length"].flatMap({ Int($0) }) {
            guard let body = await readExactly(length) else { return nil }
            return Response(status: head.status, headers: head.headers, body: body)
        }
        return Response(status: head.status, headers: head.headers, body: [])
    }

    /// Next chunk of bytes from the wire, or nil once the peer closed or the connection failed.
    func readMore() async -> Bool {
        let received: (data: [UInt8]?, finished: Bool) = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                let bytes = data.map { [UInt8]($0) }
                continuation.resume(returning: (bytes, isComplete || error != nil))
            }
        }
        if let data = received.data, !data.isEmpty {
            buffer += data
            return true
        }
        return !received.finished
    }

    // MARK: - Buffer helpers

    private func readUntilCRLFCRLF() async -> [UInt8]? {
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        while true {
            if let index = indexOf(terminator, in: buffer) {
                let head = Array(buffer[0..<index])
                buffer.removeFirst(index + terminator.count)
                return head
            }
            guard await readMore() else { return nil }
        }
    }

    private func readLine() async -> String? {
        while true {
            if let index = indexOf([0x0D, 0x0A], in: buffer) {
                let line = String(decoding: buffer[0..<index], as: UTF8.self)
                buffer.removeFirst(index + 2)
                return line
            }
            guard await readMore() else { return nil }
        }
    }

    private func readExactly(_ count: Int) async -> [UInt8]? {
        while buffer.count < count {
            guard await readMore() else { return nil }
        }
        let bytes = Array(buffer[0..<count])
        buffer.removeFirst(count)
        return bytes
    }

    private func indexOf(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return start
            }
        }
        return nil
    }
}
