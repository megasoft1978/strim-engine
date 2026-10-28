import MLX

/// Thin, testable surface over MLX so the rest of the engine never imports Cmlx.
public enum Compute {
    public static var deviceName: String {
        "\(Device.defaultDevice())"
    }

    public struct MatMul: Sendable {
        public let values: [Float]
        public let shape: [Int]
    }

    /// 2x3 * 3x2 integer matmul, evaluated on the default device.
    public static func matMulSmoke() -> MatMul {
        let a = MLXArray(0 ..< 6, [2, 3]).asType(.float32)
        let b = MLXArray(0 ..< 6, [3, 2]).asType(.float32)
        let c = matmul(a, b)
        eval(c)
        return MatMul(values: c.asArray(Float.self), shape: c.shape)
    }
}
