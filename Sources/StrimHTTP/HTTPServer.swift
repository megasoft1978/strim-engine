import Foundation
import Network

/// Minimal HTTP/1.1 server on Network.framework, bound to the IPv4 loopback address.
///
/// ```swift
/// let server = HTTPServer(port: 0, bearerToken: "secret")
/// server.route("POST", "/v1/echo") { request, responder in
///     try await responder.json(200, request.body)
/// }
/// let port = try await server.start()
/// ```
///
/// Handlers run on the Swift cooperative pool; the server never blocks a thread waiting on them.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Request, Responder) async throws -> Void

    private struct RouteKey: Hashable {
        let method: String
        let path: String
    }

    private struct PrefixRoute {
        let method: String
        let prefix: String
        let handler: Handler
    }

    private enum Resolution {
        case found(Handler)
        case methodNotAllowed([String])
        case notFound
    }

    private static let preflightMethods = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    private static let preflightMaxAge = "600"

    let bearerToken: String?
    let limits: HTTPServerLimits
    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "strim.http.server", qos: .userInitiated)
    private let lock = NSLock()
    private var exactRoutes: [RouteKey: Handler] = [:]
    private var prefixRoutes: [PrefixRoute] = []
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    /// - Parameters:
    ///   - port: TCP port on 127.0.0.1; `0` picks an ephemeral port (see `start()`).
    ///   - bearerToken: when set, every request except CORS preflights needs
    ///     `Authorization: Bearer <token>`.
    ///   - limits: connection caps and read timeouts (see `HTTPServerLimits`).
    public init(port: UInt16 = 0, bearerToken: String? = nil, limits: HTTPServerLimits = .fromEnvironment()) {
        self.limits = limits
        self.requestedPort = port
        self.bearerToken = bearerToken
    }

    /// The bound port once started, otherwise nil.
    public var port: UInt16? { lock.withLock { boundPort } }

    /// Registers a handler for an exact method and path. Exact routes win over prefix routes.
    public func route(_ method: String, _ path: String, _ handler: @escaping Handler) {
        lock.withLock {
            exactRoutes[RouteKey(method: method, path: path)] = handler
        }
    }

    /// Registers a handler for every path starting with `prefix`. The longest matching prefix wins.
    public func route(_ method: String, prefix: String, _ handler: @escaping Handler) {
        lock.withLock {
            prefixRoutes.append(PrefixRoute(method: method, prefix: prefix, handler: handler))
        }
    }

    /// Starts listening and returns the bound port once the listener is ready.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpointPort = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: endpointPort)
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true // flush each SSE event without Nagle delay
        }

        let listener = try NWListener(using: parameters)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if let raw = listener?.port?.rawValue {
                        once.resume(returning: raw)
                    } else {
                        once.resume(throwing: HTTPServerError.listenerFailed("no bound port"))
                    }
                case .failed(let error):
                    once.resume(throwing: HTTPServerError.listenerFailed("\(error)"))
                case .cancelled:
                    once.resume(throwing: HTTPServerError.listenerFailed("cancelled before ready"))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] transport in
                self?.accept(transport)
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = nil
        lock.withLock {
            self.listener = listener
            self.boundPort = port
        }
        return port
    }

    /// Stops listening and cancels open connections. In-flight handlers see `onClose`.
    public func stop() {
        let (listener, open): (NWListener?, [HTTPConnection]) = lock.withLock {
            let snapshot = (self.listener, Array(connections.values))
            self.listener = nil
            self.boundPort = nil
            return snapshot
        }
        listener?.cancel()
        open.forEach { $0.cancel() }
    }

    // MARK: - Internal

    private func accept(_ transport: NWConnection) {
        let connection = HTTPConnection(transport: transport, server: self)
        let accepted: Bool = lock.withLock {
            guard connections.count < limits.maxConnections else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        guard accepted else {
            transport.cancel()   // over the connection cap: drop before reading a byte
            return
        }
        let queue = self.queue
        Task {
            await connection.run(queue: queue)
        }
    }

    func unregister(_ connection: HTTPConnection) {
        lock.withLock {
            connections[ObjectIdentifier(connection)] = nil
        }
    }

    /// Localhost origins are echoed back for CORS; any other origin gets no CORS headers.
    func allowedOrigin(for request: Request) -> String? {
        guard let origin = request.headers["Origin"], Self.isLoopbackOrigin(origin) else { return nil }
        return origin
    }

    /// True when the Host header (port stripped, case-insensitive) is `localhost`, `127.0.0.1` or `[::1]`.
    static func isLoopbackHost(_ header: String?) -> Bool {
        guard var host = header?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            host = String(host[...close])
        } else if let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        return host == "localhost" || host == "127.0.0.1" || host == "[::1]"
    }

    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Runs auth, CORS preflight and routing for one request. Errors from handlers propagate
    /// to the connection, which answers 500 if no response was started.
    func dispatch(_ request: Request, _ responder: Responder) async throws {
        // DNS-rebinding and cross-site defense: a browser page can reach a loopback server, so the
        // Host must name a loopback host and any Origin must be loopback. Non-browser clients send no Origin.
        if !Self.isLoopbackHost(request.headers["Host"])
            || (request.headers["Origin"].map { !Self.isLoopbackOrigin($0) } ?? false) {
            try await responder.respond(403, body: Data("{\"error\":\"Forbidden\"}".utf8),
                                        contentType: "application/json")
            return
        }

        if request.method == "OPTIONS",
           request.headers["Origin"] != nil,
           request.headers["Access-Control-Request-Method"] != nil {
            var headers = HTTPHeaders()
            headers.append(name: "Access-Control-Allow-Methods", value: Self.preflightMethods)
            headers.append(name: "Access-Control-Allow-Headers",
                           value: request.headers["Access-Control-Request-Headers"] ?? "Authorization, Content-Type")
            headers.append(name: "Access-Control-Max-Age", value: Self.preflightMaxAge)
            try await responder.respond(204, body: Data(), contentType: nil, headers: headers)
            return
        }

        if let token = bearerToken, !Self.isAuthorized(request, token: token) {
            var headers = HTTPHeaders()
            headers.append(name: "WWW-Authenticate", value: "Bearer")
            try await responder.respond(401, body: Data("{\"error\":\"Unauthorized\"}".utf8),
                                        contentType: "application/json", headers: headers)
            return
        }

        switch resolve(method: request.method, path: request.path) {
        case .found(let handler):
            try await handler(request, responder)
        case .methodNotAllowed(let allowed):
            var headers = HTTPHeaders()
            headers.append(name: "Allow", value: allowed.joined(separator: ", "))
            try await responder.respond(405, body: Data("{\"error\":\"Method Not Allowed\"}".utf8),
                                        contentType: "application/json", headers: headers)
        case .notFound:
            try await responder.respond(404, body: Data("{\"error\":\"Not Found\"}".utf8),
                                        contentType: "application/json")
        }
    }

    private func resolve(method: String, path: String) -> Resolution {
        lock.withLock {
            if let handler = exactRoutes[RouteKey(method: method, path: path)] {
                return .found(handler)
            }
            var best: PrefixRoute?
            for route in prefixRoutes where route.method == method && path.hasPrefix(route.prefix) {
                if best == nil || route.prefix.count > best!.prefix.count {
                    best = route
                }
            }
            if let best {
                return .found(best.handler)
            }
            var allowed = Set<String>()
            for key in exactRoutes.keys where key.path == path {
                allowed.insert(key.method)
            }
            for route in prefixRoutes where path.hasPrefix(route.prefix) {
                allowed.insert(route.method)
            }
            return allowed.isEmpty ? .notFound : .methodNotAllowed(allowed.sorted())
        }
    }

    private static func isAuthorized(_ request: Request, token: String) -> Bool {
        guard let value = request.headers["Authorization"] else { return false }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return constantTimeEquals(String(parts[1]), token)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= Int(a ^ b)
        }
        return difference == 0
    }
}

/// Resumes a checked continuation at most once; Network.framework may report several states.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.withLock {
            let taken = continuation
            continuation = nil
            return taken
        }
    }
}
