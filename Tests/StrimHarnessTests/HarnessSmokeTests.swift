import Testing
import StrimEngine
import StrimTemplate
@testable import StrimHarness

@Suite struct HarnessSmokeTests {
    @Test func limitsDefaults() {
        let l = HarnessLimits()
        #expect(l.maxTurns == 40 && l.maxSeconds == 900 && l.maxGeneratedTokens == 60_000)
        #expect(l.maxRepeatedCalls == 3 && l.maxConsecutiveErrors == 5)
    }

    @Test func fakeEngineScriptsEvents() async throws {
        let e = FakeEngine()
        e.script([.event(.tokens([1], "hi")), .event(.finished(.stop, makeUsage()))])
        let s = try await e.openSession(SessionConfig())
        var text = ""
        for try await ev in e.generate(s, GenParams()) { if case let .tokens(_, t) = ev { text += t } }
        #expect(text == "hi")
    }
}
