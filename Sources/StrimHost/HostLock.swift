import Foundation

public struct HostLockError: Error, CustomStringConvertible {
    public let pid: Int32?
    public let path: String
    public var description: String {
        "another strim host is already running" + (pid.map { " (pid \($0))" } ?? "") + "; lock: \(path). Stop it first (two engines do not fit in memory)."
    }
}

/// Exclusive host lock (`flock`) so only one engine host runs at a time. The kernel drops it if the
/// process dies. The file records the holder's pid for the error message.
public final class HostLock: @unchecked Sendable {
    private var fd: Int32
    public let path: String

    private init(fd: Int32, path: String) { self.fd = fd; self.path = path }

    public static func acquire(at url: URL) throws -> HostLock {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HostLockError(pid: nil, path: url.path) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            var buf = [UInt8](repeating: 0, count: 32)
            let n = pread(fd, &buf, buf.count, 0)
            close(fd)
            let pid = n > 0 ? Int32(String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            throw HostLockError(pid: pid, path: url.path)
        }
        fchmod(fd, 0o600)
        ftruncate(fd, 0)
        let line = Array("\(getpid())\n".utf8)
        _ = pwrite(fd, line, line.count, 0)
        return HostLock(fd: fd, path: url.path)
    }

    public func release() {
        if fd >= 0 { flock(fd, LOCK_UN); close(fd); fd = -1 }
    }

    deinit { release() }
}
