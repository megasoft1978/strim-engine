import Foundation
import Darwin

/// Runs a shell command under `sandbox-exec` in its own session/process group, with a scrubbed
/// environment, a timeout (SIGTERM, then SIGKILL to the whole group) and a head+tail output cap.
public struct ProcessRunner: CommandRunner {
    public var profile: SandboxProfile
    /// Extra environment variable names copied from the parent process.
    public var passthroughEnv: [String]
    /// Seconds between SIGTERM and SIGKILL on timeout.
    public var killGrace: TimeInterval
    /// `false` only for tests of the runner itself.
    public var sandboxed: Bool
    /// `ulimit -f` (1024-byte blocks) set before the command in sandboxed runs; 0 disables.
    public var maxFileSizeKB: Int
    /// `ulimit -u` = the user's current process count + this margin; 0 disables. Plain `ulimit` sets soft and
    /// hard, so the agent cannot raise either.
    public var processMargin: Int
    /// Adds the language toolchains (`Toolchains`): their bin dirs on PATH, offline settings, caches under the job tmp, code-injection
    /// variables absent. The matching read grants live in the profile (`BashTool.makeRunner`).
    public var toolchains: Bool

    public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

    public init(profile: SandboxProfile, passthroughEnv: [String] = [], killGrace: TimeInterval = 1,
                sandboxed: Bool = true, maxFileSizeKB: Int = 512 * 1024, processMargin: Int = 256, toolchains: Bool = false) {
        self.toolchains = toolchains
        self.profile = profile; self.passthroughEnv = passthroughEnv
        self.killGrace = killGrace; self.sandboxed = sandboxed
        self.maxFileSizeKB = maxFileSizeKB; self.processMargin = processMargin
    }

    func buildEnv(_ extra: [String: String]) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var e: [String: String] = [
            // Real git first: the /usr/bin/git xcrun shim needs a writable cache dir the sandbox denies.
            "PATH": (SandboxProfile.trustedGitPath.map { ($0 as NSString).deletingLastPathComponent + ":" } ?? "")
                + Self.defaultPath,
            "LANG": parent["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": profile.jobTmp,
            "HOME": profile.jobTmp + "/home",
        ]
        // Object-store quarantine: new objects go to the per-job dir, the parent's objects are read-only
        // alternates (the sandbox profile does not allow writing `<common>/objects`).
        if let q = profile.gitWritable.first(where: { $0.hasSuffix("/" + GitWorktreeIsolation.quarantineName) }) {
            e["GIT_OBJECT_DIRECTORY"] = q
            e["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = profile.gitControlDirs.map { $0 + "/objects" }.joined(separator: ":")
        }
        for k in passthroughEnv { if let v = parent[k] { e[k] = v } }
        if toolchains { Toolchains.apply(to: &e, home: profile.home, scratch: profile.jobTmp) }   // after passthrough: injection variables stay cleared
        for (k, v) in extra { e[k] = v }
        return e
    }

    public func run(_ command: String, cwd: String, env: [String: String],
                    timeout: TimeInterval, outputCap: Int) async throws -> CommandOutput {
        let fm = FileManager.default
        try fm.createDirectory(atPath: profile.jobTmp + "/home", withIntermediateDirectories: true)
        var argv = [String]()
        let tags = sandboxed ? JobTags.make(profile: profile) : nil
        defer { tags?.remove() }
        if sandboxed { argv += ["/usr/bin/sandbox-exec", "-p", profile.profile + (tags?.profileRules ?? "")] }
        var script = command
        if sandboxed {
            var pre = ""
            if maxFileSizeKB > 0 { pre += "ulimit -f \(maxFileSizeKB) || exit 125; " }
            if processMargin > 0 {
                let mine = getuid()
                let n = Job.allPids().filter { Job.bsdInfo($0).map { $0.pbi_uid == mine } ?? false }.count
                pre += "ulimit -u \(n + processMargin) || exit 125; "
            }
            script = pre + command
        }
        argv += ["/bin/bash", "--noprofile", "--norc", "-c", script]
        let marker = "STRIM_JOB=" + UUID().uuidString
        let envp = buildEnv(env).map { "\($0.key)=\($0.value)" } + [marker]

        let job = try Job.spawn(argv: argv, env: envp, cwd: cwd, cap: max(outputCap, 0), marker: marker, tags: tags)
        return await withTaskCancellationHandler {
            await job.wait(timeout: timeout, grace: killGrace)
        } onCancel: {
            job.killAll(SIGKILL)
        }
    }
}

/// One spawned process group plus its output pump. Descendants that leave the group (setsid) are found
/// by tree walk (ppid, polled while running) and by an env marker (`STRIM_JOB=<uuid>`, survives
/// reparenting to launchd), and are SIGKILLed once the leader exits.
fileprivate final class Job: @unchecked Sendable {
    let pid: pid_t
    let readFD: Int32
    let cap: Int
    let marker: String
    private let lock = NSLock()
    private var head = Data()
    private var tail = [UInt8](), tailIdx = 0, total = 0
    private var timedOut = false
    private var reaped = false
    private var stopPump = false
    private var known: [pid_t: UInt64] = [:]  // descendant pid -> start time (guards against pid reuse)

    private let tags: JobTags?

    private init(pid: pid_t, readFD: Int32, cap: Int, marker: String, tags: JobTags?) {
        self.pid = pid; self.readFD = readFD; self.cap = cap; self.marker = marker; self.tags = tags
    }

    static func spawn(argv: [String], env: [String], cwd: String, cap: Int, marker: String, tags: JobTags?) throws -> Job {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw posixError("pipe") }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 2)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&fa, fds[0])
        posix_spawn_file_actions_addclose(&fa, fds[1])
        // Set cwd for the child only (macOS 10.15+).
        let rc0 = posix_spawn_file_actions_addchdir_np(&fa, cwd)
        guard rc0 == 0 else { close(fds[0]); close(fds[1]); throw posixError("chdir", rc0) }
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New session => new process group led by the child; also detaches from the controlling tty.
        // The parent may ignore SIGINT/SIGTERM (server mode); the child must start with default dispositions
        // and an empty mask, or it would shrug off SIGTERM.
        var allSigs = sigset_t(), noSigs = sigset_t()
        sigfillset(&allSigs); sigemptyset(&noSigs)
        posix_spawnattr_setsigdefault(&attr, &allSigs)
        posix_spawnattr_setsigmask(&attr, &noSigs)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var cargs = argv.map { strdup($0) } + [nil]
        var cenv = env.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) }; for p in cenv { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &fa, &attr, &cargs, &cenv)
        close(fds[1])
        guard rc == 0 else { close(fds[0]); throw posixError("posix_spawn \(argv[0])", rc) }
        let job = Job(pid: pid, readFD: fds[0], cap: cap, marker: marker, tags: tags)
        Thread.detachNewThread { job.pump() }
        Thread.detachNewThread { job.poll() }
        return job
    }

    static func posixError(_ what: String, _ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(code)))"])
    }

    private let pumpDone = DispatchSemaphore(value: 0)

    private func appendTail(_ p: UnsafeBufferPointer<UInt8>, tailCap: Int) {
        guard tailCap > 0 else { return }
        var src = p[...]
        if src.count >= tailCap { src = src.suffix(tailCap) }
        for b in src {
            if tail.count < tailCap { tail.append(b) } else { tail[tailIdx] = b; tailIdx = (tailIdx + 1) % tailCap }
        }
    }

    /// Drains the pipe until EOF or `stopPump`, keeping the first cap/2 bytes and a ring of the last cap/2.
    private func pump() {
        let headCap = cap / 2 + cap % 2, tailCap = cap / 2
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let pr = Darwin.poll(&pfd, 1, 100)
            let stop = lock.withLock { stopPump }
            if pr < 0 && errno != EINTR { break }
            if pr <= 0 && !stop { continue }
            // Readable, hung up, or stop requested: drain what is there.
            var eof = false
            while true {
                let n = buf.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN { break }
                if n <= 0 { eof = true; break }
                lock.lock()
                total += n
                buf.withUnsafeBufferPointer { bp in
                    var chunk = UnsafeBufferPointer(rebasing: bp[0..<n])
                    if head.count < headCap {
                        let take = min(headCap - head.count, n)
                        head.append(contentsOf: chunk.prefix(take))
                        chunk = UnsafeBufferPointer(rebasing: chunk[take...])
                    }
                    if !chunk.isEmpty { appendTail(chunk, tailCap: tailCap) }
                }
                lock.unlock()
            }
            if eof || stop { break }
        }
        close(readFD)
        pumpDone.signal()
    }

    // MARK: process tree

    private static func startTime(_ info: proc_bsdinfo) -> UInt64 {
        info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    fileprivate static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(Int(got), 0))).filter { $0 > 0 }
    }

    fileprivate static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz ? info : nil
    }

    /// True when the process args/env (KERN_PROCARGS2) contain this job's marker.
    private func hasMarker(_ p: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, p]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return false }
        let needle = Array((marker + "\0").utf8)
        return buf.withUnsafeBytes { b in
            memmem(b.baseAddress, size, needle, needle.count) != nil
        }
    }

    /// Records current descendants of the leader (ppid walk) into `known`.
    private func snapshotTree() {
        var infos: [pid_t: proc_bsdinfo] = [:]
        for p in Self.allPids() { if let i = Self.bsdInfo(p) { infos[p] = i } }
        var frontier: Set<pid_t> = [pid]
        lock.lock(); defer { lock.unlock() }
        for p in known.keys { frontier.insert(p) }
        var changed = true
        while changed {
            changed = false
            for (p, i) in infos where frontier.contains(pid_t(i.pbi_ppid)) && known[p] == nil && p != pid {
                known[p] = Self.startTime(i); frontier.insert(p); changed = true
            }
        }
    }

    private func poll() {
        while true {
            let done = lock.withLock { reaped || stopPump }
            if done { return }
            snapshotTree()
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Live pids that belong to this job: tracked descendants (start time must match) plus marker holders.
    private func livePids() -> [pid_t] {
        snapshotTree()
        let tracked = lock.withLock { known }
        var out = Set<pid_t>()
        for (p, st) in tracked { if let i = Self.bsdInfo(p), Self.startTime(i) == st, i.pbi_status != UInt32(SZOMB) { out.insert(p) } }
        let me = getpid()
        for p in Self.allPids() where p != me && p != pid && !out.contains(p) {
            // Sandbox tag: every process in the job's sandbox, however it was reparented or what env it has.
            if let t = tags, t.contains(p), let i = Self.bsdInfo(p), i.pbi_status != UInt32(SZOMB) { out.insert(p); continue }
            if let i = Self.bsdInfo(p), i.pbi_status != UInt32(SZOMB), hasMarker(p) { out.insert(p) }
        }
        return Array(out)
    }

    /// Signals the leader's group (only while the leader is unreaped, so the pgid cannot be reused) and
    /// every descendant, setsid'd or orphaned or not. For SIGKILL, repeats until none remain (bounded).
    func killAll(_ sig: Int32) {
        let rounds = sig == SIGKILL ? 10 : 1
        for _ in 0..<rounds {
            lock.lock()
            if !reaped { _ = Darwin.kill(-pid, sig); _ = Darwin.kill(pid, sig) }
            lock.unlock()
            let victims = livePids()
            for v in victims { _ = Darwin.kill(v, sig) }
            if victims.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func wait(timeout: TimeInterval, grace: TimeInterval) async -> CommandOutput {
        let timer = DispatchQueue(label: "strim.runner.timeout")
        let hard = DispatchWorkItem { [self] in killAll(SIGKILL) }
        let item = DispatchWorkItem { [self] in
            lock.lock(); timedOut = true; lock.unlock()
            killAll(SIGTERM)
            timer.asyncAfter(deadline: .now() + grace, execute: hard)
        }
        timer.asyncAfter(deadline: .now() + timeout, execute: item)
        let status: Int32 = await withCheckedContinuation { cont in
            DispatchQueue.global().async { [self] in
                // Wait for exit without reaping, so the pid/pgid stay reserved while we kill the tree.
                var info = siginfo_t()
                while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
                killAll(SIGKILL)
                var st: Int32 = 0
                lock.lock()
                while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
                reaped = true
                lock.unlock()
                cont.resume(returning: st)
            }
        }
        item.cancel(); hard.cancel()
        // Give the pump a moment to see EOF; a survivor holding the pipe must not hang the runner.
        let waited: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global().async { [pumpDone] in
                if pumpDone.wait(timeout: .now() + 1) == .success { cont.resume(returning: true); return }
                self.lock.withLock { self.stopPump = true }
                cont.resume(returning: pumpDone.wait(timeout: .now() + 2) == .success)
            }
        }
        lock.withLock { stopPump = true }
        _ = waited
        let (head, tail, tailIdx, total, timedOut) = lock.withLock { (self.head, self.tail, self.tailIdx, self.total, self.timedOut) }
        let truncated = total > cap
        var out = head
        if truncated {
            let dropped = total - head.count - tail.count
            out.append(Data("\n...[truncated \(dropped) bytes]...\n".utf8))
            out.append(contentsOf: tail[tailIdx...]); out.append(contentsOf: tail[..<tailIdx])
        }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return CommandOutput(exitCode: code, output: String(decoding: out, as: UTF8.self),
                             timedOut: timedOut, truncated: truncated)
    }
}

/// Kernel-level job membership for sandboxed jobs. Each job's profile denies reading a unique tag file
/// that is otherwise readable; `sandbox_check(pid, ...)` then identifies every process inheriting that
/// sandbox (setsid, double fork, reparented to launchd, empty env). A second, allowed file in the same
/// directory excludes processes in unrelated sandboxes that deny the whole directory.
/// (kqueue `NOTE_TRACK` is unsupported on this macOS: EVFILT_PROC registration fails with ENOTSUP.)
final class JobTags: Sendable {
    let deny: String, allow: String

    private init(deny: String, allow: String) { self.deny = deny; self.allow = allow }

    static func make(profile: SandboxProfile) -> JobTags? {
        let dir = SandboxProfile.realPathOf(NSTemporaryDirectory()) + "/strim-tags"
        // The tags must not be writable from inside the sandbox.
        for w in profile.writableRoots + [profile.jobTmp] + profile.gitWritable
        where dir.hasPrefix(SandboxProfile.realPathOf(w) + "/") || dir == SandboxProfile.realPathOf(w) { return nil }
        let fm = FileManager.default
        guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        let id = UUID().uuidString
        let d = dir + "/" + id + "-deny", a = dir + "/" + id + "-allow"
        guard fm.createFile(atPath: d, contents: nil), fm.createFile(atPath: a, contents: nil) else { return nil }
        return JobTags(deny: d, allow: a)
    }

    var profileRules: String {
        // $TMPDIR is read-denied by the profile; the "allow" tag must stay readable for `contains`.
        "\n(allow file-read* (literal \(SandboxProfile.quote(allow))))\n(deny file-read* (literal \(SandboxProfile.quote(deny))))\n"
    }

    func contains(_ pid: pid_t) -> Bool {
        sandboxCheck(pid, deny) != 0 && sandboxCheck(pid, allow) == 0
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: deny)
        try? FileManager.default.removeItem(atPath: allow)
    }
}

extension SandboxProfile {
    static func realPathOf(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }
}

#if arch(arm64)
// sandbox_check is variadic; on arm64 Darwin variadic arguments go on the stack, so the path is passed
// as a 9th argument (after 5 register-filling dummies) to land at sp+0.
@_silgen_name("sandbox_check")
private func sandbox_check_raw(_ pid: pid_t, _ op: UnsafePointer<CChar>?, _ type: Int32,
                               _ d3: Int, _ d4: Int, _ d5: Int, _ d6: Int, _ d7: Int,
                               _ path: UnsafePointer<CChar>?) -> Int32
private func sandboxCheck(_ pid: pid_t, _ path: String) -> Int32 {
    sandbox_check_raw(pid, "file-read-data", 1 /* SANDBOX_FILTER_PATH */ | 0x4000_0000 /* NO_REPORT */, 0, 0, 0, 0, 0, path)
}
#else
@_silgen_name("sandbox_check")
private func sandbox_check_raw(_ pid: pid_t, _ op: UnsafePointer<CChar>?, _ type: Int32,
                               _ path: UnsafePointer<CChar>?) -> Int32
private func sandboxCheck(_ pid: pid_t, _ path: String) -> Int32 {
    sandbox_check_raw(pid, "file-read-data", 1 | 0x4000_0000, path)
}
#endif
