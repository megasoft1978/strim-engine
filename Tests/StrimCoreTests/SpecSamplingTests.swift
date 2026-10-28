import Foundation
import MLX
import MLXRandom
import Testing
@testable import StrimCore

private final class BundleMarker {}

private let metalReady: Void = {
    let b = Bundle(for: BundleMarker.self)
    _ = b.load()
    _ = Bundle.allBundles
}()

/// Chi-square critical values at p = 0.01 for df 1...30.
private let chi2crit01: [Double] = [
    0, 6.635, 9.210, 11.345, 13.277, 15.086, 16.812, 18.475, 20.090, 21.666, 23.209, 24.725, 26.217, 27.688,
    29.141, 30.578, 32.000, 33.409, 34.805, 36.191, 37.566, 38.932, 40.289, 41.638, 42.980, 44.314, 45.642,
    46.963, 48.278, 49.588, 50.892,
]

/// Pearson chi-square of observed counts against expected probabilities (pooling cells with expected < 5).
/// Returns (statistic, critical value at p=0.01).
private func chiSquare(counts: [Int], probs: [Double]) -> (stat: Double, crit: Double) {
    let n = Double(counts.reduce(0, +))
    var stat = 0.0, cells = 0
    var poolObs = 0.0, poolExp = 0.0
    for (c, p) in zip(counts, probs) {
        let e = n * p
        if e < 5 { poolObs += Double(c); poolExp += e; continue }
        stat += (Double(c) - e) * (Double(c) - e) / e
        cells += 1
    }
    if poolExp > 0 {
        if poolExp >= 5 { stat += (poolObs - poolExp) * (poolObs - poolExp) / poolExp; cells += 1 }
        else { /* negligible mass; the observed mass must be tiny as well */ #expect(poolObs <= 20 + 10 * poolExp) }
    }
    return (stat, chi2crit01[min(max(cells - 1, 1), 30)])
}

private func targetP(_ row: [Float], temperature: Float, topK: Int, topP: Float) -> [Double] {
    let (ids, logp) = SpecSampling.filtered(logits: MLXArray(row).reshaped([1, row.count]),
                                            temperature: temperature, topK: topK, topP: topP)
    let i = ids.asArray(Int32.self), lp = logp.asArray(Float.self)
    var p = [Double](repeating: 0, count: row.count)
    for (t, l) in zip(i, lp) { p[Int(t)] = Double(exp(l)) }
    return p
}

private func rowFor(_ seed: UInt64, _ V: Int) -> [Float] {
    let k = MLXRandom.key(seed)
    return (MLXRandom.normal([V], key: k) * 2).asArray(Float.self)
}

@Suite struct SpecSamplingTests {
    init() { _ = metalReady }

    @Test func filteredMatchesReference() {
        // hand-checkable: logits ln([8,4,2,1,1]) -> probs [.5,.25,.125,.0625,.0625]
        let row: [Float] = [8, 4, 2, 1, 1].map { log($0) }
        let full = targetP(row, temperature: 1, topK: 0, topP: 1)
        #expect(abs(full[0] - 0.5) < 1e-5 && abs(full[4] - 0.0625) < 1e-5)
        let k2 = targetP(row, temperature: 1, topK: 2, topP: 1)
        #expect(abs(k2[0] - 2.0 / 3) < 1e-5 && abs(k2[1] - 1.0 / 3) < 1e-5 && k2[2] == 0)
        // top-p 0.7: keep tokens while mass-before <= 0.7 -> 0.5, 0.25 (before .5), 0.125 (before .75 > .7 -> dropped)
        let p7 = targetP(row, temperature: 1, topK: 0, topP: 0.7)
        #expect(abs(p7[0] - 2.0 / 3) < 1e-5 && abs(p7[1] - 1.0 / 3) < 1e-5 && p7[2] == 0)
    }

    @Test func temperatureZeroPathEqualsArgmax() {
        // Near-zero temperature collapses to argmax on every row (greedy itself never uses this
        // path; the engine keeps the exact argmax rule). Also checks the draft-accept rule is exact.
        let n = 1000, V = 64
        let logits = MLXRandom.normal([n, V], key: MLXRandom.key(7)) * 3
        let best = argMax(logits, axis: -1).asType(.int32)
        let nz = MLXRandom.uniform(low: 0, high: 1, [n, V + 1], key: MLXRandom.key(8))
        let (acc, tok) = SpecSampling.rowOutcome(logits: logits, drafts: MLXArray([Int32](repeating: -1, count: n)),
                                                 noise: nz, temperature: 1e-4, topK: 0, topP: 1)
        #expect(tok.asArray(Int32.self) == best.asArray(Int32.self))
        #expect(!any(acc).item(Bool.self))
        // draft == argmax is always accepted, any other draft never.
        let (accHit, _) = SpecSampling.rowOutcome(logits: logits, drafts: best, noise: nz, temperature: 1e-4, topK: 0, topP: 1)
        #expect(all(accHit).item(Bool.self))
        let other = (best + 1) % Int32(V)
        let (accMiss, tokMiss) = SpecSampling.rowOutcome(logits: logits, drafts: other, noise: nz, temperature: 1e-4, topK: 0, topP: 1)
        #expect(!any(accMiss).item(Bool.self))
        #expect(tokMiss.asArray(Int32.self) == best.asArray(Int32.self))
    }

    /// Accept/residual marginal over `n` trials with a fixed draft equals P.
    private func marginal(row: [Float], draft: Int32, temperature: Float, topK: Int, topP: Float, n: Int, seed: UInt64) -> (counts: [Int], p: [Double], acceptRate: Double) {
        let V = row.count
        let logits = broadcast(MLXArray(row).reshaped([1, V]), to: [n, V])
        let nz = MLXRandom.uniform(low: 0, high: 1, [n, V + 1], key: MLXRandom.key(seed))
        let (acc, tok) = SpecSampling.rowOutcome(logits: logits, drafts: MLXArray([Int32](repeating: draft, count: n)),
                                                 noise: nz, temperature: temperature, topK: topK, topP: topP)
        let out = MLX.where(acc, MLXArray(draft), tok).asArray(Int32.self)
        var counts = [Int](repeating: 0, count: V)
        for t in out { counts[Int(t)] += 1 }
        let p = targetP(row, temperature: temperature, topK: topK, topP: topP)
        return (counts, p, Double(acc.asType(.float32).mean().item(Float.self)))
    }

    @Test(arguments: [(1.0, 0, 1.0), (0.8, 5, 1.0), (1.0, 0, 0.8), (1.0, 6, 0.9)] as [(Float, Int, Float)])
    func marginalMatchesTarget(_ t: Float, _ k: Int, _ p: Float) {
        let row = rowFor(11, 16)
        let P = targetP(row, temperature: t, topK: k, topP: p)
        // drafts: the mode, a mid-prob token, a token with zero filtered mass (if any)
        let order = P.indices.sorted { P[$0] > P[$1] }
        var drafts = [Int32(order[0]), Int32(order[2])]
        if let z = P.indices.first(where: { P[$0] == 0 }) { drafts.append(Int32(z)) }
        for (j, d) in drafts.enumerated() {
            let m = marginal(row: row, draft: d, temperature: t, topK: k, topP: p, n: 200_000, seed: UInt64(2000 + j))
            let (stat, crit) = chiSquare(counts: m.counts, probs: m.p)
            #expect(stat < crit, "T=\(t) k=\(k) p=\(p) draft=\(d): chi2 \(stat) >= \(crit)")
            #expect(abs(m.acceptRate - P[Int(d)]) < 0.01)
        }
    }

    @Test func chainK3MatchesTarget() {
        // Prefix-dependent target: row j is used only while the prefix equals the drafts; any other
        // prefix would see a different row (never consulted by the verifier).
        let V = 16, n = 200_000, k = 3
        let rows = (0 ... k).map { rowFor(UInt64(40 + $0), V) }
        let (t, tk, tp): (Float, Int, Float) = (1.0, 8, 0.95)
        let Ps = rows.map { targetP($0, temperature: t, topK: tk, topP: tp) }
        let drafts: [Int32] = [Int32(Ps[0].indices.max { Ps[0][$0] < Ps[0][$1] }!),
                               Int32(Ps[1].indices.max { Ps[1][$0] < Ps[1][$1] }!),
                               Int32(Ps[2].indices.sorted { Ps[2][$0] > Ps[2][$1] }[1])]
        var acc: [MLXArray] = [], tok: [MLXArray] = []
        for j in 0 ... k {
            let logits = broadcast(MLXArray(rows[j]).reshaped([1, V]), to: [n, V])
            let nz = MLXRandom.uniform(low: 0, high: 1, [n, V + 1], key: MLXRandom.key(UInt64(500 + j)))
            let d = MLXArray([Int32](repeating: j < k ? drafts[j] : -1, count: n))
            let (a, x) = SpecSampling.rowOutcome(logits: logits, drafts: d, noise: nz, temperature: t, topK: tk, topP: tp)
            acc.append(a); tok.append(x)
        }
        // emitted[j] valid iff first j drafts accepted; emitted[j] = draft if accepted else residual
        let A = acc.map { $0.asArray(Bool.self) }, X = tok.map { $0.asArray(Int32.self) }
        var counts = [[Int]](repeating: [Int](repeating: 0, count: V), count: k + 1)
        var reached = [Int](repeating: 0, count: k + 1)
        for i in 0 ..< n {
            var j = 0
            while true {
                reached[j] += 1
                let e = (j < k && A[j][i]) ? drafts[j] : X[j][i]
                counts[j][Int(e)] += 1
                if j < k && A[j][i] { j += 1 } else { break }
            }
        }
        for j in 0 ... k {
            #expect(reached[j] > 1000, "position \(j) reached \(reached[j])")
            let (stat, crit) = chiSquare(counts: counts[j], probs: Ps[j])
            #expect(stat < crit, "chain position \(j): chi2 \(stat) >= \(crit) (n=\(reached[j]))")
        }
    }

    @Test func verifyIsReproducibleAndSeedSensitive() {
        let V = 32, k = 3
        let logits = MLXRandom.normal([k + 1, V], key: MLXRandom.key(3)) * 2
        func run(_ seed: UInt64, first: Int = 5) -> [Int32] {
            let c = SamplingConfig(temperature: 1, topK: 20, topP: 0.95, seed: seed)
            let (n, t) = SpecSampling.verify(logits: logits, drafts: [1, 2, 3], config: c, firstIndex: first)
            return concatenated([n.reshaped([1]), t.reshaped([1])]).asArray(Int32.self)
        }
        #expect(run(9) == run(9))
        // across many positions/seeds the outcome must vary
        let outs = Set((0 ..< 40).map { run(UInt64($0)) })
        #expect(outs.count > 3)
        let outsPos = Set((0 ..< 40).map { run(9, first: $0) })
        #expect(outsPos.count > 3)
        // sample(): same seed+index repeats, index changes the draw
        let c = SamplingConfig(temperature: 1, topK: 0, topP: 1, seed: 77)
        let row = logits[0]
        let a = (0 ..< 50).map { SpecSampling.sample(logits: row, config: c, index: $0).item(Int32.self) }
        let b = (0 ..< 50).map { SpecSampling.sample(logits: row, config: c, index: $0).item(Int32.self) }
        #expect(a == b)
        #expect(Set(a).count > 5)
    }

    @Test func verifyAcceptCountSemantics() {
        // Target puts all mass on d0 and d1 but not d2: accepted must be 2, token != d2 residual.
        let V = 8
        var r0 = [Float](repeating: -50, count: V); r0[1] = 0
        var r1 = r0; r1[1] = -50; r1[2] = 0
        var r2 = [Float](repeating: -50, count: V); r2[5] = 0
        let logits = MLXArray(r0 + r1 + r2 + r2).reshaped([4, V])
        let c = SamplingConfig(temperature: 1, topK: 0, topP: 1, seed: 1)
        for first in 0 ..< 20 {
            let (n, t) = SpecSampling.verify(logits: logits, drafts: [1, 2, 3], config: c, firstIndex: first)
            #expect(n.item(Int32.self) == 2)
            #expect(t.item(Int32.self) == 5)
        }
        // zero drafts == plain sample
        let (n0, t0) = SpecSampling.verify(logits: logits[2 ..< 3], drafts: [], config: c, firstIndex: 0)
        #expect(n0.item(Int32.self) == 0 && t0.item(Int32.self) == 5)
    }
}
