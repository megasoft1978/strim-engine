import Testing
@testable import StrimMCP

@Suite struct MCPSmokeTests {
    @Test func protocolVersions() {
        #expect(MCPProtocol.supported == ["2025-11-25", "2025-06-18", "2025-03-26"])
    }
}
