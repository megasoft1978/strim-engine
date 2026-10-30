import Testing
@testable import StrimCore

@Suite struct MTPStatsTests {
    @Test func everyPrefixAtEveryDepth() {
        for depth in 0...4 {
            for accepted in 0...depth {
                var stats = MTPStats()
                stats.recordRound(depth: depth, accepted: accepted)
                #expect(stats.rounds == 1 && stats.emitted == accepted + 1)
                for j in 0..<4 {
                    #expect(stats.proposed[j] == (j < depth ? 1 : 0))
                    #expect(stats.reached[j] == (j < depth && accepted >= j ? 1 : 0))
                    #expect(stats.acceptedPrefix[j] == (j < accepted ? 1 : 0))
                }
            }
        }
    }
    @Test func zeroDepthAndBudgetTruncation() {
        for remaining in 1...5 {
            let depth = QwenModel.draftDepth(4, remainingTokens: remaining)
            var stats = MTPStats(); stats.recordRound(depth: depth, accepted: depth)
            #expect(stats.emitted == remaining)
            #expect(stats.proposed.reduce(0, +) == remaining - 1)
        }
        let empty = MTPStats() // remaining == 0 never runs a round
        #expect(empty.rounds == 0 && empty.proposed == [0, 0, 0, 0])
    }
    @Test func fixedAndAdaptiveSequencesMatchTraceAccounting() {
        for depths in [[4, 4, 4, 1, 0], [3, 3, 2, 3, 1, 0], [1, 1, 1, 0]] {
            var stats = MTPStats(), proposed = [0, 0, 0, 0], reached = proposed, accepted = proposed
            var tokens = 0
            for (n, d) in depths.enumerated() {
                let a = min(d, n % 3)
                stats.recordRound(depth: d, accepted: a)
                tokens += a + 1
                for i in 1...4 {
                    if i <= d { proposed[i-1] += 1 }
                    if i <= d && a >= i-1 { reached[i-1] += 1 }
                    if a >= i { accepted[i-1] += 1 }
                }
            }
            #expect(stats.proposed == proposed && stats.reached == reached && stats.acceptedPrefix == accepted)
            #expect(stats.emitted == tokens && stats.rounds == depths.count)
        }
    }
    @Test func sampledAndConstrainedResolvedOutcomesUseSameMath() {
        // CPU fixtures of verifier results: sampled full acceptance, a mask rejecting
        // position 1, and a sampled partial prefix. Compare to the one-based contract.
        let fixtures: [(Int, Int, [Int], [Int])] = [
            (4, 4, [1, 1, 1, 1], [1, 1, 1, 1]),
            (3, 0, [1, 0, 0, 0], [0, 0, 0, 0]),
            (4, 2, [1, 1, 1, 0], [1, 1, 0, 0]),
        ]
        for (depth, accepted, reached, prefix) in fixtures {
            var stats = MTPStats(); stats.recordRound(depth: depth, accepted: accepted)
            #expect(stats.reached == reached && stats.acceptedPrefix == prefix)
        }
    }
    @Test func cancellationAndFailureDoNotCommitUncompletedRound() {
        var stats = MTPStats(); stats.recordRound(depth: 3, accepted: 1)
        let before = stats
        // Only completed rounds call recordRound. Cancellation before a round or failure
        // during verify/replay produces no delta; completed atomic rounds remain counted.
        #expect(stats.delta(since: before) == MTPStats())
        stats.recordRound(depth: 2, accepted: 0)
        let delta = stats.delta(since: before)
        #expect(delta.rounds == 1 && delta.proposed == [1, 1, 0, 0])
    }
    @Test func requestBaselinesPreventDoubleCountingAcrossReusedAndNewStreams() {
        var stream = MTPStats(), total = MTPStats(), baseline = stream
        stream.recordRound(depth: 4, accepted: 2)
        total.add(stream.delta(since: baseline)); baseline = stream
        total.add(stream.delta(since: baseline)) // same snapshot cannot count twice
        let first = total
        stream.recordRound(depth: 2, accepted: 0)
        total.add(stream.delta(since: baseline))
        #expect(total.rounds == 2 && first.rounds == 1)
        #expect(total.proposed == [2, 2, 1, 1] && total.acceptedPrefix == [1, 1, 0, 0])
        let oldTotal = total
        stream = MTPStats(); baseline = stream // a new stream gets its own baseline
        stream.recordRound(depth: 1, accepted: 1); total.add(stream.delta(since: baseline))
        #expect(total.rounds == 3 && oldTotal.rounds == 2)
    }
    @Test func boundedCountersExposeOverflow() {
        var s = MTPStats(); s.recordRound(depth: 9, accepted: 7)
        #expect(s.proposed.count == 4 && s.proposed == [1, 1, 1, 1])
        #expect(s.overflowProposed == 5 && s.emitted == 8)
    }
}

// Metadata-only stores: no weights, MLX arrays, device operations or model execution.
// Exercise the real SpecStream early exits before any drafting or forward operation.
import Foundation

@Suite struct MTPStreamEarlyExitTests {
    private func stream(adaptive: Bool = false, sampled: Bool = false) throws -> SpecStream {
        guard WiredLimit.envGB == nil else { throw CocoaError(.featureUnsupported) }
        let dir = URL(fileURLWithPath: "/tmp/mtp2/unit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = dir.appendingPathComponent("model.safetensors.index.json")
        try Data(#"{"metadata":{"total_size":0},"weight_map":{}}"#.utf8).write(to: index)
        defer { try? FileManager.default.removeItem(at: index); try? FileManager.default.removeItem(at: dir) }
        let store = try WeightStore(dir: dir)
        let st = SpecStream(store: store, head: store, cache: ModelCache(), mtp: MTPState(), seedToken: 1,
                            depth: 3, adaptive: adaptive)
        if sampled { st.enableSampling(SamplingConfig(temperature: 0.8, seed: 7)) }
        return st
    }
    @Test func emptyBudgetDoesNotRunOrCount() throws {
        let st = try stream()
        #expect(try st.step(remaining: 0).isEmpty)
        #expect(st.stats.mtp == MTPStats())
    }
    @Test func cancellationBeforeFixedAdaptiveAndSampledRoundDoesNotCount() throws {
        for adaptive in [false, true] {
            for sampled in [false, true] {
                let st = try stream(adaptive: adaptive, sampled: sampled)
                st.cancel()
                #expect(throws: SpecStreamError.self) { try st.step(remaining: 5) }
                #expect(st.stats.mtp == MTPStats())
            }
        }
    }
    @Test func unseededFailedRoundAndRepeatedStepNeverCount() throws {
        let st = try stream()
        #expect(throws: SpecStreamError.self) { try st.step(remaining: 5) }
        #expect(st.stats.mtp == MTPStats())
        #expect(throws: SpecStreamError.self) { try st.step(remaining: 5) }
        #expect(st.stats.mtp == MTPStats())
    }
}
