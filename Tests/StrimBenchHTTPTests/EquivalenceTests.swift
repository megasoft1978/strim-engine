import Foundation
import Testing
@testable import StrimBenchHTTP

/// Walks two JSON trees; counts numeric leaves compared and lists every difference (exact bit equality for doubles).
private func compare(_ a: JSONValue, _ b: JSONValue, path: String = "", numbers: inout Int, diffs: inout [String]) {
    switch (a, b) {
    case (.object(let x), .object(let y)):
        if x.keys != y.keys { diffs.append("\(path): keys \(x.keys) vs \(y.keys)"); return }
        for m in x.members { compare(m.value, y[m.key]!, path: path + "/" + m.key, numbers: &numbers, diffs: &diffs) }
    case (.array(let x), .array(let y)):
        if x.count != y.count { diffs.append("\(path): len \(x.count) vs \(y.count)"); return }
        for (i, (u, v)) in zip(x, y).enumerated() { compare(u, v, path: "\(path)[\(i)]", numbers: &numbers, diffs: &diffs) }
    case (.int(let x), .int(let y)):
        numbers += 1
        if x != y { diffs.append("\(path): \(x) vs \(y)") }
    case (.double(let x), .double(let y)):
        numbers += 1
        if x.bitPattern != y.bitPattern { diffs.append("\(path): \(x) vs \(y)") }
    default:
        if a != b { diffs.append("\(path): \(a) vs \(b)") }
    }
}

private func copyRun(to dest: String) throws {
    try FileManager.default.copyItem(atPath: TestPaths.committedRun, toPath: dest)
    try? FileManager.default.removeItem(atPath: dest + "/summary.md")
    try? FileManager.default.removeItem(atPath: dest + "/results.json")
}

/// The equivalence gate against bench/results/final-20261026 (committed raw files + committed outputs of the Python tools).
@Suite(.enabled(if: TestPaths.hasCommittedRun)) struct EquivalenceGateTests {
    @Test func aggregateRegeneratesSummaryAndResultsExactly() throws {
        let tmp = TestPaths.tempDir("gate") + "/run"
        try copyRun(to: tmp)
        let r = try Aggregate.run(dir: tmp, pathLabel: "bench/results/final-20261026", generatedBy: "bench/final_aggregate.py")
        let committedMD = try String(contentsOfFile: TestPaths.committedRun + "/summary.md", encoding: .utf8)
        let committedJSON = try String(contentsOfFile: TestPaths.committedRun + "/results.json", encoding: .utf8)
        #expect(r.summary == committedMD, "summary.md byte-identical")
        #expect(r.results == committedJSON, "results.json byte-identical")
        // parsed-number diff: every numeric leaf, bit-exact
        var numbers = 0
        var diffs: [String] = []
        compare(try JSON.parse(r.results), try JSON.parse(committedJSON), numbers: &numbers, diffs: &diffs)
        #expect(diffs.isEmpty, "\(diffs.prefix(5))")
        #expect(numbers > 1000, "compared \(numbers) numeric leaves")
        print("EQUIVALENCE aggregate: \(numbers) numeric leaves compared bit-exact, \(diffs.count) differences; summary.md \(r.summary.utf8.count) bytes identical")
    }

    @Test func onlyGeneratedByDiffersWithTheDefaultLabel() throws {
        let tmp = TestPaths.tempDir("gate") + "/run"
        try copyRun(to: tmp)
        let r = try Aggregate.run(dir: tmp, pathLabel: "bench/results/final-20261026")
        var numbers = 0
        var diffs: [String] = []
        compare(try JSON.parse(r.results), try JSON.parse(Data(contentsOf: URL(fileURLWithPath: TestPaths.committedRun + "/results.json"))),
                numbers: &numbers, diffs: &diffs)
        #expect(diffs.count == 1 && diffs[0].hasPrefix("/meta/generated_by"), "\(diffs)")
    }

    @Test func perRunSummariesRegenerateIdentically() throws {
        var checked = 0
        var bad: [String] = []
        for dir in BenchHTTPCLI.rawDirs(under: TestPaths.committedRun) {
            let first = JSON.lines(dir + "/raw.jsonl").first ?? .null
            let text: String
            if !first["workloads"].isNull { text = try Scoreboard.summarize(dir: dir) }
            else if !first["fixture"].isNull { text = try Replay.summarize(dir: dir) }
            else { continue }
            checked += 1
            if text != (try String(contentsOfFile: dir + "/summary.md", encoding: .utf8)) { bad.append(dir) }
        }
        #expect(bad.isEmpty, "\(bad)")
        #expect(checked == 37, "scoreboard + warmup + replay summaries in final-20261026, got \(checked)")
        print("EQUIVALENCE per-run summaries: \(checked - bad.count)/\(checked) identical")
    }

    @Test func syntheticFixtureIsByteIdenticalToTheCommittedOne() throws {
        let want = try String(contentsOfFile: TestPaths.committedRun + "/synthetic-8turn.json", encoding: .utf8)
        #expect(SyntheticFixture.render(try SyntheticFixture.messages(turns: 8)) == want)
        let (_, sha) = try Replay.loadFixture(TestPaths.committedRun + "/synthetic-8turn.json")
        let replayMeta = JSON.lines(TestPaths.committedRun + "/strim/pass1/replay/raw.jsonl")[0]
        #expect(sha == replayMeta["fixture_sha256"].string, "same fixture hash as recorded in the replay runs")
    }

    @Test func engineRecipesMatchTheRecordedLaunches() throws {
        let table = try EngineTable.builtin()
        let recordedRoot = "/Users/user/Desktop/Freelance/strim-engine"
        let scratch = "/private/tmp/claude-501/final-20261026-scratch"
        var matched = 0
        for name in table.names {
            let meta = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: TestPaths.committedRun + "/\(name)/pass1/meta.json")))
            let l = try table.launch(name, root: recordedRoot, scratch: scratch)
            #expect(l.cmd == meta["cmd"].array?.compactMap(\.string), "\(name) cmd")
            #expect(l.env.map(\.key) == meta["env"].object?.keys && l.env.map(\.value) == meta["env"].object?.members.compactMap { $0.value.string }, "\(name) env")
            #expect(l.cache == meta["cache"].string && l.quant == meta["quant"].string, "\(name) cache/quant")
            matched += 1
        }
        #expect(matched == 9)
        #expect(table.schedule.map { "\($0.engine)#\($0.pass)#\($0.sbReps)#\($0.replayReps)" } == [
            "strim#1#2#2", "rapid-mlx#1#2#2", "strim#2#2#2", "rapid-mlx#2#2#2", "mlx-lm#1#3#3", "tensorfold#1#3#3", "omlx#1#3#3",
            "mlx-vlm#1#3#3", "llama.cpp#1#3#3", "ollama#1#3#3",
        ], "final_all.sh order")
        let ollama = try table.launch("ollama", root: recordedRoot, scratch: scratch)
        #expect(ollama.probePath == "/api/version" && ollama.postReady?.template.contains("<think>") == true && ollama.cleanup == ["ollama", "rm", "qwen38-27b-q4km"])
        // frozen golden (Goldens/OllamaTemplateGolden.swift): the Modelfile template as it was in the removed bench/final_run.py
        #expect(Goldens.ollamaTemplate == ollama.postReady?.template)
    }
}
