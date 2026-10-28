import Testing
@testable import StrimEngine

/// F1: client-controlled token counts reach this arithmetic; it must saturate, never trap.
@Suite struct AdmissionOverflowTests {
    @Test func requestBytesSaturatesInsteadOfTrapping() {
        #expect(MemoryModel.requestBytes(tokens: 200_000_000_000_000, mtp: true) == Int.max)
        #expect(MemoryModel.requestBytes(tokens: Int.max, mtp: false) == Int.max)
        #expect(MemoryModel.requestBytes(tokens: -5, mtp: false) == MemoryModel.gdnBytesPerSequence)
        // The normal range is unchanged.
        #expect(MemoryModel.requestBytes(tokens: 4096, mtp: false) == 4096 * 64 * 1024 + 147 * 1024 * 1024)
    }

    @Test func saturatingAddClamps() {
        #expect(MemoryModel.saturatingAdd(Int.max, 1) == Int.max)
        #expect(MemoryModel.saturatingAdd(5, Int.max) == Int.max)
        #expect(MemoryModel.saturatingAdd(2, 3) == 5)
    }

    @Test func decideRejectsAnOversizedRequestWithoutOverflow() {
        let d = Admission.decide(budget: 32 << 30, fixed: 10 << 30, active: 0, hot: [(id: 1, bytes: 1 << 30)],
                                 needed: Int.max)
        guard case .reject = d.outcome else { Issue.record("expected reject"); return }
        #expect(d.evictHot.isEmpty)
    }
}
