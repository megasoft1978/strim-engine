// Licensing: the `blockedKernel` Metal kernel (blocked-sequential Gated DeltaNet
// prefill) is ported from `rapid_mlx/gdn_prefill.py` in Rapid-MLX
// (https://github.com/raullenchai/Rapid-MLX), Copyright 2025-2026 the Rapid-MLX
// contributors, Apache License 2.0 (LICENSES/Apache-2.0.txt). Rapid-MLX adapted it
// from oMLX (https://github.com/jundot/omlx), Apache License 2.0. The rest of this
// file is Strim's, MIT (LICENSE). See NOTICE and docs/THIRD-PARTY.md.

import Foundation
import MLX
import MLXFast

/// Fused gated-delta recurrence for the decode path.
///
/// The tensor version runs ~8 dependent ops per token over a 3 MB float32 state,
/// so a 3-token verify pass pays that latency three times (48 layers deep). This
/// kernel keeps one `(head, value-dim)` row of the state in registers, loops over
/// the step's tokens inside the kernel, and writes the per-token state stack the
/// speculative rollback needs. Memory traffic per layer drops from ~24 MB/token
/// to ~6 MB plus the stack.
public enum GDNMetal {
    static let Dv = 128
    static let Dk = 128

    nonisolated(unsafe) static let kernel = MLXFast.metalKernel(
        name: "gdn_recurrence",
        inputNames: ["q", "k", "v", "g", "beta", "ssm", "dims"],
        outputNames: ["y", "ssmOut", "stack"],
        source: """
            #pragma clang fp contract(off)
            uint row = threadgroup_position_in_grid.x;
            uint lane = thread_position_in_threadgroup.x;
            uint S = dims[0];
            uint Hv = dims[1];
            uint storeStack = dims[2];
            uint h = row / 128;
            uint dv = row % 128;
            uint dk0 = lane * 4;

            float st[4];
            for (uint i = 0; i < 4; ++i) st[i] = ssm[row * 128 + dk0 + i];

            for (uint t = 0; t < S; ++t) {
                float decay = g[t * Hv + h];
                const device bfloat16_t* krow = k + (t * Hv + h) * 128;

                float kv = 0.0f;
                for (uint i = 0; i < 4; ++i) {
                    st[i] *= decay;
                    // MLX's gemv accumulates with FMA (no contract(off) in gemv.h); the
                    // state update below stays separate mul+add to match the K=1 matmul.
                    kv = metal::fma(st[i], float(krow[dk0 + i]), kv);
                }
                for (uint off = 16; off > 0; off >>= 1) kv += simd_shuffle_down(kv, off);
                kv = simd_broadcast(kv, 0);

                float delta = (float(v[(t * Hv + h) * 128 + dv]) - kv) * beta[t * Hv + h];

                float yv = 0.0f;
                for (uint i = 0; i < 4; ++i) {
                    st[i] += float(krow[dk0 + i]) * delta;
                    yv = metal::fma(st[i], float(q[(t * Hv + h) * 128 + dk0 + i]), yv);
                }
                for (uint off = 16; off > 0; off >>= 1) yv += simd_shuffle_down(yv, off);

                if (lane == 0) {
                    y[(t * Hv + h) * 128 + dv] = static_cast<bfloat16_t>(yv);
                }
                if (storeStack != 0) {
                    for (uint i = 0; i < 4; ++i) {
                        stack[t * (Hv * 128 * 128) + row * 128 + dk0 + i] = st[i];
                    }
                }
            }

            for (uint i = 0; i < 4; ++i) {
                ssmOut[row * 128 + dk0 + i] = st[i];
            }
            """,
        header: "")

    /// y [1,S,Hv,Dv] bf16, ssm [1,Hv,Dv,Dk] f32, stack [S,Hv,Dv,Dk] f32.
    public static func run(q: MLXArray, k: MLXArray, v: MLXArray, g: MLXArray,
                           beta: MLXArray, ssm: MLXArray,
                           recordStack: Bool = true) -> (y: MLXArray, ssm: MLXArray, stack: MLXArray) {
        let S = q.shape[1]
        let Hv = q.shape[2]
        let dims = MLXArray([Int32(S), Int32(Hv), recordStack ? Int32(1) : Int32(0)])
        let out = kernel([q, k, v, g.asType(.float32).contiguous(),
                          beta.asType(.float32).contiguous(), ssm, dims],
                         grid: (Hv * Dv * 32, 1, 1), threadGroup: (32, 1, 1),
                         outputShapes: [[1, S, Hv, Dv], [1, Hv, Dv, Dk],
                                        recordStack ? [S, Hv, Dv, Dk] : [1, 1, 1, 1]],
                         outputDTypes: [.bfloat16, .float32, .float32])
        return (out[0], out[1], out[2])
    }

    /// Batch-dimension variant of `kernel` for B>1 decode (no stack). Same per-row arithmetic as
    /// the B=1 kernel (bitwise equal per sequence); one dispatch for all sequences, batch index
    /// on grid.y.
    nonisolated(unsafe) static let batchKernel = MLXFast.metalKernel(
        name: "gdn_recurrence_batch",
        inputNames: ["q", "k", "v", "g", "beta", "ssm", "dims"],
        outputNames: ["y", "ssmOut"],
        source: """
            #pragma clang fp contract(off)
            uint row = threadgroup_position_in_grid.x;
            uint b = threadgroup_position_in_grid.y;
            uint lane = thread_position_in_threadgroup.x;
            uint S = dims[0];
            uint Hv = dims[1];
            uint h = row / 128;
            uint dv = row % 128;
            uint dk0 = lane * 4;
            size_t tok0 = (size_t)b * S;
            size_t srow = ((size_t)b * Hv * 128 + row) * 128;

            float st[4];
            for (uint i = 0; i < 4; ++i) st[i] = ssm[srow + dk0 + i];

            for (uint t = 0; t < S; ++t) {
                size_t tk = tok0 + t;
                float decay = g[tk * Hv + h];
                const device bfloat16_t* krow = k + (tk * Hv + h) * 128;

                float kv = 0.0f;
                for (uint i = 0; i < 4; ++i) {
                    st[i] *= decay;
                    kv = metal::fma(st[i], float(krow[dk0 + i]), kv);
                }
                for (uint off = 16; off > 0; off >>= 1) kv += simd_shuffle_down(kv, off);
                kv = simd_broadcast(kv, 0);

                float delta = (float(v[(tk * Hv + h) * 128 + dv]) - kv) * beta[tk * Hv + h];

                float yv = 0.0f;
                for (uint i = 0; i < 4; ++i) {
                    st[i] += float(krow[dk0 + i]) * delta;
                    yv = metal::fma(st[i], float(q[(tk * Hv + h) * 128 + dk0 + i]), yv);
                }
                for (uint off = 16; off > 0; off >>= 1) yv += simd_shuffle_down(yv, off);

                if (lane == 0) {
                    y[(tk * Hv + h) * 128 + dv] = static_cast<bfloat16_t>(yv);
                }
            }

            for (uint i = 0; i < 4; ++i) {
                ssmOut[srow + dk0 + i] = st[i];
            }
            """,
        header: "")

    /// q,k [B,S,Hv,Dk] bf16, v [B,S,Hv,Dv], g/beta [B,S,Hv], ssm [B,Hv,Dv,Dk] f32 -> y [B,S,Hv,Dv], ssm.
    public static func runBatch(q: MLXArray, k: MLXArray, v: MLXArray, g: MLXArray,
                                beta: MLXArray, ssm: MLXArray) -> (y: MLXArray, ssm: MLXArray) {
        let B = q.shape[0], S = q.shape[1], Hv = q.shape[2]
        let dims = MLXArray([Int32(S), Int32(Hv)])
        let out = batchKernel([q.contiguous(), k.contiguous(), v.contiguous(), g.asType(.float32).contiguous(),
                               beta.asType(.float32).contiguous(), ssm.contiguous(), dims],
                              grid: (Hv * Dv * 32, B, 1), threadGroup: (32, 1, 1),
                              outputShapes: [[B, S, Hv, Dv], [B, Hv, Dv, Dk]],
                              outputDTypes: [.bfloat16, .float32])
        return (out[0], out[1])
    }

    /// Batched twin of `convKernel` (identical per-element arithmetic): convIn [B,S+3,C] -> [B,S,C].
    nonisolated(unsafe) static let convBatchKernel = MLXFast.metalKernel(
        name: "gdn_conv_silu_batch",
        inputNames: ["convIn", "w", "dims"],
        outputNames: ["out"],
        source: """
            #pragma clang fp contract(off)
            uint idx = thread_position_in_grid.x;
            uint C = dims[0];
            uint S = dims[1];
            uint B = dims[2];
            if (idx >= B * S * C) return;
            uint c = idx % C;
            uint s = (idx / C) % S;
            uint b = idx / (C * S);
            uint base = b * (S + 3);
            bfloat16_t acc = convIn[(base + 0 + s) * C + c] * w[c * 4 + 0];
            acc = acc + convIn[(base + 1 + s) * C + c] * w[c * 4 + 1];
            acc = acc + convIn[(base + 2 + s) * C + c] * w[c * 4 + 2];
            acc = acc + convIn[(base + 3 + s) * C + c] * w[c * 4 + 3];
            bfloat16_t xb = acc;
            bfloat16_t one = static_cast<bfloat16_t>(1.0f);
            bfloat16_t zero = static_cast<bfloat16_t>(0.0f);
            bfloat16_t y = one / (one + metal::exp(metal::abs(xb)));
            bfloat16_t sig = (xb < zero) ? y : one - y;
            out[idx] = static_cast<bfloat16_t>(float(xb) * float(sig));
            """,
        header: "")

    public static func convSiluBatch(convIn: MLXArray, weight: MLXArray) -> MLXArray {
        let B = convIn.shape[0], C = convIn.shape[2]
        let S = convIn.shape[1] - 3
        let dims = MLXArray([Int32(C), Int32(S), Int32(B)])
        return convBatchKernel([convIn.contiguous(), weight, dims],
                               grid: (B * S * C, 1, 1), threadGroup: (256, 1, 1),
                               outputShapes: [[B, S, C]], outputDTypes: [.bfloat16])[0]
    }

    /// Blocked-sequential GDN prefill, ported from rapid-mlx's `gdn_prefill.py`
    /// (Apache-2.0), which adapted it from oMLX. Unlike the decode kernel above, one
    /// threadgroup owns 32 value rows and stages k/q/v in 32-token blocks, so k/q rows
    /// are read once per threadgroup instead of once per value row. The recurrence is
    /// still the exact sequential one; only the f32 reduction tree changes.
    nonisolated(unsafe) static let blockedKernel = MLXFast.metalKernel(
        name: "gdn_blocked_prefill",
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

    /// Blocked prefill for B=1, bf16 q/k/v, Hk==Hv, Dk=Dv=128. Returns y/ssm.
    public static func runBlocked(q: MLXArray, k: MLXArray, v: MLXArray,
                                  g: MLXArray, beta: MLXArray,
                                  ssm: MLXArray) -> (y: MLXArray, ssm: MLXArray) {
        let B = q.shape[0], S = q.shape[1], Hk = q.shape[2], Hv = v.shape[2]
        let dims = MLXArray([Int32(S), Int32(Hk), Int32(Hv), Int32(B)])
        let out = blockedKernel([q, k, v, g.asType(.float32).contiguous(),
                                 beta.asType(.float32).contiguous(), ssm, dims],
                                grid: (4 * 256, Hv, B), threadGroup: (256, 1, 1),
                                outputShapes: [[B, S, Hv, Dv], [B, Hv, Dv, Dk]],
                                outputDTypes: [.bfloat16, .float32])
        return (out[0], out[1])
    }

    /// Depthwise 4-tap conv + SiLU in one kernel, replacing 7 dispatches per layer.
    /// Arithmetic is bf16 step-by-step in k order 0,1,2,3 with contraction off, to match
    /// `GDN.depthwise` followed by `silence` exactly.
    nonisolated(unsafe) static let convKernel = MLXFast.metalKernel(
        name: "gdn_conv_silu",
        inputNames: ["convIn", "w", "dims"],
        outputNames: ["out"],
        source: """
            #pragma clang fp contract(off)
            uint idx = thread_position_in_grid.x;
            uint C = dims[0];
            uint S = dims[1];
            if (idx >= S * C) return;
            uint c = idx % C;
            uint s = idx / C;
            bfloat16_t acc = convIn[(0 + s) * C + c] * w[c * 4 + 0];
            acc = acc + convIn[(1 + s) * C + c] * w[c * 4 + 1];
            acc = acc + convIn[(2 + s) * C + c] * w[c * 4 + 2];
            acc = acc + convIn[(3 + s) * C + c] * w[c * 4 + 3];
            // MLX's `Sigmoid` instantiated on bfloat16_t rounds at every step:
            // 1/(1+exp(|x|)) in bf16, then 1-y for x >= 0. Computing this in float and
            // casting once is ~1 ulp off (see `strim checkconv`).
            bfloat16_t xb = acc;
            bfloat16_t one = static_cast<bfloat16_t>(1.0f);
            bfloat16_t zero = static_cast<bfloat16_t>(0.0f);
            bfloat16_t y = one / (one + metal::exp(metal::abs(xb)));
            bfloat16_t sig = (xb < zero) ? y : one - y;
            out[idx] = static_cast<bfloat16_t>(float(xb) * float(sig));
            """,
        header: "")

    /// Debug-only variants used by `strim checkconv` to localise the conv kernel's
    /// difference from `GDN.depthwise` + `GDN.silence`. mode 0 = sum+silu, 1 = bf16 sum
    /// only, 2 = silu only (input is the already-computed sum, `[1,1,C]`).
    nonisolated(unsafe) static let convDebugKernel = MLXFast.metalKernel(
        name: "gdn_conv_debug",
        inputNames: ["convIn", "w", "dims"],
        outputNames: ["out"],
        source: """
            #pragma clang fp contract(off)
            uint idx = thread_position_in_grid.x;
            uint C = dims[0];
            uint S = dims[1];
            uint mode = dims[2];
            if (idx >= S * C) return;
            if (mode >= 2) {
                bfloat16_t xb = convIn[idx];
                bfloat16_t sig;
                if (mode == 4 || mode == 5) {
                    // MLX's Sigmoid instantiated on bfloat16_t: every step may round.
                    bfloat16_t one = static_cast<bfloat16_t>(1.0f);
                    bfloat16_t zero = static_cast<bfloat16_t>(0.0f);
                    bfloat16_t y = one / (one + metal::exp(metal::abs(xb)));
                    sig = (xb < zero) ? y : one - y;
                } else {
                    float f = float(xb);
                    float y = 1.0f / (1.0f + metal::exp(metal::abs(f)));
                    float sigf = (f < 0.0f) ? y : 1.0f - y;
                    sig = static_cast<bfloat16_t>(sigf);
                }
                if (mode == 2 || mode == 4) { out[idx] = sig; return; }
                out[idx] = static_cast<bfloat16_t>(float(xb) * float(sig));
                return;
            }
            uint c = idx % C;
            uint s = idx / C;
            bfloat16_t acc = convIn[(0 + s) * C + c] * w[c * 4 + 0];
            acc = acc + convIn[(1 + s) * C + c] * w[c * 4 + 1];
            acc = acc + convIn[(2 + s) * C + c] * w[c * 4 + 2];
            acc = acc + convIn[(3 + s) * C + c] * w[c * 4 + 3];
            if (mode == 1) { out[idx] = acc; return; }
            bfloat16_t xb = acc;
            bfloat16_t one = static_cast<bfloat16_t>(1.0f);
            bfloat16_t zero = static_cast<bfloat16_t>(0.0f);
            bfloat16_t y = one / (one + metal::exp(metal::abs(xb)));
            bfloat16_t sig = (xb < zero) ? y : one - y;
            out[idx] = static_cast<bfloat16_t>(float(xb) * float(sig));
            """,
        header: "")

    public static func convDebug(convIn: MLXArray, weight: MLXArray, mode: Int) -> MLXArray {
        let C = convIn.shape[2]
        let S = mode >= 2 ? convIn.size / C : convIn.shape[1] - 3
        let dims = MLXArray([Int32(C), Int32(S), Int32(mode)])
        return convDebugKernel([convIn, weight, dims], grid: (S * C, 1, 1),
                               threadGroup: (256, 1, 1),
                               outputShapes: [[1, S, C]], outputDTypes: [.bfloat16])[0]
    }

    /// convIn [B,4,C] bf16, weight [C,4] bf16 -> [B,S,C] bf16, S = convIn.dim1 - 3.
    public static func convSilu(convIn: MLXArray, weight: MLXArray) -> MLXArray {
        let C = convIn.shape[2]
        let S = convIn.shape[1] - 3
        let dims = MLXArray([Int32(C), Int32(S)])
        return convKernel([convIn, weight, dims],
                          grid: (S * C, 1, 1), threadGroup: (256, 1, 1),
                          outputShapes: [[1, S, C]], outputDTypes: [.bfloat16])[0]
    }
}

