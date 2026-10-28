import Foundation
import Testing
@testable import StrimSite

/// `check` must fail on deliberately broken inputs, as the retired Python generator did.
@Suite struct SiteCheckTests {
    enum Outcome {
        case ok(SiteResult)
        case threw(String)
    }

    static func runCheck(_ replacing: [String: String]) throws -> Outcome {
        let overlay = try OverlayRoot(replacing: replacing)
        let b = SiteBuilder(root: overlay.path)
        b.log = { _ in }
        do { return .ok(try b.run(SiteOptions(check: true))) } catch let e as SiteError { return .threw(e.message) }
    }

    static func resultsText() -> String { readString(repoRoot + "/site/data/results.json") }

    /// Edit results.json through the JSON model (figures array element by id).
    static func editFigures(_ body: (inout [PyJSON]) -> Void) throws -> String {
        guard var top = try PyJSONParser.parse(resultsText()).obj, var figs = top["figures"]?.arr else { throw SiteError("bad results.json") }
        body(&figs)
        top["figures"] = .array(figs)
        return PyJSONWriter.dumps(.object(top)) + "\n"
    }

    static func setValue(_ id: String, _ v: PyJSON) throws -> String {
        try editFigures { figs in
            for k in figs.indices where figs[k]["id"]?.str == id {
                var o = figs[k].obj!
                o["value"] = v
                figs[k] = .object(o)
            }
        }
    }

    @Test func untouchedTreeIsClean() throws {
        guard case .ok(let r) = try Self.runCheck([:]) else { Issue.record("threw"); return }
        #expect(r.exitCode == 0 && r.errors.isEmpty)
    }

    @Test func corruptedHandEnteredValueFails() throws {
        let broken = try Self.setValue("pc.4k.hit", .double(9.99))
        guard case .ok(let r) = try Self.runCheck(["site/data/results.json": broken]) else { Issue.record("threw"); return }
        #expect(r.exitCode == 1)
        #expect(r.errors.contains { $0.hasPrefix("pc.4k.hit: value 9.99 not found in bench/results/prefix-cache-exact-20261026/checkprefix-4096.log (looked for [") })
    }

    @Test func corruptedGeneratedValueIsOutOfSync() throws {
        let broken = try Self.setValue("final.d4k.strim", .double(99.9))
        guard case .ok(let r) = try Self.runCheck(["site/data/results.json": broken]) else { Issue.record("threw"); return }
        #expect(r.exitCode == 1)
        #expect(r.errors.first == "site/data/results.json is out of sync with bench/results/h2h-final-20261028 (run strim site build)")
    }

    @Test func droppedFigureIdFails() throws {
        let broken = try Self.editFigures { $0.removeAll { $0["id"]?.str == "pc.4k.hit" } }
        guard case .threw(let m) = try Self.runCheck(["site/data/results.json": broken]) else { Issue.record("expected a failure"); return }
        #expect(m.contains("pc.4k.hit"))
    }

    @Test func droppedGeneratedFigureIsOutOfSync() throws {
        let broken = try Self.editFigures { $0.removeAll { $0["id"]?.str == "final.d4k.rapid-mlx" } }
        guard case .ok(let r) = try Self.runCheck(["site/data/results.json": broken]) else { Issue.record("threw"); return }
        #expect(r.exitCode == 1)
        #expect(r.errors.contains { $0.contains("out of sync") })
    }

    static let h2hSummary = "/bench/results/h2h-final-20261028/summary.md"

    @Test func summaryCellDisagreeingWithResultsJSONFails() throws {
        let sm = readString(repoRoot + Self.h2hSummary)
        let broken = sm.replacingOccurrences(of: "| cold 4K prefill | tok/s | 980.1 |", with: "| cold 4K prefill | tok/s | 980.2 |")
        #expect(broken != sm)
        guard case .threw(let m) = try Self.runCheck(["bench/results/h2h-final-20261028/summary.md": broken]) else { Issue.record("expected a failure"); return }
        #expect(m.hasPrefix("cold 4K prefill/strim: summary.md says '980.2', results.json says 980.124"))
    }

    @Test func ratioDisagreeingWithResultsJSONFails() throws {
        let sm = readString(repoRoot + Self.h2hSummary)
        let broken = sm.replacingOccurrences(of: "| 0.99x | 0.98x | TIE | TIE |", with: "| 0.90x | 0.98x | TIE | TIE |")
        #expect(broken != sm)
        guard case .threw(let m) = try Self.runCheck(["bench/results/h2h-final-20261028/summary.md": broken]) else { Issue.record("expected a failure"); return }
        #expect(m.hasPrefix("cold 4K prefill: ratio 0.90x vs rival rapid-mlx disagrees with results.json"))
    }

    @Test func claimWordingChangedFails() throws {
        let sm = readString(repoRoot + Self.h2hSummary)
        let broken = sm.replacingOccurrences(of: "24-41% faster than rapid-mlx", with: "25-41% faster than rapid-mlx")
        #expect(broken != sm)
        guard case .threw(let m) = try Self.runCheck(["bench/results/h2h-final-20261028/summary.md": broken]) else { Issue.record("expected a failure"); return }
        #expect(m.hasPrefix("summary.md claim wording lacks '24-41% faster than rapid-mlx'"))
    }

    @Test func missingSourceFileFails() throws {
        let broken = try Self.editFigures { figs in
            for k in figs.indices where figs[k]["id"]?.str == "pc.4k.hit" {
                var o = figs[k].obj!
                o["source_path"] = .string("bench/results/does-not-exist.log")
                figs[k] = .object(o)
            }
        }
        guard case .ok(let r) = try Self.runCheck(["site/data/results.json": broken]) else { Issue.record("threw"); return }
        #expect(r.errors.contains("pc.4k.hit: source file missing: bench/results/does-not-exist.log"))
    }

    @Test func sourcePathOutsideAllowedTreesFails() throws {
        let broken = try Self.editFigures { figs in
            for k in figs.indices where figs[k]["id"]?.str == "pc.4k.hit" {
                var o = figs[k].obj!
                o["source_path"] = .string("README.md")
                figs[k] = .object(o)
            }
        }
        guard case .ok(let r) = try Self.runCheck(["site/data/results.json": broken]) else { Issue.record("threw"); return }
        #expect(r.errors.contains("pc.4k.hit: source_path outside bench/results, bench/soak, docs: README.md"))
    }

    @Test func readmeTemplateWithUnknownFigureFails() throws {
        let tpl = readString(repoRoot + "/site/README.template.md") + "\n{{no.such.figure|n}}\n"
        guard case .threw(let m) = try Self.runCheck(["site/README.template.md": tpl]) else { Issue.record("expected a failure"); return }
        #expect(m == "README template: unknown figure no.such.figure")
    }

    @Test func checkModeWritesNothing() throws {
        let overlay = try OverlayRoot(replacing: ["site/index.html": "stale", "README.md": "stale", "site/data/results.json": Self.resultsText()])
        let b = SiteBuilder(root: overlay.path)
        b.log = { _ in }
        _ = try b.run(SiteOptions(check: true))
        #expect(readString(overlay.path + "/site/index.html") == "stale")
        #expect(readString(overlay.path + "/README.md") == "stale")
    }

    @Test func buildModeWritesCommittedBytes() throws {
        let overlay = try OverlayRoot(replacing: ["site/index.html": "stale", "README.md": "stale", "site/data/results.json": Self.resultsText()])
        let b = SiteBuilder(root: overlay.path)
        var lines: [String] = []
        b.log = { lines.append($0) }
        let r = try b.run(SiteOptions())
        #expect(r.exitCode == 0)
        #expect(readString(overlay.path + "/site/index.html") == readString(repoRoot + "/site/index.html"))
        #expect(readString(overlay.path + "/README.md") == readString(repoRoot + "/README.md"))
        #expect(readString(overlay.path + "/site/data/results.json") == Self.resultsText())
        #expect(lines.contains { $0.hasPrefix("wrote site/index.html (") && $0.hasSuffix(" bytes) and README.md") })
        #expect(lines.contains { $0.hasPrefix("figures: ") && $0.contains("html links checked:") })
    }

    @Test func listFiguresPrintsOneLinePerFigure() throws {
        let b = SiteBuilder(root: repoRoot)
        var lines: [String] = []
        b.log = { lines.append($0) }
        let r = try b.run(SiteOptions(listFigures: true))
        #expect(r.exitCode == 0)
        #expect(lines.count == 387)
        #expect(lines.first?.hasPrefix("pc.4k.miss\t3.994\ts\t") == true)
    }
}
