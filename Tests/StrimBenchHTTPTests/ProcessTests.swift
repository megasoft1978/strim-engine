import Foundation
import Testing
@testable import StrimBenchHTTP

@Suite struct ProcessManagementTests {
    @Test func spawnsInItsOwnSessionAndKillsExactPidsOnly() async throws {
        let dir = TestPaths.tempDir()
        let target = try SpawnedProcess.spawn(argv: ["/bin/sleep", "300"], cwd: dir, env: [:], logPath: dir + "/s.log")
        let bystander = try SpawnedProcess.spawn(argv: ["/bin/sleep", "300"], cwd: dir, env: [:], logPath: dir + "/b.log")
        defer { kill(pid_t(bystander.pid), SIGKILL); _ = bystander.poll() }
        #expect(SystemSnapshot.alive(target.pid) && SystemSnapshot.alive(bystander.pid))
        #expect(getsid(pid_t(target.pid)) == pid_t(target.pid), "start_new_session: the child leads its own session")
        #expect(target.poll() == nil)
        let t0 = Date()
        let killed = await ProcessKiller.killExact([target.identity!], grace: 5, reap: [target], log: { _ in })
        #expect(killed == [target.pid])
        #expect(Date().timeIntervalSince(t0) < 2, "SIGTERM is enough: the child does not inherit a blocked or ignored signal state")
        #expect(!SystemSnapshot.alive(target.pid))
        #expect(SystemSnapshot.alive(bystander.pid), "a pid we did not list is left alone")
        #expect(target.poll() != nil)
    }

    @Test func descendantsAreCollectedAndKilledWithTheServer() async throws {
        let dir = TestPaths.tempDir()
        let parent = try SpawnedProcess.spawn(argv: ["/bin/sh", "-c", "sleep 300 & sleep 300 & wait"], cwd: dir, env: [:], logPath: dir + "/p.log")
        var kids: [Int] = []
        for _ in 0 ..< 50 {
            kids = SystemSnapshot.children(of: parent.pid)
            if kids.count >= 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(kids.count >= 2)
        await ProcessKiller.killExact(([parent.pid] + kids).compactMap { ProcIdentity.capture($0) }, grace: 5, reap: [parent], log: { _ in })
        for k in kids { #expect(!SystemSnapshot.alive(k)) }
    }

    @Test func envAndCwdReachTheChildAndOutputGoesToTheLog() async throws {
        let dir = TestPaths.tempDir()
        let p = try SpawnedProcess.spawn(argv: ["/bin/sh", "-c", "echo $BENCH_X; pwd"], cwd: dir, env: ["BENCH_X": "hello"], logPath: dir + "/o.log")
        for _ in 0 ..< 50 where p.poll() == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(p.poll() == 0)
        let out = try String(contentsOfFile: dir + "/o.log", encoding: .utf8)
        #expect(out.hasPrefix("hello\n") && out.contains((dir as NSString).lastPathComponent))
    }

    @Test func gpuLockIsExclusiveAndReleasable() async {
        let path = TestPaths.tempDir() + "/gpu.lock"
        let a = GPULock(path: path), b = GPULock(path: path)
        #expect(a.tryAcquire())
        #expect(!b.tryAcquire())
        #expect(await b.acquire(timeout: 0.4, poll: 0.05) == false)
        a.release()
        #expect(await b.acquire(timeout: 2, poll: 0.05))
        b.release()
        #expect(a.tryAcquire())
    }

    @Test func recycledPidIsNeverSignalled() async throws {
        let dir = TestPaths.tempDir()
        let bystander = try SpawnedProcess.spawn(argv: ["/bin/sleep", "300"], cwd: dir, env: [:], logPath: dir + "/b.log")
        defer { kill(pid_t(bystander.pid), SIGKILL); _ = bystander.poll() }
        let real = try #require(bystander.identity)
        // same pid, different start time: what a recycled pid looks like to the killer
        let stale = ProcIdentity(pid: real.pid, startSec: real.startSec &- 1000, startUsec: real.startUsec)
        #expect(!stale.isAlive && real.isAlive)
        let killed = await ProcessKiller.killExact([stale], grace: 1, log: { _ in })
        #expect(killed.isEmpty)
        #expect(SystemSnapshot.alive(bystander.pid), "the process behind a mismatching identity is left alone")
        await ProcessKiller.killExact([real], grace: 5, reap: [bystander], log: { _ in })
        #expect(!SystemSnapshot.alive(bystander.pid))
        #expect(!real.isAlive, "dead pid no longer matches")
    }

    @Test func lockFileRefusesSymlinksAndNonRegularFiles() async throws {
        let d = TestPaths.tempDir()
        try "x".write(toFile: d + "/target", atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: d + "/link.lock", withDestinationPath: d + "/target")
        let l = GPULock(path: d + "/link.lock")
        #expect(!l.tryAcquire() && l.openError?.contains("symlink") == true)
        #expect(await l.acquire(timeout: 5, poll: 0.05) == false, "unusable lock file fails fast instead of waiting")
        try FileManager.default.createDirectory(atPath: d + "/dir.lock", withIntermediateDirectories: false)
        let dl = GPULock(path: d + "/dir.lock")
        #expect(!dl.tryAcquire() && dl.openError != nil)
        let ok = GPULock(path: d + "/new.lock")
        #expect(ok.tryAcquire() && ok.openError == nil)
        var st = stat()
        stat(d + "/new.lock", &st)
        #expect(st.st_mode & 0o777 == 0o600 && st.st_uid == getuid())
        ok.release()
    }

    @Test func lockPathEnvOverrideAndDefault() {
        #expect(GPULock.resolvedPath(env: [:]) == "/tmp/strim-bench.lock")
        #expect(GPULock.resolvedPath(env: ["STRIM_BENCH_LOCK": "/x/y.lock"]) == "/x/y.lock")
        #expect(GPULock.resolvedPath(env: ["STRIM_BENCH_LOCK": ""]) == "/tmp/strim-bench.lock")
    }

    @Test func spawnLogNeverFollowsSymlinks() throws {
        let d = TestPaths.tempDir()
        try "precious".write(toFile: d + "/victim", atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: d + "/log", withDestinationPath: d + "/victim")
        #expect(throws: BenchError.self) { try SpawnedProcess.spawn(argv: ["/usr/bin/true"], cwd: d, env: [:], logPath: d + "/log") }
        #expect(try String(contentsOfFile: d + "/victim", encoding: .utf8) == "precious", "target not truncated")
        let p = try SpawnedProcess.spawn(argv: ["/bin/echo", "hi"], cwd: d, env: [:], logPath: d + "/ok.log")
        for _ in 0 ..< 50 where p.poll() == nil { Thread.sleep(forTimeInterval: 0.05) }
        var st = stat()
        stat(d + "/ok.log", &st)
        #expect(st.st_mode & 0o777 == 0o600)
    }

    @Test func scratchDirAndExclusiveWrites() throws {
        let t = try SafeFS.makeTempDir()
        var st = stat()
        stat(t, &st)
        #expect(st.st_mode & 0o777 == 0o700 && (st.st_mode & S_IFMT) == S_IFDIR)
        try SafeFS.prepareScratch(t)
        // planted symlink at the Modelfile path: replaced, victim untouched
        try "precious".write(toFile: t + "/victim", atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: t + "/Modelfile", withDestinationPath: t + "/victim")
        try SafeFS.writeExclusive(t + "/Modelfile", Data("FROM x".utf8))
        #expect(try String(contentsOfFile: t + "/victim", encoding: .utf8) == "precious")
        #expect(try String(contentsOfFile: t + "/Modelfile", encoding: .utf8) == "FROM x")
        stat(t + "/Modelfile", &st)
        #expect((st.st_mode & S_IFMT) == S_IFREG && st.st_mode & 0o777 == 0o600)
        // symlinked or group-writable scratch dirs are refused; a missing one is created 0700
        let d = TestPaths.tempDir()
        try FileManager.default.createSymbolicLink(atPath: d + "/s", withDestinationPath: t)
        #expect(throws: BenchError.self) { try SafeFS.prepareScratch(d + "/s") }
        try FileManager.default.createDirectory(atPath: d + "/w", withIntermediateDirectories: false)
        chmod(d + "/w", 0o777)
        #expect(throws: BenchError.self) { try SafeFS.prepareScratch(d + "/w") }
        try SafeFS.prepareScratch(d + "/new")
        stat(d + "/new", &st)
        #expect(st.st_mode & 0o777 == 0o700)
    }

    @Test func portFreeSeesAListener() throws {
        let s = FakeServer(); try s.start()
        #expect(!Net.portFree(Int(s.port)))
        let p = Int(s.port)
        s.stop()
        Thread.sleep(forTimeInterval: 0.1)
        #expect(Net.portFree(p))
    }

    @Test func probeReadsTheFirstModelId() async throws {
        let s = FakeServer(); try s.start(); defer { s.stop() }
        s.modelsID = "qwen38-4bit"
        #expect(await Net.probe(port: Int(s.port)) == "qwen38-4bit")
        #expect(await Net.probe(port: Int(s.port), path: "/api/version") == "up")
        #expect(await Net.probe(port: 1) == nil)
    }
}

@Suite struct PassRunnerTests {
    private func fakeRoot(port: UInt16, cmd: [String]) throws -> (root: String, table: EngineTable) {
        let root = TestPaths.tempDir("pass")
        try FileManager.default.createDirectory(atPath: root + "/bench", withIntermediateDirectories: true)
        for f in ["prompt_seed.txt", "ab_prompts.json"] {
            try FileManager.default.copyItem(atPath: TestPaths.root + "/bench/" + f, toPath: root + "/bench/" + f)
        }
        try SyntheticFixture.write(path: root + "/fx.json", turns: 3)
        let table = try EngineTable(json: JSON.dumps(.obj([
            "scratch_default": .string(root + "/scratch"),
            "engines": .obj(["fake": .obj(["port": .int(Int(port)), "cache": "fake cache", "quant": "fake quant",
                                           "cmd": .array(cmd.map { .string($0) })])]),
        ])))
        return (root, table)
    }

    private func freePort() throws -> UInt16 {
        let s = FakeServer(); try s.start(); let p = s.port; s.stop()
        Thread.sleep(forTimeInterval: 0.1)
        return p
    }

    @Test func fullPassAgainstAFakeEngineKillsOnlyItsPids() async throws {
        let port = try freePort()
        let (root, table) = try fakeRoot(port: port, cmd: ["/bin/sleep", "300"])
        let srv = FakeServer()
        srv.modelsID = "fake-model"
        Task { try? await Task.sleep(nanoseconds: 1_300_000_000); try? srv.start(port: port) }  // the "engine" comes up after launch
        defer { srv.stop() }
        var cfg = PassConfig(engine: "fake", root: root)
        cfg.out = "out"
        cfg.workloads = ["W1"]
        cfg.sbReps = 1
        cfg.replayReps = 1
        cfg.sampled = 1
        cfg.fixture = "fx.json"
        cfg.tokenizer = ""
        cfg.lockPath = root + "/gpu.lock"
        cfg.startTimeout = 30
        let rc = await PassRunner.run(cfg: cfg, table: table, factory: nil)
        #expect(rc == 0)
        let dir = root + "/out/fake/pass1"
        let meta = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: dir + "/meta.json")))
        #expect(meta["status"].string == "done" && meta["model_id"].string == "fake-model" && meta["ready_s"].double != nil)
        #expect(meta.object?.keys.prefix(9) == ["engine", "pass", "cmd", "env", "cache", "quant", "git_head", "started", "status"])
        let pids = meta["killed_pids"].array?.compactMap(\.int) ?? []
        #expect(pids.count == 1)
        for p in pids { #expect(!SystemSnapshot.alive(p), "server pid \(p) is gone") }
        for f in ["warmup/raw.jsonl", "scoreboard/raw.jsonl", "scoreboard/summary.md", "replay/raw.jsonl", "replay/summary.md", "sampled.jsonl", "steps.log", "server.log"] {
            #expect(FileManager.default.fileExists(atPath: dir + "/" + f), "\(f)")
        }
        let steps = try String(contentsOfFile: dir + "/steps.log", encoding: .utf8)
        for s in ["warmup", "scoreboard", "replay", "sampled"] { #expect(steps.contains("STEP \(s) rc=0"), "\(s)") }
        let sb = JSON.lines(dir + "/scoreboard/raw.jsonl")
        let corpus = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: root + "/bench/ab_prompts.json"))).object!.keys.count
        #expect(sb.filter { $0["kind"].string == "request" }.count == corpus * 2, "W1: corpus prompts x 2 token sizes x 1 rep")
        #expect(sb[0]["arms"].array?.first?["pid"].int == pids.first, "RSS pid passed to the scoreboard")
        // the pass output feeds the aggregator unchanged
        #expect(JSON.lines(dir + "/replay/raw.jsonl").filter { $0["kind"].string == "request" }.count == 3)
        #expect(JSON.lines(dir + "/sampled.jsonl").count == 1)
    }

    @Test func busyPortIsSkippedWithoutLaunching() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let (root, table) = try fakeRoot(port: srv.port, cmd: ["/bin/sleep", "300"])
        var cfg = PassConfig(engine: "fake", root: root)
        cfg.out = "out"
        cfg.lockPath = nil
        let rc = await PassRunner.run(cfg: cfg, table: table, factory: nil)
        #expect(rc == 3)
        let meta = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: root + "/out/fake/pass1/meta.json")))
        #expect(meta["status"].string?.hasPrefix("SKIP: port") == true)
    }

    @Test func serverThatExitsIsReportedAndCleanedUp() async throws {
        let (root, table) = try fakeRoot(port: try freePort(), cmd: ["/usr/bin/false"])
        var cfg = PassConfig(engine: "fake", root: root)
        cfg.out = "out"
        cfg.lockPath = nil
        cfg.startTimeout = 10
        let rc = await PassRunner.run(cfg: cfg, table: table, factory: nil)
        #expect(rc == 2)
        let meta = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: root + "/out/fake/pass1/meta.json")))
        #expect(meta["status"].string == "FAILED to start: exited rc=1")
    }

    @Test func unknownEngineFails() async throws {
        let (root, table) = try fakeRoot(port: 1, cmd: ["/bin/sleep", "1"])
        var cfg = PassConfig(engine: "nope", root: root)
        cfg.lockPath = nil
        #expect(await PassRunner.run(cfg: cfg, table: table, factory: nil) == 2)
    }
}
