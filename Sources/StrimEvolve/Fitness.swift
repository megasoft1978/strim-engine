import Foundation
import StrimAgentBench

public enum Phase: String, Codable, Sendable { case search, release }

/// One JSONL line per (candidate, split, task, rep). `fitness` = pass - 2 * falseDone, tie-break local tokens then wall.
public struct FitnessRow: Codable, Equatable, Sendable {
    public var candidate: String
    public var split: SplitName
    public var phase: Phase = .search
    public var round: Int = 0
    public var coordinate: String = ""
    public var taskId: String
    public var taskClass: String
    public var rep: Int
    public var pass: Bool
    public var claimedDone: Bool = false
    public var falseDone: Bool = false
    public var testsTampered: Bool = false
    public var localTokens: Int = 0
    public var wallS: Double = 0
    public var fitness: Double
    /// Seed handed to the runner and decoding mode of the candidate ("greedy" or "sampled"): both recorded per row.
    public var seed: UInt64 = 0
    public var decoding: String = "greedy"
    public var infraError: Bool = false
    public var dryRun: Bool = false
    public var error: String?
    public var ts: String = ""

    public static let falseDonePenalty = 2.0
    public static func fitness(pass: Bool, falseDone: Bool) -> Double { (pass ? 1 : 0) - (falseDone ? falseDonePenalty : 0) }

    public init(candidate: String, split: SplitName, taskId: String, taskClass: String, rep: Int, pass: Bool, falseDone: Bool) {
        self.candidate = candidate; self.split = split; self.taskId = taskId; self.taskClass = taskClass; self.rep = rep
        self.pass = pass; self.falseDone = falseDone; self.fitness = Self.fitness(pass: pass, falseDone: falseDone)
    }

    public struct Key: Hashable, Sendable {
        public var candidate: String, split: SplitName, phase: Phase, taskId: String, rep: Int
    }
    public var key: Key { Key(candidate: candidate, split: split, phase: phase, taskId: taskId, rep: rep) }
}

/// Append-only, resumable. Reading skips torn lines.
public struct FitnessLedger: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func append(_ row: FitnessRow) throws {
        var data = try JSONL.encoder().encode(row)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw LedgerError.io("cannot open \(url.path)") }
        defer { close(fd) }
        if let existing = try? Data(contentsOf: url), let last = existing.last, last != 0x0A { data.insert(0x0A, at: 0) } // torn tail
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard n == data.count else { throw LedgerError.io("short write to \(url.path)") }
        fsync(fd)
    }

    public func read() -> [FitnessRow] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONL.decoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(FitnessRow.self, from: Data($0.utf8)) }
    }
}

// MARK: - Task runner

public struct TaskRunRequest: Sendable {
    public var candidate: PackCandidate
    public var fingerprint: String
    public var taskId: String
    public var taskClass: String
    public var split: SplitName
    public var rep: Int
    public var seed: UInt64
    public init(candidate: PackCandidate, fingerprint: String, taskId: String, taskClass: String, split: SplitName, rep: Int, seed: UInt64) {
        self.candidate = candidate; self.fingerprint = fingerprint; self.taskId = taskId; self.taskClass = taskClass
        self.split = split; self.rep = rep; self.seed = seed
    }
}

public struct TaskRunResult: Sendable, Equatable {
    /// Hidden verify passed (bench judge: test_paths restored and hashed, verify_cmd or answer oracle).
    public var pass: Bool
    public var claimedDone: Bool
    public var testsTampered: Bool
    public var localTokens: Int
    public var wallS: Double
    public var infraError: Bool
    public var error: String?
    public init(pass: Bool, claimedDone: Bool, testsTampered: Bool = false, localTokens: Int = 0, wallS: Double = 0,
                infraError: Bool = false, error: String? = nil) {
        self.pass = pass; self.claimedDone = claimedDone; self.testsTampered = testsTampered; self.localTokens = localTokens
        self.wallS = wallS; self.infraError = infraError; self.error = error
    }
}

public protocol TaskRunner: Sendable {
    func run(_ request: TaskRunRequest) async -> TaskRunResult
}

public enum RowBuilder {
    public static func row(for r: TaskRunRequest, result: TaskRunResult, round: Int, coordinate: String, phase: Phase, dryRun: Bool) -> FitnessRow {
        // A tampered test tree is never a pass; "claimed done but not passing" is a false-done.
        let pass = result.pass && !result.testsTampered
        var row = FitnessRow(candidate: r.fingerprint, split: r.split, taskId: r.taskId, taskClass: r.taskClass, rep: r.rep,
                             pass: pass, falseDone: result.claimedDone && !pass)
        row.phase = phase; row.round = round; row.coordinate = coordinate
        row.claimedDone = result.claimedDone; row.testsTampered = result.testsTampered
        row.localTokens = result.localTokens; row.wallS = result.wallS
        row.seed = r.seed; row.decoding = r.candidate.temperature == .greedy ? "greedy" : "sampled"
        row.infraError = result.infraError; row.error = result.error; row.dryRun = dryRun
        row.ts = ISO8601DateFormatter().string(from: Date())
        return row
    }
}

// MARK: - Fake runner (no model)

/// Deterministic scripted outcomes. Success odds depend on a few candidate traits so the search has something to find.
public struct FakeTaskRunner: Sendable {
    public typealias Script = @Sendable (TaskRunRequest) -> TaskRunResult
    let script: Script
    public init(script: @escaping Script) { self.script = script }

    /// Hash-driven default: baseline ~45% pass; verify_first, stepwise playbooks and warm sampling shift the odds.
    public static var standard: FakeTaskRunner {
        FakeTaskRunner { r in
            func unit(_ salt: String) -> Double {
                Double(CorpusSplit.key("\(r.fingerprint)|\(r.taskId)|\(r.rep)|\(salt)") % 10_000) / 10_000
            }
            var p = 0.45
            let c = r.candidate
            if c.systemPrompt == .verifyFirst { p += 0.20 }
            if c.systemPrompt == .lean { p -= 0.05 }
            if c.toolGuidance == .strict { p += 0.05 }
            if r.taskClass.contains("test") && c.playbookTestFix == .stepwise { p += 0.15 }
            if r.taskClass.contains("qa") && c.playbookRepoQA != .off { p += 0.10 }
            if c.temperature == .warm { p -= 0.10 }
            let pass = unit("pass") < p
            let claimed = pass || unit("claim") < 0.4
            return TaskRunResult(pass: pass, claimedDone: claimed, localTokens: 20_000 + Int(unit("tok") * 30_000),
                                 wallS: 30 + unit("wall") * 120)
        }
    }

    public func runSync(_ r: TaskRunRequest) -> TaskRunResult { script(r) }
}

extension FakeTaskRunner: TaskRunner {
    public func run(_ request: TaskRunRequest) async -> TaskRunResult { script(request) }
}
