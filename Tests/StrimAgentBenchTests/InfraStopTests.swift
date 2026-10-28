import Foundation
import Testing
@testable import StrimAgentBench

/// Pilot 2026-10-28: 18 of 18 runs died at client startup and the runner kept going, then counted those rows against
/// `--max-parent-runs`. Infra errors must stop the run after 3 in a row and must not use up the paid budget.
@Suite struct InfraStopTests {
    func config(_ d: URL, arms: [Arm], max: Int? = nil) -> RunnerConfig {
        var cfg = RunnerConfig(arms: arms, ledgerURL: d.appendingPathComponent("l.jsonl"), eventsURL: d.appendingPathComponent("e.jsonl"),
                               outDir: d.appendingPathComponent("out"), workRoot: d.appendingPathComponent("work"))
        if let max { cfg.allowPaid = true; cfg.maxParentRuns = max }
        return cfg
    }

    static func infra() -> ArmOutcome { var o = ArmOutcome(); o.error = "infra: client died at startup"; o.infraError = true; return o }

    @Test func stopsAfterThreeConsecutiveInfraErrors() throws {
        let d = tempDir("infrastop")
        let tasks = (1...6).map { makeTask(d, id: "t-0\($0)") }
        let exec = ScriptExecutor { _ in Self.infra() }
        let cfg = config(d, arms: [.P], max: 12)
        let s = try BenchRunner(config: cfg, tasks: tasks, executors: [.P: exec]).run()
        #expect(exec.calls == 3)
        #expect(s.infraStopped)
        #expect(s.executed == 3)
        let ev = (try? String(contentsOf: cfg.eventsURL, encoding: .utf8)) ?? ""
        #expect(ev.contains("infra_stop"))
    }

    @Test func aSuccessResetsTheConsecutiveCount() throws {
        let d = tempDir("infrareset")
        let tasks = (1...6).map { makeTask(d, id: "t-0\($0)") }
        var n = 0
        let exec = ScriptExecutor { _ in
            n += 1
            if [3, 6].contains(n) { var o = ArmOutcome(); o.parentCostUsd = 1; return o }
            return Self.infra()
        }
        let s = try BenchRunner(config: config(d, arms: [.P], max: 12), tasks: tasks, executors: [.P: exec]).run()
        #expect(exec.calls == 6)
        #expect(!s.infraStopped)
    }

    @Test func infraRowsDoNotUseUpTheParentBudget() throws {
        let d = tempDir("infrabudget")
        let tasks = (1...5).map { makeTask(d, id: "t-0\($0)") }
        var n = 0
        let exec = ScriptExecutor { _ in
            n += 1
            if n <= 2 { return Self.infra() }
            var o = ArmOutcome(); o.parentCostUsd = 1; o.claimedDone = true; return o
        }
        let cfg = config(d, arms: [.P], max: 2)
        let s = try BenchRunner(config: cfg, tasks: tasks, executors: [.P: exec]).run()
        // 2 infra rows are free: both real runs still fit in the cap of 2, then the cap stops the run.
        #expect(exec.calls == 4)
        #expect(s.budgetStopped && !s.infraStopped)
        #expect(Ledger(url: cfg.ledgerURL).read().filter { !$0.infraError }.count == 2)
    }

    @Test func infraRowsFromAnEarlierRunAreRerunnableAndFree() throws {
        let d = tempDir("infraresume")
        let tasks = (1...2).map { makeTask(d, id: "t-0\($0)") }
        let cfg = config(d, arms: [.P], max: 2)
        let bad = ScriptExecutor { _ in Self.infra() }
        _ = try BenchRunner(config: cfg, tasks: tasks, executors: [.P: bad]).run()
        #expect(Ledger(url: cfg.ledgerURL).read().count == 2)
        let good = ScriptExecutor { _ in var o = ArmOutcome(); o.parentCostUsd = 1; return o }
        let s = try BenchRunner(config: cfg, tasks: tasks, executors: [.P: good]).run()
        #expect(good.calls == 2)
        #expect(!s.budgetStopped)
    }
}

@Suite struct ClaudeStartupFailureTests {
    /// Pilot 2 (2026-10-28): the sandboxed client could not read its login and answered `Not logged in` with zero usage.
    /// That is an environment failure, not a task FAIL: it must be an infra row.
    @Test func notLoggedInIsNotATaskResult() {
        let line = #"{"type":"result","subtype":"success","is_error":true,"num_turns":1,"result":"Not logged in · Please run /login","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}"#
        let r = ClaudeParser.parse(line)
        #expect(r.sawResult && r.isError)
        #expect(r.failedBeforeModel)
        // a run that used the model and then reported an error is a real (failed) result
        let used = ClaudeParser.parse(line.replacingOccurrences(of: #""output_tokens":0"#, with: #""output_tokens":50"#))
        #expect(!used.failedBeforeModel)
    }
}
