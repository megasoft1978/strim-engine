import Foundation

/// Small process helpers: capture a command's stdout, spawn a detached server with exact-pid
/// tracking, kill exactly the pids we started, probe and port checks, and the GPU lock.
public enum ProcessRunner {
    /// Trimmed stdout, nil when the command fails, times out or prints nothing (Python `_cmd`).
    public static func captureSync(_ exe: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
        let p = Process()
        guard let url = resolveExecutable(exe) else { return nil }
        p.executableURL = url
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    public static func capture(_ exe: String, _ args: [String], timeout: TimeInterval = 10) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global().async { cont.resume(returning: captureSync(exe, args, timeout: timeout)) }
        }
    }

    /// Runs `/bin/sh -c script` and returns trimmed stdout ("" when empty).
    public static func shell(_ script: String) -> String {
        captureSync("/bin/sh", ["-c", script]) ?? ""
    }

    static func resolveExecutable(_ exe: String) -> URL? {
        if exe.contains("/") { return URL(fileURLWithPath: exe) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let c = String(dir) + "/" + exe
            if FileManager.default.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        }
        return nil
    }
}

public enum SystemSnapshot {
    public static func env() -> (uptime: String?, loadavg: String?) {
        (ProcessRunner.captureSync("uptime", []), ProcessRunner.captureSync("sysctl", ["-n", "vm.loadavg"]))
    }

    /// `ps -A -o pid=,ppid=,rss=` rows.
    static func psTable() -> [(pid: Int, ppid: Int, rss: Int)] {
        guard let out = ProcessRunner.captureSync("ps", ["-A", "-o", "pid=,ppid=,rss="]) else { return [] }
        var rows: [(Int, Int, Int)] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 3, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) { rows.append((a, b, c)) }
        }
        return rows.map { (pid: $0.0, ppid: $0.1, rss: $0.2) }
    }

    /// RSS in KB of pid plus its direct children; nil if the pid is gone.
    public static func rssKB(pid: Int) -> Int? {
        let t = psTable()
        guard let own = t.first(where: { $0.pid == pid }) else { return nil }
        return own.rss + t.filter { $0.ppid == pid }.reduce(0) { $0 + $1.rss }
    }

    /// All descendants of pid.
    public static func children(of pid: Int) -> [Int] {
        guard let out = ProcessRunner.captureSync("ps", ["-A", "-o", "pid=,ppid="]) else { return [] }
        var kids: [Int: [Int]] = [:]
        for line in out.split(separator: "\n") {
            let p = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if p.count == 2, let a = Int(p[0]), let b = Int(p[1]) { kids[b, default: []].append(a) }
        }
        var res: [Int] = []
        var stack = [pid]
        while let p = stack.popLast() {
            for c in kids[p] ?? [] { res.append(c); stack.append(c) }
        }
        return res
    }

    public static func alive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) != 0 { return false }
        guard let st = ProcessRunner.captureSync("ps", ["-o", "stat=", "-p", String(pid)]) else { return false }
        return !st.hasPrefix("Z")
    }

    /// load_snapshot() of final_run.py.
    public static func loadSnapshot() -> JSONValue {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let top = ProcessRunner.shell("ps -Ao pcpu,rss,comm -r | sed -n 2,6p | awk '{$1=$1; print}' | cut -c1-90")
            .split(separator: "\n").map { JSONValue.string(String($0)) }
        return .obj([
            "t": .string(f.string(from: Date())),
            "uptime": .string(ProcessRunner.shell("uptime")),
            "loadavg": .string(ProcessRunner.shell("sysctl -n vm.loadavg")),
            "top_cpu": .array(top),
        ])
    }
}

/// A server process started in its own session, tracked by exact pid.
public final class SpawnedProcess: @unchecked Sendable {
    public let pid: Int
    private let lock = NSLock()
    private var status: Int32?

    init(pid: Int) { self.pid = pid }

    /// Exit code if the process has exited (reaps it), else nil.
    public func poll() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if let s = status { return s }
        var st: Int32 = 0
        let r = waitpid(pid_t(pid), &st, WNOHANG)
        if r == pid_t(pid) {
            let code: Int32 = (st & 0x7f) == 0 ? (st >> 8) & 0xff : -(st & 0x7f)
            status = code
            return code
        }
        if r < 0 { status = -1; return -1 }
        return nil
    }

    /// New session, stdout+stderr appended to `logPath`, `cwd`, env merged over the current one.
    public static func spawn(argv: [String], cwd: String, env: [String: String], logPath: String) throws -> SpawnedProcess {
        guard !argv.isEmpty else { throw BenchError("empty command") }
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        try SafeFS.requireNotSymlink(logPath)
        posix_spawn_file_actions_addopen(&fa, 1, logPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addchdir_np(&fa, cwd)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Fresh signal state: a parent that blocks or ignores SIGTERM must not leak that into the server.
        var none = sigset_t()
        sigemptyset(&none)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in env { merged[k] = v }
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cArgs { free(p) }; for p in cEnv { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, argv[0], &fa, &attr, cArgs, cEnv)
        if rc != 0 { throw BenchError("spawn \(argv[0]) failed: \(String(cString: strerror(rc)))") }
        return SpawnedProcess(pid: Int(pid))
    }

    public var identity: ProcIdentity? { ProcIdentity.capture(pid) }
}

public struct BenchError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// pid plus kernel start time: a recycled pid has a different start time, so it can never match.
public struct ProcIdentity: Sendable, Equatable, Hashable {
    public var pid: Int
    public var startSec: UInt64
    public var startUsec: UInt64

    public init(pid: Int, startSec: UInt64, startUsec: UInt64) { self.pid = pid; self.startSec = startSec; self.startUsec = startUsec }

    static func info(_ pid: Int) -> proc_bsdinfo? {
        var i = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &i, size) == size else { return nil }
        return i
    }

    public static func capture(_ pid: Int) -> ProcIdentity? {
        guard let i = info(pid) else { return nil }
        return ProcIdentity(pid: pid, startSec: i.pbi_start_tvsec, startUsec: i.pbi_start_tvusec)
    }

    /// True while the same process (same start time) still exists and is not a zombie.
    public var isAlive: Bool {
        guard let i = Self.info(pid) else { return false }
        return i.pbi_start_tvsec == startSec && i.pbi_start_tvusec == startUsec && i.pbi_status != 5  // SZOMB
    }
}

public enum ProcessKiller {
    /// SIGTERM, wait up to `grace` seconds, SIGKILL. A process is signalled only while its identity (pid + start
    /// time) still matches, so a pid recycled by the OS is never hit. Returns the pids that were alive at the start.
    @discardableResult
    public static func killExact(_ targets: [ProcIdentity], grace: TimeInterval = 30, reap: [SpawnedProcess] = [],
                                 log: (String) -> Void) async -> [Int] {
        func isAlive(_ t: ProcIdentity) -> Bool {
            if let h = reap.first(where: { $0.pid == t.pid }), h.poll() != nil { return false }
            return t.isAlive
        }
        let live = targets.filter { isAlive($0) }
        for t in live where t.isAlive { kill(pid_t(t.pid), SIGTERM) }
        let end = Date().addingTimeInterval(grace)
        while Date() < end, live.contains(where: { isAlive($0) }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        for t in live where isAlive(t) {
            log("SIGKILL \(t.pid)")
            if t.isAlive { kill(pid_t(t.pid), SIGKILL) }  // re-verified: the pid may have been recycled meanwhile
        }
        for h in reap { _ = h.poll() }
        log("killed pids \(live.map(\.pid))")
        return live.map(\.pid)
    }
}

/// File helpers that never follow symlinks.
public enum SafeFS {
    public static func requireNotSymlink(_ path: String) throws {
        var st = stat()
        if lstat(path, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK { throw BenchError("refusing to write through symlink: \(path)") }
            if (st.st_mode & S_IFMT) != S_IFREG { throw BenchError("not a regular file: \(path)") }
        }
    }

    /// Fresh 0700 directory from mkdtemp under the temp dir.
    public static func makeTempDir(prefix: String = "strim-bench") throws -> String {
        var tmpl = Array((NSTemporaryDirectory() + "/\(prefix)-XXXXXX").utf8CString)
        guard mkdtemp(&tmpl) != nil else { throw BenchError("mkdtemp failed: \(String(cString: strerror(errno)))") }
        return String(cString: tmpl)
    }

    /// Existing scratch dir must be a real directory owned by us and not group/world writable; a missing one is created 0700.
    public static func prepareScratch(_ path: String) throws {
        var st = stat()
        if lstat(path, &st) != 0 {
            guard mkdir(path, 0o700) == 0 else { throw BenchError("cannot create scratch dir \(path): \(String(cString: strerror(errno)))") }
            return
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw BenchError("scratch path is not a plain directory (symlink?): \(path)") }
        guard st.st_uid == getuid() else { throw BenchError("scratch dir not owned by this user: \(path)") }
        guard st.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw BenchError("scratch dir is group/world writable: \(path)") }
    }

    /// Creates `path` exclusively (0600, O_EXCL|O_NOFOLLOW). An existing file or symlink is unlinked first (unlink never follows).
    public static func writeExclusive(_ path: String, _ data: Data) throws {
        var st = stat()
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) != S_IFDIR else { throw BenchError("is a directory: \(path)") }
            unlink(path)
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BenchError("cannot create \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var off = 0
        let bytes = [UInt8](data)
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw BenchError("write failed: \(path)") }
            off += n
        }
    }
}

public enum Net {
    public static func portFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc != 0
    }

    static let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 3
        return URLSession(configuration: cfg)
    }()

    /// `/v1/models` -> first model id; any other path -> "up" on HTTP 200. nil on any failure.
    public static func probe(port: Int, path: String = "/v1/models") async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        do {
            let (data, resp) = try await probeSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            if path != "/v1/models" { return http.statusCode == 200 ? "up" : nil }
            guard (200 ..< 300).contains(http.statusCode) else { return nil }
            let d = try JSON.parse(data)
            return d["data"].array?.first?["id"].string
        } catch { return nil }
    }
}

/// Exclusive GPU lock, interoperable with `lockf -k /tmp/strim-bench.lock` (both are flock(2)).
/// The file is opened O_NOFOLLOW|O_CLOEXEC, mode 0600, and must be a regular file owned by the current user.
public final class GPULock: @unchecked Sendable {
    public static let defaultPath = "/tmp/strim-bench.lock"

    /// `STRIM_BENCH_LOCK` overrides the default path.
    public static func resolvedPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = env["STRIM_BENCH_LOCK"], !p.isEmpty { return p }
        return defaultPath
    }

    public let path: String
    /// Set when the lock file is unsafe or cannot be opened; waiting is pointless then.
    public private(set) var openError: String?
    private var fd: Int32 = -1

    public init(path: String) { self.path = path }

    /// Non-blocking attempt.
    public func tryAcquire() -> Bool {
        if fd >= 0 { return true }
        let f = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard f >= 0 else {
            openError = errno == ELOOP ? "lock file is a symlink: \(path)" : "cannot open lock file \(path): \(String(cString: strerror(errno)))"
            return false
        }
        var st = stat()
        guard fstat(f, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            openError = "lock file is not a regular file: \(path)"
            close(f)
            return false
        }
        guard st.st_uid == getuid() else {
            openError = "lock file \(path) is owned by uid \(st.st_uid), not this user"
            close(f)
            return false
        }
        if flock(f, LOCK_EX | LOCK_NB) == 0 { fd = f; return true }
        close(f)
        return false
    }

    /// Waits (polling, without blocking a thread) up to `timeout` seconds; nil timeout waits forever like `lockf`.
    /// Returns false at once when the lock file itself is unusable (see `openError`).
    public func acquire(timeout: TimeInterval? = nil, poll: TimeInterval = 0.25) async -> Bool {
        let end = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if tryAcquire() { return true }
            if openError != nil { return false }
            if let end, Date() >= end { return false }
            try? await Task.sleep(nanoseconds: UInt64(poll * 1e9))
        }
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
