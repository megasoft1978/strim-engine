import Foundation

/// Symlink-safe file IO for generated files under an untrusted repo root.
enum SafeIO {
    static let maxRead = 64 << 20
    private static let lock = NSLock()
    nonisolated(unsafe) private static var testRoots: Set<String> = []
    /// Tests only: lets an overlay tree built from symlinks pass the component checks (below this exact root).
    public static func registerTestRoot(_ path: String) {
        let real = realpath(path, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? path
        lock.lock(); testRoots.insert(real); lock.unlock()
    }
    static func isTestRoot(_ r: String) -> Bool { lock.lock(); defer { lock.unlock() }; return testRoots.contains(r) }

    /// lstat every component of `path` below `root`; refuse symlinks. Final component may be absent when `allowMissing`.
    static func checkNoSymlinks(root: String, path: String, allowMissing: Bool, allowSymlinks: Bool = false) throws {
        guard path.hasPrefix(root + "/") else { throw SiteError("refusing path outside root: \(path)") }
        var cur = root
        let comps = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        for (i, c) in comps.enumerated() {
            cur += "/" + c
            var st = stat()
            if lstat(cur, &st) != 0 {
                if errno == ENOENT, allowMissing, i == comps.count - 1 { return }
                throw SiteError("cannot stat \(cur)")
            }
            if allowSymlinks {   // tests only: overlay trees are built from symlinks
                var t = stat()
                if stat(cur, &t) != 0 { if allowMissing, i == comps.count - 1 { return }; throw SiteError("cannot stat \(cur)") }
                st = t
            } else if (st.st_mode & S_IFMT) == S_IFLNK { throw SiteError("refusing symlink: \(cur)") }
            if i == comps.count - 1, (st.st_mode & S_IFMT) != S_IFREG { throw SiteError("refusing non-regular file: \(cur)") }
            if i < comps.count - 1, (st.st_mode & S_IFMT) != S_IFDIR { throw SiteError("not a directory: \(cur)") }
        }
    }

    static func write(root: String, path: String, _ s: String, allowSymlinks: Bool = false) throws {
        try checkNoSymlinks(root: root, path: path, allowMissing: true, allowSymlinks: allowSymlinks)
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = dir + "/.strim-site-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw SiteError("cannot create \(tmp)") }
        var ok = true
        let bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { ok = false; break }
            off += n
        }
        close(fd)
        if !ok { unlink(tmp); throw SiteError("write failed: \(tmp)") }
        do { try checkNoSymlinks(root: root, path: path, allowMissing: true, allowSymlinks: allowSymlinks) } catch { unlink(tmp); throw error }
        if rename(tmp, path) != 0 { unlink(tmp); throw SiteError("rename failed: \(path)") }
    }

    /// Read a regular file: every component below `root` is lstat-checked (no symlinks), the open is O_NOFOLLOW, with a size cap.
    static func readRegular(root: String, path: String, allowSymlinks: Bool = false) -> String? {
        guard (try? checkNoSymlinks(root: root, path: path, allowMissing: false, allowSymlinks: allowSymlinks)) != nil else { return nil }
        let fd = open(path, allowSymlinks ? O_RDONLY : (O_RDONLY | O_NOFOLLOW))
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= maxRead else { return nil }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(buf, count: n)
            if data.count > maxRead { return nil }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
