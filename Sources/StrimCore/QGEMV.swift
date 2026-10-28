import Foundation
import MLX
import MLXFast

/// Hand-written 4-bit quantized GEMV for the M=1 decode path.
///
/// MLX's `quantizedMatmul` picks a different tiling per output width and leaves
/// bandwidth on the table for the narrower GDN projections. This kernel streams
/// one weight row per threadgroup: each lane reads whole uint32 words (8 nibbles)
/// and accumulates in float, with a shared-memory tree reduction per row.
public enum QGEMV {
    public static let threads = 32

    nonisolated(unsafe) static let kernel = MLXFast.metalKernel(
        name: "qgemv4",
        inputNames: ["xv", "wq", "sc", "bs", "dims"],
        outputNames: ["out"],
        source: """
            uint n = threadgroup_position_in_grid.x;
            uint lane = thread_position_in_threadgroup.x;
            uint T = threads_per_threadgroup.x;

            uint K = dims[0];
            uint wordsPerRow = K / 8;
            uint groupsPerRow = K / 64;
            uint vecsPerRow = wordsPerRow / 4;
            const device uint4* wp = (const device uint4*)wq;

            float acc = 0.0f;
            for (uint vi = lane; vi < vecsPerRow; vi += T) {
                uint4 w4 = wp[n * vecsPerRow + vi];
                uint base = vi * 32;
                uint g = n * groupsPerRow + (base >> 6);
                float scv = float(sc[g]);
                float bsv = float(bs[g]);
                uint ws[4] = {w4.x, w4.y, w4.z, w4.w};
                for (uint j = 0; j < 4; ++j) {
                    uint word = ws[j];
                    uint b = base + j * 8;
                    for (uint i = 0; i < 8; ++i) {
                        float q = float((word >> (4 * i)) & 0xF);
                        acc += (q * scv + bsv) * float(xv[b + i]);
                    }
                }
            }

            for (uint off = T / 2; off > 0; off >>= 1) {
                acc += simd_shuffle_xor(acc, off);
            }
            if (lane == 0) out[n] = static_cast<bfloat16_t>(acc);
            """,
        header: "")

    /// y = x @ dequant(w)^T for a single row, x shape [K] or [1,1,K].
    public static func linear(x: MLXArray, w: MLXArray, scales: MLXArray, biases: MLXArray) -> MLXArray {
        let K = x.shape[x.ndim - 1]
        let N = w.shape[0]
        let xv = x.reshaped([K])
        let dims = MLXArray([Int32(K), Int32(N)])
        return kernel([xv, w, scales, biases, dims],
                      grid: (N * threads, 1, 1), threadGroup: (threads, 1, 1),
                      outputShapes: [[1, 1, N]], outputDTypes: [.bfloat16])[0]
    }

    /// Batched variant: one threadgroup per weight row serves M=2..4 tokens, so the row is
    /// streamed once and M dot products fall out of it. MLX's quantizedMatmul drops to
    /// 114-253 GB/s for M=2..3 where this should stay near the M=1 rate.
    nonisolated(unsafe) static let kernelM = MLXFast.metalKernel(
        name: "qgemv4_m",
        inputNames: ["xv", "wq", "sc", "bs", "dims"],
        outputNames: ["out"],
        source: """
            uint n = threadgroup_position_in_grid.x;
            uint N = threadgroups_per_grid.x;
            uint lane = thread_position_in_threadgroup.x;
            uint T = threads_per_threadgroup.x;

            uint K = dims[0];
            uint M = dims[1];
            uint wordsPerRow = K / 8;
            uint groupsPerRow = K / 64;
            uint vecsPerRow = wordsPerRow / 4;
            const device uint4* wp = (const device uint4*)wq;

            float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f, a3 = 0.0f;
            for (uint vi = lane; vi < vecsPerRow; vi += T) {
                uint4 w4 = wp[n * vecsPerRow + vi];
                uint base = vi * 32;
                uint g = n * groupsPerRow + (base >> 6);
                float scv = float(sc[g]);
                float bsv = float(bs[g]);
                uint ws[4] = {w4.x, w4.y, w4.z, w4.w};
                for (uint j = 0; j < 4; ++j) {
                    uint word = ws[j];
                    uint b = base + j * 8;
                    for (uint i = 0; i < 8; ++i) {
                        float q = float((word >> (4 * i)) & 0xF);
                        float wq = q * scv + bsv;
                        uint k = b + i;
                        a0 += wq * float(xv[k]);
                        if (M > 1) a1 += wq * float(xv[K + k]);
                        if (M > 2) a2 += wq * float(xv[2 * K + k]);
                        if (M > 3) a3 += wq * float(xv[3 * K + k]);
                    }
                }
            }

            for (uint off = T / 2; off > 0; off >>= 1) {
                a0 += simd_shuffle_xor(a0, off);
                a1 += simd_shuffle_xor(a1, off);
                a2 += simd_shuffle_xor(a2, off);
                a3 += simd_shuffle_xor(a3, off);
            }
            if (lane == 0) {
                out[0 * N + n] = static_cast<bfloat16_t>(a0);
                if (M > 1) out[1 * N + n] = static_cast<bfloat16_t>(a1);
                if (M > 2) out[2 * N + n] = static_cast<bfloat16_t>(a2);
                if (M > 3) out[3 * N + n] = static_cast<bfloat16_t>(a3);
            }
            """,
        header: "")

    /// y = x @ dequant(w)^T for M=2..4 rows, x shape [1,M,K]; returns [1,M,N].
    public static func multi(x: MLXArray, w: MLXArray, scales: MLXArray, biases: MLXArray) -> MLXArray {
        let M = x.shape[x.ndim - 2]
        let K = x.shape[x.ndim - 1]
        let N = w.shape[0]
        let xv = x.reshaped([M * K])
        let dims = MLXArray([Int32(K), Int32(M)])
        return kernelM([xv, w, scales, biases, dims],
                       grid: (N * threads, 1, 1), threadGroup: (threads, 1, 1),
                       outputShapes: [[1, M, N]], outputDTypes: [.bfloat16])[0]
    }
}
