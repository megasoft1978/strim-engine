import Foundation
import Darwin

/// Bounded, symlink-safe (lstat only, never follows links) scans of a job workspace that back the `verify`
/// integrity checks: purge regenerable caches the agent could have planted, and detect new or changed
/// dependency/build dirs.
enum WorkspaceScan {
    /// Regenerable python/lint caches: deleted before verify so a planted `.pyc` cannot run.
    static let purgeDirs: Set<String> = ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"]
    /// Dependency/build dirs: exempt from the ignored-file downgrade only if they existed, unchanged, before the agent ran.
    static let dependencyDirs: Set<String> = ["node_modules", ".build", ".swiftpm", "target"]
    static let maxVisited = 200_000
    static let maxCountEntries = 5_000

    private static func lst(_ p: String) -> stat? { var st = stat(); return lstat(p, &st) == 0 ? st : nil }
    private static func isDir(_ st: stat) -> Bool { (st.st_mode & S_IFMT) == S_IFDIR }

    /// Walks directories under `root` (never into symlinks, `.git`, or dependency dirs when `skipDeps`),
    /// calling `visit` for each directory whose name is in `names`. Returns false if the visit cap was hit.
    @discardableResult
    private static func walk(_ root: String, names: Set<String>, skipDeps: Bool, visit: (String) -> Void) -> Bool {
        var stack = [root], visited = 0
        while let dir = stack.popLast() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in entries {
                visited += 1
                if visited > maxVisited { return false }
                if n == ".git" { continue }
                let p = dir + "/" + n
                guard let st = lst(p), isDir(st) else { continue }  // links and files: never followed
                if names.contains(n) { visit(p); continue }
                if skipDeps && dependencyDirs.contains(n) { continue }
                stack.append(p)
            }
        }
        return true
    }

    /// Deletes every regenerable cache dir under `root`. Returns (removed count, complete).
    @discardableResult
    static func purgeCaches(root: String) -> (removed: Int, complete: Bool) {
        var hits: [String] = []
        let complete = walk(root, names: purgeDirs, skipDeps: true) { hits.append($0) }
        for h in hits { forceRemove(h) }
        return (hits.count, complete)
    }

    /// chmod/unflag then delete a tree without following symlinks.
    static func forceRemove(_ path: String) {
        func prep(_ p: String, _ st: stat) {
            let mask = UInt32(UF_IMMUTABLE | UF_APPEND)
            if st.st_flags & mask != 0 { lchflags(p, st.st_flags & ~mask) }
            if isDir(st) {
                if st.st_mode & 0o700 != 0o700 { fchmodat(AT_FDCWD, p, (st.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW) }
                for n in (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? [] {
                    if let cs = lst(p + "/" + n) { prep(p + "/" + n, cs) }
                }
            }
        }
        if let st = lst(path) { prep(path, st) }
        try? FileManager.default.removeItem(atPath: path)
    }

    struct DependencySnapshot: Equatable {
        /// Relative dir path -> entry count of its top two levels.
        var counts: [String: Int] = [:]
        /// Visit or count cap hit: the snapshot cannot prove anything.
        var truncated = false
    }

    static func dependencySnapshot(root: String) -> DependencySnapshot {
        var snap = DependencySnapshot()
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let complete = walk(root, names: dependencyDirs, skipDeps: false) { dir in
            var n = 0
            for e1 in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                n += 1
                if let st = lst(dir + "/" + e1), isDir(st) {
                    n += ((try? FileManager.default.contentsOfDirectory(atPath: dir + "/" + e1))?.count) ?? 0
                }
                if n > maxCountEntries { snap.truncated = true; break }
            }
            snap.counts[dir.hasPrefix(prefix) ? String(dir.dropFirst(prefix.count)) : dir] = n
        }
        if !complete { snap.truncated = true }
        return snap
    }

    /// Dirs that are new, or whose top-two-level entry count changed, relative to `before`.
    /// A truncated snapshot on either side is reported as unverifiable.
    static func dependencyChanges(before: DependencySnapshot, after: DependencySnapshot) -> [String] {
        var out: [String] = []
        if before.truncated || after.truncated { out.append("unverifiable:dependency dir scan limit") }
        for (path, n) in after.counts.sorted(by: { $0.key < $1.key }) {
            if let was = before.counts[path] {
                if was != n { out.append("ignored:\(path)/ (entries changed)") }
            } else {
                out.append("ignored:\(path)/ (new)")
            }
        }
        return out
    }
}
