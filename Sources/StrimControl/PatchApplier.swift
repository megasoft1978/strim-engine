import Foundation
import StrimHarness

/// Applies a job's patch to the parent tree: `git apply --3way` run from the repo top, only after every path the
/// patch names has been validated twice (own header parse and git's own `--numstat -z`) to stay inside the
/// recorded cwd, avoid `.git`, symlinks and submodules. Git runs with the same hardening as `GitWorktreeIsolation`.
struct PatchApplier: Sendable {
    static let maxPatchBytes = 16 * 1024 * 1024
    var timeout: TimeInterval = 60

    // MARK: validation

    /// Rejects absolute, `~`, `..`, `.git` (any case), quoted and control-character paths.
    static func checkPath(_ p: String) throws {
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        let bad = p.isEmpty || p.hasPrefix("/") || p.hasPrefix("~") || p.hasPrefix("\"")
            || p.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0xFFFD }
            || parts.contains { $0.isEmpty || $0 == ".." || $0.lowercased() == ".git" }
        if bad { throw ControlError.unsafePatch("patch touches an unsafe path: \(p.prefix(120))") }
    }

    /// Paths named by the patch headers (hunk bodies are skipped by counting lines, like git does).
    static func headerPaths(_ patch: String) throws -> [String] {
        var out: [String] = []
        var inHunk = false
        var oldLeft = 0, newLeft = 0
        func stripPrefix(_ s: Substring, _ pre: String) throws -> String {
            guard s.hasPrefix(pre) else { throw ControlError.unsafePatch("unexpected path form: \(s.prefix(120))") }
            return String(s.dropFirst(pre.count))
        }
        func header(_ line: Substring, _ key: String) -> Substring? {
            line.hasPrefix(key) ? line.dropFirst(key.count) : nil
        }
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if inHunk {
                if oldLeft <= 0 && newLeft <= 0 && !line.hasPrefix("\\") { inHunk = false }
                else {
                    switch line.first {
                    case "-": oldLeft -= 1
                    case "+": newLeft -= 1
                    case "\\": break
                    default: oldLeft -= 1; newLeft -= 1     // ' ' and the blank context line
                    }
                    continue
                }
            }
            if line.hasPrefix("@@ ") {
                // @@ -a[,b] +c[,d] @@
                let f = line.split(separator: " ")
                guard f.count >= 3 else { throw ControlError.unsafePatch("malformed hunk header") }
                func count(_ s: Substring) -> Int {
                    let t = s.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
                    return t.count > 1 ? Int(t[1]) ?? 0 : 1
                }
                oldLeft = count(f[1]); newLeft = count(f[2]); inHunk = oldLeft > 0 || newLeft > 0
                continue
            }
            if let rest = header(line, "diff --git ") {
                if rest.contains("\"") { throw ControlError.unsafePatch("quoted path in diff header") }
                // `a/<p> b/<p>`: with spaces in names the split is ambiguous, so validate every candidate split.
                var from = rest.startIndex
                var found = false
                while let r = rest.range(of: " b/", range: from..<rest.endIndex) {
                    found = true
                    out.append(try stripPrefix(rest[..<r.lowerBound], "a/"))
                    out.append(String(rest[r.upperBound...]))
                    from = r.upperBound
                }
                if !found { throw ControlError.unsafePatch("malformed diff header") }
            } else if let rest = header(line, "--- ") ?? header(line, "+++ ") {
                let p = rest.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first ?? rest
                if p == "/dev/null" { continue }
                if p.hasPrefix("\"") { throw ControlError.unsafePatch("quoted path in file header") }
                guard p.hasPrefix("a/") || p.hasPrefix("b/") else { throw ControlError.unsafePatch("unexpected file header: \(p.prefix(120))") }
                out.append(String(p.dropFirst(2)))
            } else if let p = header(line, "rename from ") ?? header(line, "rename to ")
                        ?? header(line, "copy from ") ?? header(line, "copy to ") {
                out.append(String(p))
            } else if line.hasPrefix("new file mode ") || line.hasPrefix("new mode ") || line.hasPrefix("old mode ") {
                let mode = line.split(separator: " ").last.map(String.init) ?? ""
                if mode.hasPrefix("12") || mode.hasPrefix("16") { throw ControlError.unsafePatch("patch creates a symlink or submodule") }
            } else if line.hasPrefix("index "), let last = line.split(separator: " ").last,
                      last == "120000" || last == "160000" {
                throw ControlError.unsafePatch("patch touches a symlink or submodule")
            }
        }
        return out
    }

    /// Paths from `git apply --numstat -z` output.
    static func numstatPaths(_ out: Data) -> [String] {
        let toks = out.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var paths: [String] = []
        var i = 0
        while i < toks.count {
            let t = toks[i]; i += 1
            if t.isEmpty { continue }
            let f = t.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3 else { paths.append(t); continue }
            if f[2].isEmpty {                       // rename/copy: the next two tokens are old and new
                for _ in 0..<2 where i < toks.count { paths.append(toks[i]); i += 1 }
            } else {
                paths.append(String(f[2]))
            }
        }
        return paths
    }

    static func realPath(_ p: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(p, &buf) != nil else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Every path lies under `cwdReal`, also after resolving symlinks of its deepest existing ancestor.
    static func confine(_ paths: [String], top: String, cwdReal: String) throws {
        for rel in Set(paths) {
            try checkPath(rel)
            var abs = top + "/" + rel
            guard abs.hasPrefix(cwdReal + "/") else {
                throw ControlError.unsafePatch("patch path \(rel.prefix(120)) is outside the job's directory")
            }
            while abs != "/", realPath(abs) == nil { abs = (abs as NSString).deletingLastPathComponent }
            if let r = realPath(abs), !(r == cwdReal || r.hasPrefix(cwdReal + "/")) {
                throw ControlError.unsafePatch("patch path \(rel.prefix(120)) resolves outside the job's directory")
            }
        }
    }

    // MARK: apply

    func apply(patch bytes: Data, cwd: String) async throws {
        guard bytes.count <= Self.maxPatchBytes else { throw ControlError.unsafePatch("patch too large") }
        let patch = String(decoding: bytes, as: UTF8.self)
        guard let cwdReal = Self.realPath(cwd) else { throw ControlError.conflict("job directory \(cwd) no longer exists") }
        let data = bytes
        let topOut = try await Git.run(["rev-parse", "--show-toplevel"], cwd: cwdReal, stdin: nil, timeout: timeout)
        guard topOut.status == 0, let top = Self.realPath(topOut.out.trimmed) else {
            throw ControlError.badRequest("\(cwd) is not inside a git repository")
        }
        guard cwdReal == top || cwdReal.hasPrefix(top + "/") else { throw ControlError.badRequest("cwd is not inside its repo") }

        try await RepoSafety.check(top: top, timeout: timeout)

        let own = try Self.headerPaths(patch)
        let num = try await Git.run(["apply", "--numstat", "-z"], cwd: top, stdin: data, timeout: timeout)
        try Self.expectCompleted(num, what: "git apply --numstat", top: top, timeout: timeout)
        guard num.status == 0 else {
            throw ControlError.unsafePatch("git rejected the patch: \(Sanitize.text(num.err, limit: 300))")
        }
        let theirs = Self.numstatPaths(num.outData)
        guard !theirs.isEmpty else { throw ControlError.badRequest("patch changes nothing") }
        try Self.confine(own + theirs, top: top, cwdReal: cwdReal)

        // Plain apply (no --3way: the merge fallback consults repo-controlled merge drivers and attributes).
        let check = try await Git.run(["apply", "--check", "--whitespace=nowarn"], cwd: top, stdin: data, timeout: timeout)
        try Self.expectCompleted(check, what: "git apply --check", top: top, timeout: timeout)
        guard check.status == 0 else {
            throw ControlError(409, "apply_conflict", "the patch does not apply cleanly: \(Sanitize.text(check.err, limit: 500))")
        }
        let res = try await Git.run(["apply", "--whitespace=nowarn"], cwd: top, stdin: data, timeout: timeout)
        if res.timedOut || res.signal != nil {
            try await Self.expectCompletedReportingTree(res, top: top, timeout: timeout)
        }
        guard res.status == 0 else {
            throw ControlError(409, "apply_conflict", "git apply failed: \(Sanitize.text(res.err, limit: 500))")
        }
    }

    /// Timeout or crash -> typed error.
    static func expectCompleted(_ r: Git.Result, what: String, top: String, timeout: TimeInterval) throws {
        if r.timedOut { throw ControlError(500, "apply_timeout", "\(what) timed out after \(Int(timeout))s and was killed") }
        if let sig = r.signal { throw ControlError.internalError("\(what) crashed (signal \(sig))") }
    }

    /// The write step failed hard: say what state the tree is in, because a half-applied patch must be visible.
    static func expectCompletedReportingTree(_ r: Git.Result, top: String, timeout: TimeInterval) async throws {
        let st = try? await Git.run(["status", "--porcelain"], cwd: top, stdin: nil, timeout: 20)
        let tree: String
        if let st, st.status == 0 {
            let n = st.out.split(separator: "\n").count
            tree = n == 0 ? "working tree is clean" : "working tree has \(n) modified path(s): inspect with git status"
        } else {
            tree = "working tree state unknown"
        }
        if r.timedOut { throw ControlError(500, "apply_timeout", "git apply timed out after \(Int(timeout))s and was killed; \(tree)") }
        throw ControlError(500, "apply_crashed", "git apply crashed (signal \(r.signal ?? 0)); \(tree)")
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Sanitize {
    /// Printable text only: control characters (incl. newlines, ESC) become spaces; length-capped.
    static func text(_ s: String, limit: Int = 300) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.prefix(limit * 2).map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }))
            .trimmingCharacters(in: .whitespaces).prefix(limit).description
    }
}

/// Minimal hardened git runner (same flags and scrubbed environment as `GitWorktreeIsolation`, which keeps them
/// internal). Runs git in its own process group; a timeout kills the whole group; waits for pipe EOF are bounded.
enum Git {
    struct Result {
        var status: Int32
        var outData: Data
        var err: String
        var signal: Int32?
        var timedOut: Bool
        var out: String { String(decoding: outData, as: UTF8.self) }
    }

    static let hardening: [String] = [
        "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.attributesFile=/dev/null",
        "-c", "core.pager=cat", "-c", "core.excludesFile=/dev/null", "-c", "core.sparseCheckout=false",
        "-c", "core.untrackedCache=false", "-c", "core.sshCommand=/usr/bin/false", "-c", "protocol.allow=never",
        "-c", "diff.external=", "-c", "extensions.worktreeConfig=false",
    ]
    static let env: [String: String] = [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory(),
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ATTR_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
        "GIT_AUTHOR_NAME": "strim", "GIT_AUTHOR_EMAIL": "strim@localhost",
        "GIT_COMMITTER_NAME": "strim", "GIT_COMMITTER_EMAIL": "strim@localhost",
    ]
    static let maxOut = 4 * 1024 * 1024
    static let maxErr = 64 * 1024

    static func run(_ args: [String], cwd: String, stdin: Data?, timeout: TimeInterval) async throws -> Result {
        guard let exe = SandboxProfile.trustedGitPath else { throw ControlError.unavailable("no trusted git binary found") }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Swift.Result { try runBlocking(exe, hardening + args, cwd: cwd, stdin: stdin, timeout: timeout) })
            }
        }
    }

    private static func runBlocking(_ exe: String, _ args: [String], cwd: String, stdin: Data?, timeout: TimeInterval) throws -> Result {
        var inP: [Int32] = [0, 0], outP: [Int32] = [0, 0], errP: [Int32] = [0, 0]
        guard pipe(&inP) == 0, pipe(&outP) == 0, pipe(&errP) == 0 else { throw ControlError.internalError("pipe failed") }
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, inP[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outP[1], 1)
        posix_spawn_file_actions_adddup2(&fa, errP[1], 2)
        for fd in [inP[0], inP[1], outP[0], outP[1], errP[0], errP[1]] { posix_spawn_file_actions_addclose(&fa, fd) }
        posix_spawn_file_actions_addchdir_np(&fa, cwd)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &fa, &attr, argv, envp)
        close(inP[0]); close(outP[1]); close(errP[1])
        guard rc == 0 else {
            close(inP[1]); close(outP[0]); close(errP[0])
            throw ControlError.internalError("cannot run git (errno \(rc))")
        }
        for fd in [inP[1], outP[0], errP[0]] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }

        var input = stdin ?? Data()
        var inOpen = true, outOpen = true, errOpen = true
        if input.isEmpty { close(inP[1]); inOpen = false }
        var outData = Data(), errData = Data()
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 65536)
        while outOpen || errOpen {
            var fds: [pollfd] = []
            if outOpen { fds.append(pollfd(fd: outP[0], events: Int16(POLLIN), revents: 0)) }
            if errOpen { fds.append(pollfd(fd: errP[0], events: Int16(POLLIN), revents: 0)) }
            if inOpen { fds.append(pollfd(fd: inP[1], events: Int16(POLLOUT), revents: 0)) }
            if Date() >= deadline { timedOut = true; break }
            _ = poll(&fds, nfds_t(fds.count), 100)
            for f in fds where f.revents != 0 {
                if f.fd == inP[1] {
                    let n = input.withUnsafeBytes { write(inP[1], $0.baseAddress, min($0.count, 65536)) }
                    if n > 0 { input.removeFirst(n) }
                    if n < 0 && errno != EAGAIN || input.isEmpty { close(inP[1]); inOpen = false }
                } else {
                    let n = read(f.fd, &buf, buf.count)
                    if n > 0 {
                        if f.fd == outP[0] { if outData.count < maxOut { outData.append(contentsOf: buf[0..<n]) } }
                        else if errData.count < maxErr { errData.append(contentsOf: buf[0..<n]) }
                    } else if n == 0 || errno != EAGAIN {
                        close(f.fd)
                        if f.fd == outP[0] { outOpen = false } else { errOpen = false }
                    }
                }
            }
        }
        if timedOut { kill(-pid, SIGKILL) }
        if inOpen { close(inP[1]) }
        if outOpen { close(outP[0]) }
        if errOpen { close(errP[0]) }
        // Pipes are closed; wait for the exit, bounded, then kill the group.
        var st: Int32 = 0
        var waited = false
        for _ in 0..<100 {
            if waitpid(pid, &st, WNOHANG) == pid { waited = true; break }
            usleep(20_000)
        }
        if !waited { kill(-pid, SIGKILL); timedOut = true; waitpid(pid, &st, 0) }
        let sig = st & 0x7f
        let signaled = sig != 0 && sig != 0x7f
        return Result(status: signaled ? -1 : (st >> 8) & 0xff, outData: outData,
                      err: String(decoding: errData, as: UTF8.self), signal: signaled && !timedOut ? sig : nil, timedOut: timedOut)
    }
}
