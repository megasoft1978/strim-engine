import Foundation
import Testing
@testable import StrimBenchHTTP

@Suite struct BenchCLITests {
    @Test func scoreboardSubcommandRunsAgainstAFakeServer() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let out = TestPaths.tempDir() + "/sb"
        let rc = try await BenchHTTPCLI.run(["scoreboard", "--arm", "x=\(srv.url("full")),stub", "--arm", "later:pending=http://127.0.0.1:9,stub",
                                             "--workloads", "W1,W3", "--reps", "1", "--w1-tokens", "8", "--w3-sizes", "200", "--w3-gen", "8",
                                             "--tokenizer", "", "--timeout", "20", "--bench-dir", TestPaths.root + "/bench", "--out-dir", out],
                                            tokenizerFactory: nil)
        #expect(rc == 0)
        let rows = JSON.lines(out + "/raw.jsonl")
        #expect(rows.filter { $0["kind"].string == "request" }.allSatisfy { $0["tokens_flag"].string == "ok" })
        #expect(FileManager.default.fileExists(atPath: out + "/summary.md"))
        // report regenerates the same summary
        #expect(try await BenchHTTPCLI.run(["report", "--check", out], tokenizerFactory: nil) == 0)
    }

    @Test func serverLogOptionAcceptsPerArmAndPlainPaths() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let tmp = TestPaths.tempDir()
        try "".write(toFile: tmp + "/log.txt", atomically: false, encoding: .utf8)
        srv.logPath = tmp + "/log.txt"
        let rc = try await BenchHTTPCLI.run(["scoreboard", "--arm", "x=\(srv.url("log")),stub", "--workloads", "W1", "--reps", "1", "--w1-tokens", "8",
                                             "--server-log", "x=\(tmp)/log.txt", "--tokenizer", "", "--bench-dir", TestPaths.root + "/bench",
                                             "--out-dir", tmp + "/o"], tokenizerFactory: nil)
        #expect(rc == 0)
        let reqs = JSON.lines(tmp + "/o/raw.jsonl").filter { $0["kind"].string == "request" }
        #expect(reqs.allSatisfy { $0["cache_info"].string == "log" && $0["cached_tokens"].int == 0 })
    }

    @Test func sampledAndReplayAndSyntheticSubcommands() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let tmp = TestPaths.tempDir()
        #expect(try await BenchHTTPCLI.run(["sampled", srv.url("full"), "stub", "lbl", tmp + "/s.jsonl", "2", "10"], tokenizerFactory: nil) == 0)
        #expect(JSON.lines(tmp + "/s.jsonl").count == 2)
        #expect(try await BenchHTTPCLI.run(["replay", "--make-synthetic-fixture", tmp + "/f.json", "--synthetic-turns", "4"], tokenizerFactory: nil) == 0)
        #expect(try Replay.loadFixture(tmp + "/f.json").messages.count == 1 + 1 + 3 * 2 + 1)
        let rc = try await BenchHTTPCLI.run(["replay", "--fixture", tmp + "/f.json", "--arm", "a=\(srv.url("off")),stub,cache=off", "--reps", "1",
                                             "--max-tokens", "40", "--out-dir", tmp + "/r"], tokenizerFactory: nil)
        #expect(rc == 0 && FileManager.default.fileExists(atPath: tmp + "/r/summary.md"))
    }

    @Test func badInputIsReported() async throws {
        await #expect(throws: BenchError.self) { try await BenchHTTPCLI.run(["scoreboard", "--arm", "broken"], tokenizerFactory: nil) }
        await #expect(throws: BenchError.self) { try await BenchHTTPCLI.run(["scoreboard", "--nope"], tokenizerFactory: nil) }
        await #expect(throws: BenchError.self) { try await BenchHTTPCLI.run(["run"], tokenizerFactory: nil) }
        #expect(try await BenchHTTPCLI.run(["frobnicate"], tokenizerFactory: nil) == 2)
        #expect(try await BenchHTTPCLI.run(["engines", "--root", "/r", "--scratch", "/s"], tokenizerFactory: nil) == 0)
    }

    @Test func allDryRunListsTheAbabSchedule() async throws {
        #expect(try await BenchHTTPCLI.run(["all", "--dry-run"], tokenizerFactory: nil) == 0)
    }
}
