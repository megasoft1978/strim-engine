import Foundation
import MLX
import MLXRandom
import Testing
import MLXFast
@testable import StrimCore

private final class BundleMarker {}

/// Under `swift test` the test bundle is dlopen'd, so MLX needs the bundle registered with NSBundle first;
/// tests are skipped when the bundle carries no metallib.
private let metalReady: Bool = {
    let b = Bundle(for: BundleMarker.self)
    _ = b.load()
    _ = Bundle.allBundles
    let lib = b.bundleURL.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    return FileManager.default.fileExists(atPath: lib.path)
}()

/// Blocked GDN prefill kernel must be deterministic and match the serial kernel.
@Test(.enabled(if: metalReady)) func blockedGDNDeterministicAndMatchesSerial() {
    let S = 2048, Hk = 16, Hv = 48, D = 128
    MLXRandom.seed(7)
    let conv = (MLXRandom.normal([1, S, 2 * Hk * D + Hv * D]) * 0.5).asType(.bfloat16)
    // v is a strided slice of a wider tensor, exactly as GDN.forward passes it.
    let q = (MLXRandom.normal([1, S, Hk, D]) * 0.05).asType(.bfloat16)
    let k = (MLXRandom.normal([1, S, Hk, D]) * 0.05).asType(.bfloat16)
    let v = conv[0..., 0..., (2 * Hk * D)...].reshaped([1, S, Hv, D])
    let g = exp(-MLXRandom.uniform(low: 0.001, high: 0.2, [1, S, Hv]))
    let beta = sigmoid(MLXRandom.normal([1, S, Hv]))
    let ssm = (MLXRandom.normal([1, Hv, D, D]) * 0.1).asType(.float32)
    eval(q, k, v, g, beta, ssm)

    let r0 = GDNMetal.runBlocked(q: q, k: k, v: v, g: g, beta: beta, ssm: ssm)
    eval(r0.y, r0.ssm)
    for _ in 0 ..< 10 {
        let r = GDNMetal.runBlocked(q: q, k: k, v: v, g: g, beta: beta, ssm: ssm)
        eval(r.y, r.ssm)
        #expect(abs(r.y.asType(.float32) - r0.y.asType(.float32)).max().item(Float.self) == 0)
        #expect(abs(r.ssm - r0.ssm).max().item(Float.self) == 0)
    }

    let rep = MLXArray((0 ..< Hv).map { Int32($0 / (Hv / Hk)) })
    let ref = GDNMetal.run(q: q.take(rep, axis: 2), k: k.take(rep, axis: 2), v: v, g: g,
                           beta: beta, ssm: ssm, recordStack: false)
    eval(ref.y, ref.ssm)
    let yd = abs(r0.y.asType(.float32) - ref.y.asType(.float32)).max().item(Float.self)
    let sd = abs(r0.ssm - ref.ssm).max().item(Float.self)
    let ymax = abs(ref.y.asType(.float32)).max().item(Float.self)
    print("blocked vs serial: y maxabs \(yd) (ref max \(ymax)), ssm maxabs \(sd)")
    #expect(yd <= 0.02 * ymax)
    #expect(sd <= 1e-2)
}

// MARK: - speed-wave-2 L5: the retuned kernel must be bit-identical to the ported one

/// Verbatim copy of the pre-L5 blocked kernel (TB=48, DB=32, one value row per thread).
private nonisolated(unsafe) let legacyBlockedKernel = MLXFast.metalKernel(
    name: "gdn_blocked_prefill_legacy_test",
    inputNames: ["q", "k", "v", "g", "beta", "ssm", "dims"],
    outputNames: ["y", "ssmOut"],
    source: """
        constexpr int TB = 48;
        constexpr int DB = 32;
        uint T = dims[0], Hk = dims[1], Hv = dims[2], B = dims[3];
        uint tid = thread_position_in_threadgroup.x;
        uint blk = threadgroup_position_in_grid.x;
        uint hv = threadgroup_position_in_grid.y;
        uint b = threadgroup_position_in_grid.z;
        uint hk = hv / (Hv / Hk);
        uint dv0 = blk * DB;

        uint dv = tid / 8;
        uint seg = tid % 8;
        uint d0 = seg * 16;

        threadgroup bfloat16_t k_s[TB][128 + 8];
        threadgroup bfloat16_t q_s[TB][128 + 8];
        threadgroup bfloat16_t v_s[TB][DB + 8];
        threadgroup float g_s[TB];
        threadgroup float b_s[TB];

        const device bfloat16_t* k_base = k + ((size_t)b * T * Hk + hk) * 128;
        const device bfloat16_t* q_base = q + ((size_t)b * T * Hk + hk) * 128;
        const device bfloat16_t* v_base = v + ((size_t)b * T * Hv + hv) * 128 + dv0;
        const size_t krow = (size_t)Hk * 128;

        float4 st[4];
        {
            const device float4* S_in = (const device float4*)(
                ssm + (((size_t)b * Hv + hv) * 128 + dv0 + dv) * 128 + d0);
            for (int i = 0; i < 4; ++i) st[i] = S_in[i];
        }

        device bfloat16_t* y_base = y + ((size_t)b * T * Hv + hv) * 128 + dv0;

        for (uint t0 = 0; t0 < T; t0 += TB) {
            uint tt = min((uint)TB, T - t0);
            for (uint p = tid; p < tt * 128; p += 256) {
                uint r = p / 128, d = p % 128;
                k_s[r][d] = k_base[(size_t)(t0 + r) * krow + d];
                q_s[r][d] = q_base[(size_t)(t0 + r) * krow + d];
            }
            for (uint p = tid; p < tt * DB; p += 256) {
                uint r = p / DB, d = p % DB;
                v_s[r][d] = v_base[(size_t)(t0 + r) * Hv * 128 + d];
            }
            for (uint p = tid; p < tt; p += 256) {
                g_s[p] = g[((size_t)b * T + t0 + p) * Hv + hv];
                b_s[p] = beta[((size_t)b * T + t0 + p) * Hv + hv];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint t = 0; t < tt; ++t) {
                float gt = g_s[t];
                float bt = b_s[t];
                const threadgroup vec<bfloat16_t,4>* k4 =
                    (const threadgroup vec<bfloat16_t,4>*)&k_s[t][d0];
                const threadgroup vec<bfloat16_t,4>* q4 =
                    (const threadgroup vec<bfloat16_t,4>*)&q_s[t][d0];
                float4 kf[4];
                for (int i = 0; i < 4; ++i) kf[i] = float4(k4[i]);
                float4 p4 = 0.0f;
                for (int i = 0; i < 4; ++i) {
                    st[i] = st[i] * gt;
                    p4 += st[i] * kf[i];
                }
                float part = p4.x + p4.y + p4.z + p4.w;
                part += simd_shuffle_down(part, 4);
                part += simd_shuffle_down(part, 2);
                part += simd_shuffle_down(part, 1);
                float kv_mem = simd_shuffle(part, (tid % 32) / 8 * 8);
                float delta = (float(v_s[t][dv]) - kv_mem) * bt;

                float4 o4 = 0.0f;
                for (int i = 0; i < 4; ++i) {
                    st[i] += kf[i] * delta;
                    o4 += st[i] * float4(q4[i]);
                }
                float out = o4.x + o4.y + o4.z + o4.w;
                out += simd_shuffle_down(out, 4);
                out += simd_shuffle_down(out, 2);
                out += simd_shuffle_down(out, 1);
                if (seg == 0) {
                    y_base[(size_t)(t0 + t) * Hv * 128 + dv] = (bfloat16_t)out;
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        {
            device float4* S_out = (device float4*)(
                ssmOut + (((size_t)b * Hv + hv) * 128 + dv0 + dv) * 128 + d0);
            for (int i = 0; i < 4; ++i) S_out[i] = st[i];
        }
        """,
    header: "")

private func legacyBlocked(q: MLXArray, k: MLXArray, v: MLXArray, g: MLXArray, beta: MLXArray,
                           ssm: MLXArray) -> [MLXArray] {
    let B = q.shape[0], S = q.shape[1], Hk = q.shape[2], Hv = v.shape[2]
    let dims = MLXArray([Int32(S), Int32(Hk), Int32(Hv), Int32(B)])
    return legacyBlockedKernel([q, k, v, g.asType(.float32).contiguous(), beta.asType(.float32).contiguous(), ssm, dims],
                               grid: (4 * 256, Hv, B), threadGroup: (256, 1, 1),
                               outputShapes: [[B, S, Hv, 128], [B, Hv, 128, 128]],
                               outputDTypes: [.bfloat16, .float32])
}

private func blockedInputs(S: Int, B: Int, seed: UInt64, scale: Float = 1) -> [MLXArray] {
    let Hk = 16, Hv = 48, D = 128
    MLXRandom.seed(seed)
    let conv = (MLXRandom.normal([B, S, 2 * Hk * D + Hv * D]) * (0.5 * scale)).asType(.bfloat16)
    let q = (MLXRandom.normal([B, S, Hk, D]) * (0.05 * scale)).asType(.bfloat16)
    let k = (MLXRandom.normal([B, S, Hk, D]) * (0.05 * scale)).asType(.bfloat16)
    // v is a strided slice of a wider tensor, exactly as GDN.forward passes it.
    let v = conv[0..., 0..., (2 * Hk * D)...].reshaped([B, S, Hv, D])
    let g = exp(-MLXRandom.uniform(low: 0.001, high: 0.2, [B, S, Hv]))
    let beta = sigmoid(MLXRandom.normal([B, S, Hv]))
    let ssm = (MLXRandom.normal([B, Hv, D, D]) * 0.1).asType(.float32)
    eval(q, k, v, g, beta, ssm)
    return [q, k, v, g, beta, ssm]
}

private func bitEqual(_ a: MLXArray, _ b: MLXArray) -> Bool {
    a.shape == b.shape && (a.asType(.float32) .!= b.asType(.float32)).sum().item(Int.self) == 0
}

/// Chunk tails (S not a multiple of the 40-token block or the legacy 48), tiny S, B > 1, long
/// chunks, strided and contiguous v, a zero state and a wide dynamic range: y and the final state
/// must match the legacy kernel bit for bit.
@Test(.enabled(if: metalReady)) func blockedKernelBitIdenticalToLegacyLayout() {
    let cases: [(S: Int, B: Int, scale: Float)] = [
        (1024, 1, 1), (1000, 1, 1), (4096, 1, 1), (40, 1, 1), (41, 1, 1), (47, 1, 1), (49, 1, 1),
        (1, 1, 1), (3, 1, 1), (777, 2, 1), (130, 3, 1), (512, 1, 8), (1024, 1, 0.01),
    ]
    for c in cases {
        let a = blockedInputs(S: c.S, B: c.B, seed: UInt64(100 + c.S), scale: c.scale)
        let new = GDNMetal.runBlocked(q: a[0], k: a[1], v: a[2], g: a[3], beta: a[4], ssm: a[5])
        let ref = legacyBlocked(q: a[0], k: a[1], v: a[2], g: a[3], beta: a[4], ssm: a[5])
        eval(new.y, new.ssm, ref[0], ref[1])
        #expect(bitEqual(new.y, ref[0]), "y differs S=\(c.S) B=\(c.B)")
        #expect(bitEqual(new.ssm, ref[1]), "ssm differs S=\(c.S) B=\(c.B)")
        // contiguous v takes the same path with a different stride
        let vc = a[2].contiguous()
        let nc = GDNMetal.runBlocked(q: a[0], k: a[1], v: vc, g: a[3], beta: a[4], ssm: a[5])
        eval(nc.y, nc.ssm)
        #expect(bitEqual(nc.y, ref[0]) && bitEqual(nc.ssm, ref[1]), "contiguous v differs S=\(c.S) B=\(c.B)")
    }
    // zero initial state
    let a = blockedInputs(S: 1024, B: 1, seed: 5)
    let z = MLXArray.zeros([1, 48, 128, 128], dtype: .float32)
    let n0 = GDNMetal.runBlocked(q: a[0], k: a[1], v: a[2], g: a[3], beta: a[4], ssm: z)
    let r0 = legacyBlocked(q: a[0], k: a[1], v: a[2], g: a[3], beta: a[4], ssm: z)
    eval(n0.y, n0.ssm, r0[0], r0[1])
    #expect(bitEqual(n0.y, r0[0]) && bitEqual(n0.ssm, r0[1]))
    // the comparison is sensitive: one flipped k element must change y
    var kk = a[1] * MLXArray(Float(1)).asType(.bfloat16)   // a copy: MLXArray subscript assignment mutates the object
    kk[0, 3, 2, 5] = kk[0, 3, 2, 5] + MLXArray(Float(0.25)).asType(.bfloat16)
    let nk = GDNMetal.runBlocked(q: a[0], k: kk, v: a[2], g: a[3], beta: a[4], ssm: a[5])
    let nb = GDNMetal.runBlocked(q: a[0], k: a[1], v: a[2], g: a[3], beta: a[4], ssm: a[5])
    eval(nk.y, nb.y)
    #expect(!bitEqual(nk.y, nb.y))
}

/// A real q/k scale folded into the RMS-norm weight equals the separate multiply, bit for bit.
@Test(.enabled(if: metalReady)) func qkScaleFoldedIntoNormWeightIsBitIdentical() {
    MLXRandom.seed(21)
    let inv = pow(Float(GDN.Dk), -0.5)
    let ones = MLXArray.ones([GDN.Dk], dtype: .bfloat16)
    for (S, s) in [(1024, Float(1)), (333, 5), (7, 0.001), (1, 30)] {
        let x = (MLXRandom.normal([1, S, 16, GDN.Dk]) * s).asType(.bfloat16)
        eval(x)
        let oldQ = MLXFast.rmsNorm(x, weight: ones, eps: 1e-6) * (inv * inv)
        let newQ = MLXFast.rmsNorm(x, weight: GDN.qScaleBf16, eps: 1e-6)
        let oldK = MLXFast.rmsNorm(x, weight: ones, eps: 1e-6) * inv
        let newK = MLXFast.rmsNorm(x, weight: GDN.kScaleBf16, eps: 1e-6)
        eval(oldQ, newQ, oldK, newK)
        #expect(bitEqual(oldQ, newQ), "q scale fold differs S=\(S)")
        #expect(bitEqual(oldK, newK), "k scale fold differs S=\(S)")
    }
}
