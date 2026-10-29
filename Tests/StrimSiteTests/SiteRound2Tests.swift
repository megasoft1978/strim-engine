import Foundation
import Testing
@testable import StrimSite

/// Round-2 review fixes: data-driven hero caption, real image sizes, one peak-memory range, 2-decimal ratios, no dashed loss styling.
@Suite struct SiteRound2Tests {
    static func pngSize(_ path: String) -> (Int, Int)? {
        guard let d = FileManager.default.contents(atPath: path), d.count >= 24 else { return nil }
        func be(_ o: Int) -> Int { (Int(d[o]) << 24) | (Int(d[o + 1]) << 16) | (Int(d[o + 2]) << 8) | Int(d[o + 3]) }
        return (be(16), be(20))
    }

    @Test func heroCaptionIsDataDrivenFromLiveStatus() throws {
        let live = readString(repoRoot + "/docs/img/app-live/live-status.json")
        let n = Int(try #require(PyJSONParser.parse(live)["active_jobs"]?.number))
        let (b, r) = try SiteRedesignTests.build()
        let expected = "Live capture on \(b.runHW), while \(n) agent \(n == 1 ? "job was" : "jobs were") running. The benchmarks below run one request at a time."
        #expect(b.liveCaptionText() == expected)
        #expect(r.html.contains(expected))
        #expect(r.readme.contains(expected), "README hero caption is the same sentence")
        #expect(!r.html.contains("Live capture: one request on"))
        // a changed capture changes the caption
        let o = try OverlayRoot(replacing: ["docs/img/app-live/live-status.json": live.replacingOccurrences(of: "\"active_jobs\":\(n)", with: "\"active_jobs\":7")])
        let b2 = SiteBuilder(root: o.path)
        b2.log = { _ in }
        let r2 = try b2.run(SiteOptions(check: true))
        #expect(r2.html.contains("while 7 agent jobs were running") && r2.readme.contains("while 7 agent jobs were running"))
    }

    @Test func imageDimensionAttributesMatchThePNGFiles() throws {
        let (_, r) = try SiteRedesignTests.build()
        let imgs = SiteRedesignTests.matches(#"<(?:img|source)[^>]*assets/app/[^>]*>"#, in: r.html)
        #expect(imgs.count >= 10)
        var checked = 0
        for tag in imgs {
            let src = try #require(SiteRedesignTests.matches(#"(?:src|srcset)="assets/app/([^"]+\.png)""#, in: tag).first)
            let file = String(src.split(separator: "/").last!.dropLast(1))
            guard tag.hasPrefix("<img") || tag.contains("width=") else { Issue.record("no size on \(tag)"); continue }
            let w = Int(SiteRedesignTests.matches(#"width="(\d+)""#, in: tag).first.map { String($0.dropFirst(7).dropLast(1)) } ?? "")
            let h = Int(SiteRedesignTests.matches(#"height="(\d+)""#, in: tag).first.map { String($0.dropFirst(8).dropLast(1)) } ?? "")
            let actual = try #require(Self.pngSize(repoRoot + "/site/assets/app/" + file), "unreadable \(file)")
            #expect(w == actual.0 && h == actual.1, "\(file): html \(String(describing: w))x\(String(describing: h)) vs file \(actual.0)x\(actual.1)")
            checked += 1
        }
        #expect(checked >= 10)
    }

    @Test func peakMemoryRangeIsOneHelperForSiteAndReadme() throws {
        let (b, r) = try SiteRedesignTests.build()
        let m = try #require(b.peakMemoryRange())
        let lo = fmtFixed(m.lo.v, 1), hi = fmtFixed(m.hi.v, 1)
        #expect(r.readme.contains(lo == hi ? lo : "\(lo)-\(hi)"))
        let tile = try #require(SiteRedesignTests.matches(#"peak memory, vs .*?GB for [^<]*"#, in: r.html).first)
        #expect(tile.contains(">\(lo)<") && (lo == hi || tile.contains(">\(hi)<")))
        // a rival that aborted in a README row never defines the range
        for rv in b.RIVALS where !b.readmeTableRivals().contains(rv) { #expect(!m.rivals.contains(rv)) }
    }

    @Test func ratiosHaveTwoDecimalsInReadmeAndSite() throws {
        let (_, r) = try SiteRedesignTests.build()
        #expect(SiteRedesignTests.matches(#"\*{0,2}\d+\.\d+x"#, in: r.readme).allSatisfy { $0.replacingOccurrences(of: "*", with: "").range(of: #"^\d+\.\d\dx$"#, options: .regularExpression) != nil })
        #expect(!r.readme.contains("0.958x") && !r.readme.contains("0.966x"))
        #expect(!r.readme.contains("slower / **"), "the 4 and 8 request rows are separate")
    }

    @Test func styleCssHasNoDashedLossStyling() {
        let css = readString(repoRoot + "/site/assets/style.css")
        let rules = css.components(separatedBy: "}")
        for rule in rules {
            guard let brace = rule.firstIndex(of: "{") else { continue }
            let sel = rule[..<brace], body = rule[rule.index(after: brace)...]
            if sel.contains("loss") || sel.contains("behind") || sel.contains("notahead") || sel.contains(".nc") || sel.contains("slow") {
                #expect(!body.contains("dashed") && !body.contains("dasharray"), "dashed loss styling in: \(sel.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        #expect(!css.contains("dasharray:5 4"))
    }

    @Test func fig2TieRowHasNoBarAndLossCaptionIsAccurate() throws {
        let (_, r) = try SiteRedesignTests.build()
        #expect(r.html.contains("Grey bars left of 1x are where Strim is slower."))
        #expect(!r.html.contains("Numbers are generated by"))
        for row in SiteRedesignTests.matches(#"<div class="lr tie".*?</div>"#, in: r.html) { #expect(!row.contains("<b style")) }
    }
}
