import Foundation
import Darwin

/// Isolates a job in a detached git worktree of the parent repo, or in an APFS clone for non-git folders.
/// The parent's working tree, index and refs are only read. Objects are written (stash/commit-tree) and
/// worktree metadata goes under the parent's `.git/worktrees`; nothing in the parent tree changes.
///
/// The job directory is agent-writable, so git never discovers its repo from there. Each job's admin dir,
/// common dir and exact `.git` file content are recorded at prepare time; every host-side git call re-checks
/// the `.git` file and runs with explicit `--git-dir`/`--work-tree` plus hardening flags.
public actor GitWorktreeIsolation: WorkspaceIsolation {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unsafePath(String)
        case command(String, Int32, String)
        case unknownWorkspace(String)
        case tampered(String)
        case noTrustedGit
        case patchTooLarge(Int)
        case fileTooLarge(String)
        case timedOut(String, TimeInterval)
        case refusedFolder(String)
        case changesTooLarge(Int64)

        public var description: String {
            switch self {
            case let .unsafePath(p): return "unsafe relative path: \(p)"
            case let .command(cmd, code, err): return "\(cmd) exited \(code): \(err)"
            case let .unknownWorkspace(root): return "no recorded job for \(root)"
            case let .tampered(dir): return "\(dir)/.git no longer matches the recorded worktree link"
            case .noTrustedGit: return "no trusted git binary found (xcrun shim /usr/bin/git is never used)"
            case let .patchTooLarge(n): return "patchTooLarge: git output exceeds \(n) bytes"
            case let .fileTooLarge(p): return "fileTooLarge: \(p) exceeds \(GitWorktreeIsolation.maxFileBytes) bytes; remove it or add it to .gitignore"
            case let .timedOut(cmd, t): return "\(cmd) timed out after \(Int(t))s"
            case let .refusedFolder(why): return "refusing to isolate folder: \(why)"
            case let .changesTooLarge(n): return "changesTooLarge: changed and untracked files total \(n) bytes (limit \(GitWorktreeIsolation.defaultMaxChangedBytes))"
            }
        }
    }

    /// SHA-1 of the empty tree; used as the base for a repo with no commits yet, and as an empty
    /// attribute source for worktree-side git calls (no `.gitattributes`, so no filter or diff drivers).
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// Prepended to every git call: repo- and worktree-controlled config cannot run code through these keys.
    static let hardening: [String] = [
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.attributesFile=/dev/null",
        "-c", "core.pager=cat",
        "-c", "core.excludesFile=/dev/null",
        "-c", "core.sparseCheckout=false",
        "-c", "core.untrackedCache=false",
        "-c", "core.sshCommand=/usr/bin/false",
        "-c", "protocol.allow=never",
        "-c", "diff.external=",
        "-c", "extensions.worktreeConfig=false",
    ]

    /// Absolute path of the git binary used for every call. `/usr/bin/git` is an xcrun shim that reads
    /// cache files in the user temp dir, so it is never used and PATH is never searched for git.
    static func gitExecutable() throws -> String {
        guard let path = SandboxProfile.trustedGitPath else { throw Failure.noTrustedGit }
        return path
    }

    /// Scrubbed environment: no inherited GIT_DIR/GIT_CONFIG*, DEVELOPER_DIR, or system or global config, no prompts.
    static let env: [String: String] = [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory(),
        "LANG": "en_US.UTF-8",
        "TMPDIR": NSTemporaryDirectory(),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_AUTHOR_NAME": "strim", "GIT_AUTHOR_EMAIL": "strim@localhost",
        "GIT_COMMITTER_NAME": "strim", "GIT_COMMITTER_EMAIL": "strim@localhost",
    ]

    /// What a worktree job was created with. `gitFile` is the exact `.git` content written by git.
    struct Job: Sendable {
        var top: String
        var commonDir: String
        var adminDir: String
        var gitFile: String
        var commondirFile: String
        var base: String
    }

    /// Host-side git stdout cap (the patch) and stderr cap.
    public static let maxPatchBytes = 16 * 1024 * 1024
    static let maxStderrBytes = 64 * 1024
    /// A changed or untracked file bigger than this fails `collectPatch`.
    static let maxFileBytes: Int64 = 50 * 1024 * 1024
    /// Total bytes of changed plus untracked files `collectPatch` accepts.
    public static let defaultMaxChangedBytes: Int64 = 200 * 1024 * 1024
    /// Per-job object store inside the worktree admin dir. The sandbox writes new objects here and reads
    /// the parent's `<common>/objects` as an alternate; nothing in the parent's store is writable.
    public static let quarantineName = "strim-objects"
    /// Non-git clone fallback limits.
    static let maxCloneBytes: Int64 = 500 * 1024 * 1024
    static let maxCloneFiles = 50_000

    private let baseDir: URL
    private let cloneFallback: Bool
    private let gitTimeout: TimeInterval
    private let maxPatchBytes: Int
    private let maxChangedBytes: Int64
    /// Job dir -> recorded worktree link (git jobs only).
    private var jobs: [String: Job] = [:]
    /// Non-git clone root -> original folder (needed to diff against it).
    private var origins: [String: String] = [:]
    /// Job directories in use; `prune` skips them.
    private var active: Set<String> = []

    public init(baseDir: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".strim/worktrees"),
                cloneFallback: Bool = true,
                gitTimeout: TimeInterval = 120,
                maxPatchBytes: Int = GitWorktreeIsolation.maxPatchBytes,
                maxChangedBytes: Int64 = GitWorktreeIsolation.defaultMaxChangedBytes) {
        self.maxChangedBytes = maxChangedBytes
        self.baseDir = baseDir.resolvingSymlinksInPath()
        self.cloneFallback = cloneFallback
        self.gitTimeout = gitTimeout
        self.maxPatchBytes = maxPatchBytes
    }

    public func prepare(cwd: String, access: AccessLevel, files: [String]) async throws -> Workspace {
        // Validate everything before any side effect.
        let rels = try files.map(Self.safeRelativePath)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let dir = baseDir.appendingPathComponent(UUID().uuidString.lowercased()).path

        guard let top = try await repoTop(cwd) else {
            try Self.validateCloneSource(cwd)
            active.insert(dir)
            do {
                try await clone(cwd, to: dir)
            } catch {
                await cleanup(Workspace(root: dir, base: ""))
                throw error
            }
            origins[dir] = Self.trimSlash(cwd)
            return Workspace(root: dir, base: "")
        }

        let common = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: cwd)
        let prefix = try await git(["rev-parse", "--show-prefix"], in: cwd)
        let base = try await baseRevision(cwd)
        active.insert(dir)
        do {
            try await git(["worktree", "add", "--detach", dir, base], in: cwd)
            let gitFile = try String(contentsOfFile: dir + "/.git", encoding: .utf8)
            let admin = try Self.adminDir(fromGitFile: gitFile)
            guard admin.hasPrefix(common + "/worktrees/"), FileManager.default.fileExists(atPath: admin + "/HEAD") else {
                throw Failure.tampered(dir)
            }
            let commondirFile = try String(contentsOfFile: admin + "/commondir", encoding: .utf8)
            try FileManager.default.createDirectory(atPath: hostObjectsDir(dir), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(atPath: admin + "/" + Self.quarantineName,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            jobs[dir] = Job(top: dir, commonDir: common, adminDir: admin, gitFile: gitFile,
                            commondirFile: commondirFile, base: base)
            try copyUntracked(rels, from: top, to: dir)
        } catch {
            await cleanup(Workspace(root: dir, base: base))
            throw error
        }
        let sub = Self.trimSlash(prefix)
        let root = sub.isEmpty ? dir : dir + "/" + sub
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return Workspace(root: root, base: base)
    }

    public func collectPatch(_ ws: Workspace) async throws -> String {
        if ws.base.isEmpty { return try await clonePatch(ws) }
        let job = try job(for: ws)
        try await rebuildIndex(job)
        try await prepareTreeForAdd(job)
        try await gitWork(job, ["add", "-A"])
        return try await gitWorkRaw(job, ["diff", "--cached", "--binary", "--no-color", "--no-ext-diff", "--no-textconv", job.base])
    }

    /// Top of the git worktree that contains `ws.root` (the root itself for a repo top-level job).
    public func worktreeTop(for ws: Workspace) -> String? { jobDir(ws.root) }

    /// Changed and ignored paths of the workspace, from git's NUL-separated output. Call after `collectPatch`
    /// (its `add -A` has staged everything not ignored). Non-git (clone) workspaces cannot be scanned: fail closed.
    public func integrityScan(_ ws: Workspace) async throws -> WorkspaceIntegrity? {
        if ws.base.isEmpty { return WorkspaceIntegrity(suspicious: true) }
        let job = try job(for: ws)
        let status = try await gitWorkRaw(job, ["diff", "--cached", "--name-status", "-z", "-M", "--no-color",
                                               "--no-ext-diff", "--no-textconv", job.base])
        // Well-known cache dirs are excluded in git itself so a huge node_modules cannot overflow the output cap.
        let skip = Self.ignoredScanSkip.map { ":(exclude,glob)**/\($0)/**" } + [":(exclude,glob)**/.DS_Store"]
        let ignored = try await gitWorkRaw(job, ["ls-files", "-o", "--ignored", "--exclude-standard", "-z", "--"] + skip)
        return Self.parseIntegrity(nameStatus: status, ignored: ignored)
    }

    static let ignoredScanSkip = ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".build", ".swiftpm",
                                  "node_modules", "target"]

    static func parseIntegrity(nameStatus: String, ignored: String) -> WorkspaceIntegrity {
        var out = WorkspaceIntegrity()
        func take(_ s: String) -> [String] {
            var t = s.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            if t.last == "" { t.removeLast() }
            return t
        }
        let toks = take(nameStatus)
        var i = 0
        while i < toks.count {
            let st = toks[i]; i += 1
            let n = (st.first == "R" || st.first == "C") ? 2 : 1
            guard !st.isEmpty, st.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), i + n <= toks.count else {
                out.suspicious = true; break
            }
            out.changedPaths += toks[i..<(i + n)]
            i += n
        }
        out.ignoredPaths = take(ignored)
        if (out.changedPaths + out.ignoredPaths).contains(where: Self.isOddPath) { out.suspicious = true }
        return out
    }

    static func isOddPath(_ p: String) -> Bool {
        if p.isEmpty || p.hasPrefix("/") || p.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0xFFFD }) {
            return true
        }
        let body = p.hasSuffix("/") ? String(p.dropLast()) : p
        return body.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0.isEmpty || $0 == ".." || $0.lowercased() == ".git"
        }
    }

    /// Per-file line counts of a patch produced by `collectPatch`.
    public static func fileChanges(in patch: String) -> [FileChange] {
        var out: [FileChange] = []
        var inHunk = false
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                inHunk = false
                let spec = line.dropFirst("diff --git ".count)
                let path = spec.range(of: " b/", options: .backwards).map { String(spec[$0.upperBound...]) }
                    ?? String(spec)
                out.append(FileChange(path: path, added: 0, removed: 0))
            } else if line.hasPrefix("@@") {
                inHunk = true
            } else if inHunk, let last = out.indices.last {
                if line.hasPrefix("+") { out[last].added += 1 }
                else if line.hasPrefix("-") { out[last].removed += 1 }
            }
        }
        return out
    }

    public func cleanup(_ ws: Workspace) async {
        guard let dir = jobDir(ws.root) else { return }
        active.remove(dir)
        origins.removeValue(forKey: dir)
        try? FileManager.default.removeItem(atPath: hostObjectsDir(dir))
        if let job = jobs.removeValue(forKey: dir), Self.matches(job) {
            Self.makeRemovable(dir, under: baseDir.path)
            _ = try? await git(["--git-dir=" + job.commonDir, "worktree", "remove", "--force", dir], in: baseDir.path)
            try? FileManager.default.removeItem(atPath: dir)
            _ = try? await git(["--git-dir=" + job.commonDir, "worktree", "prune"], in: baseDir.path)
        } else {
            Self.makeRemovable(dir, under: baseDir.path)
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    /// Single entry point to make a job tree deletable (HarnessRunner should call it before removing a job dir).
    /// Own lstat walk under a verified direct child of `root`; never follows symlinks. Directories get
    /// user-immutable flags cleared and `u+rwx`; regular files only when `st_nlink == 1` (a hardlink shares an
    /// inode with files outside the tree, whose mode must not change); everything else is skipped, since
    /// removing the tree just unlinks it.
    public static func makeRemovable(_ path: String, under root: String) {
        let parent = (path as NSString).deletingLastPathComponent
        var st = stat()
        guard realPath(parent) == realPath(root), lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return }
        func walk(_ p: String, _ st: stat) {
            let mask = UInt32(UF_IMMUTABLE | UF_APPEND)
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                if st.st_flags & mask != 0 { lchflags(p, st.st_flags & ~mask) }
                if st.st_mode & 0o700 != 0o700 { fchmodat(AT_FDCWD, p, (st.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW) }
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: p) else { return }
                for n in names {
                    var cs = stat()
                    if lstat(p + "/" + n, &cs) == 0 { walk(p + "/" + n, cs) }
                }
            case S_IFREG where st.st_nlink == 1:
                if st.st_flags & mask != 0 { lchflags(p, st.st_flags & ~mask) }
                if st.st_mode & 0o600 != 0o600 { fchmodat(AT_FDCWD, p, (st.st_mode & 0o7777) | 0o600, AT_SYMLINK_NOFOLLOW) }
            default: break
            }
        }
        walk(path, st)
    }

    /// Git paths the sandbox must allow for a worktree job (writable) and the control dirs whose
    /// hooks/config it must deny. Both empty for non-git clones.
    public func sandboxGitPaths(for ws: Workspace) -> (writable: [String], control: [String]) {
        guard !ws.base.isEmpty, let job = try? job(for: ws) else { return ([], []) }
        let common = job.commonDir
        // Detached worktree: HEAD and its reflog live in the admin dir, new objects in the quarantine inside it
        // (ProcessRunner sets GIT_OBJECT_DIRECTORY / GIT_ALTERNATE_OBJECT_DIRECTORIES from these paths).
        // Branch refs and the parent's object store are deliberately not writable.
        return ([job.adminDir, job.adminDir + "/" + Self.quarantineName], [common])
    }

    /// Removes job directories older than `keepDays` and any beyond the newest `keepCount`.
    /// Skips directories in use. Directories without a verified recorded link are deleted without git.
    /// Returns the number removed.
    @discardableResult
    public func prune(keepDays: Int = 7, keepCount: Int = 20) async -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: keys) else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        let candidates: [(path: String, date: Date)] = items.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, !url.lastPathComponent.hasPrefix("."), !active.contains(url.path) else { return nil }
            return (url.path, values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        var removed = 0
        var commons = Set<String>()
        for (index, entry) in candidates.enumerated() where index >= keepCount || entry.date < cutoff {
            if let job = jobs.removeValue(forKey: entry.path), Self.matches(job) {
                commons.insert(job.commonDir)
                Self.makeRemovable(entry.path, under: baseDir.path)
                _ = try? await git(["--git-dir=" + job.commonDir, "worktree", "remove", "--force", entry.path], in: baseDir.path)
            }
            Self.makeRemovable(entry.path, under: baseDir.path)
            try? fm.removeItem(atPath: entry.path)
            removed += 1
        }
        for common in commons {
            _ = try? await git(["--git-dir=" + common, "worktree", "prune"], in: baseDir.path)
        }
        return removed
    }

    // MARK: - Helpers

    /// Relative path under the repo root; rejects absolute, `..`, `~` and `.git` components.
    static func safeRelativePath(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !parts.isEmpty,
              !parts.contains(".."), !parts.contains(".git") else {
            throw Failure.unsafePath(path)
        }
        return parts.joined(separator: "/")
    }

    /// `gitdir: <admin>\n` -> `<admin>`.
    static func adminDir(fromGitFile content: String) throws -> String {
        let line = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir: ") else { throw Failure.tampered(content) }
        return String(line.dropFirst("gitdir: ".count))
    }

    private func job(for ws: Workspace) throws -> Job {
        guard let dir = jobDir(ws.root), let job = jobs[dir] else { throw Failure.unknownWorkspace(ws.root) }
        guard Self.matches(job) else { throw Failure.tampered(job.top) }
        return job
    }

    /// True while `<top>/.git` and the admin `commondir` still hold exactly what git wrote at prepare time.
    private static func matches(_ job: Job) -> Bool {
        (try? String(contentsOfFile: job.top + "/.git", encoding: .utf8)) == job.gitFile
            && (try? String(contentsOfFile: job.adminDir + "/commondir", encoding: .utf8)) == job.commondirFile
    }

    private func repoTop(_ cwd: String) async throws -> String? {
        let out: String
        do {
            out = try await git(["rev-parse", "--show-toplevel"], in: cwd)
        } catch {
            return nil
        }
        return Self.trimSlash(out)
    }

    /// `git stash create` snapshots tracked changes without touching the tree or index; HEAD when clean.
    private func baseRevision(_ cwd: String) async throws -> String {
        guard let head = try? await git(["rev-parse", "--verify", "-q", "HEAD^{commit}"], in: cwd) else {
            return try await git(Self.identity + ["commit-tree", Self.emptyTree, "-m", "strim base"], in: cwd)
        }
        // A freshly copied tree has stale stat info; refresh first (failure here is harmless).
        _ = try? await git(["update-index", "-q", "--refresh"], in: cwd)
        let args = Self.identity + stashArgs
        do {
            let stash = try await git(args, in: cwd)
            return stash.isEmpty ? head : stash
        } catch {
            // Exact when the tree is clean; otherwise retry once, then fail with git's stderr.
            if let status = try? await git(["status", "--porcelain"], in: cwd), status.isEmpty { return head }
            let stash = try await git(args, in: cwd)
            return stash.isEmpty ? head : stash
        }
    }

    static let identity = ["-c", "user.name=strim", "-c", "user.email=strim@localhost"]
    /// `git stash create` arguments; tests override to force a failure.
    private var stashArgs = ["stash", "create"]
    func setStashArgs(_ a: [String]) { stashArgs = a }

    // MARK: orphans

    /// Removes every job directory this instance knows about except those whose root is in `keeping`
    /// (graceful shutdown). Returns the number cleaned.
    @discardableResult
    public func cleanupAll(keeping: Set<String> = []) async -> Int {
        let keep = Set(keeping.compactMap { jobDir($0) ?? ($0.hasPrefix(baseDir.path + "/") ? $0 : nil) })
        var dirs = active
        for d in jobs.keys { dirs.insert(d) }
        for d in origins.keys { dirs.insert(d) }
        var n = 0
        for d in dirs.sorted() where !keep.contains(d) {
            await cleanup(Workspace(root: d, base: ""))
            n += 1
        }
        return n
    }

    /// Host-start sweep: removes directories under `baseDir` that have no live job record in this
    /// instance and that either (a) are real worktrees (their `.git` file points at
    /// `<repo>/.git/worktrees/<id>` whose `gitdir` back-link names this directory) idle for `graceSeconds`,
    /// then runs hardened `git worktree prune` in that repo, or (b) are older than `maxAgeDays`.
    /// Only direct children of `baseDir` that are real directories (not symlinks) are ever removed.
    /// Returns the number removed.
    @discardableResult
    public func sweepOrphans(graceSeconds: TimeInterval = 30, maxAgeDays: Int = 1) async -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: baseDir.path) else { return 0 }
        var removed = 0
        var commons = Set<String>()
        for name in names where !name.contains("/") && !name.hasPrefix(".") {
            let path = baseDir.path + "/" + name
            if active.contains(path) || jobs[path] != nil || origins[path] != nil { continue }
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }  // no symlinks/files
            let age = Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
            let common = Self.linkedCommonDir(of: path)
            if let c = common, age >= graceSeconds {
                commons.insert(c)
            } else if age >= Double(maxAgeDays) * 86_400 {
                // stale unlinked dir
            } else {
                continue
            }
            Self.makeRemovable(path, under: baseDir.path)
            if (try? fm.removeItem(atPath: path)) != nil { removed += 1 }
        }
        for c in commons {
            _ = try? await git(["--git-dir=" + c, "worktree", "prune"], in: baseDir.path)
        }
        // Host object dirs whose job dir is gone.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: hostRoot)) ?? [] where !name.contains("/")
            && !FileManager.default.fileExists(atPath: baseDir.path + "/" + name) && !active.contains(baseDir.path + "/" + name) {
            try? FileManager.default.removeItem(atPath: hostRoot + "/" + name)
        }
        return removed
    }

    public static func sweepOrphans(baseDir: URL, graceSeconds: TimeInterval = 30, maxAgeDays: Int = 1) async -> Int {
        await GitWorktreeIsolation(baseDir: baseDir).sweepOrphans(graceSeconds: graceSeconds, maxAgeDays: maxAgeDays)
    }

    /// Common git dir of a worktree dir, only if `<dir>/.git` names `<common>/worktrees/<id>` and that
    /// admin dir's `gitdir` file points back at `<dir>/.git`.
    private static func linkedCommonDir(of dir: String) -> String? {
        var st = stat()
        guard lstat(dir + "/.git", &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              let content = try? String(contentsOfFile: dir + "/.git", encoding: .utf8),
              let admin = try? adminDir(fromGitFile: content),
              let r = admin.range(of: "/worktrees/", options: .backwards) else { return nil }
        let common = String(admin[..<r.lowerBound]), id = String(admin[r.upperBound...])
        guard admin.hasPrefix("/"), !id.isEmpty, !id.contains("/"), !id.contains(".."),
              FileManager.default.fileExists(atPath: common + "/HEAD"),
              let back = try? String(contentsOfFile: admin + "/gitdir", encoding: .utf8),
              realPath(back.trimmingCharacters(in: .whitespacesAndNewlines)) == realPath(dir + "/.git") else { return nil }
        return common
    }

    /// Copies untracked files named in `rels` from the parent repo into the worktree. Secret-looking
    /// paths (see `isSecretPath`) are skipped, including inside copied directories; symlinks leaving the repo are skipped.
    private func copyUntracked(_ rels: [String], from top: String, to dir: String) throws {
        let fm = FileManager.default
        let realTop = Self.realPath(top)
        let policy = WorkspacePolicy(root: URL(fileURLWithPath: top), access: .read)
        for rel in rels {
            let src: URL
            do { src = try policy.resolve(rel, forWriting: false) }
            catch PolicyError.denied { continue }
            catch { throw Failure.unsafePath(rel) }
            guard src.path.hasPrefix(realTop + "/") else { throw Failure.unsafePath(rel) }
            if Self.isSecretPath(rel.split(separator: "/").map(String.init)) { continue }
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: dir).appendingPathComponent(rel)
            guard !fm.fileExists(atPath: dst.path) else { continue }  // tracked files are already checked out
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.copyFiltered(src.path, dst.path, relParts: rel.split(separator: "/").map(String.init), realTop: realTop)
        }
    }

    /// realpath(3) (keeps /private, unlike Foundation's resolvingSymlinksInPath); the input on failure.
    static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// Secret-looking relative path: WorkspacePolicy deny list plus git/strim credential files.
    static func isSecretPath(_ parts: [String]) -> Bool {
        if WorkspacePolicy.isDenied(parts, forWriting: false) { return true }
        let l = parts.map { $0.lowercased() }
        if l.last == ".git-credentials" { return true }
        if l.count >= 2, l[l.count - 2] == ".strim", l.last == "token" { return true }
        // Host secrets by name wherever they sit (the clone root's own name is prepended by `scrubClone`).
        if l.last == "control-token" || l.last == "hosts.yml" { return true }
        if l.count >= 2, l[l.count - 2] == ".docker" || l[l.count - 2] == ".kube", l.last == "config.json" || l.last == "config" { return true }
        if l.count >= 2, l[l.count - 2] == ".aws", l.last == "credentials" { return true }
        return false
    }

    private static func copyFiltered(_ src: String, _ dst: String, relParts: [String], realTop: String) throws {
        var st = stat()
        guard lstat(src, &st) == 0 else { return }
        let fm = FileManager.default
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            try fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: src) {
                let parts = relParts + [name]
                if isSecretPath(parts) { continue }
                try copyFiltered(src + "/" + name, dst + "/" + name, relParts: parts, realTop: realTop)
            }
        case S_IFLNK:
            let real = realPath(src)
            guard real.hasPrefix(realTop + "/"), !isSecretPath(Array(real.dropFirst(realTop.count + 1)
                .split(separator: "/").map(String.init))) else { return }
            try fm.copyItem(atPath: src, toPath: dst)
        case S_IFREG:
            try fm.copyItem(atPath: src, toPath: dst)
        default:
            return  // fifo, socket, device
        }
    }

    // MARK: non-git clone

    /// Refuses `$HOME`, `/`, ancestors of `$HOME`, and folders over the size or file-count limits.
    /// The walk uses lstat and never follows symlinks.
    static func validateCloneSource(_ cwd: String, maxFiles: Int = maxCloneFiles,
                                    maxBytes: Int64 = maxCloneBytes) throws {
        let real = realPath(cwd)
        let homes = Set([NSHomeDirectory(), FileManager.default.homeDirectoryForCurrentUser.path].map(realPath))
        for h in homes where real == "/" || real == h || h.hasPrefix(real + "/") {
            throw Failure.refusedFolder("\(cwd) is the home directory, root, or a parent of home")
        }
        for h in homes {
            if let why = SensitiveDirs.refuse(realCwd: real, home: h) { throw Failure.refusedFolder("\(cwd): \(why)") }
        }
        var bytes: Int64 = 0, files = 0
        func walk(_ dir: String) throws {
            guard let d = opendir(dir) else { return }
            defer { closedir(d) }
            while let e = readdir(d) {
                let name = withUnsafePointer(to: &e.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                files += 1
                if (st.st_mode & S_IFMT) == S_IFDIR { try walk(path) }
                else if (st.st_mode & S_IFMT) == S_IFREG { bytes += Int64(st.st_size) }
                if files > maxFiles || bytes > maxBytes {
                    throw Failure.refusedFolder("\(cwd) exceeds \(maxFiles) files or \(maxBytes) bytes")
                }
            }
        }
        try walk(real)
    }

    /// Removes secret-looking entries from a fresh clone (never descends into a removed directory).
    private static func scrubClone(_ dir: String, rootName: String = "") {
        let fm = FileManager.default
        func walk(_ path: String, _ parts: [String]) {
            guard let names = try? fm.contentsOfDirectory(atPath: path) else { return }
            for n in names {
                let p = parts + [n]
                let full = path + "/" + n
                if isSecretPath(p) { try? fm.removeItem(atPath: full); continue }
                var st = stat()
                if lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { walk(full, p) }
            }
        }
        walk(dir, rootName.isEmpty ? [] : [rootName])
    }

    /// Drops diff sections of secret-looking paths (the original folder still has them, the clone does not).
    /// Fails closed: also drops sections with a `.git` path component (any case), headers git still quoted
    /// (special characters), and symlink sections (mode 120000) whose target is absolute or contains `..`.
    static func dropSecretSections(_ patch: String, rootName: String = "") -> String {
        var sections: [[Substring]] = [[]]
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { sections.append([]) }
            sections[sections.count - 1].append(line)
        }
        var out: [Substring] = []
        for sec in sections {
            if let first = sec.first, first.hasPrefix("diff --git "), dropSection(sec, rootName: rootName) { continue }
            out.append(contentsOf: sec)
        }
        return out.joined(separator: "\n")
    }

    private static func dropSection(_ sec: [Substring], rootName: String = "") -> Bool {
        let spec = sec[0].dropFirst("diff --git ".count)
        if spec.hasPrefix("\"") || spec.contains("\"") { return true }  // quoted header: cannot be vetted
        var paths: [String] = []
        if let r = spec.range(of: " b/", options: .backwards) {
            paths.append(String(spec[r.upperBound...]))
            paths.append(String(spec[..<r.lowerBound].dropFirst(2)))
        } else {
            paths.append(String(spec))
        }
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            if isSecretPath(rootName.isEmpty ? parts : [rootName] + parts) || parts.contains(where: { $0.lowercased() == ".git" }) { return true }
        }
        let isLink = sec.contains { l in
            (l.hasPrefix("new file mode 120000") || l.hasPrefix("deleted file mode 120000")
                || l.hasPrefix("new mode 120000") || l.hasPrefix("old mode 120000")
                || (l.hasPrefix("index ") && l.hasSuffix(" 120000")))
        }
        if isLink {
            for l in sec where (l.hasPrefix("+") && !l.hasPrefix("+++")) || (l.hasPrefix("-") && !l.hasPrefix("---")) {
                let target = l.dropFirst()
                if target.hasPrefix("/") || target.split(separator: "/").contains("..") { return true }
            }
        }
        return false
    }

    // MARK: pre-add sanitising

    /// Before `git add -A`: unlink FIFOs/sockets/devices (they hang or break git), leave symlinks alone,
    /// fail on any changed or untracked regular file over `maxFileBytes`, and on changed plus untracked
    /// files totalling over `maxChangedBytes`.
    private func prepareTreeForAdd(_ job: Job) async throws {
        var total: Int64 = 0, anyBig = false
        func walk(_ dir: String, _ top: Bool) {
            guard let d = opendir(dir) else { return }
            var names: [String] = []
            while let e = readdir(d) {
                names.append(withUnsafePointer(to: &e.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                })
            }
            closedir(d)
            for name in names where name != "." && name != ".." {
                if top && name == ".git" { continue }
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR: walk(path, false)
                case S_IFREG:
                    total += Int64(st.st_size)
                    if Int64(st.st_size) > Self.maxFileBytes { anyBig = true }
                case S_IFLNK: break
                default: unlink(path)
                }
            }
        }
        walk(job.top, true)
        guard anyBig || total > maxChangedBytes else { return }
        let changed = try await gitWorkRaw(job, ["ls-files", "-z", "-m", "-o", "--exclude-standard"])
        var sum: Int64 = 0
        for rel in changed.split(separator: "\0").map(String.init) {
            var st = stat()
            guard lstat(job.top + "/" + rel, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            if Int64(st.st_size) > Self.maxFileBytes { throw Failure.fileTooLarge(rel) }
            sum += Int64(st.st_size)
        }
        if sum > maxChangedBytes { throw Failure.changesTooLarge(sum) }
    }

    private func clone(_ cwd: String, to dir: String) async throws {
        do {
            try await Self.run("/bin/cp", ["-c", "-R", cwd, dir])
        } catch {
            guard cloneFallback else { throw error }
            try? FileManager.default.removeItem(atPath: dir)
            try await Self.run("/bin/cp", ["-R", cwd, dir])
        }
        Self.scrubClone(dir, rootName: URL(fileURLWithPath: cwd).lastPathComponent)
    }

    private func clonePatch(_ ws: Workspace) async throws -> String {
        guard let orig = origins[ws.root] else { throw Failure.unknownWorkspace(ws.root) }
        let p = try await Self.exec(try Self.gitExecutable(),
                                    Self.hardening + ["-c", "core.quotePath=false", "diff", "--no-index", "--binary", "--no-color",
                                                      "--no-ext-diff", "--no-textconv", orig, ws.root],
                                    cwd: "/", env: Self.env, timeout: gitTimeout, maxOut: maxPatchBytes)
        guard p.status == 0 || p.status == 1 else {  // 1 = differences found
            throw Failure.command("git diff --no-index", p.status, p.err)
        }
        return Self.dropSecretSections(Self.relabel(String(decoding: p.out, as: UTF8.self), orig: orig, clone: ws.root),
                                        rootName: URL(fileURLWithPath: orig).lastPathComponent)
    }

    /// `git diff --no-index` prints absolute paths; rewrite them to `a/` and `b/` repo-relative form.
    static func relabel(_ patch: String, orig: String, clone: String) -> String {
        let a = "a/" + stripLeadingSlash(orig) + "/"
        let b = "b/" + stripLeadingSlash(clone) + "/"
        return patch.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("diff --git ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") else { return String(line) }
            return String(line).replacingOccurrences(of: a, with: "a/").replacingOccurrences(of: b, with: "b/")
        }.joined(separator: "\n")
    }

    /// Job directory (`baseDir/<uuid>`) that contains `root`, or nil if `root` is outside `baseDir`.
    private func jobDir(_ root: String) -> String? {
        let prefix = baseDir.path + "/"
        guard root.hasPrefix(prefix), let name = root.dropFirst(prefix.count).split(separator: "/").first else { return nil }
        return prefix + name
    }

    /// Worktree-side git call: explicit git-dir and work-tree, no attributes (empty attribute source).
    private func gitWork(_ job: Job, _ args: [String]) async throws {
        _ = try await gitWorkRaw(job, args)
    }

    /// Sibling of `baseDir` (not inside it, so it never shows up as a job dir) and outside every sandbox-writable tree.
    private var hostRoot: String { baseDir.path + "-host-objects" }

    private func hostObjectsDir(_ jobDir: String) -> String {
        hostRoot + "/" + (jobDir as NSString).lastPathComponent
    }

    /// Removes agent-writable git config surfaces from the admin dir and validates the object quarantine:
    /// a real directory holding only 2-hex-char dirs of regular single-link files, plus `pack`; `info`
    /// (alternates) is deleted. Anything else (symlinks, hardlinks, strays) is `tampered`.
    static func sanitizeAdmin(_ job: Job, quarantine: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: job.adminDir + "/info")  // exclude, attributes, sparse-checkout, grafts
        func lst(_ p: String) -> stat? { var st = stat(); return lstat(p, &st) == 0 ? st : nil }
        guard let qs = lst(quarantine), (qs.st_mode & S_IFMT) == S_IFDIR else { throw Failure.tampered(quarantine) }
        try? fm.removeItem(atPath: quarantine + "/info")
        guard let top = try? fm.contentsOfDirectory(atPath: quarantine) else { throw Failure.tampered(quarantine) }
        let hex = Set("0123456789abcdef")
        for name in top {
            let path = quarantine + "/" + name
            guard let st = lst(path), (st.st_mode & S_IFMT) == S_IFDIR else { throw Failure.tampered(path) }
            guard name == "pack" || (name.count == 2 && name.allSatisfy { hex.contains($0) }) else {
                throw Failure.tampered(path)
            }
            guard let kids = try? fm.contentsOfDirectory(atPath: path) else { throw Failure.tampered(path) }
            for k in kids {
                let kp = path + "/" + k
                guard let ks = lst(kp), (ks.st_mode & S_IFMT) == S_IFREG, ks.st_nlink == 1 else { throw Failure.tampered(kp) }
            }
        }
    }

    /// The admin `index` is agent-writable (skip-worktree, assume-unchanged, forged entries): rebuild it
    /// from the recorded base tree. `.gitignore` files in the tree are still honoured (residual risk).
    private func rebuildIndex(_ job: Job) async throws {
        guard Self.matches(job) else { throw Failure.tampered(job.top) }
        for f in ["index", "index.lock", "sharedindex"] { try? FileManager.default.removeItem(atPath: job.adminDir + "/" + f) }
        _ = try await gitWorkRaw(job, ["read-tree", job.base])
    }

    private func gitWorkRaw(_ job: Job, _ args: [String]) async throws -> String {
        guard Self.matches(job) else { throw Failure.tampered(job.top) }
        // The admin config.worktree is agent-writable and would load filter/diff drivers; no legitimate
        // config lives there, so drop it before every host-side call (collectPatch runs after the agent exits).
        try? FileManager.default.removeItem(atPath: job.adminDir + "/config.worktree")
        var workEnv = Self.env
        workEnv["GIT_ATTR_SOURCE"] = Self.emptyTree
        // Host writes land in a host-owned dir outside every sandbox-writable tree; the validated sandbox
        // quarantine and the parent's store are read-only alternates.
        let quarantine = job.adminDir + "/" + Self.quarantineName
        try Self.sanitizeAdmin(job, quarantine: quarantine)
        let hostDir = hostObjectsDir(job.top)
        try FileManager.default.createDirectory(atPath: hostDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        workEnv["GIT_OBJECT_DIRECTORY"] = hostDir
        workEnv["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = quarantine + ":" + job.commonDir + "/objects"
        return try await Self.gitRaw(["--git-dir=" + job.adminDir, "--work-tree=" + job.top] + args,
                                     cwd: job.top, env: workEnv, timeout: gitTimeout, maxOut: maxPatchBytes)
    }

    /// Parent-side git call (trusted repo config), still hardened.
    @discardableResult
    private func git(_ args: [String], in cwd: String) async throws -> String {
        let out = try await Self.gitRaw(args, cwd: cwd, env: Self.env, timeout: gitTimeout, maxOut: maxPatchBytes)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gitRaw(_ args: [String], cwd: String, env: [String: String],
                               timeout: TimeInterval, maxOut: Int) async throws -> String {
        let p = try await exec(try gitExecutable(), hardening + args, cwd: cwd, env: env, timeout: timeout, maxOut: maxOut)
        guard p.status == 0 else {
            throw Failure.command("git " + args.joined(separator: " "), p.status, p.err)
        }
        return String(decoding: p.out, as: UTF8.self)
    }

    private static func trimSlash(_ s: String) -> String {
        s.hasSuffix("/") && s.count > 1 ? String(s.dropLast()) : s
    }

    private static func stripLeadingSlash(_ s: String) -> String {
        String(s.drop(while: { $0 == "/" }))
    }

    struct Proc: Sendable {
        var status: Int32
        var out: Data
        var err: String
    }

    /// Kill switch shared between the cancellation handler and the blocking worker.
    private final class ProcBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private(set) var cancelled = false
        func set(_ p: pid_t) -> Bool { lock.withLock { pid = p; return cancelled } }
        func cancel() { lock.withLock { cancelled = true; if pid > 0 { _ = Darwin.kill(-pid, SIGKILL) } } }
        func killGroup(_ sig: Int32) { lock.withLock { if pid > 0 { _ = Darwin.kill(-pid, sig) } } }
    }

    /// Runs a process in its own group. stdout and stderr are drained concurrently; stdout beyond `maxOut`
    /// kills the group and fails with `patchTooLarge`; stderr keeps its first `maxStderrBytes`. The group is
    /// SIGKILLed on timeout (`timedOut`) and on Task cancellation (`CancellationError`).
    static func exec(_ exe: String, _ args: [String], cwd: String, env: [String: String],
                             timeout: TimeInterval, maxOut: Int) async throws -> Proc {
        let box = ProcBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Proc, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(with: Result { try execBlocking(exe, args, cwd: cwd, env: env, timeout: timeout,
                                                                maxOut: maxOut, box: box) })
                }
            }
        } onCancel: { box.cancel() }
    }

    private static func execBlocking(_ exe: String, _ args: [String], cwd: String, env: [String: String],
                                     timeout: TimeInterval, maxOut: Int, box: ProcBox) throws -> Proc {
        func posixErr(_ what: String, _ code: Int32 = errno) -> NSError {
            NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(code)))"])
        }
        var o: [Int32] = [0, 0], e: [Int32] = [0, 0]
        guard pipe(&o) == 0 else { throw posixErr("pipe") }
        guard pipe(&e) == 0 else { close(o[0]); close(o[1]); throw posixErr("pipe") }
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, o[1], 1)
        posix_spawn_file_actions_adddup2(&fa, e[1], 2)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        let rc0 = posix_spawn_file_actions_addchdir_np(&fa, cwd)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var allSigs = sigset_t(), noSigs = sigset_t()
        sigfillset(&allSigs); sigemptyset(&noSigs)
        posix_spawnattr_setsigdefault(&attr, &allSigs)
        posix_spawnattr_setsigmask(&attr, &noSigs)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var cargs = ([exe] + args).map { strdup($0) } + [nil]
        var cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cargs { free(p) }; for p in cenv { free(p) } }
        var pid: pid_t = 0
        let rc = rc0 != 0 ? rc0 : posix_spawn(&pid, exe, &fa, &attr, &cargs, &cenv)
        close(o[1]); close(e[1])
        guard rc == 0 else { close(o[0]); close(e[0]); throw posixErr("spawn \(exe)", rc) }
        if box.set(pid) { box.killGroup(SIGKILL) }

        let state = NSLock()
        var out = Data(), err = Data(), overflow = false
        let readers = DispatchGroup()
        func drain(_ fd: Int32, _ sink: @escaping (UnsafeRawBufferPointer) -> Void) {
            readers.enter()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    buf.withUnsafeBytes { sink(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                }
                close(fd)
                readers.leave()
            }
        }
        drain(o[0]) { chunk in
            state.lock(); defer { state.unlock() }
            if overflow { return }
            if out.count + chunk.count > maxOut { overflow = true; box.killGroup(SIGKILL); return }
            out.append(contentsOf: chunk)
        }
        drain(e[0]) { chunk in
            state.lock(); defer { state.unlock() }
            if err.count < maxStderrBytes { err.append(contentsOf: chunk.prefix(maxStderrBytes - err.count)) }
        }

        let timedOutFlag = ManagedFlag()
        let killer = DispatchWorkItem { timedOutFlag.set(); box.killGroup(SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // Exit without reaping keeps pid/pgid reserved while the group is cleaned up.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
        killer.cancel()
        box.killGroup(SIGKILL)
        var st: Int32 = 0
        while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
        _ = readers.wait(timeout: .now() + 5)

        if box.cancelled { throw CancellationError() }
        let cmd = "git " + args.joined(separator: " ")
        if timedOutFlag.value { throw Failure.timedOut(cmd, timeout) }
        state.lock(); defer { state.unlock() }
        if overflow { throw Failure.patchTooLarge(maxOut) }
        let status: Int32 = (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
        return Proc(status: status, out: out, err: String(decoding: err, as: UTF8.self))
    }

    private final class ManagedFlag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.withLock { v = true } }
        var value: Bool { lock.withLock { v } }
    }

    private static func run(_ exe: String, _ args: [String]) async throws {
        let p = try await exec(exe, args, cwd: "/", env: env, timeout: 600, maxOut: 1 << 20)
        guard p.status == 0 else { throw Failure.command(exe + " " + args.joined(separator: " "), p.status, p.err) }
    }
}
