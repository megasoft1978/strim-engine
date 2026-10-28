import Foundation
import StrimAgentBench

public struct PlannedRun: Equatable, Sendable {
    public var candidate: PackCandidate
    public var fingerprint: String
    public var split: SplitName
    public var taskId: String
    public var rep: Int
    public var round: Int
    public var coordinate: String
}

public struct SearchStep: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case noProposal([Selection.Challenge])
        case confirmed(winner: String, Selection.ConfirmDecision)
    }
    public var round: Int
    public var coordinate: Coordinate
    public var incumbentBefore: String
    public var outcome: Outcome
    public var adopted: String? {
        if case .confirmed(let w, let d) = outcome, d.adopt { return w }
        return nil
    }
}

public struct RoundSummary: Equatable, Sendable {
    public var round: Int
    /// Largest val gain among challengers confirmed this round (0 when none reached val).
    public var bestValGainPP: Double
    public var adoptions: Int
}

public enum StopReason: String, Sendable { case converged, maxRounds = "max_rounds", killRule = "kill_rule" }

public struct ReplayState: Sendable {
    public var incumbent: PackCandidate
    public var steps: [SearchStep]
    public var rounds: [RoundSummary]
    /// Runs still missing for the current step, in execution order. Empty when finished.
    public var pending: [PlannedRun]
    public var finished: Bool
    public var stopReason: StopReason?
    public var candidates: [String: PackCandidate]
    public var chosenFingerprint: String { PackLibrary.fingerprint(incumbent) }
    /// Kill rule: nothing was adopted over the baseline (every round's best val gain stayed below the threshold).
    public var killed: Bool { stopReason == .killRule }
}

public enum KillRule {
    /// Stop (and do not continue to v2) when 2 rounds passed without a val-confirmed gain of at least `minGainPP`.
    public static func shouldStop(rounds: [RoundSummary], config: EvolveConfig, converged: Bool) -> Bool {
        let none = rounds.allSatisfy { $0.adoptions == 0 || $0.bestValGainPP < config.minGainPP }
        return none && (rounds.count >= 2 || converged)
    }
}

/// The whole search as a pure function of the results table: coordinate ascent over the hand-written candidate list.
/// Train screens every option of one coordinate (1 rep); the best one is confirmed on val (2 reps, paired) and adopted
/// only if `Selection.confirm` says so. The test split is never planned.
public enum SearchPlanner {
    public static func replay(rows: [FitnessRow], split: CorpusSplit, config: EvolveConfig, baseline: PackCandidate = .baseline) -> ReplayState {
        var incumbent = baseline
        var steps: [SearchStep] = []
        var rounds: [RoundSummary] = []
        var known: [String: PackCandidate] = [PackLibrary.fingerprint(baseline): baseline]
        let usable = Selection.usable(rows)

        func missing(_ cands: [PackCandidate], _ sp: SplitName, reps: Int, round: Int, coord: Coordinate) -> [PlannedRun] {
            var out: [PlannedRun] = []
            for c in cands {
                let fp = PackLibrary.fingerprint(c)
                for t in split.ids(sp) {
                    for rep in 1...max(1, reps) {
                        let k = FitnessRow.Key(candidate: fp, split: sp, phase: .search, taskId: t, rep: rep)
                        if usable[k] == nil {
                            out.append(PlannedRun(candidate: c, fingerprint: fp, split: sp, taskId: t, rep: rep, round: round, coordinate: coord.rawValue))
                        }
                    }
                }
            }
            return out
        }

        func state(pending: [PlannedRun], finished: Bool, stop: StopReason?) -> ReplayState {
            ReplayState(incumbent: incumbent, steps: steps, rounds: rounds, pending: pending, finished: finished, stopReason: stop, candidates: known)
        }

        for round in 1...max(1, config.maxRounds) {
            let startFP = PackLibrary.fingerprint(incumbent)
            var best = 0.0, adoptions = 0
            for coord in config.coordinates {
                let incFP = PackLibrary.fingerprint(incumbent)
                var seen: Set<String> = [incFP]
                var options: [PackCandidate] = []
                for v in coord.variants(of: incumbent) {
                    let fp = PackLibrary.fingerprint(v)
                    if seen.insert(fp).inserted { options.append(v); known[fp] = v }
                }
                if options.isEmpty { continue }
                let needTrain = missing([incumbent] + options, .train, reps: config.trainReps, round: round, coord: coord)
                if !needTrain.isEmpty { return state(pending: needTrain, finished: false, stop: nil) }
                let td = Selection.trainWinner(incumbent: incFP, challengers: options.map { PackLibrary.fingerprint($0) }, rows: rows,
                                               taskIds: split.train, reps: config.trainReps, config: config)
                guard let w = td.winner, let wc = known[w] else {
                    steps.append(SearchStep(round: round, coordinate: coord, incumbentBefore: incFP, outcome: .noProposal(td.challenges)))
                    continue
                }
                let needVal = missing([incumbent, wc], .val, reps: config.valReps, round: round, coord: coord)
                if !needVal.isEmpty { return state(pending: needVal, finished: false, stop: nil) }
                let cd = Selection.confirm(incumbent: incFP, challenger: w, rows: rows, valIds: split.val, config: config)
                steps.append(SearchStep(round: round, coordinate: coord, incumbentBefore: incFP, outcome: .confirmed(winner: w, cd)))
                best = max(best, cd.gainPP)
                if cd.adopt { incumbent = wc; adoptions += 1 }
            }
            rounds.append(RoundSummary(round: round, bestValGainPP: best, adoptions: adoptions))
            let converged = PackLibrary.fingerprint(incumbent) == startFP
            if KillRule.shouldStop(rounds: rounds, config: config, converged: converged) { return state(pending: [], finished: true, stop: .killRule) }
            if converged { return state(pending: [], finished: true, stop: .converged) }
        }
        return state(pending: [], finished: true, stop: .maxRounds)
    }
}

// MARK: - Evaluator / driver

public struct EvolveRunSummary: Sendable, Equatable {
    public var executed = 0
    public var infraStopped = false
    public var budgetStopped = false
    public var interrupted = false
    public var finished = false
}

/// Executes whatever the planner says is missing, one run at a time, appending each row before the next run.
/// Resume = run again: finished work is in the ledger and is not repeated.
public final class Evaluator {
    let runner: TaskRunner
    let ledger: FitnessLedger
    let split: CorpusSplit
    let config: EvolveConfig
    let classes: [String: String]
    let deadline: Date?
    let dryRun: Bool
    let log: (String) -> Void
    let stopRequested: () -> Bool

    public init(runner: TaskRunner, ledger: FitnessLedger, split: CorpusSplit, classes: [String: String], config: EvolveConfig,
                deadline: Date? = nil, dryRun: Bool = false, stopRequested: @escaping () -> Bool = { false },
                log: @escaping (String) -> Void = { _ in }) {
        self.runner = runner; self.ledger = ledger; self.split = split; self.classes = classes; self.config = config
        self.deadline = deadline; self.dryRun = dryRun; self.log = log; self.stopRequested = stopRequested
    }

    public func run() async throws -> EvolveRunSummary {
        var sum = EvolveRunSummary()
        while true {
            let state = SearchPlanner.replay(rows: ledger.read(), split: split, config: config)
            if state.finished { sum.finished = true; return sum }
            guard let next = state.pending.first else { sum.finished = true; return sum }
            if stopRequested() { sum.interrupted = true; return sum }
            if let d = deadline, Date() >= d { sum.budgetStopped = true; return sum }
            try SplitGuard.check(next.split, releaseEval: false) // search never plans test; belt and braces
            let row = await execute(next, phase: .search)
            try ledger.append(row)
            sum.executed += 1
            log("[r\(next.round) \(next.coordinate)] \(next.candidate.label) \(next.split.rawValue) \(next.taskId)#\(next.rep): "
                + (row.infraError ? "INFRA" : row.pass ? "PASS" : row.falseDone ? "FAIL false-done" : "FAIL"))
            if row.infraError { sum.infraStopped = true; return sum }
        }
    }

    /// Release evaluation on the test split: baseline and `chosen`, `reps` reps each. Caller has passed `SplitGuard`.
    public func releaseEval(chosen: PackCandidate, baseline: PackCandidate = .baseline, reps: Int) async throws -> EvolveRunSummary {
        try SplitGuard.check(.test, releaseEval: true)
        var sum = EvolveRunSummary()
        let done = Selection.usable(ledger.read(), phase: .release)
        for c in [baseline, chosen] {
            let fp = PackLibrary.fingerprint(c)
            for t in split.test {
                for rep in 1...max(1, reps) {
                    let k = FitnessRow.Key(candidate: fp, split: .test, phase: .release, taskId: t, rep: rep)
                    if done[k] != nil { continue }
                    if stopRequested() { sum.interrupted = true; return sum }
                    if let d = deadline, Date() >= d { sum.budgetStopped = true; return sum }
                    let run = PlannedRun(candidate: c, fingerprint: fp, split: .test, taskId: t, rep: rep, round: 0, coordinate: "release")
                    let row = await execute(run, phase: .release)
                    try ledger.append(row)
                    sum.executed += 1
                    if row.infraError { sum.infraStopped = true; return sum }
                }
            }
        }
        sum.finished = true
        return sum
    }

    func execute(_ p: PlannedRun, phase: Phase) async -> FitnessRow {
        let seed = config.seed ^ CorpusSplit.key("\(p.taskId)#\(p.rep)")
        let req = TaskRunRequest(candidate: p.candidate, fingerprint: p.fingerprint, taskId: p.taskId, taskClass: classes[p.taskId] ?? "",
                                 split: p.split, rep: p.rep, seed: seed)
        let res = await runner.run(req)
        return RowBuilder.row(for: req, result: res, round: p.round, coordinate: p.coordinate, phase: phase, dryRun: dryRun)
    }
}

// MARK: - Adoption gate

public struct AdoptDecision: Equatable, Sendable {
    public var ok: Bool
    public var reasons: [String]
    public var fingerprint: String
}

public enum Adoption {
    /// A pack is adoptable when the search finished with a pack other than baseline, every step on its path was
    /// val-confirmed (guaranteed by replay), no search row touched the test split, and the rows are not dry-run
    /// (unless explicitly allowed).
    public static func check(rows: [FitnessRow], state: ReplayState, allowDryRun: Bool) -> AdoptDecision {
        var why: [String] = []
        if !state.finished { why.append("search not finished (\(state.pending.count) runs pending)") }
        if state.chosenFingerprint == PackLibrary.fingerprint(.baseline) { why.append("no candidate beat the baseline on val") }
        if state.killed { why.append("kill rule hit: no val gain >= threshold after the allowed rounds") }
        if rows.contains(where: { $0.split == .test && $0.phase == .search }) { why.append("test split was touched during search") }
        if !allowDryRun && rows.contains(where: \.dryRun) { why.append("ledger holds dry-run (fake) rows") }
        return AdoptDecision(ok: why.isEmpty, reasons: why, fingerprint: state.chosenFingerprint)
    }
}
