import Foundation

/// Opens `path` without following a final symlink, close-on-exec, mode 0600 on create, and requires a regular
/// file owned by the current user (a pre-planted file or symlink in a shared directory is refused).
public func openSafe(_ path: String, flags: Int32, mode: mode_t = 0o600) throws -> Int32 {
    let fd = open(path, flags | O_NOFOLLOW | O_CLOEXEC, mode)
    guard fd >= 0 else {
        throw FileLockError.io(errno == ELOOP || errno == EMLINK
            ? "refusing to open \(path): it is a symbolic link"
            : "cannot open \(path): \(String(cString: strerror(errno)))")
    }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
        close(fd); throw FileLockError.io("refusing to use \(path): not a regular file")
    }
    guard st.st_uid == getuid() else {
        close(fd); throw FileLockError.io("refusing to use \(path): owned by uid \(st.st_uid), not by you (uid \(getuid())). Remove it or set STRIM_BENCH_LOCK to a path you own")
    }
    return fd
}

public enum FileLockError: Error, CustomStringConvertible {
    case timeout(String)
    case io(String)
    public var description: String {
        switch self {
        case .timeout(let p): return "timed out waiting for lock \(p)"
        case .io(let s): return s
        }
    }
}

/// Advisory `flock` (same primitive as `lockf(1)`), used to serialize GPU use with other bench jobs.
public final class FileLock: @unchecked Sendable {
    private var fd: Int32
    public let path: String
    private init(fd: Int32, path: String) { self.fd = fd; self.path = path }

    /// Lock path: `STRIM_BENCH_LOCK` if set, else the shared default.
    public static var defaultPath: String { ProcessInfo.processInfo.environment["STRIM_BENCH_LOCK"] ?? "/tmp/strim-bench.lock" }

    /// Waits up to `timeout` seconds (nil: forever). `onWait` is called once if the lock is contended.
    public static func acquire(path: String, timeout: TimeInterval?, onWait: (() -> Void)? = nil) throws -> FileLock {
        let fd = try openSafe(path, flags: O_RDWR | O_CREAT, mode: 0o600)
        let t0 = Date()
        var announced = false
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if !announced { announced = true; onWait?() }
            if let t = timeout, Date().timeIntervalSince(t0) > t { close(fd); throw FileLockError.timeout(path) }
            if Interrupt.requested { close(fd); throw FileLockError.io("interrupted while waiting for lock") }
            usleep(250_000)
        }
        return FileLock(fd: fd, path: path)
    }

    public func release() {
        if fd >= 0 { flock(fd, LOCK_UN); close(fd); fd = -1 }
    }
    deinit { release() }
}
