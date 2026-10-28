import Foundation
import Testing
@testable import StrimEngine

/// L3(a): a request that never reads head state must not pay the MTP head during cold prefill.
@Suite struct HeadPrefillTests {
    private func wants(hasHead: Bool = true, wantMTP: Bool = true, depth: Int = 3, prefetch: Bool = false,
                       env: [String: String] = [:]) -> Bool {
        PrefillJob.wantsHead(hasHead: hasHead, wantMTP: wantMTP, depth: depth, prefetch: prefetch, env: env)
    }

    @Test func speculatingRequestRunsTheHead() { #expect(wants()) }

    @Test func nonSpeculatingRequestSkipsTheHead() {
        #expect(!wants(wantMTP: false))
        #expect(!wants(depth: 0))
    }

    @Test func noHeadLoadedNeverRunsTheHead() {
        #expect(!wants(hasHead: false))
        #expect(!wants(hasHead: false, prefetch: true))
    }

    @Test func prefetchKeepsTheHeadSoLaterRequestsHitMTPNodes() {
        #expect(wants(wantMTP: false, depth: 0, prefetch: true))
    }

    @Test func envRestoresUnconditionalHeadPrefill() {
        #expect(wants(wantMTP: false, depth: 0, env: ["STRIM_MTP_PREFILL": "always"]))
    }
}

/// L3(b): the head prefill covers only the last `STRIM_MTP_WINDOW` tokens of a long prompt.
@Suite struct HeadWindowTests {
    private let w4k = ["STRIM_MTP_WINDOW": "4096"]

    @Test func defaultIsOffUntilTheAcceptanceGateIsMeasured() {
        #expect(PrefillJob.windowStart(count: 32768, env: [:]) == 0)
    }

    @Test func promptsThatFitKeepTheWholeHead() {
        #expect(PrefillJob.windowStart(count: 4096, env: w4k) == 0)
        #expect(PrefillJob.windowStart(count: 100, env: w4k) == 0)
    }

    @Test func longPromptsStartTheHeadAtTheLastWindow() {
        #expect(PrefillJob.windowStart(count: 16384, env: w4k) == 16384 - 4096)
        #expect(PrefillJob.windowStart(count: 4097, env: w4k) == 1)
        #expect(PrefillJob.windowStart(count: 32768, env: ["STRIM_MTP_WINDOW": "2048"]) == 32768 - 2048)
    }

    @Test func zeroWindowRestoresTheFullHead() {
        #expect(PrefillJob.windowStart(count: 32768, env: ["STRIM_MTP_WINDOW": "0"]) == 0)
    }
}
