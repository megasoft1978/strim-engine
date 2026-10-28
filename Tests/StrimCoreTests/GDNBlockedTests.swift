import Foundation
import MLX
import MLXRandom
import Testing
@testable import StrimCore

/// Blocked GDN prefill kernel must be deterministic and match the serial kernel.
@Test func blockedGDNDeterministicAndMatchesSerial() {
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
