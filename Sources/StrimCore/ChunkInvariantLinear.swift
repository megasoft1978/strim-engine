import Foundation
import MLX

/// Opt-in (`STRIM_GDN_BA_INVARIANT=1`, default OFF) row-count-invariant quantized projection for the narrow
/// GDN `in_proj_b` / `in_proj_a` matmuls (N = value heads, 48 for the 27B).
///
/// Why: `QuantizedMatmul::eval_gpu` routes every B==1, M >= vector_limit, transposed call to
/// `qmm_splitk` (mlx/backend/metal/quantized.cpp), which picks `split_k = max(1, 512 / (n_tiles * m_tiles))`
/// with 32x32 tiles. For N=48 (n_tiles=2) that is split 8 at M=1024, 4 at M=2048, 2 at M=4096 and 1 from
/// m_tiles >= 129 (M >= 4128). The K reduction is therefore associated differently per chunk size (and the
/// partials are stored in the activation dtype), so identical rows give different bits at different chunk sizes.
/// Padding the rows with zeros until split_k == 1 selects the plain `qmm` kernel, whose per-row arithmetic does not
/// depend on M. Cost: a few thousand extra rows through a 48-wide matmul.
///
/// Flag ON changes numerics versus flag OFF (different but chunk-independent association); never enable it
/// without re-baselining the exactness gates.
public enum ChunkInvariantLinear {
    public static let enabled = ProcessInfo.processInfo.environment["STRIM_GDN_BA_INVARIANT"] == "1"

    /// Mirror of MLX's `qmm_splitk` heuristic (before the K-divisibility reduction), for tests and docs.
    public static func splitK(m: Int, n: Int) -> Int {
        let nTiles = (n + 31) / 32, mTiles = (m + 31) / 32
        return max(1, 512 / (nTiles * mTiles))
    }

    /// Smallest row count whose heuristic split_k is 1 for output width `n`.
    public static func minRowsForNoSplit(n: Int) -> Int {
        let nTiles = (n + 31) / 32
        return 32 * ((257 + nTiles - 1) / nTiles)
    }

    /// Pads x [1, S, K] with zero rows to `minRowsForNoSplit(n:)` when 4 < S < that, runs `op`, slices back to S rows.
    public static func padded(_ x: MLXArray, n: Int, _ op: (MLXArray) throws -> MLXArray) rethrows -> MLXArray {
        guard x.ndim == 3, x.shape[0] == 1 else { return try op(x) }
        let S = x.shape[1]
        let target = minRowsForNoSplit(n: n)
        guard S > 4, S < target else { return try op(x) }   // decode/verify stay on the qmv path
        let pad = MLXArray.zeros([1, target - S, x.shape[2]], dtype: x.dtype)
        return try op(concatenated([x, pad], axis: 1))[0..., 0 ..< S, 0...]
    }

    /// `store.linear(prefix, x)` for x of shape [B, S, K]. With the flag off this is exactly `store.linear`.
    public static func linear(_ store: WeightStore, _ prefix: String, _ x: MLXArray, force: Bool = false) throws -> MLXArray {
        guard enabled || force else { return try store.linear(prefix, x) }
        let n = try store.tensor(prefix + ".weight").shape[0]
        return try padded(x, n: n) { try store.linear(prefix, $0) }
    }
}
