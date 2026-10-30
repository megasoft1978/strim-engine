import Foundation
import Testing
@testable import StrimEvolve

@Suite struct PairedEvalTests {
    var split: CorpusSplit { CorpusSplit(train: ["train-1", "train-2"], val: ["val-1"], test: ["never-test"]) }
    var comparison: PairedEvaluation {
        var a = PackCandidate.baseline; a.thinking = .allTurnsMedium
        var b = a; b.playbookTestFix = .converge; b.stallNudge = .on
        b.resultShape = .errorsFirst; b.toolGuidance = .strict
        return PairedEvaluation(candidate: b, against: a)
    }
    var config: EvolveConfig { var c = EvolveConfig(); c.trainReps = 3; c.valReps = 2; return c }

    @Test func strictInlineAndFileDecode() throws {
        let c = try PairedEvaluation.decode(#"{"thinking":"all_turns_medium","stall_nudge":"on"}"#)
        #expect(c.thinking == .allTurnsMedium && c.stallNudge == .on && c.toolGuidance == .baseline)
        let file = tempDir("paired-json").appendingPathComponent("candidate.json")
        try Canonical.json(c).write(to: file)
        #expect(try PairedEvaluation.decode(file.path) == c)
        for raw in [#"{"sandbox":"off"}"#, #"{"thinking":"unknown"}"#, #"{"stall_nudge":true}"#] {
            #expect(throws: EvolveError.self) { try PairedEvaluation.decode(raw) }
            try Data(raw.utf8).write(to: file)
            #expect(throws: EvolveError.self) { try PairedEvaluation.decode(file.path) }
        }
    }

    @Test func writesBothSidesInABBAOrderWithoutSearchOrTest() async throws {
        let ledger = FitnessLedger(url: tempDir("paired-order").appendingPathComponent("ledger.jsonl"))
        let c = comparison
        let runner = FakeTaskRunner { r in
            TaskRunResult(pass: r.candidate.toolGuidance == .strict, claimedDone: true, localTokens: 123, wallS: 4)
        }
        let ev = Evaluator(runner: runner, ledger: ledger, split: split, classes: [:], config: config, dryRun: true)
        let result = try await ev.pairedEval(c)
        #expect(result.finished && result.executed == 16)
        let rows = ledger.read()
        #expect(rows.count == 16 && Set(rows.map(\.key)).count == 16)
        #expect(rows.allSatisfy { $0.phase == .paired && $0.split != .test && $0.dryRun && $0.coordinate == "paired" })
        for (ti, task) in split.train.enumerated().map({ ($0.offset, $0.element) }) + split.val.enumerated().map({ ($0.offset, $0.element) }) {
            let rs = rows.filter { $0.taskId == task }
            let a = c.againstFingerprint, b = c.candidateFingerprint
            #expect(Array(rs.prefix(4).map(\.candidate)) == (ti.isMultiple(of: 2) ? [a, b, b, a] : [b, a, a, b]))
            #expect(Array(rs.prefix(4).map(\.rep)) == [1, 1, 2, 2])
            #expect(rs[0].seed == rs[1].seed && rs[2].seed == rs[3].seed)
            #expect(rs.first { $0.candidate == a }?.falseDone == true && rs.first { $0.candidate == b }?.pass == true)
        }
        #expect(Selection.usable(rows).isEmpty)
        #expect(Selection.score(c.candidateFingerprint, split: .train, rows: rows) == nil)
        #expect(Selection.score(c.candidateFingerprint, split: .train, rows: rows, phase: .paired)?.n == 6)
        #expect(try await ev.pairedEval(c).executed == 0)
    }

    @Test func resumeSkipsCompletedRowsAndPreservesOrder() async throws {
        let ledger = FitnessLedger(url: tempDir("paired-resume").appendingPathComponent("ledger.jsonl"))
        let count = Counter()
        let runner = FakeTaskRunner { r in count.bump(); return FakeTaskRunner.standard.runSync(r) }
        let first = Evaluator(runner: runner, ledger: ledger, split: split, classes: [:], config: config,
                              dryRun: true, stopRequested: { count.value >= 3 })
        let s1 = try await first.pairedEval(comparison)
        #expect(s1.interrupted && s1.executed == 3)
        // Search rows with the same candidate/task/rep do not fill paired holes.
        var search = ledger.read()[0]; search.phase = .search
        try ledger.append(search)
        let remaining = comparison.pending(rows: ledger.read(), split: split, config: config)
        #expect(remaining.first?.fingerprint == comparison.againstFingerprint && remaining.first?.rep == 2)
        let resumed = Evaluator(runner: runner, ledger: ledger, split: split, classes: [:], config: config, dryRun: true)
        let s2 = try await resumed.pairedEval(comparison)
        #expect(s2.finished && s2.executed == 13 && count.value == 16)
        let rows = ledger.read().filter { $0.phase == .paired }
        let expected = comparison.pending(rows: [], split: split, config: config)
        #expect(rows.map(\.candidate) == expected.map(\.fingerprint))
        #expect(rows.map(\.rep) == expected.map(\.rep))
        let a = comparison.againstFingerprint, b = comparison.candidateFingerprint
        #expect(rows.map(\.candidate) == [a, b, b, a, a, b, b, a, a, b, b, a, a, b, b, a])
        #expect(Set(rows.map(\.key)).count == 16)
    }

    @Test func budgetInfraAndIdenticalCandidates() async throws {
        let ledger = FitnessLedger(url: tempDir("paired-stop").appendingPathComponent("ledger.jsonl"))
        let expired = Evaluator(runner: FakeTaskRunner.standard, ledger: ledger, split: split, classes: [:], config: config,
                                deadline: Date().addingTimeInterval(-1))
        #expect(try await expired.pairedEval(comparison).budgetStopped)
        #expect(ledger.read().isEmpty)
        let broken = FakeTaskRunner { _ in TaskRunResult(pass: false, claimedDone: false, infraError: true, error: "server down") }
        let ev = Evaluator(runner: broken, ledger: ledger, split: split, classes: [:], config: config)
        #expect(try await ev.pairedEval(comparison).infraStopped)
        #expect(comparison.pending(rows: ledger.read(), split: split, config: config).count == 16)
        let repaired = Evaluator(runner: FakeTaskRunner.standard, ledger: ledger, split: split, classes: [:], config: config)
        #expect(try await repaired.pairedEval(comparison).executed == 16)
        #expect(throws: EvolveError.self) { try PairedEvaluation(candidate: .baseline).validate() }
    }

    @Test func reportIncludesPairedRowsAndTaskCounts() async throws {
        let c = comparison
        let ledger = FitnessLedger(url: tempDir("paired-report").appendingPathComponent("ledger.jsonl"))
        let runner = FakeTaskRunner { r in
            let a = r.candidate.toolGuidance != .strict
            let pass = r.rep == 1 || (a ? r.taskId == "train-1" : r.taskId != "train-1")
            return TaskRunResult(pass: pass, claimedDone: true, localTokens: a ? 100 : 200, wallS: a ? 10 : 20, timedOut: !pass)
        }
        _ = try await Evaluator(runner: runner, ledger: ledger, split: split, classes: [:], config: config).pairedEval(c)
        let text = c.report(rows: ledger.read(), split: split, config: config).joined(separator: "\n")
        #expect(text.contains("phase paired") && text.contains(c.againstFingerprint) && text.contains(c.candidateFingerprint))
        #expect(text.contains("train A: n 6/6 pass 66.7% mean wall 10.00s mean local tokens 100.0 false-done 2 (33.3%) timeouts 2"))
        #expect(text.contains("train train-1: pairs 3/3 both-pass 1 only-A 2 only-B 0 neither 0"))
        #expect(text.contains("train train-2: pairs 3/3 both-pass 1 only-A 0 only-B 2 neither 0"))
        #expect(text.contains("test split: untouched"))
    }

    @Test func comparisonManifestFreezesBothCandidates() throws {
        let dir = tempDir("paired-manifest")
        try comparison.freeze(in: dir)
        #expect(try PairedEvaluation.read(from: dir) == comparison)
        try comparison.freeze(in: dir)
        #expect(throws: EvolveError.self) { try PairedEvaluation(candidate: comparison.candidate).freeze(in: dir) }
    }

    @Test func legacyRowsKeepTheirBytesAndTimeoutsRoundTrip() throws {
        let old = Data(#"{"candidate":"legacy","split":"train","phase":"search","round":0,"coordinate":"","taskId":"t","taskClass":"test-fix","rep":1,"pass":false,"claimedDone":false,"falseDone":false,"testsTampered":false,"localTokens":0,"wallS":0,"fitness":0,"seed":0,"decoding":"greedy","infraError":false,"dryRun":false,"ts":""}"#.utf8)
        let decoded = try JSONDecoder().decode(FitnessRow.self, from: old)
        #expect(decoded.timedOut == nil)
        let canonicalOld = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: old), options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(Canonical.json(decoded) == canonicalOld)
        let ledger = FitnessLedger(url: tempDir("paired-legacy").appendingPathComponent("ledger.jsonl"))
        try old.write(to: ledger.url)
        #expect(ledger.read() == [decoded])
        let request = TaskRunRequest(candidate: .baseline, fingerprint: "f", taskId: "t", taskClass: "test-fix", split: .train, rep: 1, seed: 7)
        for timeout in [nil, false, true] as [Bool?] {
            let row = RowBuilder.row(for: request, result: TaskRunResult(pass: false, claimedDone: false, timedOut: timeout),
                                     round: 0, coordinate: "paired", phase: .paired, dryRun: false)
            try ledger.append(row)
            #expect(ledger.read().last?.timedOut == timeout)
            #expect(try JSONDecoder().decode(FitnessRow.self, from: Canonical.json(row)) == row)
        }
        #expect(ledger.read().count == 4)
    }

    @Test func fixedSplitReusesAssignmentAndOnlyRunsItsTrainAndVal() async throws {
        let root = tempDir("paired-fixed-split")
        let source = root.appendingPathComponent("source"), out = root.appendingPathComponent("out")
        try split.write(to: source)
        let tasks = (split.train + split.val + split.test + ["unassigned"]).map { (id: $0, taskClass: "test-fix") }
        let imported = try CorpusSplit.frozen(file: source.appendingPathComponent("split.json"), dir: out, tasks: tasks)
        #expect(imported == split && CorpusSplit.read(from: out) == split)
        #expect(try CorpusSplit.frozen(dir: out, tasks: tasks) == split)
        #expect(try CorpusSplit.frozen(file: source.appendingPathComponent("split.json"), dir: out, tasks: tasks) == split)
        let ledger = FitnessLedger(url: out.appendingPathComponent("ledger.dry-run.jsonl"))
        _ = try await Evaluator(runner: FakeTaskRunner.standard, ledger: ledger, split: imported, classes: [:], config: config, dryRun: true).pairedEval(comparison)
        #expect(Set(ledger.read().map(\.taskId)) == Set(split.train + split.val))
        #expect(ledger.read().allSatisfy { $0.split != .test && !split.test.contains($0.taskId) })
        #expect(try Data(contentsOf: source.appendingPathComponent("split.json")) == Data(contentsOf: out.appendingPathComponent("split.json")))
    }

    @Test func fixedSplitRejectsMissingOverlappingAndChangedAssignments() throws {
        let root = tempDir("paired-invalid-split")
        let source = root.appendingPathComponent("source"), out = root.appendingPathComponent("out")
        let tasks = (split.train + split.val + split.test).map { (id: $0, taskClass: "test-fix") }
        try split.write(to: source)
        let file = source.appendingPathComponent("split.json")
        #expect(throws: EvolveError.self) { try CorpusSplit.frozen(file: file, dir: out, tasks: Array(tasks.dropLast())) }
        var overlapping = split; overlapping.train.append(split.test[0])
        try overlapping.write(to: source)
        #expect(throws: EvolveError.self) { try CorpusSplit.frozen(file: file, dir: out, tasks: tasks) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        try split.write(to: out)
        var changed = split; changed.train = split.val; changed.val = split.train
        try changed.write(to: source)
        #expect(throws: EvolveError.self) { try CorpusSplit.frozen(file: file, dir: out, tasks: tasks) }
        try Data("broken".utf8).write(to: file)
        #expect(throws: EvolveError.self) { try CorpusSplit.frozen(file: file, dir: out, tasks: tasks) }
        #expect(CorpusSplit.read(from: out) == split)
    }
}

private final class ProductsMarker {}

@Suite struct FixedReleaseTests {
    @Test func cliRunsResumesAndReportsRelease() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // The `strim` product sits next to the test bundle (also under a custom --scratch-path, as in the release gate).
        let products: URL? = Bundle(for: ProductsMarker.self).bundleURL.deletingLastPathComponent()
        let binary = [products?.appendingPathComponent("strim"), root.appendingPathComponent(".build/debug/strim")]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? root.appendingPathComponent(".build/debug/strim")
        let out = tempDir("fixed-release-cli")
        let candidate = #"{"thinking":"all_turns_medium"}"#
        func cli(_ args: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = binary
            process.currentDirectoryURL = root
            process.arguments = ["evolve"] + args
            let output = Pipe()
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let common = ["--out", out.path, "--dry-run"]
        let refused = try cli(["run", "--candidate", candidate, "--release-eval"] + common)
        #expect(refused.0 == 2 && refused.1.contains("--release-eval needs --split test"))
        let run = ["run", "--candidate", candidate, "--split", "test", "--release-eval"] + common
        let first = try cli(run)
        #expect(first.0 == 0)
        let split = try #require(CorpusSplit.read(from: out))
        #expect(!split.test.isEmpty)
        let ledger = FitnessLedger(url: out.appendingPathComponent("ledger.dry-run.jsonl"))
        let rows = ledger.read()
        #expect(rows.count == split.test.count * 2 * 2)
        #expect(Set(rows.map(\.key)).count == rows.count)
        #expect(rows.allSatisfy { $0.phase == .release && $0.split == .test })
        let second = try cli(run)
        #expect(second.0 == 0 && second.1.contains("executed 0 runs"))
        #expect(ledger.read() == rows)
        let report = try cli(["report"] + common)
        #expect(report.0 == 0 && report.1.contains("release (phase release)"))
        #expect(report.1.contains("test A: n ") && report.1.contains("test B: n "))
        #expect(report.1.contains("both-pass") && report.1.contains("only-A") && report.1.contains("only-B") && report.1.contains("neither"))
        #expect(report.1.contains("release regression:"))
        let noRelease = try cli(["run", "--candidate", candidate, "--split", "test"] + common)
        #expect(noRelease.0 == 2)
        var incompatible = try #require(rows.first)
        incompatible.phase = .search; incompatible.candidate = "other-comparison"
        try ledger.append(incompatible)
        let mixed = try cli(run)
        #expect(mixed.0 == 2 && mixed.1.contains("ledger contains rows for a different comparison"))
    }

    @Test func releaseReportFlagsPassAndFalseDoneRegressionAndRejectsOtherRows() async throws {
        var candidate = PackCandidate.baseline; candidate.thinking = .allTurnsMedium
        let comparison = PairedEvaluation(candidate: candidate)
        let split = CorpusSplit(train: [], val: [], test: ["t"])
        var config = EvolveConfig(); config.valReps = 2
        let ledger = FitnessLedger(url: tempDir("fixed-release-report").appendingPathComponent("ledger.jsonl"))
        let runner = FakeTaskRunner { r in
            let pass = r.candidate == .baseline || r.rep == 1
            return TaskRunResult(pass: pass, claimedDone: true, localTokens: 23, wallS: 2, timedOut: !pass)
        }
        let ev = Evaluator(runner: runner, ledger: ledger, split: split, classes: [:], config: config, dryRun: true)
        #expect(try await ev.releaseEval(chosen: candidate, baseline: .baseline, reps: config.valReps).executed == 4)
        let rows = ledger.read()
        try comparison.validateLedger(rows: rows)
        let text = comparison.report(rows: rows, split: split, config: config, release: true).joined(separator: "\n")
        #expect(text.contains("test A: n 2/2 pass 100.0%") && text.contains("test B: n 2/2 pass 50.0%"))
        #expect(text.contains("false-done 1 (50.0%) timeouts 1"))
        #expect(text.contains("both-pass 1 only-A 1 only-B 0 neither 0") && text.contains("REGRESSED"))
        var equalPassRows = rows
        let aFailure = try #require(equalPassRows.firstIndex { $0.candidate == comparison.againstFingerprint && $0.rep == 2 })
        equalPassRows[aFailure].pass = false
        equalPassRows[aFailure].falseDone = false
        let equalPassReport = comparison.report(rows: equalPassRows, split: split, config: config, release: true).joined(separator: "\n")
        #expect(equalPassReport.contains("release regression: REGRESSED"))
        var other = rows[0]; other.candidate = "different"; other.phase = .search
        #expect(throws: EvolveError.self) { try comparison.validateLedger(rows: rows + [other]) }
        other.phase = .paired
        #expect(throws: EvolveError.self) { try comparison.validateLedger(rows: rows + [other]) }
    }
}
