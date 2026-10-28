import Foundation
import MLX
import Testing
@testable import StrimCore

private final class ChunkBundleMarker {}
private let chunkMetalReady: Void = {
    let b = Bundle(for: ChunkBundleMarker.self)
    _ = b.load()
    _ = Bundle.allBundles
}()

private let live = ProcessInfo.processInfo.environment["STRIM_LIVE"] == "1"

/// Chunk-size invariance of prefill (opus.md E1). CPU-safe part mirrors MLX's split-K heuristic; GPU parts need
/// `STRIM_LIVE=1` and run under `lockf -t 30 -k /tmp/strim-bench.lock`.
@Suite struct ChunkInvarianceTests {
    /// mlx/backend/metal/quantized.cpp qmm_splitk: split_k = max(1, 512 / (ceil(N/32) * ceil(M/32))).
    @Test func splitKHeuristicMirror() {
        let expect48: [(Int, Int)] = [(1024, 8), (2048, 4), (4096, 2), (4128, 1), (8192, 1)]
        for (m, k) in expect48 { #expect(ChunkInvariantLinear.splitK(m: m, n: 48) == k, "N=48 M=\(m)") }
        #expect(ChunkInvariantLinear.minRowsForNoSplit(n: 48) == 4128)
        #expect(ChunkInvariantLinear.splitK(m: 4128 - 32, n: 48) == 2)
        // k/v_proj (N=1024): only splits for M < 512; chunk >= 512 is invariant.
        #expect(ChunkInvariantLinear.splitK(m: 1024, n: 1024) == 1 && ChunkInvariantLinear.splitK(m: 256, n: 1024) == 2)
        // Wide projections never split at chunk sizes of interest.
        #expect(ChunkInvariantLinear.splitK(m: 512, n: 5120) == 1)
        #expect(ChunkInvariantLinear.minRowsForNoSplit(n: 1024) == 288)
    }

    @Test func flagIsOffByDefault() {
        if ProcessInfo.processInfo.environment["STRIM_GDN_BA_INVARIANT"] == nil { #expect(!ChunkInvariantLinear.enabled) }
    }

    /// Random-weight quantized matmul at M = 8192 (reference, split 1) vs the same rows computed in chunks.
    @Test(.enabled(if: live)) func quantizedMatmulRowInvariance() throws {
        _ = chunkMetalReady
        let K = 5120, rows = 8192
        MLXRandom.seed(7)
        let x = MLXRandom.normal([1, rows, K]).asType(.bfloat16)
        var report: [String] = []
        for N in [48, 1024, 5120] {
            let w = MLXRandom.normal([N, K]).asType(.bfloat16)
            let (wq, s, b) = quantized(w, groupSize: 64, bits: 4)
            let ref = quantizedMatmul(x, wq, scales: s, biases: b, transpose: true, groupSize: 64, bits: 4)
            eval(ref)
            for c in [1024, 2048, 4096] {
                var plain: [MLXArray] = [], fixed: [MLXArray] = []
                for st in stride(from: 0, to: rows, by: c) {
                    let xc = x[0..., st ..< (st + c), 0...]
                    plain.append(quantizedMatmul(xc, wq, scales: s, biases: b, transpose: true, groupSize: 64, bits: 4))
                    fixed.append(ChunkInvariantLinear.padded(xc, n: N) {
                        quantizedMatmul($0, wq, scales: s, biases: b, transpose: true, groupSize: 64, bits: 4)
                    })
                }
                let dPlain = abs(concatenated(plain, axis: 1).asType(.float32) - ref.asType(.float32)).max().item(Float.self)
                let dFixed = abs(concatenated(fixed, axis: 1).asType(.float32) - ref.asType(.float32)).max().item(Float.self)
                report.append("N=\(N) chunk=\(c) splitK=\(ChunkInvariantLinear.splitK(m: c, n: N)) maxAbsDiff plain=\(dPlain) padded=\(dFixed)")
                if ChunkInvariantLinear.splitK(m: c, n: N) == 1 { #expect(dPlain == 0, "N=\(N) chunk=\(c) should already be invariant") }
                #expect(dFixed == 0, "padded path must be chunk-invariant: N=\(N) chunk=\(c)")
            }
        }
        print("quantizedMatmulRowInvariance:\n" + report.joined(separator: "\n"))
    }

    /// Full-model prefill of one prompt at several chunk sizes; reports max abs diff per layer type vs the 4096 run.
    /// Needs STRIM_LIVE=1 and STRIM_LIVE_MODEL=<dir>. Run once plain and once with STRIM_GDN_BA_INVARIANT=1.
    /// Set STRIM_EXPECT_INVARIANT=1 to turn any difference into a failure.
    @Test(.enabled(if: live)) func modelPrefillChunkInvariance() throws {
        _ = chunkMetalReady
        let env = ProcessInfo.processInfo.environment
        let dir = try #require(env["STRIM_LIVE_MODEL"], "set STRIM_LIVE_MODEL")
        let store = try WeightStore(dir: URL(fileURLWithPath: dir))
        let n = Int(env["STRIM_CHUNK_TEST_TOKENS"] ?? "") ?? 4096
        var seed: UInt64 = 0x9E3779B97F4A7C15
        let prompt: [Int32] = (0 ..< n).map { _ in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int32((seed >> 33) % 100_000) }
        let ref = try run2(prompt, store, chunk: 4096)
        var failures: [String] = []
        for c in [1024, 2048] {
            let o = try run2(prompt, store, chunk: c)
            var gdnSsm: Float = 0, gdnConv: Float = 0, attnK: Float = 0, attnV: Float = 0
            for (l, g) in ref.cache.gdn {
                guard let og = o.cache.gdn[l] else { continue }
                gdnSsm = max(gdnSsm, maxDiff(g.ssm, og.ssm)); gdnConv = max(gdnConv, maxDiff(g.conv, og.conv))
            }
            for (l, a) in ref.cache.attention {
                guard let oa = o.cache.attention[l] else { continue }
                attnK = max(attnK, maxDiff(a.keys, oa.keys)); attnV = max(attnV, maxDiff(a.values, oa.values))
            }
            let lg = maxDiff(ref.logits, o.logits)
            let line = "chunk \(c) vs 4096 (BA_INVARIANT=\(ChunkInvariantLinear.enabled)): logits \(lg) gdn.ssm \(gdnSsm) gdn.conv \(gdnConv) attn.k \(attnK) attn.v \(attnV)"
            print(line)
            if lg != 0 || gdnSsm != 0 || gdnConv != 0 || attnK != 0 || attnV != 0 { failures.append(line) }
        }
        if env["STRIM_EXPECT_INVARIANT"] == "1" { #expect(failures.isEmpty, "\(failures)") }
    }
}

private func maxDiff(_ a: MLXArray?, _ b: MLXArray?) -> Float {
    guard let a, let b else { return .infinity }
    guard a.shape == b.shape else { return .infinity }
    return abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
}

private func run2(_ prompt: [Int32], _ store: WeightStore, chunk: Int) throws -> (cache: ModelCache, logits: MLXArray) {
    let cache = ModelCache()
    var st = 0
    var last: MLXArray?
    while st < prompt.count {
        let e = min(st + chunk, prompt.count)
        let out = try QwenModel.forwardAll(tokens: Array(prompt[st ..< e]), store: store, cache: cache, lastTokenOnly: true)
        eval(out.logits)
        last = out.logits
        st = e
    }
    return (cache, last!)
}
