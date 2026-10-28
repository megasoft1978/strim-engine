import Foundation

public struct EvolveConfig: Codable, Equatable, Sendable {
    public var trainReps = 1
    public var valReps = 2
    /// Adopt only if the paired val gain (mean fitness difference x 100) is at least this many percentage points.
    public var minGainPP = 5.0
    /// A challenger whose false-done rate exceeds this must still not exceed the incumbent's.
    public var maxFalseDoneRate = 0.05
    /// Fraction of the expected paired rows that must exist (infra failures leave holes).
    public var minCoverage = 0.8
    public var maxRounds = 2
    /// Search coordinates, in ascent order. Default: all of them.
    public var coordinates: [Coordinate] = Coordinate.consumed
    /// Search splits only (train, val): keep the first N tasks of each class in sorted-id order. nil = all. The test split is never limited.
    public var maxTasksPerClass: Int? = nil
    public var seed: UInt64 = 20261027
    public init() {}
}

public struct Score: Equatable, Sendable {
    public var fingerprint: String
    public var n: Int
    public var fitness: Double
    public var passRate: Double
    public var falseDoneRate: Double
    public var tokens: Double
    public var wallS: Double
}

public struct Pair: Equatable, Sendable {
    public var taskId: String
    public var rep: Int
    public var a: FitnessRow
    public var b: FitnessRow
}

/// Everything here is a pure function of a results table (the ledger rows).
public enum Selection {
    static let eps = 1e-9

    /// Usable rows: search phase (unless `phase` says otherwise), no infra errors; the last row per key wins.
    public static func usable(_ rows: [FitnessRow], phase: Phase = .search) -> [FitnessRow.Key: FitnessRow] {
        var out: [FitnessRow.Key: FitnessRow] = [:]
        for r in rows where r.phase == phase {
            if r.infraError { continue } // infra failures are holes: ignored here, rerun on resume
            out[r.key] = r
        }
        return out
    }

    public static func score(_ fp: String, split: SplitName, rows: [FitnessRow], phase: Phase = .search) -> Score? {
        let rs = usable(rows, phase: phase).values.filter { $0.candidate == fp && $0.split == split }
        guard !rs.isEmpty else { return nil }
        let n = Double(rs.count)
        return Score(fingerprint: fp, n: rs.count, fitness: rs.map(\.fitness).reduce(0, +) / n,
                     passRate: Double(rs.filter(\.pass).count) / n, falseDoneRate: Double(rs.filter(\.falseDone).count) / n,
                     tokens: Double(rs.map(\.localTokens).reduce(0, +)) / n, wallS: rs.map(\.wallS).reduce(0, +) / n)
    }

    /// Pairs (same task and rep) present for both candidates.
    public static func pairs(_ a: String, _ b: String, split: SplitName, rows: [FitnessRow], phase: Phase = .search,
                             taskIds: [String]? = nil) -> [Pair] {
        let u = usable(rows, phase: phase)
        var out: [Pair] = []
        let ids = taskIds.map(Set.init)
        for (k, ra) in u where k.candidate == a && k.split == split && (ids?.contains(k.taskId) ?? true) {
            let kb = FitnessRow.Key(candidate: b, split: split, phase: phase, taskId: k.taskId, rep: k.rep)
            if let rb = u[kb] { out.append(Pair(taskId: k.taskId, rep: k.rep, a: ra, b: rb)) }
        }
        return out.sorted { ($0.taskId, $0.rep) < ($1.taskId, $1.rep) }
    }

    // MARK: train

    public struct Challenge: Equatable, Sendable {
        public var fingerprint: String
        public var pairs: Int
        public var coverage: Double
        public var gainPP: Double
        public var tokenDelta: Double
        public var wallDelta: Double
    }

    public struct TrainDecision: Equatable, Sendable {
        public var winner: String?
        public var challenges: [Challenge]
    }

    static func challenge(incumbent: String, challenger: String, split: SplitName, rows: [FitnessRow], taskIds: [String], reps: Int) -> Challenge {
        let ps = pairs(challenger, incumbent, split: split, rows: rows, taskIds: taskIds)
        let expected = max(1, taskIds.count * reps)
        let n = Double(max(1, ps.count))
        return Challenge(fingerprint: challenger, pairs: ps.count, coverage: Double(ps.count) / Double(expected),
                         gainPP: 100 * ps.map { $0.a.fitness - $0.b.fitness }.reduce(0, +) / n,
                         tokenDelta: Double(ps.map { $0.a.localTokens - $0.b.localTokens }.reduce(0, +)) / n,
                         wallDelta: ps.map { $0.a.wallS - $0.b.wallS }.reduce(0, +) / n)
    }

    /// Picks the challenger with the best paired train gain over the incumbent. A challenger needs a strictly positive
    /// gain and enough coverage; ties on gain go to fewer local tokens, then less wall time, then the smaller fingerprint.
    public static func trainWinner(incumbent: String, challengers: [String], rows: [FitnessRow], taskIds: [String],
                                   reps: Int, config: EvolveConfig) -> TrainDecision {
        let cs = challengers.map { challenge(incumbent: incumbent, challenger: $0, split: .train, rows: rows, taskIds: taskIds, reps: reps) }
        let eligible = cs.filter { $0.coverage >= config.minCoverage && $0.gainPP > eps }
        let best = eligible.sorted { a, b in
            if abs(a.gainPP - b.gainPP) > eps { return a.gainPP > b.gainPP }
            if abs(a.tokenDelta - b.tokenDelta) > eps { return a.tokenDelta < b.tokenDelta }
            if abs(a.wallDelta - b.wallDelta) > eps { return a.wallDelta < b.wallDelta }
            return a.fingerprint < b.fingerprint
        }.first
        return TrainDecision(winner: best?.fingerprint, challenges: cs)
    }

    // MARK: val

    public enum ConfirmReason: String, Codable, Sendable {
        case adopted, gainBelowThreshold = "gain_below_threshold", repRegression = "rep_regression"
        case falseDoneTooHigh = "false_done_too_high", insufficientData = "insufficient_data"
    }

    public struct ConfirmDecision: Equatable, Sendable {
        public var adopt: Bool
        public var reason: ConfirmReason
        public var gainPP: Double
        public var perRepGainPP: [Int: Double]
        public var pairs: Int
        public var coverage: Double
        public var challengerFalseDoneRate: Double
        public var incumbentFalseDoneRate: Double
    }

    /// Paired comparison on val over `valReps` reps. Adopt iff: enough paired rows, mean gain >= minGainPP, no rep with a
    /// negative gain (noise guard), and the challenger's false-done rate is within the cap or no worse than the incumbent's.
    public static func confirm(incumbent: String, challenger: String, rows: [FitnessRow], valIds: [String], config: EvolveConfig) -> ConfirmDecision {
        let ps = pairs(challenger, incumbent, split: .val, rows: rows, taskIds: valIds)
        let expected = max(1, valIds.count * config.valReps)
        let cov = Double(ps.count) / Double(expected)
        func rate(_ f: (Pair) -> FitnessRow) -> Double { ps.isEmpty ? 0 : Double(ps.filter { f($0).falseDone }.count) / Double(ps.count) }
        let cfd = rate(\.a), ifd = rate(\.b)
        guard !ps.isEmpty, cov >= config.minCoverage else {
            return ConfirmDecision(adopt: false, reason: .insufficientData, gainPP: 0, perRepGainPP: [:], pairs: ps.count, coverage: cov,
                                   challengerFalseDoneRate: cfd, incumbentFalseDoneRate: ifd)
        }
        let gain = 100 * ps.map { $0.a.fitness - $0.b.fitness }.reduce(0, +) / Double(ps.count)
        var perRep: [Int: Double] = [:]
        for rep in Set(ps.map(\.rep)).sorted() {
            let r = ps.filter { $0.rep == rep }
            perRep[rep] = 100 * r.map { $0.a.fitness - $0.b.fitness }.reduce(0, +) / Double(r.count)
        }
        var reason = ConfirmReason.adopted
        if gain + eps < config.minGainPP { reason = .gainBelowThreshold }
        else if perRep.values.contains(where: { $0 < -eps }) { reason = .repRegression }
        else if cfd > config.maxFalseDoneRate + eps && cfd > ifd + eps { reason = .falseDoneTooHigh }
        return ConfirmDecision(adopt: reason == .adopted, reason: reason, gainPP: gain, perRepGainPP: perRep, pairs: ps.count, coverage: cov,
                               challengerFalseDoneRate: cfd, incumbentFalseDoneRate: ifd)
    }

    // MARK: release (test split, only after --release-eval)

    public struct ReleaseVerdict: Equatable, Sendable {
        public var pairs: Int
        public var gainPP: Double
        /// True when the chosen pack scores below the baseline on test.
        public var regressed: Bool
    }

    public static func releaseVerdict(chosen: String, baseline: String, rows: [FitnessRow]) -> ReleaseVerdict? {
        let ps = pairs(chosen, baseline, split: .test, rows: rows, phase: .release)
        guard !ps.isEmpty else { return nil }
        let g = 100 * ps.map { $0.a.fitness - $0.b.fitness }.reduce(0, +) / Double(ps.count)
        return ReleaseVerdict(pairs: ps.count, gainPP: g, regressed: g < -eps)
    }
}
