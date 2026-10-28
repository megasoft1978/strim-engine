import Foundation
import Testing
@testable import StrimEvolve

@Suite struct SearchTests {
    let split = CorpusSplit.make(syntheticTasks())

    // MARK: split

    @Test func splitIs60_20_20StratifiedAndDeterministic() {
        let a = CorpusSplit.make(syntheticTasks()), b = CorpusSplit.make(syntheticTasks().reversed())
        #expect(a == b)
        #expect(a.train.count == 18 && a.val.count == 6 && a.test.count == 6)
        #expect(Set(a.train + a.val + a.test).count == 30)
        for p in ["tf", "qa", "me"] {
            #expect(a.train.filter { $0.hasPrefix(p) }.count == 6)
            #expect(a.val.filter { $0.hasPrefix(p) }.count == 2)
            #expect(a.test.filter { $0.hasPrefix(p) }.count == 2)
        }
        #expect(a.name(of: a.test[0]) == .test)
    }

    @Test func realCorpusSplitMatches18_6_6() {
        let root = repoRoot().appendingPathComponent("bench/agenttasks/tasks")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path), names.count == 30 else { return }
        let tasks = names.sorted().map { (id: $0, taskClass: String($0.prefix(2))) }
        let s = CorpusSplit.make(tasks)
        #expect(s.train.count == 18 && s.val.count == 6 && s.test.count == 6)
    }

    @Test func frozenSplitIsPersistedAndMissingTasksAreRefused() throws {
        let dir = tempDir("split")
        let first = try CorpusSplit.frozen(dir: dir, tasks: syntheticTasks())
        let more = syntheticTasks() + [(id: "tf-11", taskClass: "test-fix")]
        let again = try CorpusSplit.frozen(dir: dir, tasks: more)
        #expect(again == first) // a new task does not move any assigned task
        #expect(throws: EvolveError.self) { try CorpusSplit.frozen(dir: dir, tasks: Array(syntheticTasks().dropFirst())) }
    }

    @Test func limitedKeepsFirstNPerClassInSortedIdOrderAndNeverTouchesTest() {
        let classOf = Dictionary(uniqueKeysWithValues: syntheticTasks().map { ($0.id, $0.taskClass) })
        let one = split.limited(perClass: 1, classOf: classOf)
        #expect(one.train.count == 3 && one.val.count == 3)
        #expect(one.test == split.test)
        for cls in ["test-fix", "repo-qa", "mechanical-edit"] {
            let t = one.train.filter { classOf[$0] == cls }
            #expect(t == [split.train.filter { classOf[$0] == cls }.sorted()[0]]) // lexicographically first train id of the class
        }
        // deterministic: same answer for any input order, and a cut is a prefix of the next larger cut
        let again = CorpusSplit(train: Array(split.train.reversed()), val: Array(split.val.reversed()), test: split.test).limited(perClass: 1, classOf: classOf)
        #expect(again == one)
        let two = split.limited(perClass: 2, classOf: classOf)
        #expect(Set(one.train).isSubset(of: Set(two.train)) && two.train.count == 6 && two.val.count == 6)
        #expect(split.limited(perClass: 99, classOf: classOf) == split)
        #expect(split.limited(perClass: 0, classOf: classOf).train.isEmpty)
    }

    @Test func limitedSplitIsNotPersisted() throws {
        let dir = tempDir("limit")
        let full = try CorpusSplit.frozen(dir: dir, tasks: syntheticTasks())
        let classOf = Dictionary(uniqueKeysWithValues: syntheticTasks().map { ($0.id, $0.taskClass) })
        _ = full.limited(perClass: 1, classOf: classOf)
        #expect(CorpusSplit.read(from: dir) == full)
    }

    @Test func maxTasksConfigDefaultsToAllAndOldConfigsStillDecode() throws {
        #expect(EvolveConfig().maxTasksPerClass == nil)
        // a config.json written before the field existed decodes with no limit
        var c = EvolveConfig(); c.maxTasksPerClass = 2
        let withField = try JSONEncoder().encode(c)
        var obj = try JSONSerialization.jsonObject(with: withField) as! [String: Any]
        obj.removeValue(forKey: "maxTasksPerClass")
        let old = try JSONSerialization.data(withJSONObject: obj)
        let decodedOld = try JSONDecoder().decode(EvolveConfig.self, from: old)
        #expect(decodedOld.maxTasksPerClass == nil)
        let back = try JSONDecoder().decode(EvolveConfig.self, from: withField)
        #expect(back == c)
    }

    @Test func testSplitNeedsReleaseEval() throws {
        #expect(throws: EvolveError.self) { try SplitGuard.check(.test, releaseEval: false) }
        try SplitGuard.check(.test, releaseEval: true)
        try SplitGuard.check(.train, releaseEval: false)
        try SplitGuard.check(.val, releaseEval: false)
    }

    // MARK: planner on recorded tables

    func config(_ coords: [Coordinate]) -> EvolveConfig { var c = EvolveConfig(); c.coordinates = coords; return c }

    /// Fills every pending run with `outcome` until the planner finishes; returns the final state and all rows.
    func drive(_ cfg: EvolveConfig, rows start: [FitnessRow] = [], outcome: (PlannedRun) -> (pass: Bool, falseDone: Bool)) -> (ReplayState, [FitnessRow]) {
        var rows = start
        for _ in 0..<5000 {
            let st = SearchPlanner.replay(rows: rows, split: split, config: cfg)
            guard let n = st.pending.first else { return (st, rows) }
            let o = outcome(n)
            var r = FitnessRow(candidate: n.fingerprint, split: n.split, taskId: n.taskId, taskClass: "x", rep: n.rep, pass: o.pass, falseDone: o.falseDone)
            r.localTokens = 1000; r.wallS = 10
            rows.append(r)
        }
        Issue.record("planner did not converge")
        return (SearchPlanner.replay(rows: rows, split: split, config: cfg), rows)
    }

    @Test func plannerNeverSchedulesTestSplit() {
        let (st, rows) = drive(config(Coordinate.consumed)) { n in (n.candidate.systemPrompt == .verifyFirst ? Int(CorpusSplit.key(n.taskId) % 10) < 8 : Int(CorpusSplit.key(n.taskId) % 10) < 4, false) }
        #expect(st.finished)
        #expect(!rows.contains { $0.split == .test })
        #expect(Adoption.check(rows: rows, state: st, allowDryRun: false).ok)
    }

    @Test func plannerAdoptsRealImprovementAndKeepsBaselineOtherwise() {
        // verify_first passes everything, anything else passes a fixed 40%
        let (st, _) = drive(config([.systemPrompt, .toolGuidance])) { n in
            n.candidate.systemPrompt == .verifyFirst ? (true, false) : (Int(CorpusSplit.key(n.taskId) % 10) < 4, false)
        }
        #expect(st.incumbent.systemPrompt == .verifyFirst)
        #expect(st.incumbent.toolGuidance == .baseline)
        #expect(st.steps.first?.adopted != nil)
        #expect(!st.killed)
    }

    @Test func plannerKillsWhenNothingBeatsBaseline() {
        // every candidate performs identically: no train winner, converged with no adoption -> kill rule
        let (st, rows) = drive(config([.systemPrompt, .toolGuidance, .playbookTestFix])) { n in (Int(CorpusSplit.key(n.taskId) % 10) < 5, false) }
        #expect(st.finished && st.killed && st.stopReason == .killRule)
        #expect(st.chosenFingerprint == PackLibrary.fingerprint(.baseline))
        #expect(!Adoption.check(rows: rows, state: st, allowDryRun: false).ok)
        #expect(rows.allSatisfy { $0.split == .train }) // no val spent when train shows no gain
    }

    @Test func plannerRejectsTrainOnlyWinnerThatFailsOnVal() {
        // lean wins on train (overfit) but regresses on val
        let (st, _) = drive(config([.systemPrompt])) { n in
            let base = Int(CorpusSplit.key(n.taskId) % 10) < 4
            if n.candidate.systemPrompt == .lean { return n.split == .train ? (true, false) : (false, false) }
            return (base, false)
        }
        #expect(st.incumbent == .baseline)
        #expect(st.killed)
        if case .confirmed(_, let d)? = st.steps.first?.outcome { #expect(!d.adopt && d.gainPP < 0) } else { Issue.record("expected a val confirmation") }
    }

    @Test func plannerIsResumable() {
        let cfg = config([.systemPrompt])
        let outcome: (PlannedRun) -> (pass: Bool, falseDone: Bool) = { n in (n.candidate.systemPrompt == .verifyFirst || Int(CorpusSplit.key(n.taskId) % 10) < 4, false) }
        let (full, rows) = drive(cfg, outcome: outcome)
        // crash after 25 rows, then continue from the ledger
        let partial = Array(rows.prefix(25))
        let mid = SearchPlanner.replay(rows: partial, split: split, config: cfg)
        #expect(!mid.finished && !mid.pending.isEmpty)
        #expect(!mid.pending.contains { r in partial.contains { $0.candidate == r.fingerprint && $0.taskId == r.taskId && $0.rep == r.rep && $0.split == r.split } })
        let (resumed, rows2) = drive(cfg, rows: partial, outcome: outcome)
        #expect(resumed.chosenFingerprint == full.chosenFingerprint)
        #expect(rows2.count == rows.count) // nothing rerun, nothing skipped
    }

    @Test func plannerRetriesInfraHoles() {
        let cfg = config([.systemPrompt])
        var rows = [mkRow(PackLibrary.fingerprint(.baseline), .train, split.train[0], pass: false, infra: true)]
        let st = SearchPlanner.replay(rows: rows, split: split, config: cfg)
        #expect(st.pending.contains { $0.fingerprint == PackLibrary.fingerprint(.baseline) && $0.taskId == split.train[0] })
        rows.append(mkRow(PackLibrary.fingerprint(.baseline), .train, split.train[0], pass: true))
        let st2 = SearchPlanner.replay(rows: rows, split: split, config: cfg)
        #expect(!st2.pending.contains { $0.fingerprint == PackLibrary.fingerprint(.baseline) && $0.taskId == split.train[0] })
    }

    @Test func plannerIgnoresDryRunSeparation() {
        // rows of other candidates (stale ledger from an older variant text) are simply unused
        let stale = mkRows("0000000000000000", .train, ids: split.train, reps: 1, passIds: Set(split.train))
        let st = SearchPlanner.replay(rows: stale, split: split, config: config([.systemPrompt]))
        #expect(!st.finished && st.pending.count == 3 * split.train.count)
    }

    @Test func secondRoundBuildsOnFirst() {
        // verify_first helps on its own; stepwise test-fix helps only on top of it
        let cfg = config([.systemPrompt, .playbookTestFix])
        let (st, _) = drive(cfg) { n in
            var p = 0.3
            if n.candidate.systemPrompt == .verifyFirst { p += 0.3 }
            if n.candidate.playbookTestFix == .stepwise { p += 0.3 }
            return (Double(CorpusSplit.key(n.taskId + "x") % 100) / 100 < p, false)
        }
        #expect(st.incumbent.systemPrompt == .verifyFirst)
        #expect(st.rounds.first?.adoptions ?? 0 >= 1)
    }

    @Test func killRuleRequiresTwoRoundsOrConvergence() {
        let c = EvolveConfig()
        let r1 = [RoundSummary(round: 1, bestValGainPP: 0, adoptions: 0)]
        #expect(!KillRule.shouldStop(rounds: r1, config: c, converged: false))
        #expect(KillRule.shouldStop(rounds: r1, config: c, converged: true))
        #expect(KillRule.shouldStop(rounds: r1 + [RoundSummary(round: 2, bestValGainPP: 3, adoptions: 0)], config: c, converged: false))
        #expect(!KillRule.shouldStop(rounds: r1 + [RoundSummary(round: 2, bestValGainPP: 9, adoptions: 1)], config: c, converged: false))
    }
}
