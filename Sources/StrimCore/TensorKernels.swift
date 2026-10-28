import Foundation
import MLX
import MLXFast

// W4A8 prefill prototype (lane L14): int8 x int8 -> int32 Metal 4 tensor-op (MPP matmul2d) kernel that
// runs inside the MLX lazy graph through MLXFast.metalKernel (MLX compiles custom kernels with Metal
// language version 4.0/4.1 on macOS 26+, so `#include <MetalPerformancePrimitives/...>` in the header works).
// Numerically different from the 4-bit qmm path (activations are quantized to int8), so always opt-in.
//
//   y[m,n] = sum_g a[m,g] * ( s[n,g] * P[m,n,g] ) + b[n,g] * a2[m,g]
//   P = int32 sum over the 64-wide group of xi[m,k] * q[n,k]   (q = unsigned nibble 0..15, MLX affine packing)
//   x ~ a[m,g] * xi, a2[m,g] = a[m,g] * sum_k xi[m,k]
public enum W4A8 {
    public struct Quantized {
        public let xi: MLXArray  // int8 [M, K]
        public let a: MLXArray  // float32 [M, K/64]
        public let a2: MLXArray  // float32 [M, K/64]
    }

    nonisolated(unsafe) private static var cache: [String: MLXFast.MLXFastKernel] = [:]

    private static let header = """
        #include <metal_stdlib>
        #include <metal_tensor>
        #include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
        using namespace metal;
        using namespace mpp::tensor_ops;
        """

    /// Per-64-group symmetric int8 quantization of activations (x: [M, K] half/bfloat/float, K % 64 == 0).
    /// `clip` in (0, 1] scales the group max before computing the step (percentile-like clipping).
    public static func quantizeActivations(_ x: MLXArray, clip: Float = 1.0) -> Quantized {
        let key = "w4a8_quant"
        let kernel: MLXFast.MLXFastKernel
        if let k = cache[key] { kernel = k } else {
            kernel = MLXFast.metalKernel(
                name: key, inputNames: ["x", "clipv"], outputNames: ["xi", "a", "a2"],
                source: """
                    uint t = thread_position_in_grid.x;
                    const device T* p = x + (size_t)t * 64;
                    float mx = 0.0f;
                    for (int i = 0; i < 64; ++i) mx = max(mx, abs((float)p[i]));
                    float sc = mx * clipv[0] / 127.0f;
                    float inv = sc > 0.0f ? 1.0f / sc : 0.0f;
                    int sum = 0;
                    for (int i = 0; i < 64; ++i) {
                        int q = (int)rint((float)p[i] * inv);
                        q = clamp(q, -127, 127);
                        xi[(size_t)t * 64 + i] = (int8_t)q;
                        sum += q;
                    }
                    a[t] = sc;
                    a2[t] = sc * (float)sum;
                    """)
            cache[key] = kernel
        }
        let M = x.shape[0], K = x.shape[1]
        let G = M * K / 64
        let r = kernel(
            [x, MLXArray([clip])], template: [("T", x.dtype)], grid: (G, 1, 1), threadGroup: (min(G, 256), 1, 1),
            outputShapes: [[M, K], [M, K / 64], [M, K / 64]], outputDTypes: [.int8, .float32, .float32])
        return Quantized(xi: r[0], a: r[1], a2: r[2])
    }

    /// int8 tensor-op matmul against MLX 4-bit g64 affine packed weights. wq: uint32 [N, K/8], scales/biases [N, K/64].
    public static func matmul(
        _ q: Quantized, wq: MLXArray, scales: MLXArray, biases: MLXArray, mt: Int = 64, nt: Int = 64, sg: Int = 4, variant: Int = 0
    ) -> MLXArray {
        let M = q.xi.shape[0], N = wq.shape[0]
        precondition(M % mt == 0 && N % nt == 0, "W4A8 tile must divide M and N")
        let key = "w4a8_mm_\(mt)_\(nt)_\(sg)_v\(variant)"
        let kernel: MLXFast.MLXFastKernel
        if let k = cache[key] { kernel = k } else {
            let threads = 32 * sg
            kernel = MLXFast.metalKernel(
                name: key, inputNames: ["xi", "a", "a2", "wq", "sc", "bi"], outputNames: ["y"],
                source: """
                    #define VAR \(variant)
                    constexpr int MT = \(mt), NT = \(nt), KT = 64, THREADS = \(threads);
                    constexpr int CAPMAX = MT * NT / THREADS;
                    const int M = xi_shape[0], K = xi_shape[1], N = wq_shape[0];
                    const int G = K / 64;
                    const int n0 = threadgroup_position_in_grid.x * NT;
                    const int m0 = threadgroup_position_in_grid.y * MT;
                    const uint tid = thread_index_in_threadgroup;
                    threadgroup uint2 Wt2[NT * 8];
                    threadgroup int8_t* Wt = (threadgroup int8_t*)Wt2;
                    threadgroup float sA[MT], sA2[MT], sS[NT], sB[NT];
                    using TA = tensor<device int8_t, dextents<int32_t, 2>, tensor_inline>;
                    using TW = tensor<threadgroup int8_t, dextents<int32_t, 2>, tensor_inline>;
                    TA A((device int8_t*)xi, dextents<int32_t, 2>(K, M));
                    TW Wtt(Wt, dextents<int32_t, 2>(KT, NT));
                    constexpr auto desc = matmul2d_descriptor(MT, NT, KT, false, true, false, matmul2d_descriptor::mode::multiply);
                    matmul2d<desc, execution_simdgroups<\(sg)>> op;
                    auto cI = op.get_destination_cooperative_tensor<TA, TW, int>();
                    const uint16_t cap = cI.get_capacity();
                    if (cap > CAPMAX) return;
                    float acc[CAPMAX];
                    int em[CAPMAX];
                    int en[CAPMAX];
                    #pragma unroll
                    for (uint16_t i = 0; i < CAPMAX; ++i) {
                        acc[i] = 0.0f; em[i] = -1; en[i] = 0;
                        if (i < cap && cI.is_valid_element(i)) {
                            auto ids = cI.get_multidimensional_index(i);
                            en[i] = (int)ids[0];
                            em[i] = (int)ids[1];
                        }
                    }
                    const uint kw = K / 8;
                    for (int g = 0; g < G; ++g) {
                        #if VAR != 1 && VAR != 3
                        for (uint idx = tid; idx < (uint)(NT * 8); idx += THREADS) {
                            const uint row = idx >> 3, wc = idx & 7;
                            const uint w = wq[(uint)(n0 + (int)row) * kw + (uint)g * 8 + wc];
                            uint lo = (w & 0xFu) | (((w >> 4) & 0xFu) << 8) | (((w >> 8) & 0xFu) << 16) | (((w >> 12) & 0xFu) << 24);
                            uint hi = ((w >> 16) & 0xFu) | (((w >> 20) & 0xFu) << 8) | (((w >> 24) & 0xFu) << 16) | (((w >> 28) & 0xFu) << 24);
                            Wt2[row * 8 + wc] = uint2(lo, hi);
                        }
                        #endif
                        for (uint idx = tid; idx < (uint)MT; idx += THREADS) {
                            const int mm = m0 + (int)idx;
                            sA[idx] = mm < M ? a[mm * G + g] : 0.0f;
                            sA2[idx] = mm < M ? a2[mm * G + g] : 0.0f;
                        }
                        for (uint idx = tid; idx < (uint)NT; idx += THREADS) {
                            sS[idx] = (float)sc[(n0 + (int)idx) * G + g];
                            sB[idx] = (float)bi[(n0 + (int)idx) * G + g];
                        }
                        threadgroup_barrier(mem_flags::mem_threadgroup);
                        auto tA = A.slice(g * 64, m0);
                        op.run(tA, Wtt, cI);
                        threadgroup_barrier(mem_flags::mem_threadgroup);
                        #if VAR == 2 || VAR == 3
                        for (uint16_t i = 0; i < CAPMAX; ++i) acc[i] += (float)cI[i];
                        #else
                        #pragma unroll
                        for (uint16_t i = 0; i < CAPMAX; ++i) {
                            const int m = em[i];
                            if (m >= 0) {
                                const int n = en[i];
                                acc[i] += sA[m] * sS[n] * (float)cI[i] + sB[n] * sA2[m];
                            }
                        }
                        #endif
                        threadgroup_barrier(mem_flags::mem_threadgroup);
                    }
                    #pragma unroll
                    for (uint16_t i = 0; i < CAPMAX; ++i) {
                        if (em[i] >= 0 && m0 + em[i] < M) y[(size_t)(m0 + em[i]) * N + n0 + en[i]] = (half)acc[i];
                    }
                    """,
                header: header)
            cache[key] = kernel
        }
        let tgx = N / nt, tgy = M / mt
        return kernel(
            [q.xi, q.a, q.a2, wq, scales, biases], grid: (tgx * 32 * sg, tgy, 1), threadGroup: (32 * sg, 1, 1),
            outputShapes: [[M, N]], outputDTypes: [.float16])[0]
    }
}
