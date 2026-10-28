import Testing
@testable import StrimSite

@Suite struct SiteSmokeTests {
    @Test func moduleName() { #expect(StrimSiteModule.name == "StrimSite") }
}
