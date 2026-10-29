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
        #expect(lines <= 45, "README has \(lines) lines")
        #expect(lines >= 15)
        #expect(r.readme.contains("site/assets/app/readme-hero-dark.png") && r.readme.contains("site/assets/app/readme-hero-light.png") && r.readme.contains("site/assets/readme/wordmark-dark.svg"), "themed hero screenshots and wordmark")
        #expect(r.readme.contains("img.shields.io") && r.readme.contains("https://megasoft1978.github.io/strim-engine/"))
        #expect(r.readme.contains("| Workload") && r.readme.contains("x, slower"), "the cold 32K loss row is in the table")
    }

    @Test func bothInstallPathsAndTheQuickstart() throws {
        let (_, r) = try Self.build()
        func at(_ s: String) -> String.Index { r.readme.range(of: s)!.lowerBound }
        #expect(at("brew install megasoft1978/strim/strim") < at("strim pull"))
        #expect(r.readme.contains("not notarized yet"))
        #expect(at("strim pull") < at("strim serve ~/.strim/models"))
        #expect(r.readme.contains("--port 8203"))
        #expect(r.html.contains("inst-brew") && r.html.contains("inst-curl") && r.html.contains("inst-dmg"))
        #expect(r.html.contains("brew install --cask megasoft1978/strim/strim-app") && r.readme.contains("strim-app"))
        #expect(r.html.contains("Not notarized yet: right-click &rarr; Open the first time."), "the DMG tab says so honestly")
        #expect(r.html.contains("brew install megasoft1978/strim/strim") && r.html.contains("packaging/install.sh | bash"))
    }

    @Test func lossesStayVisible() throws {
        let (b, r) = try Self.build()
        let losses = (b.H["cells"]?.arr ?? []).filter { c in GLANCE.contains(c["id"]?.str ?? "") && b.RIVALS.contains { c["verdict"]?[$0]?.str == "LOSS" } }
        #expect(!losses.isEmpty, "the stand-in run has loss cells in the glance set")
        #expect(b.speedLosses().count == losses.count)
        #expect(b.allClaimLosses().count == 10, "all ten current claim-eligible losses are reported from results.json")
        #expect(r.html.contains("All losses: <a href=\"benchmarks.html\">benchmarks</a>."))
        #expect(b.lossLine().contains("c=4 512-token aggregate") && b.lossLine().contains("c=8 512-token p95 first token"))
        let slow = b.ladderRows().filter { $0.verdict == "LOSS" }
        #expect(!slow.isEmpty && Self.matches("<div class=\"lr slow\"", in: r.html).count == slow.count, "a loss row is drawn in the ratio ladder")
        #expect(r.html.contains("Grey bars left of 1x are where Strim is slower"))
        #expect(!r.readme.lowercased().contains("fastest overall"))
        #expect(r.readme.contains("Not a fit if you want many models"), "the why-not-Strim line")
    }

    @Test func runFactsAndValidityAreOnTheBenchmarksPage() throws {
        let (b, r) = try Self.build()
        let run = b.H["run"]
        let page = r.generated["site/benchmarks.html"] ?? ""
        #expect(page.contains(run?["strim_build"]?.pyStr ?? "?"))
        #expect(page.contains(FINAL_REL + "/summary.md"))
        #expect(page.contains(run?["date"]?.pyStr ?? "?"))
        #expect(page.contains("Validity."))
        for e in b.RIVALS {
            #expect(page.contains(b.engLabel(e)))
            if let version = b.engVersion(e) { #expect(page.contains(version)) }
        }
        let v = run?["validity"]
        #expect(v?["text"]?.pyStr.isEmpty == false)
        if v?["clean"]?.truthy == false {
            #expect(page.contains("primary sessions were clean") && r.html.contains("sessions were clean"))
            #expect(page.contains("#method") && page.contains("#r-final"))
        }
        #expect(!r.html.contains("Validity."), "the landing page only carries a one-line note")
    }

    /// The hero chart is parsed from the wide-field run summary, not typed.
    @Test func wideFieldChartComesFromTheRunSummary() throws {
        let (b, r) = try Self.build()
        let bars = b.wideBars()
        #expect(bars.count == 7)
        #expect(bars.first?.strim == true, "Strim leads the wide-field decode row")
        #expect(bars.filter(\.earlier).map(\.name).sorted() == ["llama.cpp", "Ollama"].sorted())
        #expect(bars.map(\.value) == bars.map(\.value).sorted(by: >))
        let page = r.generated["site/benchmarks.html"] ?? ""
        #expect(page.contains("id=\"wide\"") && page.contains("oMLX") && page.contains("n/a"))
        #expect(page.contains("llama.cpp and Ollama from the 2026-10-26 run"))
        // landing FIG 1: the five current engines of the head-to-head run, sorted, Strim first, value labels from the cell values
        let rows = Self.matches("<div class=\"r(?: strim)?\" role=\"listitem\">", in: r.html)
        #expect(rows.count == b.ENGINES.count && rows.first == "<div class=\"r strim\" role=\"listitem\">")
        #expect(r.html.contains("Method: medians of") && r.html.contains(b.runDate) && r.html.contains(b.runBuild))
        #expect(page.contains("class=\"hv nl vw\""), "the benchmarks page draws the wide field too")
    }

    @Test func parsesTheScoreboardTable() {
        let md = "intro\n\n| metric | strim | llama.cpp | tensorfold-ctx64k |\n|---|---|---|---|\n| W3 4K cold decode tok/s | **61.9 (4)** | n/a | 29.5 (3) |\n"
        let t = parseWideScoreboard(md)
        #expect(t?.engines == ["strim", "llama.cpp"])
        #expect(t?.rows.first?.cells == [WideCell(raw: "**61.9 (4)**", value: 61.9, best: true), WideCell(raw: "n/a", value: nil, best: false)])
    }

    @Test func landingIsShortAndHasTheTwoVisuals() throws {
        let (b, r) = try Self.build()
        #expect(Self.matches("<figure class=\"fig[12]\"", in: r.html).count == 2, "FIG 1 decode bars and FIG 2 ratio ladder")
        #expect(Self.matches("<div class=\"lr(?: slow| tie)?\"", in: r.html).count == b.ladderRows().count)
        #expect(!r.html.contains("<svg class=\"hv nl") && !r.html.contains("class=\"card"), "the dial cards and the number line are gone")
        #expect(Self.matches("<details class=\"faq\"", in: r.html).count == 7)
        #expect(Self.matches("<table", in: r.html).count == 1, "only the FIG 1 data table")
        #expect(!r.html.contains("class=\"statement\"") && !r.html.contains("--wash") && !r.html.contains("dashed"))
        let top = String(r.html[r.html.range(of: "id=\"top\"")!.lowerBound..<r.html.range(of: "id=\"field\"")!.lowerBound])
        #expect(top.contains("brew install") && top.contains("Qwen3.8-27B"))
        #expect(r.html.count < 60_000)
        for tag in ["<title>", "name=\"description\"", "property=\"og:image\"", "name=\"twitter:card\"", "name=\"theme-color\"", "rel=\"canonical\" href=\"https://megasoft1978.github.io/strim-engine/\""] {
            #expect(r.html.contains(tag), "missing \(tag)")
        }
        #expect((r.generated["site/benchmarks.html"] ?? "").contains("Strim against each rival, median of"))
    }

    @Test func everyNumberOnTheLandingPageTracesToTheData() throws {
        let (b, r) = try Self.build()
        // 1. every figure span cites an id that exists
        for id in Self.matches(#"title="([a-z0-9_.\-]+\.[a-z0-9_.\-]+)""#, in: r.html).map({ $0.dropFirst(7).dropLast(1) }) {
            #expect(b.D.figs[String(id)] != nil, "unknown figure id \(id)")
        }
        // 2. no decimal or percentage appears in the page text outside a cited element; the loss line is computed from the cells (checked in lossesStayVisible)
        var text = r.html
        for strip in [#"FIG \d+\.\d+"#, #"(?s)<(b|p|i|span)[^>]*class="[^"]*\bgen\b[^"]*"[^>]*>.*?</\1>"#, #"(?s)<svg.*?</svg>"#, #"(?s)<span class="fig"[^>]*>.*?</span>"#, #"(?s)<p class="honest">.*?</p>"#, #"(?s)<code>.*?</code>"#, #"(?s)<script>.*?</script>"#, #"<[^>]+>"#] {
            text = text.replacingOccurrences(of: strip, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"Qwen3\.8|\d+\.\d+\.\d+|\d{4}-\d\d-\d\d"#, with: " ", options: .regularExpression)
        #expect(Self.matches(#"\d+\.\d+|\d+%|\d+(\.\d+)?×"#, in: text).isEmpty, "untraced numbers: \(Self.matches(#".{20}(\d+\.\d+|\d+%)"#, in: text))")
        // 3. every ladder row shows exactly the computed ratio of Strim over the closest rival
        let expected = b.ladderRows().map { ratioLabel($0.ratio) }
        let shown = Self.matches(#"(?<=<span class="lv"><span class="gen">)\d+\.\d+x(?=</span>)"#, in: r.html)
        #expect(shown == expected, "ladder shows \(shown), data says \(expected)")
        #expect(expected.count == 8)
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

/// Ratio maths and gauge geometry of the quiet modern redesign.
@Suite struct SiteQuietModernTests {
    static func builder(_ cellsJSON: String) throws -> SiteBuilder {
        let b = SiteBuilder(root: repoRoot)
        b.H = try PyJSONParser.parse("{\"cells\": \(cellsJSON)}")
        return b
    }

    /// Latency cells (better = lower) are inverted so that above 1.0x always means Strim is faster; throughput cells are not.
    @Test func ratiosAreInvertedForLatencyCells() throws {
        let b = try Self.builder("""
        [{"id":"lat","better":"lower","values":{"strim":2.0,"rapid-mlx":3.0,"mlx-vlm":4.0}},
         {"id":"slow","better":"lower","values":{"strim":5.0,"rapid-mlx":3.0,"mlx-vlm":4.0}},
         {"id":"thr","better":"higher","values":{"strim":50,"rapid-mlx":40,"mlx-vlm":60}}]
        """)
        #expect(b.rivalRatio("lat", "rapid-mlx") == 1.5 && b.rivalRatio("lat", "mlx-vlm") == 2.0, "faster first token = ratio above 1")
        #expect(b.rivalRatio("slow", "rapid-mlx") == 0.6, "a slower first token is a ratio below 1")
        #expect(b.speedRatio("lat") == 1.5, "the best rival decides")
        #expect(b.rivalRatio("thr", "rapid-mlx") == 1.25)
        #expect(abs((b.rivalRatio("thr", "mlx-vlm") ?? 0) - 50.0 / 60.0) < 1e-12)
        #expect(b.speedRatio("thr") == b.rivalRatio("thr", "mlx-vlm"))
        #expect(ratioLabel(0.96) == "0.96x" && ratioLabel(1.482) == "1.48x")
        #expect(ratioOf(strim: 2, rival: 3, lowerBetter: true) == 1.5 && ratioOf(strim: 3, rival: 2, lowerBetter: false) == 1.5)
    }

    @Test func realDataRatiosMatchTheVerdicts() throws {
        let b = SiteBuilder(root: repoRoot)
        b.log = { _ in }
        _ = try b.run(SiteOptions(check: true))
        for id in GLANCE {
            guard let c = b.hCell(id) else { Issue.record("missing cell \(id)"); continue }
            for rv in b.RIVALS {
                if ["NC", "n/a"].contains(c["verdict"]?[rv]?.str ?? "") {
                    #expect(c["not_claimable"]?[rv]?.str != nil, "\(id) vs \(rv) must retain its eligibility reason")
                    continue
                }
                guard let r = b.rivalRatio(id, rv), let sp = c["speedup"]?[rv]?.number else { Issue.record("no ratio \(id) \(rv)"); continue }
                #expect(abs(r - sp) < 0.006, "\(id) vs \(rv): computed \(r), summary \(sp)")
                #expect((c["verdict"]?[rv]?.str == "LOSS") == (r < 0.98), "\(id) vs \(rv) verdict and ratio disagree")
            }
        }
    }

    /// Arc gauge: the 1.0x tick sits left of centre on a 0.5x to 3.2x log scale; wins sweep right, losses sweep left.
    @Test func gaugeArcReflectsTheRatio() throws {
        let b = try Self.builder("[]")
        let win = b.gaugeSVGInner(1.5), loss = b.gaugeSVGInner(0.9)
        #expect(win.contains("A32 32 0 0 1 ") && !win.contains("lose"))
        #expect(loss.contains("A32 32 0 0 0 ") && loss.contains("gv lose"))
        #expect(win.contains("M27.6 10.5A32 32"), "the arc starts at the 1.0x tick")
    }

    @Test func wideFieldHasFiveCurrentEnginesAndTwoEarlierBeads() throws {
        let b = SiteBuilder(root: repoRoot)
        b.log = { _ in }
        _ = try b.run(SiteOptions(check: true))
        let svg = b.numberLineSVG(narrow: false, standalone: true)
        #expect(Self.count("class=\"nldot\"", in: svg) == 4 && Self.count("class=\"nldot earlier-run\"", in: svg) == 2 && svg.contains("class=\"strim-dot\""))
        #expect(svg.contains(b.wideNumeral()) && b.wideBars().count == 7)
        let narrow = b.numberLineSVG(narrow: true, standalone: false)
        #expect(Self.count("class=\"nldot\"", in: narrow) == 4 && Self.count("class=\"nldot earlier-run\"", in: narrow) == 2)
    }

    static func count(_ s: String, in t: String) -> Int { t.components(separatedBy: s).count - 1 }

    @Test func noGreenAnywhere() throws {
        #expect(!greenColours(in: "a{color:#00aa55}").isEmpty && !greenColours(in: "#3c9").isEmpty && !greenColours(in: "fill=\"#4cc9b0\"").isEmpty)
        #expect(greenColours(in: "#7C7CF5 #9393FF #0C0D10 #ECEDEF #A3A6B1 #4F46E5 #FAFAFB #131419").isEmpty, "the palette contains no green")
        for rel in ["site/assets/style.css", "site/assets/banner.svg", "site/assets/logo.svg", "site/assets/favicon.svg", "site/assets/h2h-hero.svg", "site/assets/h2h-ratio.svg",
                    "site/assets/h2h-speedup.svg", "site/assets/h2h-memory.svg", "site/assets/h2h-latency.svg", "site/assets/app-icon.svg", "site/index.html", "site/benchmarks.html"] {
            #expect(greenColours(in: readString(repoRoot + "/" + rel)).isEmpty, "\(rel) contains a green colour")
        }
        #expect(!readString(repoRoot + "/site/assets/style.css").lowercased().contains("green"))
    }

    /// Batch 3 README rules: 45 lines, no placeholders, no capitalised verdicts, 3 significant figures, every number from the run data.
    @Test func readmeBatch3Rules() throws {
        let (b, r) = try SiteRedesignTests.build()
        #expect(r.readme.split(separator: "\n", omittingEmptySubsequences: false).count <= 45)
        #expect(SiteRedesignTests.matches("\\{[a-z_0-9@.|]+\\}", in: r.readme).isEmpty, "no unfilled placeholders")
        #expect(!r.readme.contains("WIN") && !r.readme.contains("LOSS"))
        #expect(r.readme.contains("--port 8203") && r.readme.contains("ANTHROPIC_BASE_URL") && r.readme.contains("OPENAI_BASE_URL"))
        let table = r.readme.split(separator: "\n").filter { $0.hasPrefix("|") }
        #expect(table.count == 8, "header, rule and six rows (4 and 8 requests are separate rows)")
        for tok in table.joined(separator: " ").split(whereSeparator: { !"0123456789.".contains($0) }) {
            var digits = Array(tok.filter { $0.isNumber }.drop(while: { $0 == "0" }))
            if !tok.contains(".") { while digits.last == "0" { digits.removeLast() } }
            #expect(digits.count <= 3, "\(tok) has more than 3 significant figures")
        }
        #expect(sig3(75.34) == "75.3" && sig3(9.773) == "9.77" && sig3(0.958) == "0.958" && sig3(1.023) == "1.02" && sig3(37.06) == "37.1" && sig3(99.96) == "100" && sig3(1962) == "1960" && sig3(15260) == "15300")
        let d = b.H["cells"]?.arr?.first { $0["id"]?.str == "d4k" }
        #expect(r.readme.contains("| \(sig3(d?["values"]?["strim"]?.number ?? 0)) |"), "decode 4K comes from the run data")
        #expect(r.readme.contains("macOS ") && r.readme.contains(b.H["run"]?["date"]?.pyStr ?? "?") && r.readme.contains("build \(b.H["run"]?["strim_build"]?.pyStr ?? "?")"))
    }

    @Test func readmeAssetsAreEmittedForBothThemes() throws {
        let (_, r) = try SiteRedesignTests.build()
        for n in ["wordmark-dark", "wordmark-light", "decode-dark", "decode-light"] {
            let rel = "site/assets/readme/\(n).svg"
            #expect(r.generated[rel] != nil && readString(repoRoot + "/" + rel) == r.generated[rel], "\(rel) is generated and in sync")
            let s = r.generated[rel] ?? ""
            #expect(greenColours(in: s).isEmpty && !s.contains("<filter") && (!n.hasPrefix("wordmark") || !s.contains("<text")), "\(rel)")
            #expect(!s.contains("Space Grotesk") && !s.contains("href=\"http"))
        }
        #expect((r.generated["site/assets/readme/decode-dark.svg"] ?? "").contains("75.3"))
    }

    /// README SVGs are shown by GitHub as images: system fonts only, no filters, no external references.
    @Test func readmeSVGsAreSelfContained() throws {
        for rel in ["banner.svg", "h2h-ratio.svg", "h2h-hero.svg", "logo.svg", "readme/wordmark-dark.svg", "readme/wordmark-light.svg", "readme/decode-dark.svg", "readme/decode-light.svg"] {
            let s = readString(repoRoot + "/site/assets/" + rel)
            #expect(!s.contains("<filter") && !s.contains("feGaussianBlur") && !s.contains("@import") && !s.contains("url(http") && !s.contains("href=\"http"), "\(rel)")
            #expect(!s.contains("Space Grotesk") || s.contains("-apple-system"), "\(rel): no web font dependency")
        }
    }
}
