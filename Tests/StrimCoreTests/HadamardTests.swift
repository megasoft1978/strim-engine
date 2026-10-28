import Foundation
import MLX
import Testing
@testable import StrimCore

/// Integer inputs and a power-of-two scale (block 1024 -> 2^-5) make every partial sum exact, so the
/// MLX transform must equal the brute-force Sylvester matrix product bit for bit.
@Test func hadamardBlock1024MatchesBruteForceBitExact() {
    let n = 1024, rows = 3
    var g = SystemRandomNumberGenerator()
    let xs = (0 ..< rows * 2 * n).map { _ in Float(Int.random(in: -8 ... 8, using: &g)) }
    let signs = (0 ..< 2 * n).map { _ in Float(Bool.random(using: &g) ? 1 : -1) }
    let y = Hadamard.transform(MLXArray(xs, [rows, 2 * n]), signs: MLXArray(signs), block: n, outDType: .float32)
    eval(y)
    let yv = y.asArray(Float.self)
    let h = Hadamard.referenceMatrix(n)
    for r in 0 ..< rows {
        for b in 0 ..< 2 {
            for i in 0 ..< n {
                var acc = 0.0
                for j in 0 ..< n { acc += Double(h[i * n + j]) * Double(xs[r * 2 * n + b * n + j] * signs[b * n + j]) }
                #expect(Float(acc).bitPattern == yv[r * 2 * n + b * n + i].bitPattern)
            }
        }
    }
}

@Test func hadamardInverseRoundTrips() {
    let x = MLXRandom.normal([2, 3, 2048])
    let s = MLXArray((0 ..< 2048).map { Float($0 % 3 == 0 ? -1 : 1) })
    let back = Hadamard.inverse(Hadamard.transform(x, signs: s), signs: s)
    #expect(allClose(back, x, rtol: 1e-4, atol: 1e-4).item(Bool.self))
}
