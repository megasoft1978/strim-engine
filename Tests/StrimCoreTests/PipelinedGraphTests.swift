import Foundation
import MLX
import Testing
@testable import StrimCore

private final class PipeBundleMarker {}
private let pipeMetalReady: Void = {
    let b = Bundle(for: PipeBundleMarker.self)
    _ = b.load()
    _ = Bundle.allBundles
}()

private let pipeLive = ProcessInfo.processInfo.environment["STRIM_LIVE"] == "1"

/// `asyncEval(h)` every N layers (QwenModel.pipeEvery) only changes when the GPU starts, never what it computes.
/// Live tests need `STRIM_LIVE=1`, `STRIM_LIVE_MODEL=<qwen38 dir>`, `STRIM_LIVE_MTP=<mtp head dir>` and run under
/// `lockf -t 3600 -k /tmp/strim-bench.lock`; without them they are skipped and the CLI gates cover the same ground.
@Suite(.serialized) struct PipelinedGraphTests {
    @Test func envDefaultsAreNonNegative() {
        #expect(QwenModel.pipeEnv("STRIM_PIPE_TEST_UNSET_KEY", 8) == 8)
        #expect(QwenModel.pipeEnv("STRIM_PIPE_TEST_UNSET_KEY", 0) == 0)
        #expect(QwenModel.pipeEvery >= 0 && QwenModel.pipePrefillEvery >= 0)
    }

    /// Prefill + verify pass (M=3) + exact rollback (reject 2 / accept all) + M=1 decode: logits, hidden and
    /// cache position must be bitwise equal with pipelining on (every layer / every 8) and off.
    @Test(.enabled(if: pipeLive)) func logitsAndRollbackBitIdentical() throws {
        _ = pipeMetalReady
        let dir = try #require(ProcessInfo.processInfo.environment["STRIM_LIVE_MODEL"], "set STRIM_LIVE_MODEL")
        let store = try WeightStore(dir: URL(fileURLWithPath: dir))
        let saved = (QwenModel.pipeEvery, QwenModel.pipePrefillEvery)
        defer { (QwenModel.pipeEvery, QwenModel.pipePrefillEvery) = saved }
        let prompt: [Int32] = (0 ..< 200).map { Int32(1000 + ($0 * 37) % 5000) }
        func run(_ n: Int, prefillN: Int) throws -> [[Float]] {
            QwenModel.pipeEvery = n; QwenModel.pipePrefillEvery = prefillN
            var out: [[Float]] = []
            func rec(_ a: MLXArray) { out.append(a.asType(.float32).flattened().asArray(Float.self)) }
            let cache = ModelCache()
            let p = try QwenModel.forwardAll(tokens: prompt, store: store, cache: cache, lastTokenOnly: true)
            rec(p.logits)
            for (feed, drop) in [([Int32]([11, 22, 33]), 2), ([44, 55, 66], 0), ([77, 88, 99], 1)] {
                cache.beginVerify()
                let v = try QwenModel.forwardAll(tokens: feed, store: store, cache: cache)
                rec(v.logits); rec(v.hidden)
                cache.rollback(drop: drop)
                cache.endVerify()
                let d = try QwenModel.forwardAll(tokens: [123], store: store, cache: cache)
                rec(d.logits)
                let s = try QwenModel.forward(tokens: [124], store: store, cache: cache)
                rec(s.logits)
            }
            out.append([Float(cache.position)])
            return out
        }
        let base = try run(0, prefillN: 0)
        for (n, pn) in [(1, 0), (8, 0), (8, 8)] {
            let r = try run(n, prefillN: pn)
            #expect(r.count == base.count)
            for (i, (a, b)) in zip(base, r).enumerated() { #expect(a == b, "stage \(i) differs with pipe=\(n) prefill=\(pn)") }
        }
    }

    /// Whole speculative loop (draft chain, verify, rollback, head reseed) emits the same ids at depth 2 and 4.
    @Test(.enabled(if: pipeLive)) func speculativeLoopIdentical() throws {
        _ = pipeMetalReady
        let env = ProcessInfo.processInfo.environment
        let dir = try #require(env["STRIM_LIVE_MODEL"], "set STRIM_LIVE_MODEL")
        let mtp = try #require(env["STRIM_LIVE_MTP"], "set STRIM_LIVE_MTP")
        let store = try WeightStore(dir: URL(fileURLWithPath: dir))
        let head = try WeightStore(dir: URL(fileURLWithPath: mtp))
        head.useIntegratedMTPPrefixIfNeeded()
        let saved = QwenModel.pipeEvery
        defer { QwenModel.pipeEvery = saved }
        let prompt: [Int32] = (0 ..< 300).map { Int32(2000 + ($0 * 91) % 7000) }
        for depth in [0, 2, 4] {
            QwenModel.pipeEvery = 0
            let (a, _) = try QwenModel.generateSpec(prompt: prompt, maxTokens: 48, store: store, head: head, depth: depth)
            QwenModel.pipeEvery = 8
            let (b, _) = try QwenModel.generateSpec(prompt: prompt, maxTokens: 48, store: store, head: head, depth: depth)
            #expect(a == b, "depth \(depth) spec output differs with pipelining")
        }
    }
}
