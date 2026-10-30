import Foundation
import StrimAgentBench

/// Production `TaskRunner`: arm H of the agent bench (the harness alone, through the MCP over HTTP) on the task's
/// snapshot, judged by the bench `Verifier` (test_paths restored and hashed, then verify_cmd or the answer oracle).
///
/// How a candidate reaches the model: the pack files are written into `liveDir` and the server was started with
/// `STRIM_PACK_DIR=liveDir` (see `BenchTaskRunner.environmentForServer`), which `PackLoader.builtin()` reads on every
/// job. The runner is serial (one task at a time, GPU lock held by the caller).
public final class BenchTaskRunner: TaskRunner, @unchecked Sendable {
    let tasks: [String: LoadedTask]
    let executor: ArmExecutor
    let liveDir: URL
    let workRoot: URL
    let outDir: URL
    let timeoutS: TimeInterval
    let verifyTimeoutS: TimeInterval
    let verifyEnv: [String: String]
    let healthCheck: (() -> Bool)?
    private var liveFingerprint: String?

    public init(tasks: [LoadedTask], executor: ArmExecutor, liveDir: URL, workRoot: URL, outDir: URL, timeoutS: TimeInterval = 900,
                verifyTimeoutS: TimeInterval = 300, verifyEnv: [String: String] = [:],
                healthCheck: (() -> Bool)? = nil) {
        self.tasks = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        self.executor = executor; self.liveDir = liveDir; self.workRoot = workRoot; self.outDir = outDir
        self.timeoutS = timeoutS; self.verifyTimeoutS = verifyTimeoutS
        self.verifyEnv = verifyEnv; self.healthCheck = healthCheck
    }

    /// Extra environment for the server process only (`LocalServer.spawn(extraEnv:)`); this process's environment,
    /// and so every other child it spawns, is left alone.
    public static func environmentForServer(liveDir: URL) -> [String: String] { ["STRIM_PACK_DIR": liveDir.path] }

    /// The work root (`$TMPDIR/strim-evolve-<pid>`). Create it before `LocalServer.spawn(workRoot:)` so the host is
    /// started with exactly this root granted; the runs live under `<root>/runs`.
    public static func createWorkRoot() throws -> URL {
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("strim-evolve-\(getpid())")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    public func run(_ r: TaskRunRequest) async -> TaskRunResult {
        await Task.detached { [self] in runSync(r) }.value
    }

    func runSync(_ r: TaskRunRequest) -> TaskRunResult {
        guard let task = tasks[r.taskId] else { return TaskRunResult(pass: false, claimedDone: false, infraError: true, error: "unknown task \(r.taskId)") }
        do {
            if liveFingerprint != r.fingerprint {
                try PackStore.materialize(r.candidate, into: liveDir, fingerprint: r.fingerprint)
                liveFingerprint = r.fingerprint
            }
            // The bench seed otherwise only shuffles task order; pass each Qwen row's seed to the harness.
            if r.candidate.sampling == .qwen {
                var knobs = PackLibrary.render(r.candidate).knobs
                knobs.seed = r.seed
                try PackStore.write(Canonical.json(knobs), to: liveDir.appendingPathComponent("knobs.json"))
            }
        } catch { return TaskRunResult(pass: false, claimedDone: false, infraError: true, error: "cannot write pack: \(error)") }

        let runOut = outDir.appendingPathComponent("\(r.fingerprint)-\(r.split.rawValue)-r\(r.rep)")
        let scratchLedger = runOut.appendingPathComponent("ledger.jsonl")
        try? FileManager.default.removeItem(at: scratchLedger) // our own scratch file from an aborted attempt
        var cfg = RunnerConfig(arms: [.H], ledgerURL: scratchLedger, eventsURL: runOut.appendingPathComponent("events.jsonl"),
                               outDir: runOut, workRoot: workRoot)
        cfg.seed = r.seed; cfg.reps = 1; cfg.timeoutS = timeoutS; cfg.verifyTimeoutS = verifyTimeoutS
        cfg.verifyEnv = verifyEnv
        let runner = BenchRunner(config: cfg, tasks: [task], executors: [.H: executor], healthCheck: healthCheck)
        do { _ = try runner.run() } catch { return TaskRunResult(pass: false, claimedDone: false, infraError: true, error: "\(error)") }
        guard let row = Ledger(url: scratchLedger).read().last else {
            return TaskRunResult(pass: false, claimedDone: false, infraError: true, error: "no ledger row (interrupted or server down)")
        }
        return TaskRunResult(pass: row.success, claimedDone: row.claimedDone, testsTampered: row.testsTampered,
                             localTokens: (row.localPromptTokens ?? 0) + (row.localCompletionTokens ?? 0), wallS: row.wallS,
                             infraError: row.infraError, error: row.error, timedOut: row.timedOut)
    }
}
