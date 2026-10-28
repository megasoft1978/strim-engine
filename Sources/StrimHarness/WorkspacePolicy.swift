import Foundation

public enum PolicyError: Error, Equatable {
    case outsideWorkspace(String)
    case denied(String)
    case readOnly(String)
}

/// Path containment + deny list for file tools. Symlinks are resolved (including dangling ones and
/// the longest existing ancestor of not-yet-existing targets) before the containment check.
public struct WorkspacePolicy: Sendable {
    public let root: URL
    public let access: AccessLevel
    /// nil when the root itself cannot be resolved (symlink chain too long): every path is then refused.
    private let realRoot: [String]?

    public init(root: URL, access: AccessLevel) {
        self.root = root
        self.access = access
        self.realRoot = try? Self.realComponents(of: root.path)
    }

    public func resolve(_ path: String, forWriting: Bool) throws -> URL {
        if forWriting && access == .read { throw PolicyError.readOnly(path) }
        guard let realRoot else { throw PolicyError.outsideWorkspace(path) }

        let absolute = path.hasPrefix("/")
        var lexicalRel: [String] = []
        let full: String
        if absolute {
            full = path
        } else {
            // Lexical `..` escape check before touching the filesystem.
            for c in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
                if c == "." { continue }
                if c == ".." {
                    if lexicalRel.isEmpty { throw PolicyError.outsideWorkspace(path) }
                    lexicalRel.removeLast()
                } else {
                    lexicalRel.append(c)
                }
            }
            full = (["/"] + realRoot + lexicalRel).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
        }

        let real: [String]
        do { real = try Self.realComponents(of: full) } catch { throw PolicyError.outsideWorkspace(path) }
        guard real.count >= realRoot.count, Array(real.prefix(realRoot.count)) == realRoot else {
            throw PolicyError.outsideWorkspace(path)
        }
        let rel = Array(real.dropFirst(realRoot.count))
        if Self.isDenied(rel, forWriting: forWriting)
            || (!absolute && Self.isDenied(lexicalRel, forWriting: forWriting)) {
            throw PolicyError.denied(path)
        }
        return URL(fileURLWithPath: "/" + real.joined(separator: "/"))
    }

    /// Real (symlink-free) absolute path of `path`, or nil when it cannot be resolved.
    static func realPath(of path: String) -> String? {
        (try? realComponents(of: path)).map { "/" + $0.joined(separator: "/") }
    }

    // MARK: deny list

    static func isDenied(_ original: [String], forWriting: Bool) -> Bool {
        // APFS is case-insensitive by default: compare lowercased.
        let rel = original.map { $0.lowercased() }
        guard let last = rel.last else { return false }
        for seg in rel where seg == ".ssh" || seg == ".aws" || seg == ".gnupg" { return true }
        if last == ".env" || last.hasPrefix(".env.") { return true }
        if last.hasSuffix(".pem") || last == ".netrc" || last == ".git-credentials" { return true }
        if last == "id_rsa" || (last.hasPrefix("id_") && !last.hasSuffix(".pub")) { return true }
        // The worktree `.git` pointer file (or any `.git` entry): writes would redirect git's admin dir.
        if forWriting && last == ".git" { return true }
        for gi in rel.indices where rel[gi] == ".git" {
            let after = rel[(gi + 1)...]
            // config holds remote credentials: no reads or writes.
            if after.first == "config" && after.count == 1 { return true }
            if forWriting && after.first == "hooks" && after.count >= 2 { return true }
        }
        return false
    }

    // MARK: real path resolution

    /// Resolves symlinks component by component (dangling links too); components that do not exist
    /// are appended lexically. Returns components of an absolute path. Throws when more than 40
    /// symlinks are followed (loops, or chains too long to trust).
    static func realComponents(of path: String) throws -> [String] {
        var pending = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var cur: [String] = []
        var hops = 0
        let fm = FileManager.default
        while !pending.isEmpty {
            let c = pending.removeFirst()
            if c == "." { continue }
            if c == ".." { if !cur.isEmpty { cur.removeLast() }; continue }
            let candidate = "/" + (cur + [c]).joined(separator: "/")
            if let dest = try? fm.destinationOfSymbolicLink(atPath: candidate) {
                hops += 1
                guard hops <= 40 else { throw PolicyError.outsideWorkspace(path) }
                if dest.hasPrefix("/") { cur = [] }
                pending = dest.split(separator: "/", omittingEmptySubsequences: true).map(String.init) + pending
            } else {
                cur.append(c)
            }
        }
        return cur
    }
}
