import Foundation
import Testing
@testable import StrimSoak

@Suite struct SoakSummaryTests {
    /// Repo root from this file's compile-time path (Tests/StrimSoakTests/X.swift).
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let run2 = repo.appendingPathComponent("bench/results/soak-20261027/run2").path

    // MARK: numbers (Python-compatible)

    @Test func pyRoundMatchesPython() {
        #expect(pyRound(2.25, 1) == 2.2)     // exact tie: half-even, as Python's round()
        #expect(pyRound(0.05, 1) == 0.1)     // binary value sits just above the tie
        #expect(pyRound(96.666, 1) == 96.7)
        #expect(pyFloat(pyRound(100, 1)) == "100.0")
    }

    @Test func medians() {
        #expect(pyMedian([1, 2, 3, 4] as [Double]) == 2.5)
        #expect(pyMedian([3, 1, 2] as [Double]) == 2.0)
        #expect(pyMedian([] as [Double]) == nil)
        #expect(pyMedian([3, 1, 2] as [Int]) == .int(2))      // odd ints stay ints, printed without .0
        #expect(pyMedian([1, 2, 3, 4] as [Int]) == .float(2.5))
        #expect(PyNum.float(2.0).text == "2.0")
        #expect(PyNum.int(249).text == "249")
    }

    @Test func rssDriftSlope() {
        // 24 MB per hour, sampled every hour: slope is exactly 24.
        let rising = (0..<6).map { (Double($0) * 3600, 100 + 24 * Double($0)) }
        #expect(soakSlopePerHour(rising) == 24.0)
        // Flat RSS: no drift.
        let flat = (0..<10).map { (Double($0) * 15, 8700.0) }
        #expect(soakSlopePerHour(flat) == 0.0)
        // Falling RSS is negative.
        let falling = (0..<6).map { (Double($0) * 3600, 200 - 2 * Double($0)) }
        #expect(soakSlopePerHour(falling) == -2.0)
        // Too few points or no time spread: undefined.
        #expect(soakSlopePerHour(Array(rising.prefix(4))) == nil)
        #expect(soakSlopePerHour((0..<6).map { (5.0, Double($0)) }) == nil)
    }

    @Test func longestTaskIsFirstMaximum() {
        let rows: [[String: Any]] = [
            ["seq": 1, "client": "claude", "task": "a", "wall_s": 10.0],
            ["seq": 2, "client": "codex", "task": "b", "wall_s": 40.0],
            ["seq": 3, "client": "claude", "task": "c", "wall_s": 40.0],
        ]
        #expect(SoakSummary.longestTask(rows)?["task"] as? String == "b")
    }

    @Test func ttftParsesFirstMatchPerLine() {
        let log = "[serve] req ttft=250ms tok=3\nno timing here\n[serve] ttft=1200ms\nttft=x\n"
        #expect(SoakSummary.ttftValues(log) == [250, 1200])
    }

    @Test func reprOfStrings() {
        #expect(SoakSummary.pyStrRepr("plain") == "'plain'")
        #expect(SoakSummary.pyStrRepr("it's") == "\"it's\"")
        #expect(SoakSummary.pyStrRepr("a\nb") == "'a\\nb'")
    }

    // MARK: summary text (golden: the committed run2 soak)

    @Test func run2SummaryIsReproduced() throws {
        let read: (String) throws -> String = { try String(contentsOfFile: SoakSummaryTests.run2 + "/" + $0, encoding: .utf8) }
        let cfgData = try Data(contentsOf: URL(fileURLWithPath: SoakSummaryTests.run2 + "/run.json"))
        let cfg = try #require(try JSONSerialization.jsonObject(with: cfgData) as? [String: Any])
        let tasks = try read("tasks.jsonl").split(separator: "\n").map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let events = try read("server.jsonl").split(separator: "\n").map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let rendered = SoakSummary.render(name: "run2", cfg: cfg, tasks: tasks, events: events,
                                          serverLog: try read("server-ttft.txt"))
        let committed = try read("summary.txt")
        // Line 2 is the usage line, which names the earlier script flags; every other line must match exactly.
        var want = committed.components(separatedBy: "\n")
        var got = rendered.components(separatedBy: "\n")
        #expect(want.count > 10)
        #expect(want.count == got.count)
        #expect(want[1].hasPrefix("usage: soak.py"))
        #expect(got[1].hasPrefix("usage: strim soak"))
        want.remove(at: 1)
        got.remove(at: 1)
        #expect(got == want)
    }

    @Test func run2NumbersAreExplicit() throws {
        let read: (String) throws -> String = { try String(contentsOfFile: SoakSummaryTests.run2 + "/" + $0, encoding: .utf8) }
        let tasks = try read("tasks.jsonl").split(separator: "\n").map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let events = try read("server.jsonl").split(separator: "\n").map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let text = SoakSummary.render(name: "run2", cfg: ["duration": 30.0, "clients": "both", "elapsed_min": 30.3],
                                      tasks: tasks, events: events, serverLog: try read("server-ttft.txt"))
        #expect(text.contains("Tasks: 120 total, 116 passed (96.7%)"))
        #expect(text.contains("  claude: 56/60 passed (93.3%)"))
        #expect(text.contains("  codex: 60/60 passed (100.0%)"))
        #expect(text.contains("RSS MB: min 8687.0  max 8713.4  first-quartile median 8704.6  last-quartile median 8713.0  slope 24.0 MB/h"))
        #expect(text.contains("TTFT ms (n=666): first-quartile median 249.0  last-quartile median 310.5  p90 1334"))
        #expect(text.contains("Failures (4):"))
        #expect(text.contains("Server error events (0):"))
    }
}
