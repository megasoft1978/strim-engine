import Testing
@testable import StrimCore

@Suite struct DepthPolicyTests {
    @Test func highAcceptanceClimbsToFour() {
        let s = [0.91, 0.78, 0.63, 0.51]
        #expect(DepthPolicy.best(survival: s, ctx: 4096, current: 2, minD: 2, maxD: 4) == 4)
    }

    @Test func lowAcceptanceStaysAtTwo() {
        let s = [0.6, 0.3, 0.1, 0.05]
        #expect(DepthPolicy.best(survival: s, ctx: 4096, current: 4, minD: 2, maxD: 4) == 2)
        #expect(DepthPolicy.best(survival: s, ctx: 4096, current: 2, minD: 2, maxD: 4) == 2)
    }

    @Test func measuredAgentCurveFavoursThree() {
        let s = [0.8, 0.6, 0.38, 0.2]
        #expect(DepthPolicy.best(survival: s, ctx: 4096, current: 2, minD: 2, maxD: 4) == 3)
    }

    @Test func hysteresisHoldsInsideMargin() {
        let s = [0.88, 0.77, 0.62, 0.40]
        let r3 = DepthPolicy.rate(depth: 3, survival: s, ctx: 32768)
        let r4 = DepthPolicy.rate(depth: 4, survival: s, ctx: 32768)
        let d = DepthPolicy.best(survival: s, ctx: 32768, current: 3, minD: 2, maxD: 4)
        #expect(d == (r4 > r3 * (1 + DepthPolicy.margin) ? 4 : 3))
        // A curve engineered to be within 1% stays put.
        let flat = [0.85, 0.70, 0.55, 0.4]
        let a = DepthPolicy.rate(depth: 3, survival: flat, ctx: 4096), b = DepthPolicy.rate(depth: 4, survival: flat, ctx: 4096)
        if abs(b / a - 1) < DepthPolicy.margin {
            #expect(DepthPolicy.best(survival: flat, ctx: 4096, current: 3, minD: 2, maxD: 4) == 3)
        }
    }

    @Test func maxDepthRespected() {
        let s = [0.99, 0.99, 0.99, 0.99]
        #expect(DepthPolicy.best(survival: s, ctx: 4096, current: 2, minD: 2, maxD: 3) == 3)
    }

    @Test func costModelMatchesMeasuredPasses() {
        #expect(abs(DepthPolicy.cost(depth: 2, ctx: 4096) - 43.9) < 0.5)
        #expect(abs(DepthPolicy.cost(depth: 2, ctx: 32768) - 53.7) < 1.0)
        #expect(abs(DepthPolicy.cost(depth: 4, ctx: 32768) - 67.0) < 1.5)
    }
}
