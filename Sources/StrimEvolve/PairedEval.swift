import Foundation

extension CorpusSplit {
    /// Import a frozen assignment without recomputing it or changing an existing output's split.
    public static func frozen(file: URL, dir: URL, tasks: [(id: String, taskClass: String)]) throws -> CorpusSplit {
        let imported: CorpusSplit
        do { imported = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file)) }
        catch { throw EvolveError.usage("cannot read --split file \(file.path): \(error)") }
        let ids = imported.train + imported.val + imported.test
        guard Set(ids).count == ids.count else {
            throw EvolveError.splitChanged("--split file must assign each task at most once across train, val and test")
        }
        let missing = Set(ids).subtracting(tasks.map(\.id))
        guard missing.isEmpty else {
            throw EvolveError.splitChanged("tasks in --split file are missing from the corpus: \(missing.sorted().joined(separator: ","))")
        }
        let savedURL = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: savedURL.path) {
            guard read(from: dir) == imported else {
                throw EvolveError.splitChanged("split.json in \(dir.path) differs from --split; use a new --out")
            }
        } else { try imported.write(to: dir) }
        return imported
    }
}

/// A fixed A/B comparison. A is `against`, B is `candidate`; neither is selected or adopted.
public struct PairedEvaluation: Codable, Equatable, Sendable {
    public let against: PackCandidate
    public let candidate: PackCandidate
    public let againstFingerprint: String
    public let candidateFingerprint: String

    public init(candidate: PackCandidate, against: PackCandidate = .baseline) {
        self.against = against; self.candidate = candidate
        againstFingerprint = PackLibrary.fingerprint(against)
        candidateFingerprint = PackLibrary.fingerprint(candidate)
    }

    public func validate() throws {
        guard candidateFingerprint != againstFingerprint else {
            throw EvolveError.usage("--candidate and --against have the same fingerprint; nothing to compare")
        }
    }

    /// Both inline JSON and files use the same strict candidate decoder.
    public static func decode(_ value: String) throws -> PackCandidate {
        do {
            let data = value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                ? Data(value.utf8) : try Data(contentsOf: URL(fileURLWithPath: value))
            return try JSONDecoder().decode(PackCandidate.self, from: data)
        } catch { throw EvolveError.usage("invalid candidate JSON or file \(value): \(error)") }
    }

    public static let fileName = "paired.json"

    /// Refuse rows from other comparisons before recording this manifest.
    public func validateLedger(rows: [FitnessRow]) throws {
        let allowed = Set([againstFingerprint, candidateFingerprint])
        guard rows.allSatisfy({ allowed.contains($0.candidate) }) else {
            throw EvolveError.usage("ledger contains rows for a different comparison; use a new --out")
        }
    }

    /// Preserve the comparison and its labels for resume and a standalone `evolve report`.
    public func freeze(in directory: URL) throws {
        let url = directory.appendingPathComponent(Self.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard saved == self else { throw EvolveError.usage("paired.json differs from this comparison; use a new --out") }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Canonical.json(self).write(to: url, options: .atomic)
        }
    }

    public static func read(from directory: URL) throws -> Self? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Alternate the first arm by task, then alternate each repetition (ABBA or BAAB for two reps).
    /// Filtering completed keys preserves the remaining execution order on resume.
    public func pending(rows: [FitnessRow], split: CorpusSplit, config: EvolveConfig) -> [PlannedRun] {
        var done = Set(Selection.usable(rows, phase: .paired).keys)
        var runs: [PlannedRun] = []
        for sp in [SplitName.train, .val] {
            let reps = sp == .train ? config.trainReps : config.valReps
            for (ti, task) in split.ids(sp).enumerated() {
                for rep in 1...max(1, reps) {
                    let a = (against, againstFingerprint), b = (candidate, candidateFingerprint)
                    for (c, fp) in (rep + ti).isMultiple(of: 2) ? [b, a] : [a, b] {
                        let key = FitnessRow.Key(candidate: fp, split: sp, phase: .paired, taskId: task, rep: rep)
                        if done.insert(key).inserted {
                            runs.append(PlannedRun(candidate: c, fingerprint: fp, split: sp, taskId: task,
                                                   rep: rep, round: 0, coordinate: "paired"))
                        }
                    }
                }
            }
        }
        return runs
    }

    /// Shared by run and report; completed pairs are counted per task and repetition.
    public func report(rows: [FitnessRow], split: CorpusSplit, config: EvolveConfig, release: Bool = false) -> [String] {
        let phase: Phase = release ? .release : .paired
        var lines = [release ? "release (phase release): A \(againstFingerprint) [\(against.label)]" : "paired (phase paired): A \(againstFingerprint) [\(against.label)]",
                     "                       B \(candidateFingerprint) [\(candidate.label)]"]
        for sp in (release ? [SplitName.test] : [.train, .val]) {
            let reps = max(1, sp == .train ? config.trainReps : config.valReps)
            let ids = split.ids(sp)
            let relevant = rows.filter { ids.contains($0.taskId) && (1...reps).contains($0.rep) }
            for (name, fp) in [("A", againstFingerprint), ("B", candidateFingerprint)] {
                let rs = Selection.usable(relevant, phase: phase).values.filter { $0.candidate == fp && $0.split == sp }
                let n = Double(max(1, rs.count))
                let passRate = 100 * Double(rs.filter(\.pass).count) / n
                let meanWall = rs.map(\.wallS).reduce(0, +) / n
                let meanTokens = Double(rs.map(\.localTokens).reduce(0, +)) / n
                let falseDone = rs.filter(\.falseDone).count
                let timeouts = rs.filter { $0.timedOut == true }.count
                lines.append(String(format: "%@ %@: n %d/%d pass %.1f%% mean wall %.2fs mean local tokens %.1f false-done %d (%.1f%%) timeouts %d",
                                    sp.rawValue, name, rs.count, ids.count * reps, passRate, meanWall, meanTokens,
                                    falseDone, 100 * Double(falseDone) / n, timeouts))
            }
            let pairs = Selection.pairs(againstFingerprint, candidateFingerprint, split: sp, rows: relevant, phase: phase, taskIds: ids)
            for id in ids {
                let ps = pairs.filter { $0.taskId == id }
                lines.append("\(sp.rawValue) \(id): pairs \(ps.count)/\(reps) both-pass \(ps.filter { $0.a.pass && $0.b.pass }.count) only-A \(ps.filter { $0.a.pass && !$0.b.pass }.count) only-B \(ps.filter { !$0.a.pass && $0.b.pass }.count) neither \(ps.filter { !$0.a.pass && !$0.b.pass }.count)")
            }
        }
        if release {
            let relevant = rows.filter { split.test.contains($0.taskId) && (1...max(1, config.valReps)).contains($0.rep) }
            let usable = Selection.usable(relevant, phase: .release).values.filter { $0.split == .test }
            let a = usable.filter { $0.candidate == againstFingerprint }
            let b = usable.filter { $0.candidate == candidateFingerprint }
            let expected = split.test.count * max(1, config.valReps)
            if expected > 0 && a.count == expected && b.count == expected {
                let passA = Double(a.filter(\.pass).count) / Double(a.count)
                let passB = Double(b.filter(\.pass).count) / Double(b.count)
                let fdA = Double(a.filter(\.falseDone).count) / Double(a.count)
                let fdB = Double(b.filter(\.falseDone).count) / Double(b.count)
                lines.append("release regression: \(passB < passA || fdB > fdA ? "REGRESSED" : "no")")
            } else { lines.append("release regression: pending") }
        } else {
            lines.append("paired evaluation: no search or adoption; test split: untouched")
        }
        return lines
    }
}

extension Evaluator {
    /// Fixed candidates only, using the same runner, row builder, ledger and stop rules as search.
    public func pairedEval(_ comparison: PairedEvaluation) async throws -> EvolveRunSummary {
        var sum = EvolveRunSummary()
        for next in comparison.pending(rows: ledger.read(), split: split, config: config) {
            if stopRequested() { sum.interrupted = true; return sum }
            if let d = deadline, Date() >= d { sum.budgetStopped = true; return sum }
            try SplitGuard.check(next.split, releaseEval: false)
            let row = await execute(next, phase: .paired)
            try ledger.append(row)
            sum.executed += 1
            log("[paired] \(next.candidate.label) \(next.split.rawValue) \(next.taskId)#\(next.rep): "
                + (row.infraError ? "INFRA" : row.pass ? "PASS" : row.falseDone ? "FAIL false-done" : "FAIL"))
            if row.infraError { sum.infraStopped = true; return sum }
        }
        sum.finished = true
        return sum
    }
}
