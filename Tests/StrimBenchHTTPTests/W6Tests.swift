import Foundation
import Testing
@testable import StrimBenchHTTP

@Suite struct W6AgentPromptTests {
    @Test func w6RunsDistinctSaltedAgentPromptsAtEachConcurrency() async throws {
        let srv = FakeServer(); try srv.start(); defer { srv.stop() }
        let tmp = TestPaths.tempDir()
        try #"["file A\nquestion","file B\nquestion","file C\nquestion"]"#.write(toFile: tmp + "/p.json", atomically: false, encoding: .utf8)
        let out = tmp + "/o"
        let rc = try await BenchHTTPCLI.run(["scoreboard", "--arm", "x=\(srv.url("full")),stub", "--workloads", "W6", "--reps", "1", "--conc", "2,3",
                                             "--w6-prompts", tmp + "/p.json", "--w6-gen", "8", "--tokenizer", "", "--timeout", "20",
                                             "--bench-dir", TestPaths.root + "/bench", "--out-dir", out], tokenizerFactory: nil)
        #expect(rc == 0)
        let rows = JSON.lines(out + "/raw.jsonl")
        let reqs = rows.filter { $0["kind"].string == "request" }
        #expect(reqs.count == 5 && reqs.allSatisfy { $0["workload"].string == "W6" && $0["tokens_flag"].string == "ok" })
        #expect(Set(reqs.compactMap { $0["variant"].string }) == ["agent-c2", "agent-c3"])
        #expect(rows.filter { $0["kind"].string == "batch" }.count == 2)
    }

    @Test func w6WithoutPromptsFileIsRejected() async throws {
        await #expect(throws: BenchError.self) {
            try await BenchHTTPCLI.run(["scoreboard", "--arm", "x=http://127.0.0.1:9,stub", "--workloads", "W6"], tokenizerFactory: nil)
        }
    }

    @Test func groupsAreSaltedPerRepAndCyclePrompts() {
        var cfg = ScoreboardConfig(outDir: "/tmp/unused")
        cfg.conc = [4]
        let p = TestPaths.tempDir() + "/p.json"
        try? #"["a","b"]"#.write(toFile: p, atomically: false, encoding: .utf8)
        cfg.w6PromptsFile = p
        let pr = Prompter(seed: "x", tokenizer: nil, note: "")
        let g0 = Scoreboard.buildGroups(workload: "W6", rep: 0, runID: "r", cfg: cfg, prompter: pr, corpus: JSONObject())
        let g1 = Scoreboard.buildGroups(workload: "W6", rep: 1, runID: "r", cfg: cfg, prompter: pr, corpus: JSONObject())
        #expect(g0.count == 1 && g0[0].items.count == 4)
        #expect(Set(g0[0].items.map(\.prompt)).count == 4)
        #expect(g0[0].items[0].prompt != g1[0].items[0].prompt)
        #expect(g0[0].items[0].prompt.hasSuffix("\na") && g0[0].items[2].prompt.hasSuffix("\na"))
    }
}
