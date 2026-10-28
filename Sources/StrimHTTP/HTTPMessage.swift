import Foundation

/// Hard limits enforced by the parser and server.
public enum HTTPLimits {
    /// Maximum accepted `Content-Length`; larger requests get 413 before the body is read.
    public static let maxBodyBytes = 16 * 1024 * 1024
    /// Maximum size of request line plus headers.
    public static let maxHeadBytes = 64 * 1024
}

/// Case-insensitive header collection that keeps insertion order.
public struct HTTPHeaders: Sendable, Equatable {
    public private(set) var fields: [Field] = []

    public struct Field: Sendable, Equatable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public init(_ fields: [Field] = []) {
        self.fields = fields
    }

    public mutating func append(name: String, value: String) {
        fields.append(Field(name: name, value: value))
    }

    /// First value for `name` (case-insensitive).
    public subscript(name: String) -> String? {
        let key = name.lowercased()
        return fields.first { $0.name.lowercased() == key }?.value
    }

    /// All values for `name` (case-insensitive), in order.
    public func values(for name: String) -> [String] {
        let key = name.lowercased()
        return fields.filter { $0.name.lowercased() == key }.map(\.value)
    }
}

/// A fully received HTTP/1.x request.
public struct Request: Sendable {
    public let method: String
    /// Raw request-target path without the query string, e.g. `/v1/chat/completions`.
    public let path: String
    /// Decoded query parameters; the last occurrence of a repeated key wins.
    public let query: [String: String]
    public let headers: HTTPHeaders
    public let body: Data
    public let version: String

    public init(method: String, path: String, query: [String: String] = [:],
                headers: HTTPHeaders = HTTPHeaders(), body: Data = Data(), version: String = "HTTP/1.1") {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.version = version
    }
}

/// Errors surfaced by the server and responder.
public enum HTTPServerError: Error, Sendable, Equatable {
    /// The peer went away (or the connection failed) before the write completed.
    case connectionClosed
    /// The response was already started or finished, or the operation does not apply to it.
    case invalidState(String)
    /// The listener failed or stopped before becoming ready.
    case listenerFailed(String)
}

/// Reason phrases for the status codes this server emits.
enum HTTPReason {
    static func phrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Unknown"
        }
    }
}

/// Connection-level abuse limits, enforced before any request is routed or authenticated.
/// Defaults (override by environment): `STRIM_HTTP_MAX_CONNECTIONS` 128, `STRIM_HTTP_HEAD_TIMEOUT_S` 10,
/// `STRIM_HTTP_BODY_TIMEOUT_S` 30, `STRIM_HTTP_IDLE_TIMEOUT_S` 120, `STRIM_HTTP_MAX_PIPELINED` 8.
public struct HTTPServerLimits: Sendable, Equatable {
    /// Open connections; further ones are closed at accept.
    public var maxConnections: Int
    /// Seconds from the first byte of a request line/headers until the head is complete (total deadline).
    public var headTimeout: Double
    /// Seconds without progress while a body is incomplete. The body also has a total deadline of
    /// `bodyTimeout + contentLength / 64 KiB/s`, so a one-byte-per-interval trickle cannot hold 16 MiB forever.
    public var bodyTimeout: Double
    /// Seconds a keep-alive connection may sit with no request in flight and no bytes pending.
    public var idleTimeout: Double
    /// Parsed requests queued behind the one being handled; one more closes the connection with 429.
    public var maxPipelined: Int

    public init(maxConnections: Int = 128, headTimeout: Double = 10, bodyTimeout: Double = 30,
                idleTimeout: Double = 120, maxPipelined: Int = 8) {
        self.maxConnections = max(1, maxConnections)
        self.headTimeout = max(0.05, headTimeout)
        self.bodyTimeout = max(0.05, bodyTimeout)
        self.idleTimeout = max(0.05, idleTimeout)
        self.maxPipelined = max(1, maxPipelined)
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> HTTPServerLimits {
        func num(_ key: String, _ fallback: Double) -> Double { env[key].flatMap(Double.init) ?? fallback }
        let d = HTTPServerLimits()
        return HTTPServerLimits(maxConnections: Int(num("STRIM_HTTP_MAX_CONNECTIONS", Double(d.maxConnections))),
                                headTimeout: num("STRIM_HTTP_HEAD_TIMEOUT_S", d.headTimeout),
                                bodyTimeout: num("STRIM_HTTP_BODY_TIMEOUT_S", d.bodyTimeout),
                                idleTimeout: num("STRIM_HTTP_IDLE_TIMEOUT_S", d.idleTimeout),
                                maxPipelined: Int(num("STRIM_HTTP_MAX_PIPELINED", Double(d.maxPipelined))))
    }
}
