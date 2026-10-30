import Foundation

final class SyncBox<T>: @unchecked Sendable { var value: T? }

/// Blocking HTTP helper (the bench is a sequential program).
func httpSync(_ req: URLRequest) -> (data: Data?, status: Int, error: String?) {
    let sem = DispatchSemaphore(value: 0)
    let box = SyncBox<(Data?, Int, String?)>()
    URLSession.shared.dataTask(with: req) { d, r, e in
        box.value = (d, (r as? HTTPURLResponse)?.statusCode ?? 0, e?.localizedDescription)
        sem.signal()
    }.resume()
    sem.wait()
    return box.value ?? (nil, 0, "no response")
}

/// A running strim host. The token lives in memory only; it is never printed or logged.
public struct ServerEndpoint: Sendable {
    public var port: UInt16
    public var token: String
    public var modelId: String
    /// The server's `--state-dir` (jobs under `<stateDir>/jobs`), when this process started it with one; nil when unknown.
    public var stateDir: URL?
    public init(port: UInt16, token: String, modelId: String, stateDir: URL? = nil) {
        self.port = port; self.token = token; self.modelId = modelId; self.stateDir = stateDir
    }
    public var baseURL: String { "http://127.0.0.1:\(port)" }
}

public struct ToolReply: Sendable {
    public var text: String
    public var isError: Bool
    public var transportError: String?
}

public final class MCPClient: @unchecked Sendable {
    let endpoint: ServerEndpoint
    public init(endpoint: ServerEndpoint) { self.endpoint = endpoint }

    public func call(_ tool: String, _ args: [String: Any], timeout: TimeInterval = 60) -> ToolReply {
        var req = URLRequest(url: URL(string: endpoint.baseURL + "/mcp")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": args]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, status, err) = httpSync(req)
        guard let data, status == 200 else {
            return ToolReply(text: "", isError: true, transportError: err ?? "HTTP \(status)")
        }
        var raw = String(decoding: data, as: UTF8.self)
        if raw.hasPrefix("event:") || raw.hasPrefix("data:") {
            raw = raw.split(separator: "\n").last(where: { $0.hasPrefix("data:") }).map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? raw
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            return ToolReply(text: "", isError: true, transportError: "unparseable MCP reply")
        }
        if let e = obj["error"] as? [String: Any] {
            return ToolReply(text: (e["message"] as? String) ?? "rpc error", isError: true, transportError: nil)
        }
        let result = obj["result"] as? [String: Any] ?? [:]
        let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return ToolReply(text: text, isError: result["isError"] as? Bool ?? false, transportError: nil)
    }
}

/// `strim serve` started (and stopped) by the bench. Only the child it spawned is ever signalled.
public final class LocalServer: @unchecked Sendable {
    public let endpoint: ServerEndpoint
    private let handle: ProcHandle?

    init(endpoint: ServerEndpoint, handle: ProcHandle?) { self.endpoint = endpoint; self.handle = handle }

    /// The state dir the server was started with (`--state-dir`, granting the work root); nil when attached or unknown.
    public var stateDir: URL? { endpoint.stateDir }

    public static func healthy(port: UInt16) -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 3
        return httpSync(req).status == 200
    }

    /// Use an already running host (nothing is started or stopped).
    public static func attach(port: UInt16, tokenFile: String, modelId: String) throws -> LocalServer {
        guard healthy(port: port) else { throw LedgerError.io("no healthy strim host on 127.0.0.1:\(port)") }
        return LocalServer(endpoint: ServerEndpoint(port: port, token: try readToken(tokenFile), modelId: modelId), handle: nil)
    }

    static func readToken(_ path: String) throws -> String {
        guard let t = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            throw LedgerError.io("cannot read token file \(path)")
        }
        return t
    }

    /// `strim serve` argv with every path made absolute (the child runs with the log dir as cwd).
    public static func serveArgv(strimBin: String, model: String, head: String?, port: UInt16, tokenFile: String) -> [String] {
        var argv = [PathArgs.absolute(strimBin), "serve", PathArgs.absolute(model)]
        if let head { argv.append(PathArgs.absolute(head)) }
        return argv + ["--port", String(port), "--token-file", PathArgs.absolute(tokenFile)]
    }

    /// Agentbench creates this process-specific root before starting its server. Other users of
    /// LocalServer do not create it and retain their existing server configuration.
    static func benchmarkState(workRoot: URL, logDir: URL) throws -> URL {
        var st = stat()
        guard lstat(workRoot.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(), st.st_mode & 0o022 == 0 else {
            throw LedgerError.io("unsafe benchmark work root: \(workRoot.path)")
        }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(workRoot.path, &resolved) != nil else {
            throw LedgerError.io("cannot resolve benchmark work root: \(workRoot.path)")
        }
        let root = String(cString: resolved)
        guard root != "/", root != NSHomeDirectory(), root.hasPrefix("/") else {
            throw LedgerError.io("unsafe benchmark work root: \(root)")
        }
        var template = Array(logDir.appendingPathComponent("server-state-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw LedgerError.io("cannot create benchmark server state") }
        let state = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let config: [String: Any] = ["mcp": ["allowedRoots": [root]]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let path = state.appendingPathComponent("config.json").path
        let fd = try openSafe(path, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
        defer { close(fd) }
        let count = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard count == data.count else { throw LedgerError.io("cannot write benchmark server config") }
        return state
    }

    /// `--state-dir` arguments granting the host exactly one work root. An explicit `workRoot` must exist and pass
    /// `benchmarkState`'s checks. Without one, the legacy `strim-agentbench-<pid>` root is granted when it exists
    /// (agentbench CLI and MCP client command still rely on that name).
    static func stateGrant(workRoot: URL?, logDir: URL) throws -> URL? {
        if let workRoot { return try benchmarkState(workRoot: workRoot, logDir: logDir) }
        let legacy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("strim-agentbench-\(getpid())")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        return try benchmarkState(workRoot: legacy, logDir: logDir)
    }

    static func stateArgv(workRoot: URL?, logDir: URL) throws -> [String] {
        try stateGrant(workRoot: workRoot, logDir: logDir).map { ["--state-dir", $0.path] } ?? []
    }

    /// The full `strim serve` argv, including the state dir that grants `workRoot`.
    static func serverArgv(strimBin: String, model: String, head: String?, port: UInt16, tokenFile: String,
                           workRoot: URL?, logDir: URL) throws -> [String] {
        try serverLaunch(strimBin: strimBin, model: model, head: head, port: port, tokenFile: tokenFile,
                         workRoot: workRoot, logDir: logDir).argv
    }

    /// The argv plus the state dir it grants (nil when none), created once.
    static func serverLaunch(strimBin: String, model: String, head: String?, port: UInt16, tokenFile: String,
                             workRoot: URL?, logDir: URL) throws -> (argv: [String], stateDir: URL?) {
        let state = try stateGrant(workRoot: workRoot, logDir: logDir)
        let argv = serveArgv(strimBin: strimBin, model: model, head: head, port: port, tokenFile: tokenFile)
        return (argv + (state.map { ["--state-dir", $0.path] } ?? []), state)
    }

    /// `workRoot`: the directory the server must accept as cwd (created by the caller before this call).
    public static func spawn(strimBin: String, model: String, head: String?, port: UInt16, tokenFile: String,
                             logDir: URL, readyTimeout: TimeInterval,
                             extraEnv: [String: String] = [:], workRoot: URL? = nil) throws -> LocalServer {
        guard !healthy(port: port) else { throw LedgerError.io("port \(port) already serves something; refusing to start a second host (use --attach)") }
        guard FileManager.default.fileExists(atPath: PathArgs.absolute(model)) else { throw LedgerError.io("model directory not found: \(PathArgs.absolute(model))") }
        let launch = try serverLaunch(strimBin: strimBin, model: model, head: head, port: port, tokenFile: tokenFile, workRoot: workRoot, logDir: logDir)
        let argv = launch.argv
        var env = ProcessInfo.processInfo.environment
        env["STRIM_SERVER_LOG"] = "1"
        for (k, v) in extraEnv { env[k] = v }
        let h = try Proc.start(argv: argv, env: env, cwd: logDir.path,
                               stdout: logDir.appendingPathComponent("server.log").path,
                               stderr: logDir.appendingPathComponent("server.err.log").path)
        let t0 = Date()
        while Date().timeIntervalSince(t0) < readyTimeout {
            if let code = h.poll() { throw LedgerError.io("strim serve exited early (code \(code)); see server.err.log") }
            if Interrupt.requested { h.terminate(); throw LedgerError.io("interrupted") }
            if healthy(port: port) {
                let tok = try readToken(tokenFile)
                return LocalServer(endpoint: ServerEndpoint(port: port, token: tok, modelId: URL(fileURLWithPath: argv[2]).lastPathComponent,
                                                                      stateDir: launch.stateDir), handle: h)
            }
            usleep(500_000)
        }
        h.terminate()
        throw LedgerError.io("strim serve not ready after \(Int(readyTimeout))s")
    }

    public var isAlive: Bool { handle.map { $0.poll() == nil } ?? LocalServer.healthy(port: endpoint.port) }

    public func stop() { handle?.terminate(grace: 10) }
}
