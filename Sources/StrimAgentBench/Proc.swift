import Foundation

public enum Interrupt {
    nonisolated(unsafe) public static var requested = false
    public static func install() {
        let h: @convention(c) (Int32) -> Void = { _ in Interrupt.requested = true }
        signal(SIGINT, h)
        signal(SIGTERM, h)
    }
}

public struct ProcResult: Sendable {
    public var exitCode: Int32
    public var timedOut: Bool
    public var interrupted: Bool
    public var wallS: Double
}

/// A child in its own process group. Signals go only to that group, and only while the leader has not been
/// reaped (a zombie leader keeps its pid and pgid reserved) and its pid + start time still match what we
/// recorded at spawn, so a reused pid can never be hit.
public final class ProcHandle: @unchecked Sendable {
    public let pid: pid_t
    private var status: Int32?
    private let startSec: UInt64
    private let startUsec: UInt64

    static func startTime(of pid: pid_t) -> (UInt64, UInt64, pid_t)? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec, pid_t(info.pbi_pgid))
    }

    init(pid: pid_t) {
        self.pid = pid
        let t = Self.startTime(of: pid)
        startSec = t?.0 ?? 0; startUsec = t?.1 ?? 0
    }

    /// Test hook: a handle whose recorded identity does not match `pid`.
    init(pid: pid_t, forgedStart sec: UInt64) { self.pid = pid; startSec = sec; startUsec = 0 }

    /// True when `pid` is still the process we spawned and leads its own group.
    func identityMatches() -> Bool {
        guard let t = Self.startTime(of: pid) else { return false }
        return t.0 == startSec && t.1 == startUsec && t.2 == pid
    }

    /// Exited (possibly still unreaped)? Does not reap.
    public func exited() -> Bool {
        if status != nil { return true }
        var info = siginfo_t()
        let r = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        return r == 0 && info.si_pid == pid
    }

    /// Reaps if exited. Exit code (128+signal when killed), nil while running.
    public func poll() -> Int32? {
        if let s = status { return s }
        var st: Int32 = 0
        guard waitpid(pid, &st, WNOHANG) == pid else { return nil }
        status = Self.code(st)
        return status
    }

    static func code(_ st: Int32) -> Int32 { (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f) }

    /// Signals the process group if (and only if) the identity checks pass. Returns whether it signalled.
    @discardableResult
    public func signalGroup(_ sig: Int32) -> Bool {
        // An exited-but-unreaped leader (zombie) still owns its pid/pgid, so reuse is impossible and proc_pidinfo
        // may not describe it; otherwise require the recorded identity.
        guard status == nil, exited() || identityMatches() else { return false }
        return killpg(pid, sig) == 0
    }

    /// SIGTERM the group, SIGKILL after `grace` seconds, then SIGKILL stragglers left by an exited leader
    /// before reaping it. Safe to call again.
    @discardableResult
    public func terminate(grace: TimeInterval = 3) -> Int32 {
        if let s = status { return s }
        signalGroup(SIGTERM)
        let end = Date().addingTimeInterval(grace)
        while Date() < end, !exited() { usleep(50_000) }
        signalGroup(SIGKILL)
        var st: Int32 = 0
        waitpid(pid, &st, 0)
        status = Self.code(st)
        return status ?? -1
    }

    /// The leader exited on its own: kill what it left behind (still unreaped, so the pgid is ours), then reap.
    func reapKillingStragglers() -> Int32 {
        if let s = status { return s }
        if exited() { signalGroup(SIGKILL) }
        return poll() ?? terminate()
    }
}

public enum Proc {
    public static func start(argv: [String], env: [String: String], cwd: String, stdout: String, stderr: String) throws -> ProcHandle {
        try spawn(argv: argv, env: env, cwd: cwd, stdoutPath: stdout, stderrPath: stderr, stdoutFD: nil, stderrFD: nil)
    }

    /// Core spawn. Output goes to inherited host fds when given (nothing the child can re-link), else to fresh files.
    static func spawn(argv: [String], env: [String: String], cwd: String, stdoutPath: String?, stderrPath: String?,
                      stdoutFD: Int32?, stderrFD: Int32?) throws -> ProcHandle {
        precondition(!argv.isEmpty)
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        if let o = stdoutFD, let e = stderrFD {
            posix_spawn_file_actions_adddup2(&fa, o, 1)
            posix_spawn_file_actions_adddup2(&fa, e, 2)
        } else if let stdout = stdoutPath, let stderr = stderrPath {        // Fresh 0600 files: unlink first (never follows a symlink), then O_EXCL|O_NOFOLLOW, no O_TRUNC.
        for p in Set([stdout, stderr]) { unlink(p) }
        let lflags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
        posix_spawn_file_actions_addopen(&fa, 1, stdout, lflags, 0o600)
        if stderr == stdout { posix_spawn_file_actions_adddup2(&fa, 1, 2) }
        else { posix_spawn_file_actions_addopen(&fa, 2, stderr, lflags, 0o600) }
        }
        posix_spawn_file_actions_addchdir_np(&fa, cwd)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        let cargs = argv.map { strdup($0) } + [nil]
        let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cargs.forEach { free($0) }; cenv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &fa, &attr, cargs, cenv)
        guard rc == 0 else { throw ProcError.spawn("\(argv[0]): \(String(cString: strerror(rc)))") }
        return ProcHandle(pid: pid)
    }

    public static func run(argv: [String], env: [String: String], cwd: String, stdout: String, stderr: String,
                           timeout: TimeInterval) throws -> ProcResult {
        let t0 = Date()
        let h = try start(argv: argv, env: env, cwd: cwd, stdout: stdout, stderr: stderr)
        var timedOut = false, interrupted = false
        while !h.exited() {
            if Interrupt.requested { interrupted = true; break }
            if Date().timeIntervalSince(t0) > timeout { timedOut = true; break }
            usleep(50_000)
        }
        let code = (timedOut || interrupted) ? h.terminate() : h.reapKillingStragglers()
        return ProcResult(exitCode: code, timedOut: timedOut, interrupted: interrupted, wallS: Date().timeIntervalSince(t0))
    }

    /// An anonymous (already unlinked) host-owned file in a private 0700 dir, so no path to it exists for a child to re-link.
    static func anonymousFile() -> Int32? {
        var tmpl = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("agentbench-host-XXXXXX").utf8CString)
        guard mkdtemp(&tmpl) != nil else { return nil }
        let dir = String(cString: tmpl)
        defer { rmdir(dir) }
        let file = dir + "/o"
        let fd = open(file, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        unlink(file)
        return fd >= 0 ? fd : nil
    }

    /// Last `max` bytes of an fd, read through the fd itself (never by path).
    static func readTail(_ fd: Int32, max: Int) -> Data {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return Data() }
        let size = Int(st.st_size), n = Swift.min(size, max)
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, n - got, off_t(size - n + got)) }
            if r <= 0 { break }
            got += r
        }
        return Data(buf[0..<got])
    }

    public struct Captured: Sendable {
        public var result: ProcResult
        public var stdout: Data
        public var stderr: Data
        public var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// Runs a command with stdout/stderr captured through host-held anonymous fds. `mergeStderr`: both streams in `stdout`.
    public static func runCaptured(argv: [String], env: [String: String], cwd: String, timeout: TimeInterval,
                                   maxBytes: Int = 16_000_000, mergeStderr: Bool = false) throws -> Captured {
        guard let o = anonymousFile(), let e = mergeStderr ? o : anonymousFile() else { throw ProcError.spawn("cannot create capture file") }
        defer { close(o); if !mergeStderr { close(e) } }
        let t0 = Date()
        let h = try spawn(argv: argv, env: env, cwd: cwd, stdoutPath: nil, stderrPath: nil, stdoutFD: o, stderrFD: e)
        var timedOut = false, interrupted = false
        while !h.exited() {
            if Interrupt.requested { interrupted = true; break }
            if Date().timeIntervalSince(t0) > timeout { timedOut = true; break }
            usleep(50_000)
        }
        let code = (timedOut || interrupted) ? h.terminate() : h.reapKillingStragglers()
        let res = ProcResult(exitCode: code, timedOut: timedOut, interrupted: interrupted, wallS: Date().timeIntervalSince(t0))
        return Captured(result: res, stdout: readTail(o, max: maxBytes), stderr: mergeStderr ? Data() : readTail(e, max: maxBytes))
    }

    /// Runs a small command and returns (exit, stdout+stderr text).
    @discardableResult
    public static func capture(_ argv: [String], cwd: String, env: [String: String]? = nil, timeout: TimeInterval = 120,
                               scratch: URL) -> (code: Int32, text: String) {
        let e = env ?? ProcessInfo.processInfo.environment
        guard let c = try? runCaptured(argv: argv, env: e, cwd: cwd, timeout: timeout, maxBytes: 1_000_000, mergeStderr: true) else { return (127, "spawn failed") }
        return (c.result.exitCode, c.text)
    }

    /// Writes a host-side log: replaces whatever is at `path` (unlink never follows), then O_EXCL|O_NOFOLLOW, 0600.
    public static func writeLog(_ path: String, _ data: Data) {
        unlink(path)
        guard let fd = try? openSafe(path, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600) else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        close(fd)
    }
}

public enum ProcError: Error, CustomStringConvertible {
    case spawn(String)
    public var description: String { if case .spawn(let s) = self { return "spawn failed: \(s)" }; return "" }
}

/// Env without credentials or client-config variables.
public func scrubbedEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    let bad = ["TOKEN", "SECRET", "PASSWORD", "API_KEY", "APIKEY", "CREDENTIAL"]
    let badPrefix = ["ANTHROPIC_", "CLAUDE_", "CLAUDECODE", "CODEX_", "OPENAI_", "AWS_", "GITHUB_", "GH_"]
    return base.filter { k, _ in
        let u = k.uppercased()
        return !bad.contains(where: { u.contains($0) }) && !badPrefix.contains(where: { u.hasPrefix($0) })
    }
}

/// Redacts `secret` from a file in place.
public func redactFile(_ path: String, secret: String) {
    guard !secret.isEmpty, let s = try? String(contentsOfFile: path, encoding: .utf8), s.contains(secret) else { return }
    try? s.replacingOccurrences(of: secret, with: "<redacted>").write(toFile: path, atomically: true, encoding: .utf8)
}
