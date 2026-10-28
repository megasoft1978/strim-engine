import Foundation
import StrimAgentBench

/// One soak run: starts the server, drives the arms over the task list, polls the server, writes the results dir.
/// `makeLauncher` receives the bearer token (read from the server's token file) so the launcher can pass it via env.
public final class SoakSession: @unchecked Sendable {
    public let opts: SoakOptions
    public let out: String
    let server: SoakServer
    private let verifyEnv: SoakVerify.Env
    private let makeLauncher: (String) -> ClientLauncher
    public let tasks: [SoakTask]
    private let workroot: String
    private let tasksRec: SoakRecorder
    private let serverRec: SoakRecorder
    private let stateLock = NSLock()
    private var _token = ""
    private var _stopping = false
    private var launcher: ClientLauncher?

    var token: String { stateLock.lock(); defer { stateLock.unlock() }; return _token }
    var stopping: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _stopping }
        set { stateLock.lock(); _stopping = newValue; stateLock.unlock() }
    }

    /// `out` must not exist yet (created here). `verify` carries the sandbox, go binary and real home for the post-run checks.
    public init(opts: SoakOptions, out: String, server: SoakServer, verify: SoakVerify.Env,
                makeLauncher: @escaping (String) -> ClientLauncher) throws {
        self.opts = opts
        self.out = out
        self.server = server
        self.makeLauncher = makeLauncher
        tasks = opts.only.isEmpty ? SoakTasks.all : SoakTasks.all.filter { opts.only.contains($0.id) }
        let fm = FileManager.default
        if fm.fileExists(atPath: out) { throw SoakError.io("results dir already exists: \(out)") }
        try fm.createDirectory(atPath: out + "/isolated/claude-config", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: out + "/isolated/codex-home", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: out + "/tasks", withIntermediateDirectories: true)
        let root = opts.tmpRoot ?? NSTemporaryDirectory()
        guard let wr = makeTempDir((root.hasSuffix("/") ? root : root + "/") + "strim-soak-root-XXXXXX") else {
            throw SoakError.io("cannot create temp root under \(root)")
        }
        workroot = realPath(wr)
        var warmed = verify
        warmed.cacheSeed = verify.cacheSeed ?? SoakVerify.warmCache(root: workroot, env: verify)
        self.verifyEnv = warmed
        tasksRec = try SoakRecorder(path: out + "/tasks.jsonl")
        serverRec = try SoakRecorder(path: out + "/server.jsonl")
    }

    var claudeConfigDir: String { out + "/isolated/claude-config" }
    var codexHome: String { out + "/isolated/codex-home" }

    func redact(_ s: String) -> String {
        let tok = token
        return tok.isEmpty ? s : s.replacingOccurrences(of: tok, with: "<redacted>")
    }

    /// Runs the whole soak. Returns the process exit code: 0 clean, 2 smoke failed, 130 aborted.
    public func execute() -> Int32 {
        let started = SoakClock.nowISO()
        let t0 = Date()
        let deadline = t0.addingTimeInterval(opts.durationMin * 60)
        var aborted = false
        var code: Int32 = 0
        var poller: SoakPoller?
        var cfg: [String: Any] = [
            "duration": opts.durationMin, "clients": opts.armsName, "task_timeout": opts.taskTimeout,
            "concurrent_every": opts.concurrentEvery, "poll": opts.poll, "port": opts.port, "started": started,
        ]
        writeJSON(out + "/run.json", cfg, pretty: true)

        do {
            try server.start()
            let tok = try server.loadToken()
            setToken(tok)
            try server.waitReady(timeout: Double(opts.readyTimeout))
            serverRec.write(["event": "server_up", "t": SoakClock.nowISO(), "pid": Int(server.pid ?? 0)])
            launcher = makeLauncher(tok)
            let p = SoakPoller(session: self, interval: opts.poll, t0: t0)
            poller = p
            p.sample()
            p.start()
            let problems = runSmoke()
            if !problems.isEmpty {
                serverRec.write(["event": "smoke_failed", "t": SoakClock.nowISO(), "problems": problems.map(redact)])
                FileHandle.standardError.write(Data(("smoke check failed, aborting:\n  " + problems.joined(separator: "\n  ") + "\n").utf8))
                aborted = true
                code = 2
            } else {
                aborted = !runLoop(deadline: deadline)
            }
        } catch {
            aborted = true
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        }

        // Clients first, then the server gracefully; a crash-restart loop cannot run past this point.
        stopping = true
        SoakChild.killAll(except: server.pid)
        if let p = poller { p.stop(); p.waitDone() }
        server.stop()
        SoakChild.killAll()
        if poller != nil { serverRec.write(["event": "server_stopped", "t": SoakClock.nowISO(), "aborted": aborted]) }
        tasksRec.close()
        serverRec.close()
        try? FileManager.default.removeItem(atPath: workroot)  // our own temp root only
        if aborted && code == 0 { code = 130 }
        cfg["elapsed_min"] = pyRound(Date().timeIntervalSince(t0) / 60, 1)
        cfg["aborted"] = aborted
        writeJSON(out + "/run.json", cfg, pretty: true)
        let text = SoakSummary.render(name: URL(fileURLWithPath: out).lastPathComponent, cfg: cfg,
                                      tasks: readRows(out + "/tasks.jsonl"), events: readRows(out + "/server.jsonl"),
                                      serverLog: (try? String(contentsOfFile: out + "/server.log", encoding: .utf8)) ?? "")
        try? text.write(toFile: out + "/summary.txt", atomically: false, encoding: .utf8)
        print(text)
        print("results: \(out)")
        return code
    }

    /// The timed loop. Returns false when interrupted (Ctrl-C/SIGTERM), true when the deadline or task cap ended it.
    private func runLoop(deadline: Date) -> Bool {
        var seq = 0
        var sinceConc = 0
        let clients = opts.clients
        let pairOK = clients.count == 2 && opts.concurrentEvery > 0
        let n = tasks.count
        while Date() < deadline {
            if Interrupt.requested { return false }
            if opts.maxTasks > 0 && seq >= opts.maxTasks { break }
            if pairOK && sinceConc >= opts.concurrentEvery && (opts.maxTasks == 0 || seq + 2 <= opts.maxTasks) {
                sinceConc = 0
                let ta = tasks[seq % n], tb = tasks[(seq + 1) % n]
                let group = DispatchGroup()
                let ok = Flags(2)
                let s = seq
                group.enter()
                DispatchQueue.global().async {
                    ok.set(0, self.runOne(seq: s, phase: "conc", client: "claude", task: ta, background: false) != nil)
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    // Codex goes out as background priority in each concurrent round; Claude stays interactive.
                    ok.set(1, self.runOne(seq: s + 1, phase: "conc", client: "codex", task: tb, background: true) != nil)
                    group.leave()
                }
                group.wait()
                if !ok.all { return false }
                seq += 2
                continue
            }
            // Each task cycles through both clients across passes over the task list.
            let cycle = seq / n, pos = seq % n
            let client = clients[(pos + cycle) % clients.count]
            guard runOne(seq: seq, phase: "seq", client: client, task: tasks[pos], background: false) != nil else { return false }
            seq += 1
            sinceConc += 1
        }
        return true
    }

    /// One client run in a fresh toy repo, then the deterministic check. nil when interrupted (no row written).
    func runOne(seq: Int, phase: String, client: String, task: SoakTask, background: Bool) -> [String: Any]? {
        let runID = String(format: "%04d-%@-%@", seq, client, task.id)
        let tdir = out + "/tasks/" + runID
        try? FileManager.default.createDirectory(atPath: tdir, withIntermediateDirectories: true)
        let tStart = SoakClock.nowISO()
        guard let repo = makeRepo(task.files) else { return nil }
        let clientScratch = workroot + "/client-" + runID
        defer { try? FileManager.default.removeItem(atPath: clientScratch) }  // our own temp root only
        let before = requestsTotal()
        let outcome: ClientOutcome
        do {
            outcome = try currentLauncher().launch(ClientRequest(
                client: client, prompt: SoakTasks.prefix + task.prompt, repo: repo, background: background,
                timeout: Double(opts.taskTimeout), logBase: tdir + "/client", scratch: clientScratch))
        } catch {
            FileHandle.standardError.write(Data("launch failed: \(error)\n".utf8))
            return nil
        }
        if Interrupt.requested { return nil }
        let after = requestsTotal()
        let scratch = workroot + "/scratch-" + runID
        let verdict = SoakVerify.verify(task, repo: repo, scratch: scratch, env: verifyEnv)
        try? FileManager.default.removeItem(atPath: scratch)
        let (checkOK, detail) = (verdict.ok, verdict.detail)
        let passed = checkOK && outcome.exitCode == 0 && !outcome.timedOut
        var row: [String: Any] = [
            "event": "task", "seq": seq, "phase": phase, "client": client, "task": task.id,
            "t_start": tStart, "wall_s": pyRound(outcome.wall, 1), "exit_code": Int(outcome.exitCode),
            "timed_out": outcome.timedOut,
            "server_requests": (before != nil && after != nil) ? after! - before! : NSNull(),
            "requests_window": phase == "conc" ? "shared" : "exact",
            "priority": background ? "background" : "interactive",
            "check_ok": checkOK, "check_detail": detail, "pass": passed,
            "stderr_tail": redact(String(outcome.stderr.suffix(800))),
        ]
        let info = SoakClientOutput.parse(client: client, stdout: String(outcome.stdout.suffix(10_000_000)))
        for (k, v) in info { row[k] = v }
        row["result_snippet"] = redact((info["result_snippet"] as? String) ?? "")
        if !passed { row["workdir"] = repo }  // failing repos are kept for inspection
        tasksRec.write(row)
        if passed { try? FileManager.default.removeItem(atPath: repo) }  // our own temp repo only
        return row
    }

    func currentLauncher() -> ClientLauncher {
        stateLock.lock(); defer { stateLock.unlock() }
        return launcher!
    }

    /// Trivial client run per arm before the timed loop. Returns problems; empty means every arm is usable.
    func runSmoke() -> [String] {
        var bad: [String] = []
        for client in opts.clients {
            let repo = makeRepo(SoakTasks.module([:]))
            guard let repo else { bad.append("\(client): cannot create a toy repo"); continue }
            let tdir = out + "/tasks/smoke-\(client)"
            try? FileManager.default.createDirectory(atPath: tdir, withIntermediateDirectories: true)
            do {
                let o = try currentLauncher().launch(ClientRequest(
                    client: client, prompt: "Reply with the single word OK. Do not use any tools.", repo: repo,
                    background: false, timeout: Double(opts.taskTimeout), logBase: tdir + "/client",
                    scratch: workroot + "/client-smoke-\(client)"))
                if o.exitCode != 0 || o.timedOut {
                    bad.append("\(client): smoke rc=\(o.exitCode) timed_out=\(o.timedOut): "
                               + redact(String(o.stderr.suffix(600))))
                }
            } catch {
                bad.append("\(client): smoke launch failed: \(error)")
            }
            try? FileManager.default.removeItem(atPath: repo)
        }
        return bad
    }

    /// Creates a throwaway repo under the workroot with the given module files.
    func makeRepo(_ files: [String: String]) -> String? {
        guard let repo = makeTempDir(workroot + "/soak-XXXXXX") else { return nil }
        for (rel, text) in files {
            let p = repo + "/" + rel
            try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: p, contents: Data(text.utf8))
        }
        return repo
    }

    /// Bearer-authenticated `server.requests_total`, nil when /metrics is not readable.
    func requestsTotal() -> Int? {
        let (code, body) = server.metrics(token: token)
        guard code == 200, let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let srv = obj["server"] as? [String: Any] else { return nil }
        return (srv["requests_total"] as? NSNumber)?.intValue
    }

    func setToken(_ t: String) { stateLock.lock(); _token = t; stateLock.unlock() }

    func restartServer(elapsed: Double) {
        let pid = server.pid ?? 0
        let rc = server.exitCode() ?? 0
        var tail: [String] = []
        if let text = try? String(contentsOfFile: server.logPath, encoding: .utf8) {
            tail = Array(text.components(separatedBy: "\n").suffix(15))
        }
        serverRec.write(["event": "crash", "t": SoakClock.nowISO(), "elapsed_s": pyRound(elapsed, 1),
                         "pid": Int(pid), "rc": Int(rc), "log_tail": tail.map { String(redact($0).prefix(200)) }])
        do {
            try server.start()
            setToken(try server.loadToken())
            try server.waitReady(timeout: Double(opts.readyTimeout))
            serverRec.write(["event": "restart", "t": SoakClock.nowISO(), "elapsed_s": pyRound(elapsed, 1),
                             "pid": Int(server.pid ?? 0)])
        } catch {
            serverRec.write(["event": "restart_failed", "t": SoakClock.nowISO(), "error": String(redact("\(error)").prefix(200))])
        }
    }

    func writeServerRow(_ row: [String: Any]) { serverRec.write(row) }

    private func writeJSON(_ path: String, _ obj: [String: Any], pretty: Bool) {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: opts) {
            FileManager.default.createFile(atPath: path, contents: data + Data([0x0a]))
        }
    }

    private func readRows(_ path: String) -> [[String: Any]] { SoakEntry.readRows(path) }
}

/// Polls /health, /metrics, RSS and the server log on a thread until stopped; restarts a crashed server.
final class SoakPoller: @unchecked Sendable {
    private unowned let session: SoakSession
    private let interval: Double
    private let t0: Date
    private let stopSem = DispatchSemaphore(value: 0)
    private let doneSem = DispatchSemaphore(value: 0)
    private var logOffset: UInt64 = 0
    static let patterns: [(name: String, needle: String)] = [
        ("error", "error"), ("unhealthy", "unhealthy"), ("insufficient_memory", "insufficient memory"),
    ]

    init(session: SoakSession, interval: Double, t0: Date) {
        self.session = session
        self.interval = interval
        self.t0 = t0
    }

    func start() {
        Thread { [self] in
            while stopSem.wait(timeout: .now() + interval) == .timedOut { sample() }
            doneSem.signal()
        }.start()
    }

    func stop() { stopSem.signal() }

    func waitDone() { _ = doneSem.wait(timeout: .now() + 30) }

    private var elapsed: Double { pyRound(Date().timeIntervalSince(t0), 1) }

    /// One poll: a crash restarts the server; otherwise one `sample` row.
    func sample() {
        let server = session.server
        let pid = server.pid
        let alive = pid != nil && server.exitCode() == nil
        if !alive && !session.stopping {
            session.restartServer(elapsed: elapsed)
            return
        }
        guard alive, let pid else { return }
        var row: [String: Any] = ["event": "sample", "t": SoakClock.nowISO(), "elapsed_s": elapsed,
                                  "pid": Int(pid), "rss_mb": opt(SoakProc.rssMB(pid))]
        let (hcode, hbody) = server.health()
        row["health"] = opt(hcode)
        if hcode == 503 {
            session.writeServerRow(["event": "unhealthy", "t": SoakClock.nowISO(), "elapsed_s": elapsed,
                                    "body": String(hbody.prefix(200))])
        } else if let c = hcode, c >= 500 {
            session.writeServerRow(["event": "http_5xx", "t": SoakClock.nowISO(), "elapsed_s": elapsed,
                                    "path": "/health", "code": c])
        }
        let (mcode, mbody) = server.metrics(token: session.token)
        row["metrics_code"] = opt(mcode)
        if let c = mcode, c >= 500 {
            session.writeServerRow(["event": "http_5xx", "t": SoakClock.nowISO(), "elapsed_s": elapsed,
                                    "path": "/metrics", "code": c])
        }
        if mcode == 200 {
            if let m = (try? JSONSerialization.jsonObject(with: Data(mbody.utf8))) as? [String: Any] {
                let e = m["engine"] as? [String: Any] ?? [:]
                let s = m["server"] as? [String: Any] ?? [:]
                func num(_ d: [String: Any], _ k: String) -> Any { d[k] ?? NSNull() }
                row["engine_healthy"] = num(e, "healthy")
                row["active_requests"] = num(e, "active_requests")
                row["sessions"] = num(e, "sessions")
                row["hot_sessions"] = num(e, "hot_sessions")
                row["requests_total"] = num(s, "requests_total")
                row["requests_failed"] = num(s, "requests_failed")
                row["requests_active"] = num(s, "requests_active")
                row["pooled_sessions"] = num(s, "pooled_sessions")
                row["mlx_active_mb"] = pyRound(((e["mlx_active_bytes"] as? NSNumber)?.doubleValue ?? 0) / 1_048_576, 1)
                row["mlx_peak_mb"] = pyRound(((e["mlx_peak_bytes"] as? NSNumber)?.doubleValue ?? 0) / 1_048_576, 1)
            } else {
                session.writeServerRow(["event": "metrics_parse_error", "t": SoakClock.nowISO(), "elapsed_s": elapsed])
            }
        }
        row["log_hits"] = scanLog()
        session.writeServerRow(row)
    }

    /// Scans log bytes appended since the last poll. Counts every pattern; logs at most 20 hits per poll.
    private func scanLog() -> [String: Int] {
        var hits = ["error": 0, "unhealthy": 0, "insufficient_memory": 0]
        guard let fh = FileHandle(forReadingAtPath: session.server.logPath) else { return hits }
        defer { try? fh.close() }
        try? fh.seek(toOffset: logOffset)
        let data = fh.readDataToEndOfFile()
        logOffset += UInt64(data.count)
        var shown = 0
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
            for p in Self.patterns where line.range(of: p.needle, options: .caseInsensitive) != nil {
                hits[p.name, default: 0] += 1
                if shown < 20 {
                    shown += 1
                    session.writeServerRow(["event": "log_hit", "t": SoakClock.nowISO(), "pattern": p.name,
                                            "line": String(session.redact(line).prefix(300))])
                }
            }
        }
        return hits
    }
}


/// Per-slot success flags written from concurrent runs.
final class Flags: @unchecked Sendable {
    private var values: [Bool]
    private let lock = NSLock()
    init(_ n: Int) { values = Array(repeating: true, count: n) }
    func set(_ i: Int, _ v: Bool) { lock.lock(); values[i] = v; lock.unlock() }
    var all: Bool { lock.lock(); defer { lock.unlock() }; return values.allSatisfy { $0 } }
}
