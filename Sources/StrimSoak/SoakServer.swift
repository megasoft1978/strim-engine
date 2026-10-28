import Foundation

/// The server under test. `StrimServeProcess` runs `strim serve`; tests substitute a fake.
public protocol SoakServer: AnyObject {
    var pid: Int32? { get }
    var logPath: String { get }
    /// Starts (or restarts) the server process. Log output is appended to `logPath`.
    func start() throws
    /// Exit code once the process has ended, nil while it runs (or before the first start).
    func exitCode() -> Int32?
    /// Reads the bearer token the server wrote. Never printed; passed to clients via env only.
    func loadToken() throws -> String
    func waitReady(timeout: Double) throws
    /// SIGINT to the process group, a 30 s grace, then SIGKILL.
    func stop()
    func health() -> (code: Int?, body: String)
    func metrics(token: String) -> (code: Int?, body: String)
}

/// `strim serve <model> <mtp-head> --port N --token-file PATH` with STRIM_SERVER_LOG=1, bound to 127.0.0.1.
public final class StrimServeProcess: SoakServer {
    private let bin: String
    private let model: String
    private let head: String
    private let port: Int
    private let tokenFile: String
    public let logPath: String
    private var child: SoakChild?

    public init(bin: String, model: String, head: String, port: Int, tokenFile: String, logPath: String) {
        self.bin = bin; self.model = model; self.head = head; self.port = port
        self.tokenFile = tokenFile; self.logPath = logPath
    }

    public var pid: Int32? { child?.pid }

    public func start() throws {
        let argv = [bin, "serve", model, head, "--port", String(port), "--token-file", tokenFile]
        child = try SoakChild.spawn(argv: argv, env: ProcessInfo.processInfo.environment.merging(["STRIM_SERVER_LOG": "1"]) { $1 },
                                    cwd: nil, stdoutPath: logPath, stderrPath: logPath, append: true)
    }

    public func exitCode() -> Int32? { child?.poll() }

    public func loadToken() throws -> String {
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: tokenFile) && Date() < deadline { usleep(200_000) }
        let text = (try? String(contentsOfFile: tokenFile, encoding: .utf8)) ?? ""
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SoakError.io("bearer token file is empty or missing") }
        return token
    }

    public func waitReady(timeout: Double) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let rc = exitCode() { throw SoakError.io("strim serve exited rc=\(rc) during startup (see server.log)") }
            if health().code == 200 { return }
            sleepSeconds(2)
        }
        throw SoakError.io("server not ready after \(Int(timeout))s")
    }

    public func stop() {
        guard let c = child, c.poll() == nil else { return }
        c.signalGroup(SIGINT)
        if c.wait(timeout: 30) == nil { _ = c.kill() }
    }

    public func health() -> (code: Int?, body: String) { SoakHTTP.get(port: port, path: "/health") }

    public func metrics(token: String) -> (code: Int?, body: String) {
        SoakHTTP.get(port: port, path: "/metrics", token: token)
    }
}

func sleepSeconds(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }
