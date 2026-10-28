import Foundation
import Testing
@testable import StrimSite

@Suite struct SiteEquivalenceTests {
    /// The gate: the Swift builder, run on the committed inputs, must regenerate the committed outputs byte for byte.
    @Test func regeneratesCommittedOutputsByteForByte() throws {
        let b = SiteBuilder(root: repoRoot)
        b.log = { _ in }
        let res = try b.run(SiteOptions(check: true))
        #expect(res.errors.isEmpty, "check errors: \(res.errors)")
        #expect(res.exitCode == 0)
        let html = readString(repoRoot + "/site/index.html")
        #expect(res.html.utf8.count == html.utf8.count)
        #expect(res.html == html)
        let readme = readString(repoRoot + "/README.md")
        #expect(res.readme == readme)
        let data = readString(repoRoot + "/site/data/results.json")
        #expect(res.dataJSON == data)
        // the generated comparison data, charts and the chart CSS block must match what is committed
        #expect(res.generated.keys.contains("site/data/headline.json"))
        for (rel, content) in res.generated { #expect(content == readString(repoRoot + "/" + rel), "\(rel) differs from the committed file") }
    }
}
