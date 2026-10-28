import Foundation

public struct RunnerConfig: Sendable {
    public var arms: [Arm]
    public var reps = 1
    public var seed: UInt64 = 20261027
    public var ledgerURL: URL
    public var eventsURL: URL
    /// Logs per run (kept).
    public var outDir: URL
    /// Base snapshots and per-run working copies (temp; removed per run unless keepWorkdirs).
    public var workRoot: URL
    public var allowPaid = false
    public var maxParentRuns: Int?
    public var timeoutS: TimeInterval = 900
    public var verifyTimeoutS: TimeInterval = 300
    public var dryRun = false
    public var keepWorkdirs = false
    /// Ignored: the verifier is always sandboxed and fails closed (kept so existing callers compile).
    public var sandboxVerify = true
    public var verifyEnv: [String: String] = [:]
    public init(arms: [Arm], ledgerURL: URL, eventsURL: URL, outDir: URL, workRoot: URL) {
        self.arms = arms; self.ledgerURL = ledgerURL; self.eventsURL = eventsURL; self.outDir = outDir; self.workRoot = workRoot
    }
}

public struct RunSummary: Sendable, Equatable {
    public var planned = 0
    public var skipped = 0
    public var executed = 0
    public var passed = 0
    public var budgetStopped = false
    public var interrupted = false
    /// Stopped after `BenchRunner.maxConsecutiveInfraErrors` infra errors in a row (the rows stay rerunnable).
    public var infraStopped = false
}

public final class BenchRunner {
    let config: RunnerConfig
    let tasks: [LoadedTask]
    let executors: [Arm: ArmExecutor]
    let log: (String) -> Void
    let ledger: Ledger
    let events: EventLog
    let healthCheck: (() -> Bool)?
    /// Per-language startup check (nil result = ok); default runs `SelfCheck` unless dry-run.
    public var selfCheck: ((String, URL) -> String?)?
    private var selfCheckCache: [String: String] = [:]  // "" = ok

    /// `healthCheck`: called before each run that needs the local model; false stops the run (server died).
    public init(config: RunnerConfig, tasks: [LoadedTask], executors: [Arm: ArmExecutor], healthCheck: (() -> Bool)? = nil,
                log: @escaping (String) -> Void = { _ in }) {
        self.config = config; self.tasks = tasks; self.executors = executors; self.log = log; self.healthCheck = healthCheck
        ledger = Ledger(url: config.ledgerURL); events = EventLog(url: config.eventsURL)
    }

    /// Stop rule (docs/PLAN-AGENT-HARNESS): abort the run after this many consecutive infra errors.
    public static let maxConsecutiveInfraErrors = 3

    static func iso() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// Prepares the base copy of a task once.
    func baseDir(for t: LoadedTask) throws -> URL {
        let dir = config.workRoot.appendingPathComponent("base").appendingPathComponent(t.id)
        if FileManager.default.fileExists(atPath: dir.path) { return dir }
        guard let src = t.snapshotSource() else { throw LedgerError.io("task \(t.id): no snapshot found in \(t.dir.path)") }
        try Verifier.extractSnapshot(src, into: dir)
        return dir
    }

    func freshWorkdir(base: URL, name: String, scratch: URL) throws -> URL {
        let fm = FileManager.default
        let work = config.workRoot.appendingPathComponent("runs").appendingPathComponent(name)
        try? fm.removeItem(at: work) // our own run dir from a previous aborted attempt
        try fm.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: base, to: work)
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "bench"; env["GIT_AUTHOR_EMAIL"] = "bench@localhost"
        env["GIT_COMMITTER_NAME"] = "bench"; env["GIT_COMMITTER_EMAIL"] = "bench@localhost"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        for c in [["init", "-q"], ["add", "-A"], ["commit", "-qm", "base", "--no-gpg-sign"]] {
            _ = Proc.capture(["/usr/bin/git"] + c, cwd: work.path, env: env, scratch: scratch)
        }
        return work
    }

    public func run() throws -> RunSummary {
        try BudgetGuard.validate(arms: config.arms, allowPaid: config.allowPaid, maxParentRuns: config.maxParentRuns)
        var summary = RunSummary()
        let existing = ledger.read()
        let done = Set(existing.filter { !$0.infraError }.map(\.key))
        var budget = BudgetGuard(limit: config.maxParentRuns ?? 0, alreadyUsed: existing.filter { $0.arm.isPaid && !$0.dryRun && !BudgetGuard.isFree($0) }.count)
        let plan = Planner.plan(taskIds: tasks.map(\.id), arms: config.arms, reps: config.reps, seed: config.seed)
        summary.planned = plan.count
        let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let fm = FileManager.default

        var consecutiveInfra = 0
        for item in plan {
            if Interrupt.requested { summary.interrupted = true; events.record("interrupted"); break }
            if done.contains(item.key) { summary.skipped += 1; continue }
            guard let task = byId[item.taskId], let exec = executors[item.arm] else { continue }
            if item.arm.usesLocalModel, !config.dryRun, let hc = healthCheck, !hc() {
                events.record("server_down", ["next": "\(item.taskId)/\(item.arm.rawValue)/\(item.rep)"])
                log("local server is not healthy: stopping (resume later)")
                summary.interrupted = true
                break
            }
            if item.arm.isPaid && !config.dryRun {
                guard budget.reserve() else {
                    summary.budgetStopped = true
                    events.record("budget_reached", ["limit": String(budget.limit), "used": String(budget.used),
                                                     "next": "\(item.taskId)/\(item.arm.rawValue)/\(item.rep)"])
                    log("budget reached (\(budget.used)/\(budget.limit) paid parent runs): stopping before \(item.taskId) \(item.arm.rawValue) rep\(item.rep)")
                    break
                }
            }
            let name = "\(item.taskId)-\(item.arm.rawValue)-\(item.rep)"
            let runDir = config.outDir.appendingPathComponent("runs").appendingPathComponent(name)
            try fm.createDirectory(at: runDir, withIntermediateDirectories: true)
            var row = LedgerRow(taskId: task.id, taskClass: task.spec.taskClass, arm: item.arm, rep: item.rep, success: false)
            row.dryRun = config.dryRun
            row.ts = Self.iso()
            let t0 = Date()
            var work: URL?
            do {
                let base = try baseDir(for: task)
                let w = try freshWorkdir(base: base, name: name, scratch: runDir)
                work = w
                let ctx = RunContext(task: task, arm: item.arm, rep: item.rep, workdir: w, runDir: runDir,
                                     timeout: config.timeoutS, seed: config.seed)
                log("run \(name) ...")
                if let sc = selfCheck, let lang = task.language {
                    if selfCheckCache[lang] == nil { selfCheckCache[lang] = sc(lang, runDir) ?? "" }
                    if let why = selfCheckCache[lang], !why.isEmpty { throw LedgerError.io("infra: \(why)") }
                }
                let o = exec.execute(ctx)
                row.wallS = (Date().timeIntervalSince(t0) * 10).rounded() / 10
                Self.apply(o, to: &row)
                if o.infraError {
                    row.infraError = true
                } else {
                    let v = Verifier.verify(task: task.spec, base: base, work: w, answer: o.answer,
                                            scratch: runDir.appendingPathComponent("verify"), timeout: config.verifyTimeoutS,
                                            extraEnv: config.verifyEnv)
                    if v.infra { row.infraError = true; row.error = v.note }
                    row.success = v.success
                    row.testsTampered = v.testsTampered
                    row.verifyNote = v.note
                    row.falseDone = row.claimedDone && !v.success
                }
            } catch {
                row.error = "\(error)".hasPrefix("infra:") ? "\(error)" : "infra: \(error)"
                row.infraError = true
                row.wallS = (Date().timeIntervalSince(t0) * 10).rounded() / 10
            }
            if !config.keepWorkdirs, let w = work { try? fm.removeItem(at: w) } // our own temp copy
            try ledger.append(row)
            summary.executed += 1
            // An infra error never reached the model, so it does not use up the paid cap (it is rerun on resume).
            if item.arm.isPaid && !config.dryRun && BudgetGuard.isFree(row) { budget.release() }
            consecutiveInfra = row.infraError ? consecutiveInfra + 1 : 0
            if row.success { summary.passed += 1 }
            log("  -> \(row.success ? "PASS" : "FAIL")\(row.falseDone ? " false-done" : "")\(row.infraError ? " INFRA" : "") \(row.wallS)s \(row.verifyNote.prefix(120))")
            if consecutiveInfra >= Self.maxConsecutiveInfraErrors {
                summary.infraStopped = true
                events.record("infra_stop", ["consecutive": String(consecutiveInfra), "last": name])
                log("\(consecutiveInfra) consecutive infra errors: stopping (fix the environment, then resume; infra rows are rerun and not counted against the cap)")
                break
            }
        }
        return summary
    }

    static func apply(_ o: ArmOutcome, to r: inout LedgerRow) {
        r.parentInUncached = o.parentInUncached; r.parentCacheCreate = o.parentCacheCreate
        r.parentCacheRead = o.parentCacheRead; r.parentOut = o.parentOut; r.parentCostUsd = o.parentCostUsd
        if o.parentInUncached != nil || o.parentCacheCreate != nil || o.parentCacheRead != nil || o.parentOut != nil {
            r.parentTotal = (o.parentInUncached ?? 0) + (o.parentCacheCreate ?? 0) + (o.parentCacheRead ?? 0) + (o.parentOut ?? 0)
        }
        r.localPromptTokens = o.localPromptTokens; r.localCachedTokens = o.localCachedTokens
        r.localCompletionTokens = o.localCompletionTokens; r.localTurns = o.localTurns
        r.turns = o.turns; r.delegations = o.delegations; r.polls = o.polls; r.pathRefusals = o.pathRefusals > 0 ? o.pathRefusals : nil
        r.patchApplied = o.patchApplied; r.claimedDone = o.claimedDone; r.redo = o.redo
        r.timedOut = o.timedOut; r.error = o.error
        r.harnessVerifyStatus = o.harnessVerifyStatus; r.harnessVerifyExit = o.harnessVerifyExit; r.harnessStatus = o.harnessStatus
    }
}
