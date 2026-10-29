import Foundation
import Testing
@testable import StrimSite

/// Comparison charts, scoreboard and functionality matrix: data-driven from site/data/headline.json and features.json.
@Suite struct SiteComparisonTests {
    static func generated() throws -> [String: String] {
        let b = SiteBuilder(root: repoRoot)
        b.log = { _ in }
        return try b.run(SiteOptions(check: true)).generated
    }

    @Test func scoreboardTotalsMatchTheCellVerdicts() throws {
        let g = try Self.generated()
        let h = try PyJSONParser.parse(g["site/data/headline.json"] ?? "")
        let cells = h["cells"]?.arr ?? []
        let rivals = (h["run"]?["versions"]?.obj?.keys ?? []).sorted()
        var expect = Dictionary(uniqueKeysWithValues: rivals.map { ($0, ["WIN": 0, "TIE": 0, "LOSS": 0, "NC": 0]) })
        for r in h["scoreboard"]?["regimes"]?.arr ?? [] {
            for rv in rivals {
                for id in r["cells"]?.arr?.compactMap({ $0.str }) ?? [] {
                    let v = id == "whole_run" ? h["memory"]?["whole_run_verdict"]?[rv]?.str : cells.first(where: { $0["id"]?.str == id })?["verdict"]?[rv]?.str
                    #expect(v != nil, "no verdict for \(id) vs \(rv)")
                    if let v { expect[rv]![v, default: 0] += 1 }
                }
            }
        }
        for rv in rivals {
            for k in ["WIN", "TIE", "LOSS", "NC"] {
                #expect(Int(h["scoreboard"]?["total"]?[rv]?[k]?.number ?? -1) == expect[rv]![k], "\(rv) \(k)")
            }
        }
        // losses are part of the data, not hidden
        #expect(rivals.contains { (expect[$0]?["LOSS"] ?? 0) > 0 })
    }

    @Test func everyHeadlineNumberTracesToAFinalFigure() throws {
        let g = try Self.generated()
        let h = try PyJSONParser.parse(g["site/data/headline.json"] ?? "")
        let d = try SiteData(raw: try PyJSONParser.parse(readString(repoRoot + "/site/data/results.json")))
        for c in h["cells"]?.arr ?? [] {
            let id = c["id"]?.pyStr ?? ""
            for e in (h["engines"]?.obj?.keys ?? []).sorted() {
                guard let v = c["values"]?[e]?.number else { continue }
                #expect(d.figs[fid(id, e)]?.value.number == v, "\(id)/\(e)")
            }
        }
        for e in (h["engines"]?.obj?.keys ?? []).sorted() { #expect(d.figs["final.mem.\(e)"]?.value.number == h["memory"]?["whole_run"]?[e]?.number) }
    }

    @Test func chartSVGsAreSelfContainedAndSmall() throws {
        let g = try Self.generated()
        for name in ["h2h-speedup.svg", "h2h-memory.svg", "h2h-latency.svg"] {
            let svg = try #require(g["site/assets/" + name])
            #expect(svg.utf8.count < 24_000, "\(name) is \(svg.utf8.count) bytes")
            #expect(svg.contains("<title") && svg.contains("<desc") && svg.contains("role=\"img\""))
            #expect(!svg.contains("<script") && !svg.contains("href=") && !svg.contains("url("))
            #expect(!svg.replacingOccurrences(of: "http://www.w3.org/2000/svg", with: "").contains("http"))
            #expect(!svg.contains("prefers-color-scheme") && svg.contains("#14151A") && !svg.contains("url(#"), "standalone charts use flat dark surfaces and no gradients")
            var p = LinkScan(); p.feed(svg)
            #expect(p.errors.isEmpty && p.stack.isEmpty, "\(name): \(p.errors) \(p.stack)")
        }
        let hero = try #require(g["site/assets/h2h-speedup.svg"])
        #expect(hero.contains("LOSS ") && hero.contains("WIN ") && hero.contains("TIE "))
    }

    @Test func staleHeadlineJSONFailsCheck() throws {
        let source = readString(repoRoot + "/site/data/headline.json")
        let run = try PyJSONParser.parse(source)["run"]
        let build = run?["strim_build"]?.pyStr ?? ""
        let text = source.replacingOccurrences(of: "\"strim_build\": \"\(build)\"", with: "\"strim_build\": \"0000000\"")
        #expect(text != source)
        guard case .ok(let r) = try SiteCheckTests.runCheck(["site/data/headline.json": text]) else { Issue.record("threw"); return }
        #expect(r.exitCode == 1)
        #expect(r.errors.contains("site/data/headline.json is out of sync (run strim site build)"))
    }

    @Test func badFeatureStatusIsRejected() throws {
        let text = readString(repoRoot + "/site/data/features.json").replacingOccurrences(of: "\"s\": \"partial\"", with: "\"s\": \"maybe\"")
        guard case .threw(let m) = try SiteCheckTests.runCheck(["site/data/features.json": text]) else { Issue.record("expected a failure"); return }
        #expect(m.contains("bad status"))
    }

    @Test func featureRowsNameAVerifiedSourceAndUnverifiedCellsAreNotYes() throws {
        let f = try PyJSONParser.parse(readString(repoRoot + "/site/data/features.json"))
        let rows = f["rows"]?.arr ?? []
        #expect(rows.count >= 15)
        for r in rows {
            #expect(FileManager.default.fileExists(atPath: repoRoot + "/" + (r["source"]?.pyStr ?? "missing")))
            for e in ["strim", "rapid-mlx", "mlx-vlm"] {
                let note: String = (r[e]?["n"]?.pyStr ?? "").lowercased()
                let hasPlaceholder = note.contains("tbd")
                #expect(!hasPlaceholder)
            }
        }
        // the matrix keeps the rows where Strim is behind
        for id in ["breadth"] {
            #expect(rows.first(where: { $0["id"]?.str == id })?["strim"]?["s"]?.str == "no")
        }
    }
}
