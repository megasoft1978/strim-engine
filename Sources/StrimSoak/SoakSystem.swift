import Foundation

// Process, lock, signal, HTTP and clock helpers for the soak. Kept local so the soak tests do not link the engine.

public enum SoakError: Error, CustomStringConvertible {
    case io(String)
    public var description: String {
        switch self { case .io(let s): return s }
    }
}

/// A child in its own process group, so signals reach the whole client tree and nothing else.
/// Exit code follows Python's convention: -N when killed by signal N.
public final class SoakChild: @unchecked Sendable {
    public let pid: pid_t
    private var status: Int32?
    private static let table = NSLock()
    nonisolated(unsafe) private static var live: [pid_t: SoakChild] = [:]

    private init(pid: pid_t) { self.pid = pid }

    /// Starts `argv` with stdin from /dev/null. Stdout/stderr go to fresh files (`append` false: O_TRUNC) or are
    /// appended (server log). Log paths are opened with O_NOFOLLOW and 0600.
    public static func spawn(argv: [String], env: [String: String], cwd: String?, stdoutPath: String,
                             stderrPath: String, append: Bool) throws -> SoakChild {
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | (append ? O_APPEND : O_TRUNC)
        posix_spawn_file_actions_addopen(&fa, 1, stdoutPath, flags, 0o600)
        if stderrPath == stdoutPath { posix_spawn_file_actions_adddup2(&fa, 1, 2) }
        else { posix_spawn_file_actions_addopen(&fa, 2, stderrPath, flags, 0o600) }
        if let cwd { posix_spawn_file_actions_addchdir_np(&fa, cwd) }
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cargs.forEach { free($0) }; cenv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &fa, &attr, cargs, cenv)
        guard rc == 0 else { throw SoakError.io("spawn \(argv[0]): \(String(cString: strerror(rc)))") }
        let child = SoakChild(pid: pid)
        table.lock(); live[pid] = child; table.unlock()
        return child
    }

    /// Reaps without blocking. Returns the exit code once the process has ended.
    public func poll() -> Int32? {
        if let s = status { return s }
        var st: Int32 = 0
        guard waitpid(pid, &st, WNOHANG) == pid else { return nil }
        return reaped(st)
    }

    /// Waits up to `timeout` seconds. Returns nil on timeout (process still running).
    public func wait(timeout: Double) -> Int32? {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if let s = poll() { return s }
            if Date() >= end { return nil }
            usleep(50_000)
        }
    }

    /// Blocking reap after a kill.
    public func reap() -> Int32 {
        if let s = status { return s }
        var st: Int32 = 0
        waitpid(pid, &st, 0)
        return reaped(st)
    }

    /// Signals the process group, only while the leader is unreaped (so the pid cannot have been reused).
    public func signalGroup(_ sig: Int32) {
        guard status == nil else { return }
        killpg(pid, sig)
    }

    /// Kills the group with SIGKILL and reaps.
    public func kill() -> Int32 {
        signalGroup(SIGKILL)
        return reap()
    }

    private func reaped(_ st: Int32) -> Int32 {
        let code: Int32 = (st & 0x7f) == 0 ? (st >> 8) & 0xff : -(st & 0x7f)
        status = code
        Self.table.lock(); Self.live[pid] = nil; Self.table.unlock()
        return code
    }

    /// Kills every child that is still running (used on exit and abort paths).
    public static func killAll(except: pid_t? = nil) {
        table.lock(); let kids = live.values.filter { $0.pid != except }; table.unlock()
        for k in kids where k.status == nil { _ = k.kill() }
    }
}

/// Loopback HTTP GET without proxies. Returns (status, body); status nil when the request itself failed.
public enum SoakHTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 15
        return URLSession(configuration: c)
    }()

    public static func get(port: Int, path: String, token: String? = nil) -> (code: Int?, body: String) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return (nil, "URLError") }
        var req = URLRequest(url: url)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Int?, String) = (nil, "URLError")
        let task = session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let http = resp as? HTTPURLResponse {
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                result = (http.statusCode, http.statusCode >= 400 ? String(text.prefix(300)) : text)
            } else {
                result = (nil, err.map { String(describing: type(of: $0)) } ?? "URLError")
            }
        }
        task.resume()
        if sem.wait(timeout: .now() + 20) == .timedOut { task.cancel(); return (nil, "timeout") }
        return result
    }
}

public enum SoakProc {
    /// Resident set size in MB (ps `rss`, KB, /1024 rounded to 0.1). nil when the process is gone.
    public static func rssMB(_ pid: Int32) -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "rss=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kb = Int(text) else { return nil }
        return pyRound(Double(kb) / 1024, 1)
    }

    /// First executable named `name` on PATH, absolute.
    public static func which(_ name: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let p = String(dir) + "/" + name
            if access(p, X_OK) == 0 { return p }
        }
        return nil
    }
}

/// Clock helpers. Timestamps are UTC ISO-8601 with seconds, as Python's `isoformat(timespec="seconds")`.
public enum SoakClock {
    public static func nowISO() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: Date()) + "+00:00"
    }

    public static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: Date())
    }
}

/// Append-only JSON-lines writer with sorted keys (as `json.dumps(sort_keys=True)`).
public final class SoakRecorder: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    public init(path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
            throw SoakError.io("cannot create \(path)")
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }

    public func write(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        lock.lock(); defer { lock.unlock() }
        try? handle.write(contentsOf: data + Data([0x0a]))
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle.close()
    }
}

/// `nil` as JSON null for optional row fields.
func opt<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }

/// `mkdtemp` on `template` (ends in XXXXXX). Returns the created directory path, nil on failure.
func makeTempDir(_ template: String) -> String? {
    var buf = Array(template.utf8CString)
    guard mkdtemp(&buf) != nil else { return nil }
    return String(decoding: buf.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Canonical path (symlinks resolved): sandbox profiles match real paths, so temp roots must be canonical.
func realPath(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
