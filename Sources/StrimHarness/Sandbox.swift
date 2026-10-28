import Foundation

/// Builds an inline `sandbox-exec` (SBPL) profile. Named profiles (`-n`) crash, so the profile is
/// always passed as a string via `-p`. SBPL is last-match-wins, so the order below matters:
/// broad deny, then narrow allow, then the secret read denies last.
public struct SandboxProfile: Sendable, Equatable {
    public var access: AccessLevel
    /// Directories writable in `.write` mode (e.g. the job worktree).
    public var writableRoots: [String]
    /// Per-job temp dir; always writable, even for `.read`.
    public var jobTmp: String
    public var home: String
    /// Extra writable git dirs (worktree gitdir `<common>/worktrees/<id>`, `<common>/objects`,
    /// `<common>/refs`, which is write-denied again below) so git works inside a worktree whose `.git` is a file. Only in `.write` mode.
    public var gitWritable: [String]
    /// Git control dirs (the common gitdir) whose `hooks/`, `config*`, refs and packed-refs are always write-denied.
    public var gitControlDirs: [String]
    /// Extra read-only roots under /Users or the real home that tools need (e.g. `~/.cargo`, a pyenv).
    /// Everything else under /Users and the real home is unreadable; the secret denies still win.
    public var extraReadable: [String]

    public init(access: AccessLevel, writableRoots: [String] = [], jobTmp: String,
                home: String = NSHomeDirectory(), gitWritable: [String] = [], gitControlDirs: [String] = [],
                extraReadable: [String] = []) {
        self.access = access; self.writableRoots = writableRoots; self.jobTmp = jobTmp; self.home = home
        self.gitWritable = gitWritable; self.gitControlDirs = gitControlDirs; self.extraReadable = extraReadable
    }

    /// World-shared temp locations (real paths): `/tmp`, `/var/tmp` and the per-user `$TMPDIR`. The per-user caches (`C`) stay readable.
    static func tempAreas() -> [String] {
        var out = Set<String>()
        for p in ["/tmp", "/var/tmp", NSTemporaryDirectory()] {
            let t = p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
            for v in variants(t) { out.insert(v) }
        }
        return out.sorted()
    }

    /// Case-insensitive regex fragment (APFS is case-insensitive): `.git` -> `\.[gG][iI][tT]`.
    static func ci(_ s: String) -> String {
        s.map { c in
            c.isLetter ? "[\(c.lowercased())\(c.uppercased())]" : regexEscape(String(c))
        }.joined()
    }

    static let secretSubpaths = [".ssh", ".aws", ".gnupg", ".codex", "Library/Keychains", ".config/gh"]
    static let secretLiterals = [".strim/token", ".netrc"]

    /// Quote a string for an SBPL string literal.
    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }

    /// Escape regex metacharacters (POSIX ERE), for use before `quote`.
    static func regexEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\^$.|?*+()[]{}".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// The path plus its symlink-resolved form (`/tmp` -> `/private/tmp`); sandbox matches real paths.
    static func variants(_ path: String) -> [String] {
        // realpath(3), not Foundation's resolvingSymlinksInPath (which strips `/private`).
        guard let r = realpath(path, nil) else { return [path] }
        defer { free(r) }
        let resolved = String(cString: r)
        return resolved == path ? [path] : [path, resolved]
    }

    /// A real (non-xcrun-shim) git for use inside the sandbox and by host code that operates on
    /// agent-writable trees. `/usr/bin/git` is an xcrun shim that reads/writes `xcrun_db*` cache files
    /// in the user temp dir; an agent that could poison that cache could redirect host tool resolution.
    public static let trustedGitPath: String? = [
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        "/opt/homebrew/bin/git",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// `/a/b/c` -> `["/", "/a", "/a/b"]`: ancestors of `path`, stat-able so cwd/realpath resolution works.
    static func ancestors(_ path: String) -> [String] {
        var out: [String] = [], cur = (path as NSString).deletingLastPathComponent
        while cur != "/" && !cur.isEmpty { out.append(cur); cur = (cur as NSString).deletingLastPathComponent }
        return out
    }

    /// Common git dirs: the control dirs plus any derived from `objects`, `refs`, `logs/refs` entries.
    var commonDirs: [String] {
        var out = gitControlDirs
        for g in gitWritable {
            for suffix in ["/logs/refs", "/objects", "/refs"] where g.hasSuffix(suffix) {
                out.append(String(g.dropLast(suffix.count)))
                break
            }
        }
        return out
    }

    public var profile: String {
        // network*: no sockets. signal/process-info*: only self and same-sandbox processes (the
        // `(target others)` filter is a no-op on current macOS, so deny all and allow back).
        // mach-lookup: denied entirely. That blocks LaunchServices (`open`), Apple events, pasteboard,
        // securityd/keychain, mDNSResponder/DNS, opendirectory, tccd, accessibility; git, python,
        // swift/clang, coreutils and curl (failing on the network) were verified to run without it.
        // ipc-posix-shm*/iokit-open: no cross-process shared memory or device access (git, python3,
        // clang, swiftc verified without them). Path matching: sandbox canonicalises case for
        // subpath/literal on APFS (probed: /users, /USERS, mixed-case secret paths are denied).
        // Hard links: a link needs write on its source, so non-writable (protected/system) files
        // cannot be linked in, and links out into protected paths hit the write denies.
        // Note: the `/usr/bin/{clang,swiftc}` xcrun shims cannot run in the sandbox (their xcrun_db
        // cache write is deliberately not allowed); use the toolchain binaries directly with SDKROOT.
        // Without mach-lookup, confstr(_CS_DARWIN_USER_CACHE_DIR) fails so swiftc falls back to $HOME caches.
        var p = "(version 1)\n(allow default)\n(deny network*)\n"
        p += "(deny signal)\n(allow signal (target self) (target same-sandbox))\n"
        p += "(deny process-info*)\n(allow process-info* (target self) (target same-sandbox))\n"
        p += "(deny mach-lookup)\n(deny ipc-posix-shm*)\n(deny iokit-open)\n(deny file-write*)\n"
        var allow: [String] = []
        for r in (access == .write ? writableRoots : []) + [jobTmp] {
            for v in Self.variants(r) { allow.append("(subpath \(Self.quote(v)))") }
        }
        for d in ["/dev/null", "/dev/tty", "/dev/dtracehelper"] { allow.append("(literal \(Self.quote(d)))") }
        if access == .write {
            for g in gitWritable { for v in Self.variants(g) { allow.append("(subpath \(Self.quote(v)))") } }
        }
        p += "(allow file-write*\n  " + allow.joined(separator: "\n  ") + ")\n"

        // Git control paths stay write-denied (hooks run outside the sandbox later). Must follow the allow.
        func denyRegex(_ r: String) -> String { "(regex \(Self.quote("^" + r)))" }
        var gitDeny: [String] = []
        // hooks/**, info/** (attributes/exclude steer filters), config, config.worktree, commondir, gitdir.
        let controlTail = "/(" + ["hooks", "info"].map { Self.ci($0) + "(/.*)?" }.joined(separator: "|") + "|"
            + Self.ci("config") + "(\\." + Self.ci("worktree") + ")?|" + Self.ci("commondir") + "|" + Self.ci("gitdir") + ")$"
        for r in writableRoots {
            for v in Self.variants(r) {
                let git = Self.regexEscape(v) + "/" + Self.ci(".git")
                gitDeny.append(denyRegex(git + "$"))  // `.git` itself: rewriting the worktree pointer file
                gitDeny.append(denyRegex(git + controlTail))
            }
        }
        for g in gitWritable + gitControlDirs {
            for v in Self.variants(g) { gitDeny.append(denyRegex(Self.regexEscape(v) + controlTail)) }
        }
        if !gitDeny.isEmpty { p += "(deny file-write*\n  " + gitDeny.joined(separator: "\n  ") + ")\n" }

        // A detached worktree needs only its admin dir and objects: the shared refs (branches, tags,
        // packed-refs, reflogs, common HEAD) are never writable, even if the caller passed them.
        var refDeny: [String] = []
        for c in commonDirs {
            for v in Self.variants(c) {
                for sub in ["refs", "logs/refs"] { refDeny.append("(subpath \(Self.quote(v + "/" + sub)))") }
                // Case-insensitive regexes, not literals (APFS is case-insensitive).
                let names = ["refs", "logs", "packed-refs", "HEAD", "ORIG_HEAD", "FETCH_HEAD", "index"]
                    .map { Self.ci($0) + "(/.*)?" }.joined(separator: "|")
                refDeny.append("(regex \(Self.quote("^" + Self.regexEscape(v) + "/(" + names + ")$")))")
            }
        }
        if !refDeny.isEmpty { p += "(deny file-write*\n  " + refDeny.joined(separator: "\n  ") + ")\n" }

        // Reads: everything under /Users, /Volumes and the real home is denied, then only the workspace, job
        // tmp, git dirs and explicit extras are allowed back. Secret denies below still win.
        let homes = Self.variants(home)
        var userDeny = ["(subpath \"/Users\")", "(subpath \"/Volumes\")"]
        for h in homes { userDeny.append("(subpath \(Self.quote(h)))") }
        // Shared temp areas too: tools of the same user leave secrets in $TMPDIR, /tmp and /var/tmp (for example a copied
        // auth.json). Only the job's own dirs and the explicit roots below are re-allowed.
        for t in Self.tempAreas() { userDeny.append("(subpath \(Self.quote(t)))") }
        p += "(deny file-read*\n  " + userDeny.joined(separator: "\n  ") + ")\n"
        var readRoots = writableRoots + [jobTmp] + gitWritable + gitControlDirs + extraReadable
        // Only roots under a denied region need re-allowing; everything else is already readable.
        let denied = ["/Users", "/Volumes"] + homes + Self.tempAreas()
        readRoots = readRoots.flatMap(Self.variants).filter { r in
            denied.contains { r == $0 || r.hasPrefix($0 + "/") }
        }
        if !readRoots.isEmpty {
            p += "(allow file-read*\n  " + readRoots.map { "(subpath \(Self.quote($0)))" }.joined(separator: "\n  ") + ")\n"
        }
        // Ancestors of allowed roots: metadata only (stat/realpath/getcwd), no directory listing.
        let anc = Set(readRoots.flatMap(Self.ancestors)).sorted()
        if !anc.isEmpty {
            p += "(allow file-read-metadata\n  " + anc.map { "(literal \(Self.quote($0)))" }.joined(separator: "\n  ") + ")\n"
        }

        var deny: [String] = []
        for h in homes {
            for s in Self.secretSubpaths { deny.append("(subpath \(Self.quote(h + "/" + s)))") }
            for l in Self.secretLiterals { deny.append("(literal \(Self.quote(h + "/" + l)))") }
            deny.append("(regex \(Self.quote("^" + Self.regexEscape(h + "/.claude"))))")  // ~/.claude*
        }
        // Credential-like files in the common git dir. `config` itself must stay readable: git
        // refuses to run without it (fatal "unable to access .../config"), so callers must redact
        // remote URLs/tokens from output instead.
        for c in commonDirs {
            for v in Self.variants(c) {
                let e = Self.regexEscape(v)
                deny.append("(regex \(Self.quote("^" + e + "/" + Self.ci("credentials") + "[^/]*$")))")
                deny.append("(regex \(Self.quote("^" + e + "/.*" + Self.ci(".pem") + "$")))")
            }
        }
        p += "(deny file-read*\n  " + deny.joined(separator: "\n  ") + ")\n"
        return p
    }
}
