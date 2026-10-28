import Foundation
import MLX
import MLXRandom
import Testing
@testable import StrimCore

/// The batch-dimension decode kernels (STRIM_BATCH_DECODE) must be bitwise equal, per sequence,
/// to the B=1 kernels they replace.
@Test func batchGDNKernelsBitwiseEqualPerSequence() {
    let B = 5, S = 1, Hk = 16, Hv = 48, D = 128, C = 2 * Hk * D + Hv * D
    MLXRandom.seed(11)
    let q = (MLXRandom.normal([B, S, Hv, D]) * 0.05).asType(.bfloat16)
    let k = (MLXRandom.normal([B, S, Hv, D]) * 0.05).asType(.bfloat16)
    let v = (MLXRandom.normal([B, S, Hv, D]) * 0.5).asType(.bfloat16)
    let g = exp(-MLXRandom.uniform(low: 0.001, high: 0.2, [B, S, Hv]))
    let beta = sigmoid(MLXRandom.normal([B, S, Hv]))
    let ssm = (MLXRandom.normal([B, Hv, D, D]) * 0.1).asType(.float32)
    let convIn = (MLXRandom.normal([B, S + 3, C]) * 0.5).asType(.bfloat16)
    let w = (MLXRandom.normal([C, 4]) * 0.3).asType(.bfloat16)
    eval(q, k, v, g, beta, ssm, convIn, w)

    let rb = GDNMetal.runBatch(q: q, k: k, v: v, g: g, beta: beta, ssm: ssm)
    let cb = GDNMetal.convSiluBatch(convIn: convIn, weight: w)
    eval(rb.y, rb.ssm, cb)
    for b in 0 ..< B {
        let r = GDNMetal.run(q: q[b ..< (b + 1)], k: k[b ..< (b + 1)], v: v[b ..< (b + 1)], g: g[b ..< (b + 1)],
                             beta: beta[b ..< (b + 1)], ssm: ssm[b ..< (b + 1)], recordStack: false)
        let c = GDNMetal.convSilu(convIn: convIn[b ..< (b + 1)], weight: w)
        eval(r.y, r.ssm, c)
        #expect(abs(rb.y[b ..< (b + 1)].asType(.float32) - r.y.asType(.float32)).max().item(Float.self) == 0)
        #expect(abs(rb.ssm[b ..< (b + 1)] - r.ssm).max().item(Float.self) == 0)
        #expect(abs(cb[b ..< (b + 1)].asType(.float32) - c.asType(.float32)).max().item(Float.self) == 0)
    }
}
