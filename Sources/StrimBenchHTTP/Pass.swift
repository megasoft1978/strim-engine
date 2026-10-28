import Foundation

public struct PassConfig: Sendable {
    public var engine: String
    public var pass = 1
    public var out = "bench/results/final-20261026"
    public var sbReps = 3
    public var replayReps = 3
    public var sampled = 3
    public var steps: Set<String> = ["warmup", "scoreboard", "replay", "sampled"]
    public var workloads = ["W1", "W2", "W3", "W4", "W5"]
    public var startTimeout = 900.0
    public var deadlineMin = 50.0
    public var root: String
    public var scratch: String?
    public var fixture = "bench/results/final-20261026/synthetic-8turn.json"
    public var tokenizer: String?
    /// GPU lock file; nil runs without taking the lock (e.g. already under `lockf`).
    public var lockPath: String? = GPULock.resolvedPath()

    public init(engine: String, root: String) { self.engine = engine; self.root = root }
}

/// One engine pass of the final all-engine benchmark (final_run.py): start the engine, wait for readiness,
/// warm-up (discarded), scoreboard W1-W5, 8-turn agent replay, sampled decode, then kill exactly the pids started.
/// Raw files land in `<out>/<engine>/pass<N>/`.
public enum PassRunner {
    public static func run(cfg: PassConfig, table: EngineTable, factory: TokenizerFactory?, log userLog: LogSink? = nil) async -> Int32 {
        let scratch: String
        do {
            if let s = cfg.scratch { try SafeFS.prepareScratch(s); scratch = s } else { scratch = try SafeFS.makeTempDir() }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 2
        }
        let spec: EngineLaunch
        do { spec = try table.launch(cfg.engine, root: cfg.root, scratch: scratch) } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 2
        }
        var lock: GPULock?
        if let lp = cfg.lockPath {
            let l = GPULock(path: lp)
            let t0 = Date()
            guard await l.acquire() else {
                FileHandle.standardError.write(Data("GPU lock unusable: \(l.openError ?? "unknown")\n".utf8))
                return 2
            }
            if Date().timeIntervalSince(t0) > 1 { FileHandle.standardError.write(Data("waited \(Int(Date().timeIntervalSince(t0)))s for GPU lock \(lp)\n".utf8)) }
            lock = l
        }
        defer { lock?.release() }

        let outURL = URL(fileURLWithPath: cfg.root).appendingPathComponent(cfg.out)
            .appendingPathComponent(cfg.engine.replacingOccurrences(of: "/", with: "_")).appendingPathComponent("pass\(cfg.pass)")
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let out = outURL.path
        let stepsLog = LineLog(path: out + "/steps.log")
        let log: LogSink = { m in
            let hms = DateFormatter()
            hms.dateFormat = "HH:mm:ss"
            let line = "[\(hms.string(from: Date()))] \(m)"
            print(line)
            fflush(stdout)
            stepsLog.append(line)
            userLog?(m)
        }
        let deadline = Date().addingTimeInterval(cfg.deadlineMin * 60)
        var meta = JSONObject()
        func writeMeta() {
            try? JSON.dumps(.object(meta), indent: 1).write(toFile: out + "/meta.json", atomically: false, encoding: .utf8)
        }
        meta["engine"] = .string(cfg.engine)
        meta["pass"] = .int(cfg.pass)
        meta["cmd"] = .array(spec.cmd.map { .string($0) })
        var envO = JSONObject()
        for (k, v) in spec.env { envO[k] = .string(v) }
        meta["env"] = .object(envO)
        meta["cache"] = .string(spec.cache)
        meta["quant"] = .string(spec.quant)
        meta["git_head"] = .string(ProcessRunner.captureSync("git", ["-C", cfg.root, "rev-parse", "HEAD"]) ?? "")
        meta["started"] = SystemSnapshot.loadSnapshot()
        meta["status"] = "init"

        for p in spec.prepare {
            switch p {
            case .mkdir(let d): try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            case .symlink(let link, let to):
                if !FileManager.default.fileExists(atPath: link) { try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: to) }
            }
        }
        if !Net.portFree(spec.port) {
            meta["status"] = .string("SKIP: port \(spec.port) busy before launch")
            writeMeta()
            log(meta["status"]!.string!)
            return 3
        }

        let slog = out + "/server.log"
        let t0 = Date()
        var env: [String: String] = [:]
        for (k, v) in spec.env { env[k] = v }
        let proc: SpawnedProcess
        do { proc = try SpawnedProcess.spawn(argv: spec.cmd, cwd: cfg.root, env: env, logPath: slog) } catch {
            meta["status"] = .string("FAILED to start: \(error)")
            writeMeta()
            log(meta["status"]!.string!)
            return 2
        }
        let started = [proc.pid]
        log("server pid \(proc.pid): \(shellJoin(spec.cmd))")
        var rc: Int32 = 1
        var allPids = started
        // Identity (pid + start time) is recorded the first time a pid is seen, so a recycled pid is never signalled.
        var idents: [Int: ProcIdentity] = [:]
        func remember(_ pids: [Int]) {
            for p in pids where idents[p] == nil { if let i = ProcIdentity.capture(p) { idents[p] = i } }
        }
        remember(started)
        func pidsForKill() -> [Int] {
            let now = SystemSnapshot.children(of: proc.pid)
            remember(now)
            return Array(Set(started + now + allPids)).sorted()
        }

        func finish() async {
            if let cl = spec.cleanup, proc.poll() == nil {
                let r = runProcessEnv(cl, env: env, cwd: cfg.root)
                log("\(cl.first ?? "cleanup") rm rc=\(r.rc)")
            }
            let pids = pidsForKill()
            await ProcessKiller.killExact(pids.compactMap { idents[$0] }, reap: [proc], log: log)
            meta["ended"] = SystemSnapshot.loadSnapshot()
            meta["killed_pids"] = .array(pids.map { .int($0) })
            writeMeta()
        }

        // readiness
        var mid: String?
        while Date().timeIntervalSince(t0) < cfg.startTimeout {
            if proc.poll() != nil { break }
            mid = await Net.probe(port: spec.port, path: spec.probePath)
            if mid != nil { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard var modelIDVar = mid else {
            let state = proc.poll().map { "exited rc=\($0)" } ?? "no /v1/models after \(Int(cfg.startTimeout))s"
            meta["status"] = .string("FAILED to start: \(state)")
            log(meta["status"]!.string!)
            await finish()
            return 2
        }
        meta["ready_s"] = .double((Date().timeIntervalSince(t0) * 10).rounded() / 10)

        if let pr = spec.postReady {
            let mf = "FROM \(pr.gguf)\nTEMPLATE \"\"\"\(pr.template)\"\"\"\nPARAMETER num_ctx \(pr.numCtx)\nPARAMETER stop \"\(pr.stop)\"\n"
            do { try SafeFS.writeExclusive(pr.modelfile, Data(mf.utf8)) } catch {
                meta["status"] = .string("FAILED: modelfile: \(error)")
                await finish()
                return 2
            }
            let r = runProcessEnv(["ollama", "create", pr.name, "-f", pr.modelfile], env: env, cwd: cfg.root)
            try? (r.out).write(toFile: out + "/ollama-create.log", atomically: false, encoding: .utf8)
            log("ollama create rc=\(r.rc)")
            if r.rc != 0 {
                meta["status"] = .string("FAILED: ollama create: " + String(r.out.suffix(300)))
                await finish()
                return 2
            }
            modelIDVar = pr.name
        }
        let url = "http://127.0.0.1:\(spec.port)"
        let modelID = modelIDVar
        meta["model_id"] = .string(modelID)
        allPids = [proc.pid] + SystemSnapshot.children(of: proc.pid)
        remember(allPids)
        meta["pids"] = .array(allPids.map { .int($0) })
        meta["status"] = "running"
        writeMeta()
        log("ready in \(pyFloatRepr(meta["ready_s"]!.double!))s model_id=\(modelID)")
        let arm = cfg.engine.replacingOccurrences(of: "/", with: "_")

        let tokenizerPath = cfg.tokenizer ?? cfg.root + "/models/qwen38-4bit/tokenizer.json"
        func sbConfig(outDir: String, workloads: [String], reps: Int, pid: Int?, serverLog: String?) -> ScoreboardConfig {
            var c = ScoreboardConfig(outDir: outDir)
            c.arms = [Arm(name: arm, url: url, model: modelID, pending: false, pid: pid)]
            c.workloads = workloads
            c.reps = reps
            c.timeout = 1500
            c.benchDir = cfg.root + "/bench"
            c.tokenizer = tokenizerPath
            if let serverLog { c.serverLogs[arm] = serverLog }
            c.deadline = deadline
            return c
        }
        func step(_ name: String, _ desc: String, _ body: (LogSink) async throws -> Void) async {
            guard cfg.steps.contains(name) else { return }
            let left = deadline.timeIntervalSinceNow
            if left < 30 { log("STEP \(name) skipped: pass deadline reached"); return }
            log("STEP \(name): \(desc)  load=\(JSON.dumps(SystemSnapshot.loadSnapshot()))")
            let s0 = Date()
            let stdoutLog = LineLog(path: out + "/\(name).stdout.log", truncate: true)
            var status = "0"
            do { try await body({ stdoutLog.append($0) }) } catch { status = "error: \(error)" }
            log("STEP \(name) rc=\(status) \(Int(Date().timeIntervalSince(s0)))s")
        }

        let wt = Date()
        await step("warmup", "scoreboard warm-up W3 4096 gen 8") { l in
            var c = sbConfig(outDir: out + "/warmup", workloads: ["W3"], reps: 1, pid: nil, serverLog: nil)
            c.w3Sizes = [4096]
            c.w3Gen = 8
            try await Scoreboard.execute(cfg: c, factory: factory, log: l)
        }
        meta["warmup_s"] = .double((Date().timeIntervalSince(wt) * 10).rounded() / 10)
        allPids = Array(Set([proc.pid] + SystemSnapshot.children(of: proc.pid))).sorted()
        remember(allPids)
        meta["pids"] = .array(allPids.map { .int($0) })
        let serverPid = proc.pid
        await step("scoreboard", "scoreboard \(cfg.workloads.joined(separator: ",")) reps \(cfg.sbReps)") { l in
            let c = sbConfig(outDir: out + "/scoreboard", workloads: cfg.workloads, reps: cfg.sbReps, pid: serverPid, serverLog: slog)
            try await Scoreboard.execute(cfg: c, factory: factory, log: l)
        }
        await step("replay", "replay \(cfg.fixture) reps \(cfg.replayReps)") { l in
            var rc = ReplayConfig(fixture: cfg.root + "/" + cfg.fixture,
                                  arms: [ReplayArm(name: arm, url: url, model: modelID, cache: .on, serverLog: slog)],
                                  outDir: out + "/replay")
            rc.reps = cfg.replayReps
            rc.maxTokens = 48
            rc.timeout = 1500
            rc.deadline = deadline
            try await Replay.run(cfg: rc, log: l)
        }
        await step("sampled", "sampled \(cfg.sampled) x 256") { l in
            let sc = SampledConfig(url: url, model: modelID, label: arm, outPath: out + "/sampled.jsonl")
            var s2 = sc
            s2.n = cfg.sampled
            s2.tokens = 256
            try await Sampled.run(cfg: s2, log: l)
        }
        meta["status"] = "done"
        rc = 0
        await finish()
        return rc
    }

    static func shellJoin(_ a: [String]) -> String {
        a.map { s in
            s.isEmpty || s.contains(where: { " \t\n\"'\\$&|;<>(){}*?[]#~`!".contains($0) }) ? "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" : s
        }.joined(separator: " ")
    }

    static func runProcessEnv(_ argv: [String], env: [String: String], cwd: String) -> (rc: Int32, out: String) {
        let p = Process()
        guard let exe = ProcessRunner.resolveExecutable(argv[0]) else { return (127, "not found: \(argv[0])") }
        p.executableURL = exe
        p.arguments = Array(argv.dropFirst())
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (126, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Append-only line log, safe to call from any thread.
final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?

    init(path: String, truncate: Bool = false) {
        if truncate || !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        handle = FileHandle(forWritingAtPath: path)
        if !truncate { _ = try? handle?.seekToEnd() }
    }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        handle?.write(Data((line + "\n").utf8))
    }

    deinit { try? handle?.close() }
}
