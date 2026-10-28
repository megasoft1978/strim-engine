import Foundation
import StrimAPI

/// Typed failures of the HTTP control client.
public enum ControlClientError: Error, Equatable, LocalizedError {
    case hostUnreachable(String)
    case timeout
    case unauthorized(tokenPresent: Bool)
    case forbidden
    case notImplemented
    case http(status: Int, api: APIError?)
    case decoding(String)
    case badResponse
    case invalidConfig(String)
    case redirectRefused

    public var errorDescription: String? {
        switch self {
        case .hostUnreachable(let d): "host unreachable (\(d))"
        case .timeout: "host did not respond in time"
        case .unauthorized(let present): present ? "host rejected the token (401)" : "host requires a token but none was found (401)"
        case .forbidden: "host refused the request (403, loopback only)"
        case .notImplemented: "not implemented by this host (501)"
        case .http(let s, let a): a.map { "\($0.code): \($0.message) (\(s))" } ?? "HTTP \(s)"
        case .decoding(let d): "unexpected response (\(d))"
        case .badResponse: "invalid HTTP response"
        case .invalidConfig(let d): d
        case .redirectRefused: "host answered with a redirect, which is refused"
        }
    }
}

/// True for a 501 / `not_implemented` answer, whichever client produced it.
public func isNotImplemented(_ error: Error) -> Bool {
    if let e = error as? ControlClientError, e == .notImplemented { return true }
    if let e = error as? APIError, e.code == "not_implemented" { return true }
    if case ControlClientError.http(let s, _) = error, s == 501 { return true }
    return false
}

/// State of the control-token file.
public enum TokenFileStatus: Equatable, Sendable {
    case ok
    case missing
    case notRegular
    case wrongOwner
    case outsideHome
    case empty
    /// Readable by group/other. Still usable, but the user is warned.
    case insecure(mode: Int)

    public var usable: Bool { self == .ok || { if case .insecure = self { return true }; return false }() }

    /// Banner text, or nil when fine. Never contains the token.
    public func banner(path: String) -> String? {
        let p = (path as NSString).abbreviatingWithTildeInPath
        switch self {
        case .ok: return nil
        case .missing: return "Control token missing. Start the host once so it creates \(p)."
        case .notRegular: return "\(p) is not a regular file (symlinks are refused)."
        case .wrongOwner: return "\(p) is owned by another user; refusing to use it."
        case .outsideHome: return "control_token_path must be inside your home folder; refusing \(p)."
        case .empty: return "\(p) is empty. Restart the host so it regenerates it."
        case .insecure(let m): return "\(p) is readable by other users (mode \(String(format: "%04o", m))). Run: chmod 600 \(p)"
        }
    }
}

/// Reads the control-plane bearer token (default ~/.strim/control-token). The path must be under `home`, a regular
/// file (no symlink) owned by the user. Never logged or shown.
public struct TokenReader: Sendable {
    public var path: String
    public var home: String
    public init(path: String = AppPaths.defaultControlTokenPath, home: String = NSHomeDirectory()) { self.path = path; self.home = home }

    public func inspect() -> TokenFileStatus { check().0 }

    private func check() -> (TokenFileStatus, String?) {
        let std = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        guard std.hasPrefix("/") else { return (.outsideHome, nil) }
        let homeR = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let parentR = URL(fileURLWithPath: (std as NSString).deletingLastPathComponent).resolvingSymlinksInPath().path
        guard parentR == homeR || parentR.hasPrefix(homeR.hasSuffix("/") ? homeR : homeR + "/") else { return (.outsideHome, nil) }
        var st = stat()
        guard lstat(std, &st) == 0 else { return (.missing, nil) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return (.notRegular, nil) }
        guard st.st_uid == getuid() else { return (.wrongOwner, nil) }
        guard let raw = try? String(contentsOfFile: std, encoding: .utf8) else { return (.empty, nil) }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return (.empty, nil) }
        let m = Int(st.st_mode & 0o7777)
        return (m & 0o077 != 0 ? .insecure(mode: m) : .ok, t)
    }

    /// The token, only when the file passes the checks above.
    public func read() -> String? {
        let (status, token) = check()
        return status.usable ? token : nil
    }
}

/// `host_url` validation: only plain `http://127.0.0.1:<port>`, `http://localhost:<port>` or `http://[::1]:<port>`.
public enum HostURL {
    /// nil when acceptable, else the reason.
    public static func validate(_ s: String) -> String? {
        if s.isEmpty { return "host_url is empty" }
        if s.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value >= 0x7f || $0 == "\\" }) {
            return "host_url contains whitespace, control, backslash or non-ASCII characters"
        }
        guard let c = URLComponents(string: s) else { return "host_url is not a valid URL" }
        guard c.scheme?.lowercased() == "http" else { return "host_url must use http (loopback only)" }
        if c.user != nil || c.password != nil || c.percentEncodedUser != nil || c.percentEncodedPassword != nil {
            return "host_url must not contain user info"
        }
        guard let host = normalizedHost(c), !(c.percentEncodedHost ?? "").contains("%"),
              ["127.0.0.1", "localhost", "::1"].contains(host) else {
            return "host_url host must be 127.0.0.1, localhost or [::1]"
        }
        guard let port = c.port, (1...65535).contains(port) else { return "host_url needs a port (1-65535)" }
        guard c.path.isEmpty || c.path == "/" else { return "host_url must not have a path" }
        guard c.query == nil, c.fragment == nil else { return "host_url must not have a query or fragment" }
        return nil
    }
    /// Host without IPv6 brackets, lowercased (URLComponents may or may not keep them).
    private static func normalizedHost(_ c: URLComponents) -> String? {
        guard var h = c.host?.lowercased() else { return nil }
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        return h
    }
    /// Normalised URL (`http://host:port`), or nil when rejected.
    public static func url(_ s: String) -> URL? {
        guard validate(s) == nil, let c = URLComponents(string: s), let host = normalizedHost(c), let port = c.port else { return nil }
        return URL(string: "http://" + (host.contains(":") ? "[\(host)]" : host) + ":\(port)")
    }
}

/// Refuses every redirect: a control-plane host must answer directly.
public final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum AppPaths {
    public static var home: String { NSHomeDirectory() }
    public static var defaultControlTokenPath: String { home + "/.strim/control-token" }
    public static var settingsPath: String { home + "/.strim/app.json" }
    public static var hostLogPath: String { home + "/.strim/host.log" }
    public static let defaultHostURL = "http://127.0.0.1:8203"
}

/// Incremental Server-Sent-Events parser. Feed raw lines (without terminator); blank line dispatches a frame.
public struct SSEParser: Sendable {
    public struct Frame: Equatable, Sendable { public var event: String?; public var data: String }
    private var event: String?
    private var dataLines: [String] = []
    public init() {}

    public mutating func feed(line: String) -> Frame? {
        if line.isEmpty {
            defer { event = nil; dataLines.removeAll() }
            guard !dataLines.isEmpty else { return nil }
            return Frame(event: event, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }  // comment / ping
        let name: Substring, value: Substring
        if let i = line.firstIndex(of: ":") {
            name = line[..<i]
            var v = line[line.index(after: i)...]
            if v.first == " " { v = v.dropFirst() }
            value = v
        } else { name = line[...]; value = "" }
        switch name {
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}

/// `StrimControlClient` over HTTP (URLSession). One SSE connection per `events()` call; reconnect and
/// backoff are the caller's job (`AppModel`).
public struct HTTPControlClient: StrimControlClient {
    public let baseURL: URL
    private let token: TokenReader
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let streamIdleTimeout: TimeInterval

    public init(baseURL: URL = URL(string: AppPaths.defaultHostURL)!, token: TokenReader = TokenReader(),
                session: URLSession = HTTPControlClient.hardenedSession(), requestTimeout: TimeInterval = 8, streamIdleTimeout: TimeInterval = 45) {
        self.baseURL = baseURL; self.token = token; self.session = session
        self.requestTimeout = requestTimeout; self.streamIdleTimeout = streamIdleTimeout
    }

    // MARK: hardened session

    /// Ephemeral, no proxies, no cache or cookies.
    public static func hardenedConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return c
    }
    public static func hardenedSession(extraProtocols: [AnyClass] = []) -> URLSession {
        let c = hardenedConfiguration()
        if !extraProtocols.isEmpty { c.protocolClasses = extraProtocols + (c.protocolClasses ?? []) }
        return URLSession(configuration: c, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// Client for the app's settings; fails closed (every call throws `invalidConfig`) when `host_url` is rejected.
    public static func make(settings: AppSettings) -> StrimControlClient {
        if let problem = settings.hostURLProblem { return InvalidConfigClient(reason: "Invalid host_url: \(problem)") }
        return HTTPControlClient(baseURL: settings.url, token: TokenReader(path: settings.controlTokenPath))
    }

    private func checkBase() throws {
        if let p = HostURL.validate(baseURL.absoluteString) { throw ControlClientError.invalidConfig("Invalid host_url: \(p)") }
    }

    // MARK: request plumbing

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval) -> URLRequest {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.path = path
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.timeoutInterval = timeout
        if let t = token.read() { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func mapTransport(_ error: Error) -> ControlClientError {
        if let e = error as? ControlClientError { return e }
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return .timeout
            default: return .hostUnreachable(u.localizedDescription)
            }
        }
        return .hostUnreachable(error.localizedDescription)
    }

    private func mapStatus(_ status: Int, body: Data) -> ControlClientError {
        let api = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: body))?.error
        switch status {
        case 401: return .unauthorized(tokenPresent: token.read() != nil)
        case 300..<400: return .redirectRefused
        case 403: return .forbidden
        case 501: return .notImplemented
        default: return .http(status: status, api: api)
        }
    }

    @discardableResult
    private func send(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        try checkBase()
        let req = makeRequest(path, method: method, body: body, timeout: requestTimeout)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw mapTransport(error) }
        guard let h = resp as? HTTPURLResponse else { throw ControlClientError.badResponse }
        guard (200..<300).contains(h.statusCode) else { throw mapStatus(h.statusCode, body: data) }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ControlClientError.decoding(String(describing: error).prefix(120).description) }
    }

    private func post<B: Encodable>(_ path: String, _ body: B) async throws -> Data {
        try await send(path, method: "POST", body: try JSONEncoder().encode(body))
    }

    // MARK: StrimControlClient

    public func status() async throws -> HostStatus {
        try decode(HostStatus.self, try await send(StrimRoutes.status))
    }
    public func load(_ request: LoadRequest) async throws { _ = try await post(StrimRoutes.load, request) }
    public func unload() async throws { _ = try await send(StrimRoutes.unload, method: "POST", body: Data("{}".utf8)) }
    public func jobs() async throws -> [JobSummary] {
        try decode([JobSummary].self, try await send(StrimRoutes.jobs))
    }
    public func job(id: String) async throws -> JobDetail {
        try decode(JobDetail.self, try await send(StrimRoutes.job(id)))
    }
    public func approve(_ approval: PatchApproval) async throws { _ = try await post(StrimRoutes.jobApprove, approval) }
    public func chatOpen(_ request: ChatOpenRequest) async throws -> ChatSession {
        try decode(ChatSession.self, try await post(StrimRoutes.chatOpen, request))
    }
    public func chatAppend(_ request: ChatAppendRequest) async throws { _ = try await post(StrimRoutes.chatAppend, request) }
    public func chatCancel(_ request: ChatCancelRequest) async throws { _ = try await post(StrimRoutes.chatCancel, request) }

    public func pauseJobs(_ request: PauseRequest) async throws -> JobsPauseState {
        try decode(JobsPauseState.self, try await post(StrimRoutes.pause, request))
    }
    public func resumeJobs() async throws -> JobsPauseState {
        try decode(JobsPauseState.self, try await send(StrimRoutes.resume, method: "POST", body: Data("{}".utf8)))
    }
    public func cancelJob(_ request: JobCancelRequest) async throws -> JobCancelResult {
        try decode(JobCancelResult.self, try await post(StrimRoutes.jobCancel, request))
    }
    public func models() async throws -> ModelList { try decode(ModelList.self, try await send(StrimRoutes.models)) }
    public func pack() async throws -> PackInfo { try decode(PackInfo.self, try await send(StrimRoutes.pack)) }

    public func events() -> AsyncThrowingStream<StrimEvent, Error> {
        let req = makeRequest(StrimRoutes.events, timeout: streamIdleTimeout)
        var accept = req
        accept.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let request = accept
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    try checkBase()
                    let (bytes, resp) = try await session.bytes(for: request)
                    guard let h = resp as? HTTPURLResponse else { throw ControlClientError.badResponse }
                    guard (200..<300).contains(h.statusCode) else {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 4096 { break } }
                        throw mapStatus(h.statusCode, body: body)
                    }
                    var parser = SSEParser()
                    var line = [UInt8]()
                    func handle(_ l: String) {
                        guard let frame = parser.feed(line: l) else { return }
                        if let ev = try? JSONDecoder().decode(StrimEvent.self, from: Data(frame.data.utf8)) {
                            cont.yield(ev)
                        }  // unknown event types are skipped for forward compatibility
                    }
                    for try await b in bytes {
                        if b == 0x0A {
                            if line.last == 0x0D { line.removeLast() }
                            handle(String(decoding: line, as: UTF8.self)); line.removeAll(keepingCapacity: true)
                        } else { line.append(b) }
                    }
                    cont.finish()
                } catch is CancellationError {
                    cont.finish()
                } catch {
                    cont.finish(throwing: mapTransport(error))
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Stand-in client used when settings are invalid: nothing leaves the process.
struct InvalidConfigClient: StrimControlClient {
    var reason: String
    private var err: Error { ControlClientError.invalidConfig(reason) }
    func status() async throws -> HostStatus { throw err }
    func events() -> AsyncThrowingStream<StrimEvent, Error> { let e = err; return AsyncThrowingStream { $0.finish(throwing: e) } }
    func load(_ request: LoadRequest) async throws { throw err }
    func unload() async throws { throw err }
    func jobs() async throws -> [JobSummary] { throw err }
    func job(id: String) async throws -> JobDetail { throw err }
    func approve(_ approval: PatchApproval) async throws { throw err }
    func chatOpen(_ request: ChatOpenRequest) async throws -> ChatSession { throw err }
    func chatAppend(_ request: ChatAppendRequest) async throws { throw err }
    func chatCancel(_ request: ChatCancelRequest) async throws { throw err }
    func pauseJobs(_ request: PauseRequest) async throws -> JobsPauseState { throw err }
    func resumeJobs() async throws -> JobsPauseState { throw err }
    func cancelJob(_ request: JobCancelRequest) async throws -> JobCancelResult { throw err }
    func models() async throws -> ModelList { throw err }
    func pack() async throws -> PackInfo { throw err }
}
