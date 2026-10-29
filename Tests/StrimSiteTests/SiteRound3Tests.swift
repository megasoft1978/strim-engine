import Foundation
import Testing
@testable import StrimSite

/// Round-3 site fixes: command wrapping on mobile, collapsed not-claimable list, nowrap run date, caption comma.
@Suite struct SiteRound3Tests {
    @Test func commandStylesNeverBreakMidToken() throws {
        let css = readString(repoRoot + "/site/assets/style.css")
        #expect(!css.contains("overflow-wrap: anywhere") && !css.contains("overflow-wrap:anywhere"))
        #expect(css.contains(".cmdchip code { text-align: left; font-size: .78rem; }"))
    }

    @Test func commandsHaveWbrButCopyTextHasNone() throws {
        let (_, r) = try SiteRedesignTests.build()
        #expect(r.html.contains("ANTHROPIC_BASE_URL=<wbr>http://127.0.0.1:8203"))
        #expect(r.html.contains("OPENAI_BASE_URL=<wbr>http://127.0.0.1:8203/v1"))
        #expect(r.html.contains("brew install <wbr>megasoft1978/strim/strim"))
        for m in SiteRedesignTests.matches(#"data-copy="[^"]*""#, in: r.html) { #expect(!m.contains("wbr"), "\(m)") }
        #expect(!r.html.contains("&lt;wbr"))
    }

    @Test func notClaimableListIsCollapsedAndRunDateDoesNotWrap() throws {
        let (_, r) = try SiteRedesignTests.build()
        let bm = try #require(r.generated["site/benchmarks.html"])
        let range = try #require(bm.range(of: "<details><summary><strong>Not claimable:</strong>"))
        let tail = String(bm[range.lowerBound...])
        let close = try #require(tail.range(of: "</details>"))
        #expect(tail[..<close.lowerBound].contains("<ul><li>"))
        #expect(bm.contains("<span style=\"white-space:nowrap\">2026-"))
    }

    @Test func captionsHaveCommaBeforeWhile() throws {
        let (_, r) = try SiteRedesignTests.build()
        #expect(r.html.contains("64 GB, while "))
        #expect(r.readme.contains("64 GB, while "))
    }
}
