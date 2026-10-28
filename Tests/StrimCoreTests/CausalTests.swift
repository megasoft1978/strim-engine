import Foundation
import MLX
import Testing
@testable import StrimCore

private final class BundleMarker {}

/// Under `swift test` the test bundle is dlopen'd, so MLX cannot find the SwiftPM metallib
/// bundle unless the test bundle is registered with NSBundle first.
private let metalReady: Void = {
    let b = Bundle(for: BundleMarker.self)
    _ = b.load()
    _ = Bundle.allBundles
}()

/// MLXFast `.causal` must be bottom-right aligned (queries are the last S of `total`
/// positions) and match the explicit additive mask the engine used to build on the host.
@Test func causalMaskMatchesExplicitMaskWithOffset() {
    _ = metalReady
    let Hq = 24, Hkv = 4, D = 256
    let scale = Float(1.0) / Float(D).squareRoot()
    for S in [1, 2, 3, 4, 5, 64] {
        let total = S + 100
        MLXRandom.seed(UInt64(S))
        let q = MLXRandom.normal([1, Hq, S, D]).asType(.bfloat16)
        let k = MLXRandom.normal([1, Hkv, total, D]).asType(.bfloat16)
        let v = MLXRandom.normal([1, Hkv, total, D]).asType(.bfloat16)
        let offset = total - S
        var m = [Float](repeating: 0, count: S * total)
        for i in 0 ..< S { for j in 0 ..< total where j > offset + i { m[i * total + j] = -1e9 } }
        let arr = MLXArray(m, [1, 1, S, total]).asType(.bfloat16)
        let a = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: .array(arr))
        let c = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: .causal)
        let ok = allClose(a.asType(.float32), c.asType(.float32), rtol: 1e-5, atol: 1e-5).item(Bool.self)
        #expect(ok, "causal != array mask for S=\(S)")
    }
}

@Test func preallocatedCacheKeepsContentAndRollsBack() {
    _ = metalReady
    let c = AttentionCache()
    var all: [MLXArray] = []
    for n in [3, 300, 1, 1, 5] {
        let k = MLXRandom.normal([1, 4, n, 256]).asType(.bfloat16)
        all.append(k)
        let (kk, vv) = c.append(k, k)
        #expect(kk.shape[2] == c.offset && vv.shape[2] == c.offset)
    }
    let ref = concatenated(all, axis: 2)
    #expect(allClose(c.keys!, ref, rtol: 0, atol: 0).item(Bool.self))
    let snap = c.keys!
    c.rollback(5)
    #expect(c.offset == ref.shape[2] - 5)
    let k2 = MLXRandom.normal([1, 4, 2, 256]).asType(.bfloat16)
    _ = c.append(k2, k2)
    #expect(allClose(c.keys![0..., 0..., 0 ..< (ref.shape[2] - 5)], ref[0..., 0..., 0 ..< (ref.shape[2] - 5)], rtol: 0, atol: 0).item(Bool.self))
    // earlier view must not be mutated by the later slice-update
    #expect(allClose(snap, ref, rtol: 0, atol: 0).item(Bool.self))
}

@Test func snapshotIsIsolatedFromLaterAppendAndRollback() {
    _ = metalReady
    let c = AttentionCache()
    let kRef = MLXRandom.normal([1, 4, 10, 256]).asType(.bfloat16)
    let vRef = MLXRandom.normal([1, 4, 10, 256]).asType(.bfloat16)
    _ = c.append(kRef, vRef)
    let mc = ModelCache()
    mc.attention[0] = c
    mc.position = 10
    let snap = mc.snapshot()
    c.rollback(3)
    let k2 = MLXRandom.normal([1, 4, 3, 256]).asType(.bfloat16) + 7
    _ = c.append(k2, k2)
    // snapshot must still hold the pre-rollback data, exactly
    let sc = snap.attention[0]!
    #expect(sc.offset == 10)
    #expect(allClose(sc.keys!, kRef, rtol: 0, atol: 0).item(Bool.self))
    #expect(allClose(sc.values!, vRef, rtol: 0, atol: 0).item(Bool.self))
    // restore() must return the snapshot's KV, unaffected by the live cache
    let restored = ModelCache()
    restored.restore(snap)
    #expect(restored.position == 10)
    #expect(allClose(restored.attention[0]!.keys!, kRef, rtol: 0, atol: 0).item(Bool.self))
    #expect(allClose(restored.attention[0]!.values!, vRef, rtol: 0, atol: 0).item(Bool.self))
}
