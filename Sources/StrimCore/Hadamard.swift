import Foundation
import MLX

// Blockwise normalized Sylvester-Walsh-Hadamard activation transform used by Prism "Bonsai" checkpoints
// (hadamard.json: version 1, block 1024, axis input-last-dimension, sign_mode explicit).
//
//   T(x) = H_blk(x * s)   per block of `block` consecutive features, H = (1/sqrt(block)) * Sylvester matrix
//   y = qmm(T(x), W')     with W' the stored (rotated) 2-bit weight; W' = W * T^{-1}
//   embedding rows: stored rotated, original row = T^{-1}(row) = s * H_blk(row)   (H symmetric and involutive)
//
// SPIKE (lane L17): derived from hadamard.json + per-module `.signs` tensors only.
public enum Hadamard {
    /// Brute-force reference matrix: H[i][j] = (-1)^popcount(i & j) / sqrt(n), row-major. n must be a power of two.
    public static func referenceMatrix(_ n: Int) -> [Float] {
        precondition(n > 0 && (n & (n - 1)) == 0, "n must be a power of two")
        let scale = Float(1.0 / Double(n).squareRoot())
        var m = [Float](repeating: 0, count: n * n)
        for i in 0 ..< n { for j in 0 ..< n { m[i * n + j] = ((i & j).nonzeroBitCount & 1 == 0 ? 1 : -1) * scale } }
        return m
    }

    /// y = H_blk(x * signs) over the last axis (K % block == 0), computed in float32, returned in `x.dtype`
    /// (or `outDType`). `signs` is [K] (or nil for no sign flip).
    public static func transform(_ x: MLXArray, signs: MLXArray?, block: Int = 1024, outDType: DType? = nil) -> MLXArray {
        let k = x.shape[x.ndim - 1]
        precondition(k % block == 0, "last dimension \(k) is not a multiple of the Hadamard block \(block)")
        var v = x.asType(.float32)
        if let signs { v = v * signs }
        let lead = Array(x.shape.dropLast())
        let y = hadamardTransform(v.reshaped(lead + [k / block, block]), scale: Float(1.0 / Double(block).squareRoot()))
        return y.reshaped(lead + [k]).asType(outDType ?? x.dtype)
    }

    /// Inverse of `transform`: s * H_blk(y).
    public static func inverse(_ y: MLXArray, signs: MLXArray?, block: Int = 1024, outDType: DType? = nil) -> MLXArray {
        let k = y.shape[y.ndim - 1]
        precondition(k % block == 0)
        let lead = Array(y.shape.dropLast())
        var v = hadamardTransform(y.asType(.float32).reshaped(lead + [k / block, block]),
                                  scale: Float(1.0 / Double(block).squareRoot())).reshaped(lead + [k])
        if let signs { v = v * signs }
        return v.asType(outDType ?? y.dtype)
    }
}

public enum HadamardError: Error, CustomStringConvertible {
    case bad(String)
    public var description: String { switch self { case .bad(let m): "hadamard.json: \(m)" } }
}

/// The rotation contract of a checkpoint: block size plus one sign vector per input width.
/// Every rotated quantized projection of the same input width shares the vector (hadamard.json
/// `sign_widths` / `sign_values`); `WeightStore` therefore keys the activation transform on K.
public final class ActivationRotation: @unchecked Sendable {
    public let block: Int
    public let signsByWidth: [Int: MLXArray]
    public let weightNames: Set<String>
    public let inverseWeightNames: Set<String>

    public init(block: Int, signsByWidth: [Int: MLXArray], weightNames: Set<String>, inverseWeightNames: Set<String>) {
        self.block = block; self.signsByWidth = signsByWidth
        self.weightNames = weightNames; self.inverseWeightNames = inverseWeightNames
    }

    /// Activation / scale dtype. hadamard.json modules declare float16, but the engine GDN Metal kernels are bf16-only,
    /// so bf16 is the default. STRIM_BONSAI_ACT=bf16|f16|f32.
    public static let actDType: DType = {
        switch ProcessInfo.processInfo.environment["STRIM_BONSAI_ACT"] ?? "bf16" {
        case "f16": return .float16
        case "f32": return .float32
        default: return .bfloat16
        }
    }()
    public var actDType: DType { ActivationRotation.actDType }

    /// Variants for the spike's orientation experiment (env STRIM_BONSAI_ORDER): 0 = H(x*s) (default).
    nonisolated(unsafe) public static var order = Int(ProcessInfo.processInfo.environment["STRIM_BONSAI_ORDER"] ?? "") ?? 0

    /// nil when `<dir>/hadamard.json` is absent.
    public static func load(dir: URL) throws -> ActivationRotation? {
        let path = dir.appendingPathComponent("hadamard.json").path
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HadamardError.bad("not an object")
        }
        guard (o["prism.hadamard.version"] as? Int) == 1 else { throw HadamardError.bad("unsupported version") }
        guard (o["prism.hadamard.transform"] as? String) == "normalized-sylvester-walsh-hadamard",
              (o["prism.hadamard.axis"] as? String) == "input-last-dimension",
              (o["prism.hadamard.sign_mode"] as? String) == "explicit" else {
            throw HadamardError.bad("unsupported transform/axis/sign_mode")
        }
        guard let block = o["prism.hadamard.block_size"] as? Int, block > 0, block & (block - 1) == 0 else {
            throw HadamardError.bad("block_size is not a power of two")
        }
        guard let widths = o["prism.hadamard.sign_widths"] as? [Int],
              let values = (o["prism.hadamard.sign_values"] as? [NSNumber])?.map({ Float(truncating: $0) }),
              values.count == widths.reduce(0, +) else { throw HadamardError.bad("sign_widths / sign_values mismatch") }
        guard values.allSatisfy({ $0 == 1 || $0 == -1 }) else { throw HadamardError.bad("sign values must be +-1") }
        var by: [Int: MLXArray] = [:]
        var off = 0
        for w in widths {
            guard w % block == 0 else { throw HadamardError.bad("width \(w) not a multiple of block \(block)") }
            by[w] = MLXArray(Array(values[off ..< off + w])); off += w
        }
        let names = Set((o["prism.hadamard.weight_names"] as? [String]) ?? [])
        let inv = Set((o["prism.hadamard.inverse_weight_names"] as? [String]) ?? [])
        return ActivationRotation(block: block, signsByWidth: by, weightNames: names, inverseWeightNames: inv)
    }

    /// Rotated activation for a quantized projection with input width K (unchanged when K has no sign vector).
    public func apply(_ x: MLXArray) -> MLXArray {
        let k = x.shape[x.ndim - 1]
        guard let s = signsByWidth[k] else { return x }
        if ActivationRotation.order == 1 {   // experiment: s * H(x)
            return Hadamard.inverse(x, signs: s, block: block)
        }
        return Hadamard.transform(x, signs: s, block: block)
    }

    /// Inverse rotation of dequantized embedding rows.
    public func invert(_ y: MLXArray) -> MLXArray {
        let k = y.shape[y.ndim - 1]
        guard let s = signsByWidth[k] else { return y }
        if ActivationRotation.order == 1 { return Hadamard.transform(y, signs: s, block: block) }
        return Hadamard.inverse(y, signs: s, block: block)
    }
}
