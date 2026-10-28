import CryptoKit
import Foundation
import Testing
@testable import StrimEvolve

@Suite struct EvaluatorTests {
    let tasks = syntheticTasks()
    var classes: [String: String] { Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.taskClass) }) }

    @Test func fitnessRowFollowsSpec() {
        let req = TaskRunRequest(candidate: .baseline, fingerprint: "f", taskId: "tf-01", taskClass: "test-fix", split: .train, rep: 1, seed: 7)
        let pass = RowBuilder.row(for: req, result: TaskRunResult(pass: true, claimedDone: true, localTokens: 9, wallS: 2), round: 1, coordinate: "c", phase: .search, dryRun: false)
        #expect(pass.fitness == 1 && !pass.falseDone && pass.seed == 7 && pass.decoding == "greedy" && pass.candidate == "f")
        let fd = RowBuilder.row(for: req, result: TaskRunResult(pass: false, claimedDone: true), round: 1, coordinate: "c", phase: .search, dryRun: false)
        #expect(fd.fitness == -2 && fd.falseDone)
        let quiet = RowBuilder.row(for: req, result: TaskRunResult(pass: false, claimedDone: false), round: 1, coordinate: "c", phase: .search, dryRun: false)
        #expect(quiet.fitness == 0 && !quiet.falseDone)
        let tampered = RowBuilder.row(for: req, result: TaskRunResult(pass: true, claimedDone: true, testsTampered: true), round: 1, coordinate: "c", phase: .search, dryRun: false)
        #expect(!tampered.pass && tampered.falseDone && tampered.fitness == -2)
        var warm = req; warm.candidate.temperature = .warm
        #expect(RowBuilder.row(for: warm, result: TaskRunResult(pass: true, claimedDone: true), round: 1, coordinate: "c", phase: .search, dryRun: false).decoding == "sampled")
    }

    @Test func ledgerRoundTripAndTornTail() throws {
        let url = tempDir("ledger").appendingPathComponent("l.jsonl")
        let l = FitnessLedger(url: url)
        try l.append(mkRow("a", .train, "t1", pass: true))
        let h = try FileHandle(forWritingTo: url); h.seekToEndOfFile(); h.write(Data("{\"candidate\":\"torn".utf8)); try h.close()
        try l.append(mkRow("a", .val, "t2", pass: false, falseDone: true))
        let rows = l.read()
        #expect(rows.count == 2 && rows[1].fitness == -2 && rows[0].candidate == "a")
        #expect((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int == 0o600)
    }

    @Test func endToEndOnFakeDataWithResume() async throws {
        let dir = tempDir("e2e")
        let split = CorpusSplit.make(tasks)
        var cfg = EvolveConfig(); cfg.coordinates = [.systemPrompt, .playbookTestFix]
        let ledger = FitnessLedger(url: dir.appendingPathComponent("ledger.dry-run.jsonl"))
        let counter = Counter()
        let runner = FakeTaskRunner { r in await_free(counter); return FakeTaskRunner.standard.runSync(r) }
        // first call: stop after 40 runs via stopRequested
        let stopAt = 40
        var ev = Evaluator(runner: runner, ledger: ledger, split: split, classes: classes, config: cfg, dryRun: true,
                           stopRequested: { counter.value >= stopAt })
        let s1 = try await ev.run()
        #expect(s1.interrupted && s1.executed == stopAt && !s1.finished)
        ev = Evaluator(runner: runner, ledger: ledger, split: split, classes: classes, config: cfg, dryRun: true)
        let s2 = try await ev.run()
        #expect(s2.finished && !s2.interrupted)
        let rows = ledger.read()
        #expect(Set(rows.map(\.key)).count == rows.count) // no run repeated
        #expect(rows.allSatisfy { $0.dryRun && $0.split != .test && $0.seed != 0 && !$0.candidate.isEmpty })
        // a fresh single pass gives the same decisions
        let fresh = FitnessLedger(url: dir.appendingPathComponent("fresh.jsonl"))
        _ = try await Evaluator(runner: FakeTaskRunner.standard, ledger: fresh, split: split, classes: classes, config: cfg, dryRun: true).run()
        let a = SearchPlanner.replay(rows: ledger.read(), split: split, config: cfg), b = SearchPlanner.replay(rows: fresh.read(), split: split, config: cfg)
        #expect(a.chosenFingerprint == b.chosenFingerprint && a.steps == b.steps)
    }

    @Test func budgetDeadlineStopsAndInfraStops() async throws {
        let dir = tempDir("budget")
        let split = CorpusSplit.make(tasks)
        var cfg = EvolveConfig(); cfg.coordinates = [.systemPrompt]
        let ledger = FitnessLedger(url: dir.appendingPathComponent("l.jsonl"))
        let past = Evaluator(runner: FakeTaskRunner.standard, ledger: ledger, split: split, classes: classes, config: cfg, deadline: Date().addingTimeInterval(-1), dryRun: true)
        let s = try await past.run()
        #expect(s.budgetStopped && s.executed == 0)
        let broken = FakeTaskRunner { _ in TaskRunResult(pass: false, claimedDone: false, infraError: true, error: "server down") }
        let s2 = try await Evaluator(runner: broken, ledger: ledger, split: split, classes: classes, config: cfg, dryRun: true).run()
        #expect(s2.infraStopped && s2.executed == 1)
        #expect(ledger.read().first?.infraError == true)
        // the hole is retried on the next run
        let s3 = try await Evaluator(runner: FakeTaskRunner.standard, ledger: ledger, split: split, classes: classes, config: cfg,
                                     deadline: Date().addingTimeInterval(-1), dryRun: true).run()
        #expect(s3.budgetStopped)
    }

    @Test func releaseEvalOnlyOnTestAndRecordsReleasePhase() async throws {
        let dir = tempDir("release")
        let split = CorpusSplit.make(tasks)
        var cfg = EvolveConfig(); cfg.coordinates = [.systemPrompt]
        let ledger = FitnessLedger(url: dir.appendingPathComponent("l.jsonl"))
        let ev = Evaluator(runner: FakeTaskRunner.standard, ledger: ledger, split: split, classes: classes, config: cfg, dryRun: true)
        var chosen = PackCandidate.baseline; chosen.systemPrompt = .verifyFirst
        let s = try await ev.releaseEval(chosen: chosen, reps: 2)
        #expect(s.finished && s.executed == 2 * 2 * split.test.count)
        let rows = ledger.read()
        #expect(rows.allSatisfy { $0.phase == .release && $0.split == .test })
        // release rows do not count as search rows, so adoption's "test untouched" check stays true
        let st = SearchPlanner.replay(rows: rows, split: split, config: cfg)
        #expect(!rows.contains { $0.split == .test && $0.phase == .search })
        #expect(!st.finished)
        // rerun does nothing
        #expect(try await ev.releaseEval(chosen: chosen, reps: 2).executed == 0)
    }

    @Test func adoptionGate() {
        let split = CorpusSplit.make(tasks)
        var cfg = EvolveConfig(); cfg.coordinates = [.systemPrompt]
        let rows = mkRows(PackLibrary.fingerprint(.baseline), .train, ids: split.train, reps: 1, passIds: [])
        let st = SearchPlanner.replay(rows: rows, split: split, config: cfg)
        let d = Adoption.check(rows: rows, state: st, allowDryRun: false)
        #expect(!d.ok && d.reasons.contains { $0.contains("not finished") })
        var touched = rows; touched.append(mkRow("x", .test, "tf-01", pass: true))
        #expect(Adoption.check(rows: touched, state: st, allowDryRun: false).reasons.contains { $0.contains("test split was touched") })
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}
func await_free(_ c: Counter) { c.bump() }
