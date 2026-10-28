import Foundation
import Network

/// Response state shared between one request's handler and the connection reader.
/// Holds the response phase and the close hooks that fire if the peer leaves mid-response.
final class ResponseCore: @unchecked Sendable {
    enum Phase: Sendable, Equatable {
        case pending, sse, done, broken
    }

    private let lock = NSLock()
    private var phase: Phase = .pending
    private var closed: Bool
    private var hooks: [@Sendable () -> Void] = []

    init(closed: Bool) {
        self.closed = closed
    }

    var currentPhase: Phase { lock.withLock { phase } }

    var isClosed: Bool { lock.withLock { closed } }

    /// Moves to `next` only when the phase is currently `expected`.
    func advance(from expected: Phase, to next: Phase) -> Bool {
        lock.withLock {
            guard phase == expected else { return false }
            setLocked(next)
            return true
        }
    }

    func setPhase(_ next: Phase) {
        lock.withLock { setLocked(next) }
    }

    /// Completed responses drop their hooks: a later disconnect has nothing to cancel.
    private func setLocked(_ next: Phase) {
        phase = next
        if next == .done || next == .broken {
            hooks = []
        }
    }

    func addCloseHook(_ hook: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if closed { return true }
            hooks.append(hook)
            return false
        }
        if runNow { hook() }
    }

    func markClosed() {
        let toRun: [@Sendable () -> Void] = lock.withLock {
            guard !closed else { return [] }
            closed = true
            let pending = hooks
            hooks = []
            return pending
        }
        toRun.forEach { $0() }
    }
}

/// One accepted TCP connection. A reader task parses requests and watches for EOF while a
/// processing loop runs handlers strictly in order, which keeps pipelined responses ordered.
final class HTTPConnection: @unchecked Sendable {
    private enum Item: Sendable {
        case request(Request)
        case protocolError(Int)
    }

    private enum Chunk {
        case bytes([UInt8])
        case end
    }

    private let transport: NWConnection
    private let server: HTTPServer
    private let lock = NSLock()
    private var peerClosed = false
    private var current: ResponseCore?
    // Read-side bookkeeping for the watchdog (guarded by `lock`).
    private enum ReadPhase { case between, head, body(length: Int) }
    private var readPhase = ReadPhase.between
    private var phaseSince = HTTPConnection.now()
    private var lastByteAt = HTTPConnection.now()
    /// Parsed requests not yet fully handled (queued plus the running one).
    private var queuedRequests = 0

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    init(transport: NWConnection, server: HTTPServer) {
        self.transport = transport
        self.server = server
    }

    func run(queue: DispatchQueue) async {
        transport.start(queue: queue)
        let (stream, continuation) = AsyncStream<Item>.makeStream()
        let reader = Task { await self.readLoop(into: continuation) }
        let watchdog = Task { await self.watch() }
        for await item in stream {
            let keepGoing = await handle(item)
            if case .request = item { lock.withLock { queuedRequests -= 1; lastByteAt = Self.now() } }
            guard keepGoing else { break }
        }
        watchdog.cancel()
        reader.cancel()
        transport.cancel()
        server.unregister(self)
    }

    /// Cancels the transport; the reader then sees the failure and fires close hooks.
    func cancel() {
        transport.cancel()
    }

    // MARK: - Reading

    private func readLoop(into continuation: AsyncStream<Item>.Continuation) async {
        var parser = HTTPRequestParser()
        var failed = false
        reading: while true {
            switch await receive() {
            case .end:
                break reading
            case .bytes(let bytes):
                // After a protocol error, keep reading only to detect EOF; the bytes are ignored.
                guard !failed, !bytes.isEmpty else { continue }
                lock.withLock { lastByteAt = Self.now() }
                parser.append(bytes)
                while !failed, let event = parser.next() {
                    switch event {
                    case .request(let request):
                        let queued: Int = lock.withLock { queuedRequests += 1; return queuedRequests }
                        if queued > server.limits.maxPipelined + 1 {
                            // Pipelining flood: stop parsing, answer 429 after the queued work, close.
                            lock.withLock { queuedRequests -= 1 }
                            continuation.yield(.protocolError(429))
                            failed = true
                            break
                        }
                        continuation.yield(.request(request))
                    case .failure(let status):
                        continuation.yield(.protocolError(status))
                        failed = true
                    }
                }
                updatePhase(parser)
            }
        }
        markPeerClosed()
        continuation.finish()
    }

    private func updatePhase(_ parser: HTTPRequestParser) {
        let next: ReadPhase
        if let length = parser.awaitingBodyLength { next = .body(length: length) }
        else if parser.hasPartialRequest { next = .head }
        else { next = .between }
        lock.withLock {
            switch (readPhase, next) {
            case (.between, .between), (.head, .head): return   // keep the original start time
            case (.body(let a), .body(let b)) where a == b: return
            default:
                readPhase = next
                phaseSince = Self.now()
            }
        }
    }

    /// Closes the connection when a read deadline passes. Runs pre-auth, so a slow or silent peer cannot hold a
    /// connection (and up to 16 MiB of buffer) without a token. Never fires while a request is being handled.
    private func watch() async {
        let limits = server.limits
        let tick = Duration.milliseconds(max(20, min(500, Int(min(limits.headTimeout, limits.bodyTimeout, limits.idleTimeout) * 250))))
        while !Task.isCancelled {
            try? await Task.sleep(for: tick)
            if Task.isCancelled { return }
            let t = Self.now()
            let expired: Bool = lock.withLock {
                switch readPhase {
                case .between:
                    return queuedRequests == 0 && t - max(phaseSince, lastByteAt) > limits.idleTimeout
                case .head:
                    return t - phaseSince > limits.headTimeout
                case .body(let length):
                    let total = limits.bodyTimeout + Double(length) / 65_536
                    return t - lastByteAt > limits.bodyTimeout || t - phaseSince > total
                }
            }
            if expired { transport.cancel(); return }
        }
    }

    private func receive() async -> Chunk {
        await withCheckedContinuation { (continuation: CheckedContinuation<Chunk, Never>) in
            transport.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: .bytes([UInt8](data)))
                } else if isComplete || error != nil {
                    continuation.resume(returning: .end)
                } else {
                    continuation.resume(returning: .bytes([]))
                }
            }
        }
    }

    // MARK: - Processing

    /// Returns true when the connection may serve another request.
    private func handle(_ item: Item) async -> Bool {
        switch item {
        case .protocolError(let status):
            let responder = Responder(connection: self, core: beginRequest(), keepAlive: false, corsOrigin: nil)
            try? await responder.respond(status, body: Data(errorJSON(status).utf8), contentType: "application/json")
            return false

        case .request(let request):
            let core = beginRequest()
            let responder = Responder(connection: self, core: core, keepAlive: request.keepAlive,
                                      corsOrigin: server.allowedOrigin(for: request))
            do {
                try await server.dispatch(request, responder)
                switch core.currentPhase {
                case .pending:
                    try await responder.respond(500, body: Data(errorJSON(500).utf8), contentType: "application/json")
                case .sse:
                    try await responder.finish()
                case .done, .broken:
                    break
                }
            } catch {
                if core.currentPhase == .pending {
                    try? await responder.respond(500, body: Data(errorJSON(500).utf8), contentType: "application/json")
                }
                return false
            }
            return request.keepAlive && !core.isClosed
        }
    }

    private func errorJSON(_ status: Int) -> String {
        "{\"error\":\"\(HTTPReason.phrase(for: status))\"}"
    }

    // MARK: - Shared state

    private func beginRequest() -> ResponseCore {
        lock.withLock {
            let core = ResponseCore(closed: peerClosed)
            current = core
            return core
        }
    }

    private func markPeerClosed() {
        let core: ResponseCore? = lock.withLock {
            peerClosed = true
            return current
        }
        core?.markClosed()
    }

    // MARK: - Writing

    /// Sends `data` and suspends until Network.framework has accepted it. A slow reader
    /// therefore stalls the handler instead of growing an unbounded buffer.
    func send(_ data: Data) async throws {
        guard !lock.withLock({ peerClosed }) else { throw HTTPServerError.connectionClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            transport.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    continuation.resume(throwing: HTTPServerError.connectionClosed)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
