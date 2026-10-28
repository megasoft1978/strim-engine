import CryptoKit
import Foundation
import StrimAPI
import StrimHTTP

/// A failure that maps to the `APIErrorEnvelope` body and an HTTP status.
struct ControlError: Error {
    var status: Int
    var error: StrimAPI.APIError
    init(_ status: Int, _ code: String, _ message: String) { self.status = status; self.error = StrimAPI.APIError(code: code, message: message) }

    static func badRequest(_ m: String) -> ControlError { .init(400, "bad_request", m) }
    static func forbidden(_ m: String) -> ControlError { .init(403, "forbidden", m) }
    static func notFound(_ m: String) -> ControlError { .init(404, "not_found", m) }
    static func conflict(_ m: String) -> ControlError { .init(409, "conflict", m) }
    static func unavailable(_ m: String) -> ControlError { .init(503, "unavailable", m) }
    static func internalError(_ m: String) -> ControlError { .init(500, "internal", m) }
    static func notImplemented(_ m: String) -> ControlError { .init(501, "not_implemented", m) }
    static func unsafePatch(_ m: String) -> ControlError { .init(400, "unsafe_patch", m) }
}

struct Reply {
    var status: Int
    var body: Data
    static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> Reply {
        Reply(status: status, body: try ControlJSON.encode(value))
    }
    static let empty = Reply(status: 200, body: Data("{}".utf8))
}

enum ControlJSON {
    static func encode<T: Encodable>(_ v: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(v)
    }
    static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        guard !body.isEmpty else { throw ControlError.badRequest("request body required") }
        do { return try JSONDecoder().decode(type, from: body) }
        catch { throw ControlError.badRequest("invalid JSON body: \(type)") }
    }
}

/// Request checks shared by every control route, on top of the server's bearer-token guard.
enum ControlGuard {
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
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Loopback Host and Origin (DNS rebinding / cross-site), no cross-site fetch metadata, then credentials:
    /// the control token unlocks everything; the API/MCP token unlocks only `GET status`; anything else is 401.
    static func check(_ req: Request, status: Bool, auth: ControlAuth) throws {
        guard isLoopbackHost(req.headers["Host"]) else { throw ControlError.forbidden("Host must be a loopback name") }
        if let o = req.headers["Origin"], !isLoopbackOrigin(o) { throw ControlError.forbidden("Origin is not loopback") }
        if let site = req.headers["Sec-Fetch-Site"]?.lowercased(), site == "cross-site" {
            throw ControlError.forbidden("cross-site requests are refused")
        }
        switch auth.level(of: req) {
        case .control: return
        case .api:
            if status { return }
            throw ControlError.forbidden("this credential is not valid for this route")
        case .none:
            if status, !auth.apiRequired { return }
            throw ControlError(401, "unauthorized", "missing or invalid credentials")
        }
    }

    static func jsonBody(_ req: Request, maxBytes: Int) throws {
        if req.body.count > maxBytes { throw ControlError.badRequest("body too large") }
        if !req.body.isEmpty {
            let ct = (req.headers["Content-Type"] ?? "").lowercased()
            guard ct.hasPrefix("application/json") else { throw ControlError.badRequest("Content-Type must be application/json") }
        }
    }
}


/// Two credentials, compared as fixed-length SHA-256 digests in constant time. Neither answer reveals which
/// token (if any) is the valid one.
public struct ControlAuth: Sendable {
    public enum Level: Sendable { case control, api, none }
    private let control: [UInt8]
    private let api: [UInt8]?

    /// - apiToken: the OpenAI/MCP token (nil when the host runs with --no-auth).
    public init(controlToken: String, apiToken: String?) {
        control = Self.digest(controlToken)
        api = apiToken.map(Self.digest)
    }

    var apiRequired: Bool { api != nil }

    static func digest(_ s: String) -> [UInt8] { Array(SHA256.hash(data: Data(s.utf8))) }

    static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var d: UInt8 = 0
        for i in 0..<32 { d |= a[i] ^ b[i] }
        return d == 0
    }

    func level(of req: Request) -> Level {
        guard let v = req.headers["Authorization"] else { return .none }
        let parts = v.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return .none }
        let d = Self.digest(String(parts[1]))
        let isControl = Self.equal(d, control)
        let isAPI = api.map { Self.equal(d, $0) } ?? false
        return isControl ? .control : (isAPI ? .api : .none)
    }
}
