import Foundation
import Testing
@testable import StrimSite

@Suite struct SiteSoakTests {
    static let summary = """
    strim soak summary  X
    Tasks: 93 total, 77 passed (82.8%)
      claude: 38/46 passed (82.6%)
      codex: 39/47 passed (83.0%)
    Server:
      crashes: 1  restarts: 1  restart_failures: 0
      http 5xx events: 0  unhealthy samples: 0
      server requests_total last: 758  failed: 0
    RSS MB: min 1.0  max 2.0  first-quartile median 8705.4  last-quartile median 8713.3  slope 21.1 MB/h
    TTFT ms (n=760): first-quartile median 261.0  last-quartile median 263.5  p90 1114

    """

    static let base = "bench/results/soak-20991231/20991231T000000Z"
    /// The real 30.3-minute run in the repo. Overlays disable it so the synthetic run is the only candidate.
    static let run2 = "bench/results/soak-20261027/run2/run.json"
    static let disabledRun2 = "{\"duration\": 30.0, \"elapsed_min\": 30.3, \"aborted\": true}"

    static func overlay(dir: String = base, runJSON: String, summaryText: String = summary) throws -> OverlayRoot {
        try OverlayRoot(replacing: [
            dir + "/summary.txt": summaryText,
            dir + "/run.json": runJSON,
            run2: disabledRun2,
            "site/index.html": "stale", "site/benchmarks.html": "stale", "README.md": "stale",
            "site/data/results.json": readString(repoRoot + "/site/data/results.json"),
        ])
    }

    static func refresh(_ o: OverlayRoot) throws -> (lines: [String], result: SiteResult) {
        let b = SiteBuilder(root: o.path)
        var lines: [String] = []
        b.log = { lines.append($0) }
        let r = try b.run(SiteOptions(refreshSoak: true))
        return (lines, r)
    }

    static func figure(_ path: String, _ id: String) throws -> PyJSON? {
        try PyJSONParser.parse(readString(path + "/site/data/results.json"))["figures"]?.arr?.first { $0["id"]?.str == id }?["value"]
    }

    @Test func refreshFillsSoakFiguresFromTheLatestCompleteRun() throws {
        let o = try Self.overlay(runJSON: "{\"duration\": 45, \"elapsed_min\": 46.2, \"aborted\": false}")
        let (lines, r) = try Self.refresh(o)
        #expect(r.exitCode == 0, "errors: \(r.errors)")
        #expect(lines.first == "soak figures refreshed from bench/results/soak-20991231/20991231T000000Z/summary.txt")
        func val(_ id: String) throws -> PyJSON? { try Self.figure(o.path, id) }
        #expect(try val("soak.tasks_total") == .int(93))
        #expect(try val("soak.pass_codex") == .double(83.0))
        #expect(try val("soak.ttft_q1") == .int(261))        // integral floats become ints, as in the Python
        #expect(try val("soak.ttft_q4") == .double(263.5))
        #expect(try val("soak.rss_slope") == .double(21.1))
        #expect(try val("soak.claude_passed") == .int(38))
        #expect(try val("soak.codex_tasks") == .int(47))
        #expect(readString(o.path + "/site/benchmarks.html").contains("pass rates below"))
    }

    @Test func realThirtyMinuteRunFillsEveryFigure() throws {
        let o = try OverlayRoot(replacing: [
            "site/index.html": "stale", "site/benchmarks.html": "stale", "README.md": "stale",
            "site/data/results.json": readString(repoRoot + "/site/data/results.json"),
        ])
        let (lines, r) = try Self.refresh(o)
        #expect(r.exitCode == 0, "errors: \(r.errors)")
        #expect(lines.first == "soak figures refreshed from bench/results/soak-20261027/run2/summary.txt")
        func val(_ id: String) throws -> PyJSON? { try Self.figure(o.path, id) }
        #expect(try val("soak.tasks_total") == .int(120))
        #expect(try val("soak.tasks_passed") == .int(116))
        #expect(try val("soak.claude_passed") == .int(56))
        #expect(try val("soak.claude_tasks") == .int(60))
        #expect(try val("soak.pass_claude") == .double(93.3))
        #expect(try val("soak.codex_passed") == .int(60))
        #expect(try val("soak.codex_tasks") == .int(60))
        #expect(try val("soak.pass_codex") == .double(100.0))
        #expect(try val("soak.failures") == .int(4))
        #expect(try val("soak.elapsed_min") == .double(30.3))
        #expect(try val("soak.rss_min") == .double(8687.0))
        #expect(try val("soak.rss_max") == .double(8713.4))
        #expect(try val("soak.rss_slope") == .double(24.0))
        #expect(try val("soak.ttft_q1") == .int(249))
        #expect(try val("soak.ttft_q4") == .double(310.5))
        #expect(try val("soak.ttft_p90") == .int(1334))
        #expect(try val("soak.crashes") == .int(0))
        #expect(try val("soak.http5xx") == .int(0))
        #expect(readString(o.path + "/site/benchmarks.html").contains("title=\"soak.tasks_passed\">116"))
    }

    @Test func soakRuleAcceptsThirtyMinutesAndSkipsAbortedRunningAndInvalidRuns() throws {
        let cases: [(dir: String, json: String, accepted: Bool)] = [
            (Self.base, "{\"duration\": 29.9, \"elapsed_min\": 30.0, \"aborted\": false}", false),
            (Self.base, "{\"duration\": 45.0, \"elapsed_min\": 46.0, \"aborted\": true}", false),
            (Self.base, "{\"duration\": 45.0}", false),
            (Self.base + "-invalid", "{\"duration\": 45.0, \"elapsed_min\": 46.0, \"aborted\": false}", false),
            (Self.base, "{\"duration\": 30.0, \"elapsed_min\": 30.3, \"aborted\": false}", true),
        ]
        for c in cases {
            let o = try Self.overlay(dir: c.dir, runJSON: c.json)
            let (lines, _) = try Self.refresh(o)
            if c.accepted {
                #expect(lines.first == "soak figures refreshed from \(c.dir)/summary.txt", "\(c.json)")
            } else {
                #expect(lines.first == "no complete 30-minute soak run found; soak.* figures stay pending", "\(c.json)")
            }
        }
    }
}
