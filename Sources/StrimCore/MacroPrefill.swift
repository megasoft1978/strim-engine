import Foundation
import MLX

/// S3 experiment: opt-in macro projections/MLP, with the original 1K
/// recurrence and SDPA ranges. Dense weights are transient graph intermediates.
public enum MacroPrefill {
    public static let enabled = ProcessInfo.processInfo.environment["STRIM_PREFILL_MACRO_BF16"] == "1"
    public static let rows = 4096
    public static let subRows = 1024

    public static func ranges(count: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: subRows).map { $0 ..< min($0 + subRows, count) }
    }

    static func splits(_ x: MLXArray) -> Bool {
        enabled && x.ndim == 3 && x.shape[0] == 1
            && x.shape[1] > subRows && x.shape[1] <= rows && x.dtype == .bfloat16
    }

    static func dense(_ x: MLXArray, spec: QuantSpec, rotated: Bool) -> Bool {
        !rotated && splits(x) && x.shape[1] == rows && spec.bits == 4 && spec.mode == "affine"
    }
}
