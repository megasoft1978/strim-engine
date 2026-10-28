import Foundation

/// Writes the response for one request. Each request gets exactly one response: either a
/// fixed-length body (`json`, `text`) or an open-ended `text/event-stream` (`startSSE`).
///
/// All writes suspend until the bytes are accepted by the socket, so a slow client applies
/// backpressure to the handler. Writes after the peer disconnects throw
/// `HTTPServerError.connectionClosed`.
public struct Responder: Sendable {
    let connection: HTTPConnection
    let core: ResponseCore
    let keepAlive: Bool
    /// Request `Origin` when it is a localhost origin; echoed in `Access-Control-Allow-Origin`.
    let corsOrigin: String?

    /// True once the peer has gone away.
    public var isClosed: Bool { core.isClosed }

    /// Registers `hook` to run when the client disconnects before the response completes.
    /// Runs immediately if the connection is already closed. Hooks are dropped once the
    /// response completes, so a later disconnect does not fire them.
    public func onClose(_ hook: @escaping @Sendable () -> Void) {
        core.addCloseHook(hook)
    }

    public func json(_ status: Int, _ data: Data, headers: HTTPHeaders = HTTPHeaders()) async throws {
        try await respond(status, body: data, contentType: "application/json", headers: headers)
    }

    public func text(_ status: Int, _ string: String, headers: HTTPHeaders = HTTPHeaders()) async throws {
        try await respond(status, body: Data(string.utf8), contentType: "text/plain; charset=utf-8", headers: headers)
    }

    /// Starts a chunked `text/event-stream` response and flushes the headers immediately.
    public func startSSE(headers: HTTPHeaders = HTTPHeaders()) async throws {
        guard core.advance(from: .pending, to: .sse) else {
            throw HTTPServerError.invalidState("response already started")
        }
        var fields = [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Transfer-Encoding", "chunked"),
        ]
        fields += headers.fields.map { ($0.name, $0.value) }
        try await send(responseHead(200, fields: fields))
    }

    /// Writes one event: `data: <line>` per line of `data`, then a blank line. The chunk is
    /// flushed before this returns. Starts the stream if it has not been started.
    public func sseWrite(_ data: String) async throws {
        try await ensureStreaming()
        var payload = ""
        for line in data.components(separatedBy: .newlines) {
            payload += "data: \(line)\n"
        }
        payload += "\n"
        try await writeChunk(payload)
    }

    /// Writes a named event: `event: <name>`, `data: <line>` per line of `data`, then a blank line.
    public func sseEvent(_ event: String, _ data: String) async throws {
        try await ensureStreaming()
        var payload = "event: \(event)\n"
        for line in data.components(separatedBy: .newlines) {
            payload += "data: \(line)\n"
        }
        payload += "\n"
        try await writeChunk(payload)
    }

    /// Writes an SSE comment line (`: text`), useful as a keep-alive heartbeat.
    public func sseComment(_ text: String) async throws {
        try await ensureStreaming()
        var payload = ""
        for line in text.components(separatedBy: .newlines) {
            payload += ": \(line)\n"
        }
        payload += "\n"
        try await writeChunk(payload)
    }

    /// Ends the response. For SSE this writes the terminating zero-length chunk; a pending
    /// response becomes an empty event stream. Calling it again is a no-op.
    public func finish() async throws {
        switch core.currentPhase {
        case .pending:
            try await startSSE()
            try await finish()
        case .sse:
            do {
                try await connection.send(Data("0\r\n\r\n".utf8))
                core.setPhase(.done)
            } catch {
                core.setPhase(.broken)
                throw error
            }
        case .done, .broken:
            return
        }
    }

    // MARK: - Internal

    /// Sends a complete fixed-length response. Used by the server for preflight and errors.
    func respond(_ status: Int, body: Data, contentType: String?, headers: HTTPHeaders = HTTPHeaders()) async throws {
        guard core.advance(from: .pending, to: .done) else {
            throw HTTPServerError.invalidState("response already started")
        }
        var fields: [(String, String)] = []
        if let contentType {
            fields.append(("Content-Type", contentType))
        }
        if status != 204 && status != 304 {
            fields.append(("Content-Length", String(body.count)))
        }
        fields += headers.fields.map { ($0.name, $0.value) }
        do {
            try await send(responseHead(status, fields: fields) + body)
        } catch {
            core.setPhase(.broken)
            throw error
        }
    }

    // MARK: - Private

    private func ensureStreaming() async throws {
        if core.currentPhase == .pending {
            try await startSSE()
        }
        guard core.currentPhase == .sse else {
            throw HTTPServerError.invalidState("stream is not open")
        }
    }

    private func writeChunk(_ payload: String) async throws {
        let body = Array(payload.utf8)
        var framed = Array(String(body.count, radix: 16).utf8)
        framed += Array("\r\n".utf8)
        framed += body
        framed += Array("\r\n".utf8)
        do {
            try await connection.send(Data(framed))
        } catch {
            core.setPhase(.broken)
            throw error
        }
    }

    /// Sends bytes for a response that is already marked in progress; marks it broken on failure.
    private func send(_ data: Data) async throws {
        do {
            try await connection.send(data)
        } catch {
            core.setPhase(.broken)
            throw error
        }
    }

    private func responseHead(_ status: Int, fields: [(String, String)]) -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPReason.phrase(for: status))\r\n"
        for (name, value) in fields {
            head += "\(name): \(value)\r\n"
        }
        if let corsOrigin {
            head += "Access-Control-Allow-Origin: \(corsOrigin)\r\nVary: Origin\r\n"
        }
        head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }
}
