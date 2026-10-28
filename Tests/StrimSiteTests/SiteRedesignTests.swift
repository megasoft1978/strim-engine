import Foundation
import Testing
@testable import StrimSite

/// Invariants of the README / landing redesign (docs/BRIEF-README-SITE-REDESIGN-2026-10-28.md).
@Suite struct SiteRedesignTests {
    static func build() throws -> (b: SiteBuilder, r: SiteResult) {
        let b = SiteBuilder(root: repoRoot)
        b.log = { _ in }
        return (b, try b.run(SiteOptions(check: true)))
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }
    }

    @Test func readmeIsShortWithOneHeroChart() throws {
        let (_, r) = try Self.build()
        let lines = r.readme.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(lines <= 60, "README has \(lines) lines")
        #expect(lines >= 25)
        #expect(Self.matches(#"\]\(site/assets/[^)]+\)"#, in: r.readme).count == 1)
        #expect(r.readme.contains("](site/assets/h2h-hero.svg)"))
        #expect(!r.readme.contains("33-cell") && !r.readme.contains("Scoreboard"))
    }

    @Test func installAndQuickstartOrder() throws {
        let (_, r) = try Self.build()
        func at(_ s: String) -> String.Index { r.readme.range(of: s)!.lowerBound }
        // one code block: install, pull, serve (in that order), then the token path, all before the results table
        #expect(at("brew install megasoft1978/strim/strim") < at("strim pull "))
        #expect(at("strim pull ") < at("strim serve ~/.strim/models"))
        #expect(r.readme.contains("--port 8203") && r.readme.contains("~/.strim/token"))
        #expect(at("strim serve ~/.strim/models") < at("| Measurement"))
        #expect(r.readme.components(separatedBy: "```").count == 3, "one code block")
    }

    @Test func lossesStayVisible() throws {
        let (b, r) = try Self.build()
        let losses = (b.H["cells"]?.arr ?? []).filter { c in README_GLANCE.contains(c["id"]?.str ?? "") && RIVALS.contains { c["verdict"]?[$0]?.str == "LOSS" } }
        #expect(!losses.isEmpty, "the stand-in run has loss cells in the glance set")
        #expect(r.readme.contains("| LOSS"))
        #expect(r.html.contains("<g class=\"pl\">"))   // a LOSS badge in the chart
        #expect(r.readme.contains("Not faster:"))
        #expect(r.html.contains("Where it is not faster."))
        #expect(r.readme.split(separator: "\n").filter { $0.hasPrefix("| ") && $0.contains("LOSS") }.count == losses.count)
        #expect(!r.readme.lowercased().contains("fastest overall") || r.readme.contains("No \"fastest overall\""))
    }

    @Test func runFactsAndValidityAreOnThePage() throws {
        let (b, r) = try Self.build()
        let run = b.H["run"]
        let build = run?["strim_build"]?.pyStr ?? "?"
        for page in [r.html, r.generated["site/benchmarks.html"] ?? ""] {
            #expect(page.contains(build))
            #expect(page.contains(FINAL_REL + "/summary.md"))
            #expect(page.contains(run?["date"]?.pyStr ?? "?"))
            #expect(page.contains("Validity."))
        }
        #expect(r.readme.contains(FINAL_REL + "/results.json"))
        let v = run?["validity"]
        #expect(v?["text"]?.pyStr.isEmpty == false)
        if v?["clean"]?.truthy == false { #expect(r.html.contains("Preliminary results")) }
    }

    @Test func landingTableAndMatrixAreCompact() throws {
        let (_, r) = try Self.build()
        func rows(_ id: String, _ next: String) -> Int {
            let a = r.html.range(of: "id=\"\(id)\"")!.lowerBound
            let seg = String(r.html[a..<(r.html.range(of: "id=\"\(next)\"", range: a..<r.html.endIndex)?.lowerBound ?? r.html.endIndex)])
            return seg.components(separatedBy: "<tbody>").dropFirst().first.map { $0.components(separatedBy: "<tr>").count - 1 } ?? 0
        }
        #expect(rows("compare", "faq") <= 8 && rows("compare", "faq") > 0)
        #expect(rows("results", "install") <= 8)
        #expect(Self.matches("<svg class=\"hv\"", in: r.html).count == 3)   // hero proof (3 groups) and the six-group chart (two panels); the table lives on benchmarks.html
        #expect(Self.matches("<details class=\"faq\"", in: r.html).count == 4)
        #expect(r.html.contains("class=\"term\""))
        // hero proof sits in the first section; the 8-row table is on benchmarks.html only
        let top = String(r.html[r.html.range(of: "id=\"top\"")!.lowerBound..<r.html.range(of: "id=\"proof\"")!.lowerBound])
        #expect(top.contains("<svg class=\"hv\"") && top.contains("brew install"))
        #expect(Self.matches("<tr>", in: r.html).count <= 7)   // only the 6-row comparison has a table
        #expect((r.generated["site/benchmarks.html"] ?? "").contains("Strim against each rival, median of"))
        #expect(r.html.contains("inst-brew") && r.html.contains("inst-curl") && r.html.contains("inst-src"))
    }

    @Test func everyNumberOnTheLandingPageTracesToTheData() throws {
        let (b, r) = try Self.build()
        // 1. every figure span and cell cites an id that exists
        for id in Self.matches(#"title="([a-z0-9_.\-]+\.[a-z0-9_.\-]+)""#, in: r.html).map({ $0.dropFirst(7).dropLast(1) }) {
            #expect(b.D.figs[String(id)] != nil, "unknown figure id \(id)")
        }
        // 2. in the proof, results and install sections, no decimal or percentage appears outside a cited element
        var text = r.html
        for strip in [#"(?s)<svg.*?</svg>"#, #"(?s)<span class="fig"[^>]*>.*?</span>"#, #"(?s)<td[^>]*title=[^>]*>.*?</td>"#, #"(?s)<code>.*?</code>"#, #"(?s)<pre.*?</pre>"#, #"(?s)<script>.*?</script>"#, #"<[^>]+>"#] {
            text = text.replacingOccurrences(of: strip, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"Qwen3\.8|\d+\.\d+\.\d+|2%|\d{4}-\d\d-\d\d"#, with: " ", options: .regularExpression)
        #expect(Self.matches(#"\d+\.\d+|\d+%|\d+(\.\d+)?×"#, in: text).isEmpty, "untraced numbers: \(Self.matches(#".{20}(\d+\.\d+|\d+%)"#, in: text))")
        // 3. the hero chart labels are exactly the figure values
        let known = Set(GLANCE.flatMap { id in ENGINES.map { b.D.text(fid(id, $0)) } })
        for t in Self.matches(#"(?<=>)\d+(\.\d+)?(?=</text>)"#, in: r.html) { #expect(known.contains(t), "chart label \(t) is not a figure value") }
    }

    @Test func swappingTheRunIsOneConstant() throws {
        // every presented fact derives from FINAL_REL: the generated headline carries it, nothing else hard-codes a run directory
        let (b, _) = try Self.build()
        #expect(b.H["run"]?["raw_dir"]?.pyStr == FINAL_REL)
        for f in ["Landing.swift", "Page.swift", "Pieces.swift", "Readme.swift", "Headline.swift", "Compare.swift"] {
            let src = readString(repoRoot + "/Sources/StrimSite/" + f)
            #expect(!src.contains("h2h-final-2026") && !src.contains("h2h-final2-2026"), "\(f) hard-codes a run directory")
        }
    }
}
