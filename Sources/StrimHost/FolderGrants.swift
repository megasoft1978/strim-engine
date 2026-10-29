import Foundation
import StrimHarness

/// A grant/revoke refusal. `kind` maps to an HTTP status in the control plane.
public struct FolderGrantError: Error, CustomStringConvertible, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case badRequest, forbidden, notFound, conflict, io }
    public let kind: Kind
    public let message: String
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    public var description: String { message }
}

/// The runtime list of folders jobs and chats may use (`mcp.allowedRoots`), shared by every `HostPolicy` copy.
/// Grants take effect immediately and are persisted to the host config, so they survive a restart.
///
/// Only the control plane (control token, the menu-bar app) may call `grant`/`revoke`. Nothing an agent, an MCP
/// client or a chat can send reaches this type: the MCP/API token is refused by the route guard.
public final class FolderGrants: @unchecked Sendable {
    public static let maxRoots = 64
    private let lock = NSLock()
    private var current: [String]
    /// Roots that came from the config as written by hand (not by a grant): never revocable through the API.
    private let fixed: Set<String>
    public let configURL: URL
    public let home: String
    /// True when the host started with at least one root: an empty list can then never mean "unrestricted".
    public let restricted: Bool

    /// - roots: the effective roots at start (after `withProductionDefaults`). Empty means the host is unrestricted
    ///   (tests only); grants are then refused because they would silently narrow it.
    /// Roots are stored in canonical form (symlinks resolved now); `HostPolicy` later accepts a root only while it still
    /// canonicalizes to itself, so swapping a granted folder for a symlink cannot widen access. Roots that resolve to `/`
    /// are dropped. Grants persisted earlier are listed in `mcp.grantedRoots`; every other root is `fixed`.
    public init(roots: [String], configURL: URL, home: String = NSHomeDirectory()) {
        var seen = Set<String>(), norm: [String] = []
        for r in roots {
            let c = HostPolicy.canonical(r)
            if c == "/" || c.isEmpty || !seen.insert(c).inserted { continue }
            norm.append(c)
        }
        // Roots were configured but none survived (all resolve to "/", say): fall back to home, never to unrestricted.
        if norm.isEmpty, !roots.isEmpty { norm = [HostPolicy.canonical(home)] }
        let granted = Set(Self.readGranted(configURL).map { HostPolicy.canonical($0) })
        self.restricted = !roots.isEmpty
        self.current = norm
        self.fixed = Set(norm.filter { !granted.contains($0) })
        self.configURL = configURL; self.home = home
    }

    static func readGranted(_ url: URL) -> [String] {
        guard let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let m = o["mcp"] as? [String: Any], let g = m["grantedRoots"] as? [String] else { return [] }
        return g
    }

    public var roots: [String] { lock.withLock { current } }

    // MARK: protected locations

    static let protectedAbsolute = ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/var/root", "/private/var/root",
                                    "/Library/Keychains", "/dev", "/private/var/db"]
    /// Too broad to grant as a whole; their children are fine.
    static let containerOnly: Set<String> = ["/private", "/private/var", "/private/var/folders", "/Volumes", "/Users", "/Applications", "/Library"]
    static let credentialNames = [".ssh", ".aws", ".gnupg", ".strim"]

    private func homes() -> [String] {
        var s = [home]
        if let r = Self.realpath(home) { s.append(r) }
        return s.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    static func realpath(_ p: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return Foundation.realpath(p, &buf) != nil ? String(cString: buf) : nil
    }

    /// Validates `path` and returns its resolved form, or throws why it can never be a grant.
    func validate(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0") else {
            throw FolderGrantError(.badRequest, "path must be a non-empty absolute path")
        }
        guard path.hasPrefix("/") else { throw FolderGrantError(.badRequest, "path must be absolute") }
        if path.split(separator: "/", omittingEmptySubsequences: true).contains("..") {
            throw FolderGrantError(.forbidden, "path may not contain '..'")
        }
        guard let real = Self.realpath(path) else { throw FolderGrantError(.notFound, "folder does not exist: \(path)") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else {
            throw FolderGrantError(.badRequest, "not a folder: \(path)")
        }
        if real == "/" { throw FolderGrantError(.forbidden, "the filesystem root cannot be granted") }
        if Self.containerOnly.contains(real) {
            throw FolderGrantError(.forbidden, "\(real) is too broad to grant; pick a folder inside it")
        }
        let hs = homes()
        for p in Self.protectedAbsolute where real == p || real.hasPrefix(p + "/") {
            throw FolderGrantError(.forbidden, "\(real) is inside a protected system location (\(p))")
        }
        if let why = SensitiveDirs.refuse(realCwd: real, home: home) {
            throw FolderGrantError(.forbidden, "\(real): \(why)")
        }
        // A folder that equals or contains a credential directory would expose it; the home folder itself stays allowed.
        if !hs.contains(real) {
            var creds = Self.protectedAbsolute
            for h in hs { creds += Self.credentialNames.map { h + "/" + $0 } }
            for c in creds where c == real || c.hasPrefix(real + "/") {
                throw FolderGrantError(.forbidden, "\(real) contains a credentials or host-state directory (\(c))")
            }
        }
        return real
    }

    private static func covers(_ root: String, _ real: String) -> Bool {
        let r = HostPolicy.canonical(root)
        return real == r || real.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    // MARK: operations

    /// Adds `path` (resolved) to the roots and persists. A path already covered by a root is a no-op.
    @discardableResult
    public func grant(_ path: String) throws -> [String] {
        let real = try validate(path)
        return try lock.withLock {
            guard !current.isEmpty else {
                throw FolderGrantError(.conflict, "this host is unrestricted (no allowed roots); nothing to grant")
            }
            if current.contains(where: { Self.covers($0, real) }) { return current }
            guard current.count < Self.maxRoots else {
                throw FolderGrantError(.conflict, "too many granted folders (max \(Self.maxRoots)); revoke one first")
            }
            let next = current + [real]
            try Self.persist(next, granted: next.filter { !fixed.contains($0) }, to: configURL)
            current = next
            return next
        }
    }

    /// Removes the root that resolves to `path`. The home folder cannot be revoked. Open chats keep their isolated
    /// copy, but their cwd no longer passes `HostPolicy`, so applying their patch is refused.
    @discardableResult
    public func revoke(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
            throw FolderGrantError(.badRequest, "path must be absolute")
        }
        let want = HostPolicy.canonical(path)
        if homes().contains(want) { throw FolderGrantError(.forbidden, "the home folder is the default and cannot be revoked") }
        return try lock.withLock {
            guard let hit = current.first(where: { HostPolicy.canonical($0) == want }) else {
                throw FolderGrantError(.notFound, "no such granted folder: \(path)")
            }
            if fixed.contains(hit) {
                throw FolderGrantError(.forbidden, "\(hit) comes from mcp.allowedRoots in the host config, not from a grant; edit the config file to remove it")
            }
            let next = current.filter { HostPolicy.canonical($0) != want }
            guard !next.isEmpty || !restricted else {
                throw FolderGrantError(.forbidden, "refusing to remove the last allowed folder")
            }
            try Self.persist(next, granted: next.filter { !fixed.contains($0) }, to: configURL)
            current = next
            return next
        }
    }

    // MARK: persistence

    /// Rewrites only `mcp.allowedRoots` and `mcp.grantedRoots` (the subset added by grants), keeping every other key; atomic (temp file + rename), 0600.
    static func persist(_ roots: [String], granted: [String], to url: URL) throws {
        var obj: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw FolderGrantError(.io, "\(url.path) is not valid JSON; fix or remove it before changing folder access")
            }
            obj = o
        }
        var mcp: [String: Any] = [:]
        if let m = obj["mcp"] {
            guard let md = m as? [String: Any] else { throw FolderGrantError(.io, "\(url.path): \"mcp\" must be an object") }
            mcp = md
        }
        mcp["allowedRoots"] = roots
        mcp["grantedRoots"] = granted
        obj["mcp"] = mcp
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let tmp = dir.appendingPathComponent(".config.\(UUID().uuidString).tmp")
            let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw FolderGrantError(.io, "cannot write \(tmp.path)") }
            let ok = data.withUnsafeBytes { buf -> Bool in
                var off = 0
                while off < buf.count {
                    let n = write(fd, buf.baseAddress! + off, buf.count - off)
                    if n <= 0 { return false }
                    off += n
                }
                return true
            }
            fsync(fd); close(fd)
            guard ok, rename(tmp.path, url.path) == 0 else {
                unlink(tmp.path)
                throw FolderGrantError(.io, "cannot write \(url.path)")
            }
            chmod(url.path, 0o600)
        } catch let e as FolderGrantError { throw e }
        catch { throw FolderGrantError(.io, "cannot write \(url.path): \(error.localizedDescription)") }
    }
}
