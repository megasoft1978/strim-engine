import Foundation
import Testing
@testable import StrimHarness

@Suite struct PackLoaderScopeTests {
    @Test func systemPromptStaysUnder650Words() {
        let words = PackLoader.builtin().system.split(whereSeparator: \.isWhitespace).count
        #expect(words < 650, "system.md is \(words) words")
    }

    @Test func systemPromptHasDeclineAndScopeCriteria() {
        let s = PackLoader.builtin().system
        for needle in ["declined=true", "design", "6 files", "no way to verify", "network", "credentials",
                       "Never rewrite a whole file when a targeted edit works", "Before finish, run"] {
            #expect(s.contains(needle), "missing: \(needle)")
        }
    }

    @Test func systemPromptHasNoTimestampsOrDates() {
        let s = PackLoader.builtin().system
        #expect(s.range(of: #"\b20\d\d-\d\d-\d\d\b"#, options: .regularExpression) == nil)
    }
}
