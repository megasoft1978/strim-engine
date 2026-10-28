import Testing
@testable import StrimSoak

@Suite struct SoakOptionsTests {
    static let cwd = "/work/repo"
    static let home = "/home/u"

    func parse(_ args: [String], env: [String: String] = [:]) throws -> SoakMode {
        try SoakArgs.parse(args, cwd: Self.cwd, home: Self.home, env: env)
    }

    func opts(_ args: [String], env: [String: String] = [:]) throws -> SoakOptions {
        guard case .run(let o) = try parse(args, env: env) else { throw SoakUsageError("not a run") }
        return o
    }

    @Test func defaults() throws {
        let o = try opts([])
        #expect(o.durationMin == 30)
        #expect(o.clients == ["claude", "codex"])
        #expect(o.armsName == "both")
        #expect(o.taskTimeout == 240)
        #expect(o.concurrentEvery == 6)
        #expect(o.poll == 15)
        #expect(o.port == 8203)
        #expect(o.tokenFile == "/home/u/.strim/token")
        #expect(o.model == "/work/repo/models/qwen38-4bit")
        #expect(o.head == "/work/repo/models/qwen38-mtp-4bit")
        #expect(o.modelId == "qwen38-4bit")
        #expect(o.lockPath == "/tmp/strim-bench.lock")
        #expect(o.lockWaitS == nil)
        #expect(o.out == nil)
        #expect(o.only.isEmpty)
    }

    @Test func relativeAndTildePathsResolveAtParseTime() throws {
        let o = try opts(["--out", "results/run-x", "--model", "../models/m", "--head", "/abs/head",
                          "--token-file", "~/.strim/alt", "--tmp-root", "scratch/"])
        #expect(o.out == "/work/repo/results/run-x")
        #expect(o.model == "/work/models/m")
        #expect(o.head == "/abs/head")
        #expect(o.tokenFile == "/home/u/.strim/alt")
        #expect(o.tmpRoot == "/work/repo/scratch")
        #expect(o.modelId == "m")
    }

    @Test func durationAndPollParse() throws {
        #expect(try opts(["--duration", "2.5"]).durationMin == 2.5)
        #expect(try opts(["--duration=5"]).durationMin == 5)
        #expect(try opts(["--poll", "0.5"]).poll == 0.5)
        #expect(throws: SoakUsageError.self) { try opts(["--duration", "0"]) }
        #expect(throws: SoakUsageError.self) { try opts(["--duration", "abc"]) }
        #expect(throws: SoakUsageError.self) { try opts(["--poll", "-1"]) }
    }

    @Test func armsSelectClients() throws {
        #expect(try opts(["--arms", "claude"]).clients == ["claude"])
        #expect(try opts(["--arms", "codex"]).armsName == "codex")
        #expect(try opts(["--arms", "both"]).clients == ["claude", "codex"])
        #expect(throws: SoakUsageError.self) { try opts(["--arms", "gpt"]) }
    }

    @Test func taskTimeoutIsCappedAt240() throws {
        #expect(try opts(["--task-timeout", "999"]).taskTimeout == 240)
        #expect(try opts(["--task-timeout", "60"]).taskTimeout == 60)
        #expect(throws: SoakUsageError.self) { try opts(["--task-timeout", "0"]) }
    }

    @Test func integerBounds() throws {
        #expect(try opts(["--concurrent-every", "0"]).concurrentEvery == 0)
        #expect(throws: SoakUsageError.self) { try opts(["--concurrent-every", "-1"]) }
        #expect(throws: SoakUsageError.self) { try opts(["--port", "70000"]) }
        #expect(throws: SoakUsageError.self) { try opts(["--port", "x"]) }
        #expect(try opts(["--max-tasks", "3"]).maxTasks == 3)
    }

    @Test func lockPathFromEnvAndFlag() throws {
        #expect(try opts([], env: ["STRIM_BENCH_LOCK": "/work/lock"]).lockPath == "/work/lock")
        #expect(try opts(["--lock-path", "lk"], env: ["STRIM_BENCH_LOCK": "/work/lock"]).lockPath == "/work/repo/lk")
        #expect(try opts(["--lock-wait-s", "5"]).lockWaitS == 5)
        #expect(throws: SoakUsageError.self) { try opts(["--lock-wait-s", "-2"]) }
    }

    @Test func onlyValidatesIds() throws {
        #expect(try opts(["--only", "fix_median,add_stdev"]).only == ["fix_median", "add_stdev"])
        #expect(throws: SoakUsageError.self) { try opts(["--only", "fix_median,nope"]) }
    }

    @Test func modesAndErrors() throws {
        #expect(try parse(["--list-tasks"]) == .listTasks)
        #expect(try parse(["--help"]) == .help)
        #expect(try parse(["--summarize", "bench/results/run2"]) == .summarize("/work/repo/bench/results/run2"))
        #expect(throws: SoakUsageError.self) { try parse(["--bogus"]) }
        #expect(throws: SoakUsageError.self) { try parse(["--out"]) }
        #expect(throws: SoakUsageError.self) { try parse(["stray"]) }
        #expect(throws: SoakUsageError.self) { try parse(["--list-tasks=1"]) }
    }
}
