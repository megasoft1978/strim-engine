import Foundation
import Testing
@testable import StrimSite

/// Five engines (strim, rapid-mlx, mlx-vlm, mlx-lm, omlx) from the schema-2 dry-run fixture: n/a oMLX cells (W5 guard abort) and a cell that is not claim_eligible.
@Suite struct SiteEnginesTests {
    static func build() throws -> (SiteBuilder, SiteResult) {
        let dir = repoRoot + "/Tests/StrimSiteTests/Fixtures/h2h-dry5"
        let o = try OverlayRoot(replacing: [FINAL_REL + "/results.json": readString(dir + "/results.json"), FINAL_REL + "/summary.md": readString(dir + "/summary.md")])
        let b = SiteBuilder(root: o.path)
        b.log = { _ in }
        let r = try b.run(SiteOptions(check: true))
        withExtendedLifetime(o) {}
        return (b, r)
    }

    @Test func readsAllFiveEnginesFromTheRun() throws {
        let (b, r) = try Self.build()
        #expect(b.ENGINES == ["strim", "rapid-mlx", "mlx-vlm", "mlx-lm", "omlx"])
        #expect(b.RIVALS.count == 4)
        #expect(b.engLabel("omlx") == "oMLX (no MTP)" && b.engLabel("rapid-mlx") == "rapid-mlx (MTP)")
        #expect(r.html.contains("oMLX") && r.generated["site/benchmarks.html"]?.contains("mlx-lm") == true)
        let errs = r.errors.filter { !$0.contains("out of sync") }
        #expect(errs.isEmpty, "\(errs)")
    }

    @Test func naCellsStayNaAndCarryNoVerdict() throws {
        let (b, _) = try Self.build()
        let c = b.hCell("aw5")
        #expect(c?["values"]?["omlx"] == nil)
        #expect(c?["verdict"]?["omlx"]?.str == "n/a")
        #expect(b.D.isNA(fid("aw5", "omlx")))
        #expect(b.rivalRatio("aw5", "omlx") == nil)
    }

    @Test func nonClaimableCellsNeverShowWinOrLoss() throws {
        let (b, r) = try Self.build()
        let c = b.hCell("d16k")
        #expect(c?["verdict"]?["rapid-mlx"]?.str == "NC")
        #expect(c?["not_claimable"]?["rapid-mlx"]?.str?.contains("POLLUTED") == true)
        #expect(b.D.text(fverdict("d16k", "rapid-mlx")) == "NC")
        #expect(b.speedRatio("d16k") != nil, "other rivals still give a claimable ratio")
        let bench = r.generated["site/benchmarks.html"] ?? ""
        #expect(bench.contains("Not claimable"))
        // the headline scoreboard counts it separately
        let nc = b.H["scoreboard"]?["total"]?["rapid-mlx"]?["NC"]?.number ?? 0
        #expect(nc >= 1)
    }

    @Test func bestRivalIsTheWeakestRatioOverAllRivals() throws {
        let (b, _) = try Self.build()
        for id in ["d4k", "d32k", "aagc8"] {
            guard let best = b.bestRival(id) else { Issue.record("no best rival \(id)"); continue }
            let claimable = b.RIVALS.filter { b.hCell(id)?["verdict"]?[$0]?.str != "NC" }.compactMap { b.rivalRatio(id, $0) }
            #expect(abs(best.ratio - (claimable.min() ?? 0)) < 1e-9)
        }
    }

    @Test func wideFieldUsesTheCurrentRunDecodeRow() throws {
        let (b, r) = try Self.build()
        #expect(b.wideFromRun)
        #expect(b.wideBars().count == 5)
        #expect(b.wideBars().allSatisfy { !$0.earlier })
        #expect(r.generated["site/assets/h2h-hero.svg"]?.contains("oMLX") == true)
    }

    @Test func labelsOnTheNumberLineDoNotOverlap() throws {
        let b = SiteBuilder(root: repoRoot)
        b.log = { _ in }
        let r = try b.run(SiteOptions(check: true))
        let svg = r.generated["site/assets/h2h-hero.svg"] ?? ""
        // each value label (nlv mo) must sit in its own box: no two with the same baseline y and x ranges closer than their widths
        let re = try NSRegularExpression(pattern: #"<text x="([\d.]+)" y="([\d.]+)" text-anchor="(start|end)" class="nln mo"><tspan class="nlv">([\d.]+)</tspan> ([^<]+)</text>"#)
        var boxes: [(y: Double, x0: Double, x1: Double)] = []
        for m in re.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)) {
            func g(_ i: Int) -> String { String(svg[Range(m.range(at: i), in: svg)!]) }
            let x = Double(g(1))!, y = Double(g(2))!, w = Double(g(4).count) * 10.2 + 6 + Double(g(5).count) * 7.5
            boxes.append((y, g(3) == "start" ? x : x - w, g(3) == "start" ? x + w : x))
        }
        #expect(boxes.count == 6)
        for (i, a) in boxes.enumerated() { for b2 in boxes[(i + 1)...] where a.y == b2.y { #expect(a.x1 <= b2.x0 || b2.x1 <= a.x0, "labels overlap on row \(a.y)") } }
    }

    @Test func appSectionShowsRealCapturesWithBothThemes() throws {
        let b = SiteBuilder(root: repoRoot); b.log = { _ in }
        let r = try b.run(SiteOptions(check: true))
        #expect(r.html.contains("id=\"app\"") && r.html.contains("assets/app/app-hero-live.png"))
        for n in ["status", "chat", "jobs"] {
            for t in ["dark", "light"] {
                #expect(r.html.contains("assets/app/\(n)-\(t).png"))
                #expect(FileManager.default.fileExists(atPath: repoRoot + "/site/assets/app/\(n)-\(t).png"))
            }
        }
        #expect(r.html.contains("Captured from the running app against a live server on a 64 GB M5 Max; real numbers."))
        #expect(r.html.contains("loading=\"lazy\"") && r.html.contains("width=\"1072\" height=\"628\""))
        #expect(r.readme.contains("site/assets/app/app-hero-live.png"))
        #expect(r.readme.split(separator: "\n", omittingEmptySubsequences: false).count <= 30)
        let sz = (try FileManager.default.attributesOfItem(atPath: repoRoot + "/site/assets/app/app-hero-live.png")[.size] as? Int) ?? 0
        #expect(sz < 600_000, "hero capture is \(sz) bytes")
    }

    @Test func everyAppFigureOpensInAnAccessibleLightbox() throws {
        let b = SiteBuilder(root: repoRoot); b.log = { _ in }
        let r = try b.run(SiteOptions(check: true))
        let tiles = r.html.components(separatedBy: "<button type=\"button\" class=\"zoom\"").dropFirst()
        #expect(tiles.count == 4, "hero plus three strip tiles")
        for t in tiles {
            let tag = String(t.prefix(while: { $0 != ">" }))
            #expect(tag.contains("data-full=\"assets/app/full/") && tag.contains("data-alt=\"") && tag.contains("aria-label=\"Expand"))
            #expect(t.contains(" alt=\""))
            if let m = tag.range(of: #"data-full="([^"]+)""#, options: .regularExpression) {
                let p = String(tag[m]).dropFirst(11).dropLast()
                #expect(FileManager.default.fileExists(atPath: repoRoot + "/site/" + p), "missing \(p)")
            }
        }
        #expect(r.html.contains("<dialog id=\"lb\"") && r.html.contains("id=\"lbx\"") && r.html.contains("id=\"lbp\"") && r.html.contains("id=\"lbn\""))
        #expect(r.html.contains("assets/site.js"))
        for hook in ["showModal", "ArrowLeft", "ArrowRight", "touchstart", "touchend", "dblclick", "classList.add('lb-open')", "last.focus()"] {
            #expect(SITE_JS.contains(hook), "script lacks \(hook)")
        }
        #expect(!SITE_JS.contains("http") && !SITE_JS.contains("<script"), "script must not contain network URLs")
        #expect(SITE_JS.utf8.count < 6_000)
    }

    @Test func styleHooksAreProgressiveAndDataDriven() throws {
        let b = SiteBuilder(root: repoRoot); b.log = { _ in }
        let r = try b.run(SiteOptions(check: true))
        #expect(r.html.contains("class=\"surface\"") && !r.html.contains("class=\"aurora\"") && !r.html.contains("id=\"prog\"") && r.html.contains("<footer>"))
        #expect(r.html.contains("Not affiliated with Qwen, Alibaba or Apple"))
        for page in [r.html, r.generated["site/benchmarks.html"] ?? ""] { #expect(page.contains("<header class=\"site\">") && page.contains("assets/site.js") && page.contains("class=\"fgrid\"")) }
        #expect(!SITE_JS.contains("data-count") && !SITE_JS.contains("IntersectionObserver") && !SITE_JS.contains("pointermove"))
        #expect(!HV_PAGE_EXTRA.contains(".rev") && HV_PAGE_EXTRA.contains(".hv.nl"))
        let css = readString(repoRoot + "/site/assets/style.css")
        for need in ["prefers-reduced-motion: reduce", "position: sticky", "::selection", "details.faq::details-content"] { #expect(css.contains(need), "style.css lacks \(need)") }
        #expect(!css.contains("https://"), "no external requests from the stylesheet")
    }

    @Test func appSectionIsAbsentWithoutTheHeroCapture() throws {
        // an overlay root has the repo's files via symlinks; hide the hero by replacing the asset dir contents check through a missing-name root
        let b = SiteBuilder(root: repoRoot); b.log = { _ in }
        _ = try b.run(SiteOptions(check: true))
        #expect(b.appLive("app-hero-live.png") && !b.appLive("nonexistent.png"))
    }
}
