import Testing
@testable import StrimCore

@Test func speedConfigIsFourBit() {
    #expect(RuntimeConfig.measuredSpeed.quant == .q4)
    #expect(RuntimeConfig.measuredSpeed.prefillStep == 2048)
}

@Test func qualityConfigIsEightBit() {
    #expect(RuntimeConfig.measuredQuality.quant == .q8)
}

@Test func speculativeDepthStaysWithinOutputBudget() {
    #expect(QwenModel.draftDepth(4, remainingTokens: 0) == 0)
    #expect(QwenModel.draftDepth(4, remainingTokens: 1) == 0)
    #expect(QwenModel.draftDepth(4, remainingTokens: 2) == 1)
    #expect(QwenModel.draftDepth(4, remainingTokens: 3) == 2)
    #expect(QwenModel.draftDepth(2, remainingTokens: 8) == 2)
    #expect(QwenModel.draftDepth(-1, remainingTokens: 8) == 0)
}
