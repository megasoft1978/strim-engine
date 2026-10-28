import Foundation

/// Bearer token persisted at a 0600 file (default ~/.strim/token).
public enum TokenStore {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".strim/token").path
    }

    public enum Failure: Error, CustomStringConvertible {
        case io(String)
        public var description: String { if case .io(let m) = self { return m } else { return "" } }
    }

    /// Reads the token at `path`, or creates the file (and its 0700 parent) with 32 random bytes as hex.
    /// The file mode is forced to 0600 either way.
    public static func loadOrCreate(path: String) throws -> String {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        if let data = fm.contents(atPath: path), let s = String(data: data, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                return t
            }
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.io("cannot read secure random bytes")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw Failure.io("cannot write token file \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let line = Array((token + "\n").utf8)
        guard write(fd, line, line.count) == line.count else { throw Failure.io("short write to \(path)") }
        fchmod(fd, 0o600)
        return token
    }
}
