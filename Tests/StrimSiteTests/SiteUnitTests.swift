import Foundation
import Testing
@testable import StrimSite

@Suite struct SiteUnitTests {
    @Test func pythonFloatRepr() {
        let cases: [(Double, String)] = [
            (63.3, "63.3"), (65.4, "65.4"), (0.0, "0.0"), (-0.0, "-0.0"), (1.0, "1.0"), (100.0, "100.0"),
            (1e16, "1e+16"), (1e15, "1000000000000000.0"), (123456789012345680.0, "1.2345678901234568e+17"),
            (0.0001, "0.0001"), (0.00001, "1e-05"), (1.5e-7, "1.5e-07"), (63.28040249981089, "63.28040249981089"),
            (0.1 + 0.2, "0.30000000000000004"), (-2.5, "-2.5"), (5e-324, "5e-324"),
        ]
        for (d, s) in cases { #expect(pyRepr(d) == s, "repr(\(d))") }
    }

    @Test func formatting() {
        #expect(fmtCommas(1234567) == "1,234,567")
        #expect(fmtCommas(999) == "999")
        #expect(fmtCommas(-1000) == "-1,000")
        #expect(fmtFixed(2.675, 2) == "2.67")      // exact binary value is below the tie, like Python
        #expect(fmtFixed(0.125, 2) == "0.12")      // exact tie rounds half to even, like Python
        #expect(pyRound(63.28040249981089, 1) == 63.3)
        #expect(esc("a&b<c>\"d'") == "a&amp;b&lt;c&gt;&quot;d&#x27;")
    }

    @Test func jsonRoundTripKeepsIntFloatAndOrder() throws {
        let text = "{\n \"b\": 1,\n \"a\": [\n  1.0,\n  2,\n  null,\n  true,\n  \"x\\u00e9\\n\\\"\"\n ],\n \"c\": {},\n \"d\": []\n}"
        let v = try PyJSONParser.parse(text)
        #expect(PyJSONWriter.dumps(v) == text.replacingOccurrences(of: "\\u00e9", with: "é"))
        #expect(v["a"]?.arr?[0] == .double(1.0))
        #expect(v["a"]?.arr?[1] == .int(2))
        #expect(v.obj?.keys == ["b", "a", "c", "d"])
    }

    @Test func markdownCells() throws {
        let c = try #require(try numCell("**63.3 (4)**"))
        #expect(c.value == 63.3 && c.dp == 1 && c.n == "4")
        #expect(try numCell("n/a") == nil)
        let p = try #require(try numCell("12.50%"))
        #expect(p.value == 12.5 && p.dp == 2 && p.n == nil)
        #expect(throws: SiteError.self) { try numCell("fast") }
        let text = "# t\n\n## Scoreboard\n\n| metric | a | b |\n|---|---|---|\n| m1 | **1.0 (3)** | 2.0 (3) |\n"
        #expect(try mdCell(text, "Scoreboard", "m1", "a") == "1.0 (3)")
        #expect(try mdCell(text, "Scoreboard", "m1", "zzz") == nil)
        #expect(throws: SiteError.self) { try mdCell(text, "Nope", "m1", "a") }
    }

    @Test func soakPatterns() {
        typealias T = Pat.Tok
        let t = "Tasks: 93 total, 77 passed (82.8%)\nrequests_total last: 758  failed: 0\nTTFT ms (n=760): first-quartile median 261.0  last-quartile median 263.5  p90 1114\nslope -3.5 MB/h"
        #expect(Pat([.lit("Tasks: "), .cap(true), .digits, .cap(false), .lit(" total")]).search(t) == "93")
        #expect(Pat([.lit("requests_total last: "), .digits, .ws, .lit("failed: "), .cap(true), .digits, .cap(false)]).search(t) == "0")
        #expect(Pat([.lit("TTFT ms"), .notNL, .lit("last-quartile median "), .cap(true), .numDot, .cap(false)]).search(t) == "263.5")
        #expect(Pat([.lit("slope "), .cap(true), .optMinus, .numDot, .cap(false), .lit(" MB/h")]).search(t) == "-3.5")
        #expect(Pat([.lit("crashes: "), .cap(true), .digits, .cap(false)]).search(t) == nil)
    }

    @Test func htmlLinkScanFlagsProblems() {
        var s = LinkScan()
        s.feed("<!doctype html><html><body><a href=\"#x\">x</a><p id=\"a\"><p id=\"a\"></div><rect id=\"r\"/><br></body>")
        #expect(s.hrefs == ["#x"])
        #expect(s.errors.contains("duplicate id a"))
        #expect(s.errors.contains { $0.hasPrefix("unbalanced </div>") })
        #expect(s.ids.contains("r"))
    }
}
