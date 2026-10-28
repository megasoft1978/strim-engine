import Foundation
import StrimHTTP
import StrimTemplate

/// MCP streamable-HTTP server side for `/mcp` (POST/GET/DELETE). Stateless apart from handing out an
/// `Mcp-Session-Id` at `initialize`, which is never required later. Auth/Host/Origin are enforced by the
/// HTTP server and `guarded()`; register `handle` through `StrimOpenAIServer.addGuardedRoute`.
public final class MCPRoute: Sendable {
    /// Largest JSON-RPC batch accepted (each `tools/call` can submit a job and wait up to 25 s).
    public static let maxBatchItems = 16
    public static let maxBodyBytes = 1_048_576

    private let provider: any MCPToolProvider
    private let serverName: String
    private let version: String
    private let instructions: String
    private let progressInterval: Duration

    public init(provider: any MCPToolProvider, serverName: String, version: String, instructions: String,
                progressInterval: Duration = .seconds(5)) {
        self.provider = provider
        self.serverName = serverName
        self.version = version
        self.instructions = instructions
        self.progressInterval = progressInterval
    }

    public func handle(request: Request, responder: Responder) async throws {
        do {
            switch request.method {
            case "POST": try await post(request, responder)
            case "GET":
                var h = HTTPHeaders()
                h.append(name: "Allow", value: "POST, DELETE")
                try await responder.text(405, "Method Not Allowed", headers: h)
            case "DELETE": try await responder.json(200, Data("{}".utf8))
            default:
                var h = HTTPHeaders()
                h.append(name: "Allow", value: "POST, DELETE")
                try await responder.text(405, "Method Not Allowed", headers: h)
            }
        } catch let e as HTTPServerError {
            throw e
        } catch {
            // Never leak internals: log detail, answer generically.
            FileHandle.standardError.write(Data("mcp: internal error: \(error)\n".utf8))
            try? await responder.json(500, RPC.data(RPC.error(.null, RPCCode.internalError, "Internal error")))
        }
    }

    // MARK: POST

    private func post(_ request: Request, _ responder: Responder) async throws {
        if request.body.count > Self.maxBodyBytes {
            try await responder.json(413, RPC.data(RPC.error(.null, RPCCode.invalidRequest, "Request body too large")))
            return
        }
        // Stateless negotiation: the MCP-Protocol-Version header; absent means 2025-03-26 (spec back-compat rule).
        let headerVersion = request.headers["MCP-Protocol-Version"]
        let negotiated = headerVersion ?? MCPProtocol.v20250326
        guard MCPProtocol.supported.contains(negotiated) else {
            try await responder.json(400, RPC.data(RPC.error(.null, RPCCode.invalidRequest,
                                                            "Unsupported MCP-Protocol-Version")))
            return
        }
        guard let text = String(data: request.body, encoding: .utf8),
              let body = try? OrderedJSON.parse(text) else {
            try await responder.json(400, RPC.data(RPC.error(.null, RPCCode.parseError, "Parse error")))
            return
        }

        if case let .array(items) = body {
            guard negotiated == MCPProtocol.v20250326 else {
                try await responder.json(400, RPC.data(RPC.error(.null, RPCCode.invalidRequest,
                                                                "Batching is not supported in this protocol version")))
                return
            }
            guard !items.isEmpty else {
                try await responder.json(400, RPC.data(RPC.error(.null, RPCCode.invalidRequest, "Empty batch")))
                return
            }
            guard items.count <= MCPRoute.maxBatchItems else {
                try await responder.json(400, RPC.data(RPC.error(.null, RPCCode.invalidRequest,
                                                                "Batch too large (max \(MCPRoute.maxBatchItems) requests)")))
                return
            }
            var replies: [OrderedJSON] = []
            for item in items {
                let msg = RPCMessage.classify(item)
                if case let .request(_, method, _) = msg, method == "initialize" {
                    replies.append(RPC.error(item["id"] ?? .null, RPCCode.invalidRequest,
                                             "initialize must not be batched"))
                } else if let reply = await process(msg).reply {
                    replies.append(reply)
                }
            }
            if replies.isEmpty {
                try await responder.text(202, "")
            } else {
                try await responder.json(200, RPC.data(.array(replies)))
            }
            return
        }

        let msg = RPCMessage.classify(body)
        switch msg {
        case .invalid(let id):
            try await responder.json(400, RPC.data(RPC.error(id, RPCCode.invalidRequest, "Invalid Request")))
        case .notification, .response:
            try await responder.text(202, "")
        case let .request(id, method, params):
            if method == "tools/call", let streaming = streamingCall(id: id, params: params) {
                try await stream(streaming, responder)
                return
            }
            let out = await process(msg)
            var headers = HTTPHeaders()
            if let session = out.sessionID { headers.append(name: "Mcp-Session-Id", value: session) }
            try await responder.json(200, RPC.data(out.reply ?? RPC.error(id, RPCCode.internalError, "Internal error")),
                                     headers: headers)
        }
    }

    // MARK: dispatch

    private struct Outcome {
        var reply: OrderedJSON?
        var sessionID: String?
        init(reply: OrderedJSON?, sessionID: String? = nil) { self.reply = reply; self.sessionID = sessionID }
    }

    private func process(_ msg: RPCMessage) async -> Outcome {
        switch msg {
        case .invalid(let id):
            return Outcome(reply: RPC.error(id, RPCCode.invalidRequest, "Invalid Request"))
        case .notification, .response:
            return Outcome(reply: nil)
        case let .request(id, method, params):
            switch method {
            case "initialize":
                guard let requested = params?["protocolVersion"]?.stringValue else {
                    return Outcome(reply: RPC.error(id, RPCCode.invalidParams, "Missing protocolVersion"))
                }
                let chosen = MCPProtocol.supported.contains(requested) ? requested : MCPProtocol.v20250618
                var members: [(String, OrderedJSON)] = [
                    ("protocolVersion", .string(chosen)),
                    ("capabilities", .ordered([("tools", .ordered([("listChanged", .bool(false))]))])),
                    ("serverInfo", .ordered([("name", .string(serverName)), ("version", .string(version))])),
                ]
                if !instructions.isEmpty { members.append(("instructions", .string(instructions))) }
                return Outcome(reply: RPC.result(id, .ordered(members)), sessionID: Self.newSessionID())
            case "ping":
                return Outcome(reply: RPC.result(id, .object([])))
            case "tools/list":
                let tools = provider.definitions().map { d in
                    var m: [(String, OrderedJSON)] = [("name", .string(d.name))]
                    if let t = d.title { m.append(("title", .string(t))) }
                    m.append(("description", .string(d.description)))
                    m.append(("inputSchema", d.inputSchema))
                    if let a = d.annotations { m.append(("annotations", a)) }
                    return OrderedJSON.ordered(m)
                }
                return Outcome(reply: RPC.result(id, .ordered([("tools", .array(tools))])))
            case "tools/call":
                switch parseCall(params) {
                case .failure(let e): return Outcome(reply: RPC.error(id, e.code, e.message))
                case .success(let (name, args)):
                    let r = await provider.call(name: name, arguments: args, progress: { _, _ in })
                    return Outcome(reply: RPC.result(id, Self.render(r)))
                }
            default:
                return Outcome(reply: RPC.error(id, RPCCode.methodNotFound, "Method not found"))
            }
        }
    }

    private func parseCall(_ params: OrderedJSON?) -> Result<(String, OrderedJSON), RPCError> {
        guard let name = params?["name"]?.stringValue else {
            return .failure(RPCError(code: RPCCode.invalidParams, message: "Missing tool name"))
        }
        var args = OrderedJSON.object([])
        if let a = params?["arguments"] {
            switch a {
            case .object: args = a
            case .null: break
            default: return .failure(RPCError(code: RPCCode.invalidParams, message: "arguments must be an object"))
            }
        }
        guard provider.definitions().contains(where: { $0.name == name }) else {
            return .failure(RPCError(code: RPCCode.invalidParams, message: "Unknown tool: \(name)"))
        }
        return .success((name, args))
    }

    static func render(_ r: MCPToolResult) -> OrderedJSON {
        var m: [(String, OrderedJSON)] = [
            ("content", .array([.ordered([("type", .string("text")), ("text", .string(r.text))])])),
        ]
        if let s = r.structured { m.append(("structuredContent", s)) }
        m.append(("isError", .bool(r.isError)))
        return .ordered(m)
    }

    static func newSessionID() -> String {
        var g = SystemRandomNumberGenerator()
        return String(format: "%016llx%016llx", g.next() as UInt64, g.next() as UInt64)
    }

    // MARK: SSE progress

    private struct StreamingCall {
        var id: OrderedJSON
        var name: String
        var arguments: OrderedJSON
        var token: OrderedJSON
    }

    /// Non-nil when this valid single tools/call carries a progressToken (string or integer).
    private func streamingCall(id: OrderedJSON, params: OrderedJSON?) -> StreamingCall? {
        guard let token = params?["_meta"]?["progressToken"] else { return nil }
        switch token {
        case .string, .int: break
        default: return nil
        }
        guard case .success(let (name, args)) = parseCall(params) else { return nil }
        return StreamingCall(id: id, name: name, arguments: args, token: token)
    }

    private enum Event: Sendable {
        case tick
        case done(MCPToolResult)
    }

    private func stream(_ call: StreamingCall, _ responder: Responder) async throws {
        let box = ProgressBox()
        let provider = self.provider
        let interval = progressInterval
        let (events, sink) = AsyncStream.makeStream(of: Event.self)
        try await responder.startSSE()
        let work = Task {
            let r = await provider.call(name: call.name, arguments: call.arguments,
                                        progress: { p, m in box.report(p, m) })
            sink.yield(.done(r))
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                sink.yield(.tick)
            }
        }
        responder.onClose {
            work.cancel(); ticker.cancel(); sink.finish()
        }
        defer { ticker.cancel() }
        var lastSent = -Double.infinity
        do {
            for await event in events {
                switch event {
                case .tick:
                    guard let (p, m) = box.take(), p > lastSent else { continue }
                    lastSent = p
                    let params = OrderedJSON.ordered([("progressToken", call.token), ("progress", .double(p)),
                                                      ("message", .string(m))])
                    try await responder.sseWrite(RPC.notification("notifications/progress", params).serialized())
                case .done(let r):
                    try await responder.sseWrite(RPC.result(call.id, Self.render(r)).serialized())
                    try await responder.finish()
                    return
                }
            }
        } catch {
            work.cancel()
            throw error
        }
    }
}

/// Latest unsent progress report, coalesced between ticks.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (Double, String)?

    func report(_ progress: Double, _ message: String) {
        lock.withLock { pending = (progress, message) }
    }

    func take() -> (Double, String)? {
        lock.withLock { defer { pending = nil }; return pending }
    }
}
