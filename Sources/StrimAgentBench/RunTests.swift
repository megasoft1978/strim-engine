import Foundation
import StrimHarness

/// Host-side `runtests` service for the paid arms. The client's Bash child shares the client's network and can read its
/// OAuth credential, and `sandbox-exec` cannot nest, so Bash may not run `go test`/`swift test` itself (they execute
/// parent-written code). Instead Bash may only call `runtests <args>`, a tiny script that sends the args to this loopback
/// listener; the HOST validates them and runs the runner inside the verify-style sandbox (no network at all, no home or
/// credential reads, writes only in the worktree and a scratch dir) and returns capped output.
public final class RunTestsService: @unchecked Sendable {
    public let port: UInt16
    public let token: String
    let workdir: String, scratch: String, home: String
    let maxOutput: Int, timeout: TimeInterval, maxCalls: Int
    private var listenFD: Int32
    private var stopped = false
    private let lock = NSLock()
    private var thread: Thread?
    private var calls = 0
    /// Environment extras for tests (none in production).
    var extraEnv: [String: String] = [:]

    public init?(workdir: String, scratch: String, home: String = NSHomeDirectory(), maxOutput: Int = PaidBash.maxOutputChars,
                 timeout: TimeInterval = TimeInterval(PaidBash.maxTimeoutMs / 1000), maxCalls: Int = 80) {
        self.workdir = workdir; self.scratch = scratch; self.home = home
        self.maxOutput = maxOutput; self.timeout = timeout; self.maxCalls = maxCalls
        var raw = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess else { return nil }
        token = raw.map { String(format: "%02x", $0) }.joined()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        let b = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard b == 0, listen(fd, 4) == 0 else { close(fd); return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        listenFD = fd
        for d in [scratch, scratch + "/tmp", scratch + "/home"] { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let t = Thread { [self] in serve() }
        t.start(); thread = t
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        shutdown(listenFD, SHUT_RDWR); close(listenFD)
    }
    deinit { stop() }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func serve() {
        while !isStopped {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 200) <= 0 { continue }
            let c = accept(listenFD, nil, nil)
            if c < 0 { continue }
            handle(c)
            close(c)
        }
    }

    private func readLine(_ fd: Int32) -> String? {
        var buf = [UInt8](), byte: UInt8 = 0
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while buf.count < 8192 {
            guard read(fd, &byte, 1) == 1 else { return nil }
            if byte == 10 { return String(decoding: buf, as: UTF8.self) }
            buf.append(byte)
        }
        return nil
    }

    private func reply(_ fd: Int32, status: Int32, _ text: String) {
        let data = Array(("EXIT \(status)\n" + text).utf8)
        var off = 0
        while off < data.count {
            let n = data[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            off += n
        }
    }

    private func handle(_ fd: Int32) {
        guard let line = readLine(fd) else { return }
        let parts = line.components(separatedBy: "\u{1f}")
        guard parts.first == token else { reply(fd, status: 77, "runtests: bad token\n"); return }
        let args = Array(parts.dropFirst())
        if let why = Self.validate(args) { reply(fd, status: 64, "runtests: refused: \(why)\n"); return }
        lock.lock(); calls += 1; let n = calls; lock.unlock()
        if n > maxCalls { reply(fd, status: 75, "runtests: call limit (\(maxCalls)) reached\n"); return }
        let (code, text) = run(args)
        reply(fd, status: code, text)
    }

    /// nil when the request is a runner invocation that cannot name another program.
    public static func validate(_ args: [String]) -> String? {
        guard let prog = args.first else { return "usage: runtests <runner> ..." }
        for a in args where a.contains("\0") { return "bad argument" }
        if RunTestsGrammar.covers(prog) {
            guard args.count >= 2 || prog == "javatest" else { return "usage: runtests \(prog) ..." }
            return RunTestsGrammar.validate(args)
        }
        guard args.count >= 2 else { return "usage: runtests go|swift|node|bun|deno|cargo|ruby|tsc|npm|npx|javatest ..." }
        let ok: [String: Set<String>] = ["go": ["test", "vet", "build", "version"], "swift": ["test", "build", "--version"]]
        guard let subs = ok[args[0]], subs.contains(args[1]) else { return "only go test|vet|build|version and swift test|build are allowed" }
        for a in args {
            let l = a.lowercased()
            for bad in ["-exec", "--exec", "-toolexec", "--toolexec", "-vettool", "--vettool", "-overlay", "--overlay", "-modfile", "--package-path", "--scratch-path", "--build-path", "--cache-path"] where l == bad || l.hasPrefix(bad + "=") {
                return "flag \(bad) is not allowed"
            }
            if a.contains("\0") { return "bad argument" }
        }
        return nil
    }

    private func run(_ args: [String]) -> (Int32, String) {
        let work = URL(fileURLWithPath: workdir), scr = URL(fileURLWithPath: scratch)
        let profile = Verifier.sandboxProfile(work: work, scratch: scr, home: home)
        var env: [String: String] = ["PATH": PaidBash.path, "HOME": scratch + "/home", "TMPDIR": scratch + "/tmp", "GOCACHE": scratch + "/gocache",
                                     "GOPROXY": "off", "CI": "1", "LANG": "en_US.UTF-8"]
        let mod = home + "/go/pkg/mod"
        if FileManager.default.fileExists(atPath: mod) { env["GOMODCACHE"] = mod }
        Toolchains.apply(to: &env, home: home, scratch: scratch)
        for (k, v) in extraEnv { env[k] = v }
        let argv = [Verifier.sandboxExec, "-p", profile, "/usr/bin/env"] + RunTestsGrammar.argv(args)
        guard let c = try? Proc.runCaptured(argv: argv, env: env, cwd: workdir, timeout: timeout, maxBytes: 1_000_000, mergeStderr: true) else {
            return (70, "runtests: could not start\n")
        }
        var text = String(decoding: c.stdout, as: UTF8.self)
        if text.count > maxOutput { text = "[... truncated ...]\n" + String(text.suffix(maxOutput)) }
        if c.result.timedOut { text += "\nruntests: timed out after \(Int(timeout)) s\n" }
        return (c.result.timedOut ? 124 : c.result.exitCode, text)
    }

    /// Writes `<dir>/runtests` (0700). The script only talks to this listener; the host validates every request.
    @discardableResult
    public func writeScript(dir: String) -> String {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = dir + "/runtests"
        let s = """
        #!/bin/bash
        exec 3<>/dev/tcp/127.0.0.1/\(port) || { echo "runtests: service unreachable" >&2; exit 70; }
        { printf '%s' '\(token)'; for a in "$@"; do printf '\\037%s' "$a"; done; printf '\\n'; } >&3
        IFS= read -r st <&3 || exit 70
        cat <&3
        exit "${st#EXIT }"

        """
        FileManager.default.createFile(atPath: path, contents: Data(s.utf8), attributes: [.posixPermissions: 0o700])
        return path
    }
}
