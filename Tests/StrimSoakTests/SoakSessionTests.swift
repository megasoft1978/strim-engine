import Foundation
import StrimAgentBench
import Testing
@testable import StrimSoak

/// A server that is "running" as this test process: no GPU, no network. Its RSS is this process's real RSS.
final class FakeServer: SoakServer, @unchecked Sendable {
    let logPath: String
    static let token = "fake-token-7Q"
    private let lock = NSLock()
    private var running = false
    private var requests = 0

    init(logPath: String) { self.logPath = logPath }

    var pid: Int32? { lock.lock(); defer { lock.unlock() }; return running ? getpid() : nil }

    func start() throws {
        lock.lock(); running = true; lock.unlock()
        // Log lines the poller scans: one TTFT sample and one error-looking line.
        FileManager.default.createFile(atPath: logPath, contents: Data("[serve] ready\n[serve] req ttft=300ms\n[serve] error: none\n".utf8))
    }

    func exitCode() -> Int32? { nil }

    func loadToken() throws -> String { FakeServer.token }

    func waitReady(timeout: Double) throws {}

    func stop() { lock.lock(); running = false; lock.unlock() }

    func health() -> (code: Int?, body: String) { (200, "{}") }

    func metrics(token: String) -> (code: Int?, body: String) {
        lock.lock(); requests += 1; let n = requests; lock.unlock()
        let body = """
        {"engine":{"healthy":true,"active_requests":0,"sessions":1,"hot_sessions":0,\
        "mlx_active_bytes":536870912,"mlx_peak_bytes":603979776},\
        "server":{"requests_total":\(n),"requests_failed":0,"requests_active":0,"pooled_sessions":0}}
        """
        return (200, body)
    }
}

/// Answers every client run with a clean exit and canned output. Writes no repo files, so checks fail (expected here).
struct StubLauncher: ClientLauncher {
    func launch(_ req: ClientRequest) throws -> ClientOutcome {
        let out = req.client == "claude"
            ? #"{"num_turns":2,"is_error":false,"subtype":"success","result":"stub"}"#
            : "{\"type\":\"turn.completed\"}\n"
        try out.write(toFile: req.logBase + ".stdout", atomically: false, encoding: .utf8)
        return ClientOutcome(exitCode: 0, timedOut: false, wall: 0.01, stdout: out, stderr: "")
    }
}

@Suite struct SoakSessionTests {
    /// A fresh scratch root with `tmp/` for the workroot and a not-yet-existing `out/`.
    func scratch() throws -> (root: String, out: String, tmp: String) {
        let root = NSTemporaryDirectory() + "soak-session-\(UUID().uuidString)"
        let tmp = root + "/tmp"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        return (root, root + "/out", tmp)
    }

    func options(durationSeconds: Double, tmp: String, clients: [String] = ["claude", "codex"]) -> SoakOptions {
        var o = SoakOptions(cwd: tmp, home: tmp, env: [:])
        o.durationMin = durationSeconds / 60
        o.poll = 0.5
        o.taskTimeout = 30
        o.readyTimeout = 5
        o.tmpRoot = tmp
        o.clients = clients
        o.concurrentEvery = 1  // a concurrent pair must occur early so the smoke does not depend on machine speed
        return o
    }

    func rows(_ path: String) throws -> [[String: Any]] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    @Test func fiveSecondSoakWithStubExecutorAndFakeServer() throws {
        let go = try #require(SoakProc.which("go"))
        let s = try scratch()
        defer { try? FileManager.default.removeItem(atPath: s.root) }
        let opts = options(durationSeconds: 5, tmp: s.tmp)
        let server = FakeServer(logPath: s.out + "/server.log")
        let session = try SoakSession(opts: opts, out: s.out, server: server, verify: SoakVerify.Env(home: NSHomeDirectory(), goBin: go)) { _ in StubLauncher() }

        let code = session.execute()
        #expect(code == 0)

        let tasks = try rows(s.out + "/tasks.jsonl")
        #expect(tasks.count >= 4)
        #expect(Set(tasks.compactMap { $0["client"] as? String }) == ["claude", "codex"])
        #expect(tasks.contains { ($0["phase"] as? String) == "conc" })
        #expect(tasks.contains { ($0["priority"] as? String) == "background" })
        #expect(tasks.allSatisfy { ($0["check_detail"] as? String) != nil })
        // Fresh repos are kept for failing checks and recorded as workdir.
        #expect(tasks.filter { ($0["pass"] as? Bool) == false }.allSatisfy { ($0["workdir"] as? String) != nil })

        let events = try rows(s.out + "/server.jsonl")
        #expect(events.contains { ($0["event"] as? String) == "server_up" })
        let samples = events.filter { ($0["event"] as? String) == "sample" }
        #expect(samples.count >= 3)
        #expect(samples.allSatisfy { ($0["rss_mb"] as? NSNumber)?.doubleValue ?? 0 > 0 })
        #expect(samples.allSatisfy { ($0["pid"] as? NSNumber)?.int32Value == getpid() })
        #expect(events.contains { ($0["event"] as? String) == "log_hit" && ($0["pattern"] as? String) == "error" })
        #expect(events.contains { ($0["event"] as? String) == "server_stopped" && ($0["aborted"] as? Bool) == false })

        let run = try #require(SoakEntry.readObject(s.out + "/run.json"))
        #expect(run["aborted"] as? Bool == false)
        #expect((run["elapsed_min"] as? NSNumber)?.doubleValue ?? 99 < 1)

        let summary = try String(contentsOfFile: s.out + "/summary.txt", encoding: .utf8)
        #expect(summary.hasPrefix("strim soak summary  out\n"))
        #expect(summary.contains("pids seen: 1"))
        #expect(summary.contains("TTFT ms (n=1)"))

        // The token never reaches any output file, and the workroot is removed.
        for f in ["tasks.jsonl", "server.jsonl", "server.log", "summary.txt", "run.json"] {
            let text = try String(contentsOfFile: s.out + "/" + f, encoding: .utf8)
            #expect(!text.contains(FakeServer.token), "token leaked into \(f)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.tmp).isEmpty)
    }

    @Test func taskCapStopsTheLoopWithoutPairs() throws {
        let go = try #require(SoakProc.which("go"))
        let s = try scratch()
        defer { try? FileManager.default.removeItem(atPath: s.root) }
        var opts = options(durationSeconds: 60, tmp: s.tmp)
        opts.maxTasks = 3
        opts.concurrentEvery = 0
        let session = try SoakSession(opts: opts, out: s.out, server: FakeServer(logPath: s.out + "/server.log"),
                                      verify: SoakVerify.Env(home: NSHomeDirectory(), goBin: go)) { _ in StubLauncher() }
        #expect(session.execute() == 0)
        let tasks = try rows(s.out + "/tasks.jsonl")
        #expect(tasks.count == 3)
        #expect(tasks.allSatisfy { ($0["phase"] as? String) == "seq" })
        // Client = clients[(position + cycle) % 2]: positions 0, 1, 2 give claude, codex, claude.
        #expect(tasks.map { $0["client"] as? String } == ["claude", "codex", "claude"])
    }

    @Test func singleArmNeverPairs() throws {
        let go = try #require(SoakProc.which("go"))
        let s = try scratch()
        defer { try? FileManager.default.removeItem(atPath: s.root) }
        var opts = options(durationSeconds: 60, tmp: s.tmp, clients: ["codex"])
        opts.maxTasks = 4
        opts.concurrentEvery = 2
        let session = try SoakSession(opts: opts, out: s.out, server: FakeServer(logPath: s.out + "/server.log"),
                                      verify: SoakVerify.Env(home: NSHomeDirectory(), goBin: go)) { _ in StubLauncher() }
        #expect(session.execute() == 0)
        let tasks = try rows(s.out + "/tasks.jsonl")
        #expect(tasks.count == 4)
        #expect(tasks.allSatisfy { ($0["client"] as? String) == "codex" })
        #expect(tasks.allSatisfy { ($0["phase"] as? String) == "seq" })
    }
}
