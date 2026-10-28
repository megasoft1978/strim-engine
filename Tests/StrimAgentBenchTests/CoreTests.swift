import Foundation
import Testing
@testable import StrimAgentBench

@Suite struct LedgerTests {
    @Test func appendReadAndResume() throws {
        let d = tempDir("ledger")
        let l = Ledger(url: d.appendingPathComponent("l.jsonl"))
        try l.append(row("a", "c", .H))
        try l.append(row("a", "c", .P, cost: 0.5))
        var infra = row("b", "c", .H); infra.infraError = true
        try l.append(infra)
        // torn tail
        let h = FileHandle(forWritingAtPath: l.url.path)!
        h.seekToEndOfFile(); h.write(Data("{\"task_id\":\"x".utf8)); try h.close()
        try l.append(row("c", "c", .C))
        let rows = l.read()
        #expect(rows.count == 4)
        let keys = l.doneKeys()
        #expect(keys.contains(RunKey(taskId: "a", arm: .H, rep: 1)))
        #expect(keys.contains(RunKey(taskId: "a", arm: .P, rep: 1)))
        #expect(!keys.contains(RunKey(taskId: "b", arm: .H, rep: 1)))  // infra failures are rerun
        #expect(rows[1].parentCostUsd == 0.5)
    }
}

@Suite struct PlanTests {
    @Test func interleaveIsDeterministicAndComplete() {
        let ids = ["a", "b", "c", "d"]
        let p1 = Planner.plan(taskIds: ids, arms: [.P, .M, .H, .C], reps: 2, seed: 42)
        let p2 = Planner.plan(taskIds: ids, arms: [.C, .H, .M, .P], reps: 2, seed: 42)
        #expect(p1 == p2)  // independent of the order the arms were given
        #expect(p1.count == 4 * 2 * 4)
        let p3 = Planner.plan(taskIds: ids, arms: [.P, .M, .H, .C], reps: 2, seed: 43)
        #expect(p1 != p3)
        // every (task, rep) group holds each arm once, tasks stay grouped
        for g in stride(from: 0, to: p1.count, by: 4) {
            #expect(Set(p1[g..<g + 4].map(\.arm)) == Set(Arm.allCases))
            #expect(Set(p1[g..<g + 4].map(\.taskId)).count == 1)
        }
        // not all groups use the same order
        let orders = Set(stride(from: 0, to: p1.count, by: 4).map { p1[$0..<$0 + 4].map(\.arm.rawValue).joined() })
        #expect(orders.count > 1)
    }
    @Test func fixedGolden() {
        let p = Planner.plan(taskIds: ["x"], arms: [.P, .M, .H, .C], reps: 1, seed: 1)
        #expect(p.map(\.arm.rawValue).joined() == Planner.plan(taskIds: ["x"], arms: Arm.allCases, reps: 1, seed: 1).map(\.arm.rawValue).joined())
        #expect(fnv1a("a") == 0xaf63dc4c8601ec8c)
    }
}

@Suite struct BudgetTests {
    @Test func refusedWithoutFlags() {
        #expect(throws: BudgetError.paidNotAllowed(.P)) { try BudgetGuard.validate(arms: [.H, .P], allowPaid: false, maxParentRuns: 5) }
        #expect(throws: BudgetError.missingMax) { try BudgetGuard.validate(arms: [.M], allowPaid: true, maxParentRuns: nil) }
        #expect(throws: BudgetError.missingMax) { try BudgetGuard.validate(arms: [.M], allowPaid: true, maxParentRuns: 0) }
        #expect(throws: Never.self) { try BudgetGuard.validate(arms: [.H, .C], allowPaid: false, maxParentRuns: nil) }
        #expect(throws: Never.self) { try BudgetGuard.validate(arms: [.P, .M], allowPaid: true, maxParentRuns: 3) }
    }
    @Test func guardStopsAtLimit() {
        var g = BudgetGuard(limit: 2, alreadyUsed: 1)
        let a = g.reserve(), b = g.reserve()
        #expect(a); #expect(!b); #expect(g.exhausted)
    }
    @Test func runnerRefusesAndStops() throws {
        let d = tempDir("budget")
        let tasks = (1...4).map { makeTask(d, id: "t-0\($0)") }
        var cfg = RunnerConfig(arms: [.P, .H], ledgerURL: d.appendingPathComponent("l.jsonl"), eventsURL: d.appendingPathComponent("e.jsonl"),
                               outDir: d.appendingPathComponent("out"), workRoot: d.appendingPathComponent("work"))
        let paid = ScriptExecutor { _ in var o = ArmOutcome(); o.parentCostUsd = 1; o.claimedDone = true; return o }
        let free = ScriptExecutor { _ in ArmOutcome() }
        #expect(throws: BudgetError.paidNotAllowed(.P)) { try BenchRunner(config: cfg, tasks: tasks, executors: [.P: paid, .H: free]).run() }
        #expect(paid.calls == 0)
        cfg.allowPaid = true; cfg.maxParentRuns = 2
        let s = try BenchRunner(config: cfg, tasks: tasks, executors: [.P: paid, .H: free]).run()
        #expect(s.budgetStopped)
        #expect(paid.calls == 2)
        #expect(Ledger(url: cfg.ledgerURL).read().filter { $0.arm == .P }.count == 2)
        #expect(FileManager.default.fileExists(atPath: cfg.eventsURL.path))
        // resume: ledger rows count against the cap, nothing more is spent
        let s2 = try BenchRunner(config: cfg, tasks: tasks, executors: [.P: paid, .H: free]).run()
        #expect(s2.budgetStopped)
        #expect(paid.calls == 2)
        // raising the cap resumes where it stopped and skips finished rows
        cfg.maxParentRuns = 3
        let s3 = try BenchRunner(config: cfg, tasks: tasks, executors: [.P: paid, .H: free]).run()
        #expect(paid.calls == 3)
        #expect(s3.skipped >= 2)
    }
}

@Suite struct VerifierTests {
    @Test func fixPassesAndEditedTestFails() throws {
        let d = tempDir("verify")
        let task = makeTask(d)
        let base = d.appendingPathComponent("base")
        try Verifier.extractSnapshot(task.snapshotSource()!, into: base)

        // honest fix
        let w1 = d.appendingPathComponent("w1")
        try FileManager.default.copyItem(at: base, to: w1)
        write(w1.appendingPathComponent("src.txt"), "fixed\n")
        let ok = Verifier.verify(task: task.spec, base: base, work: w1, answer: nil, scratch: d.appendingPathComponent("s1"))
        #expect(ok.success, "\(ok.note)")
        #expect(!ok.testsTampered)

        // agent edits the test oracle: fails even though verify would pass after restore
        let w2 = d.appendingPathComponent("w2")
        try FileManager.default.copyItem(at: base, to: w2)
        write(w2.appendingPathComponent("src.txt"), "fixed\n")
        write(w2.appendingPathComponent("tests/check.txt"), "cheated\n")
        let bad = Verifier.verify(task: task.spec, base: base, work: w2, answer: nil, scratch: d.appendingPathComponent("s2"))
        #expect(!bad.success)
        #expect(bad.testsTampered)
        // test_paths were restored from the base snapshot (hash check)
        #expect(Verifier.hashPaths(w2, ["tests"]) == Verifier.hashPaths(base, ["tests"]))

        // agent deletes the test dir
        let w3 = d.appendingPathComponent("w3")
        try FileManager.default.copyItem(at: base, to: w3)
        write(w3.appendingPathComponent("src.txt"), "fixed\n")
        try FileManager.default.removeItem(at: w3.appendingPathComponent("tests"))
        #expect(!Verifier.verify(task: task.spec, base: base, work: w3, answer: nil, scratch: d.appendingPathComponent("s3")).success)

        // unfixed tree fails on verify
        let w4 = d.appendingPathComponent("w4")
        try FileManager.default.copyItem(at: base, to: w4)
        let nofix = Verifier.verify(task: task.spec, base: base, work: w4, answer: nil, scratch: d.appendingPathComponent("s4"))
        #expect(!nofix.success && nofix.verifyExit == 1)
    }

    @Test func pathTraversalRejected() {
        #expect(Verifier.safeRel("../x") == nil)
        #expect(Verifier.safeRel("/etc") == nil)
        #expect(Verifier.safeRel("tests/") == "tests")
    }

    @Test func answerOracleAndNoEdit() throws {
        let d = tempDir("qa")
        var spec = TaskSpec(id: "q", taskClass: "repo-qa", prompt: "?", verifyCmd: "grep -Eq 'flag\\.go' \"$ANSWER_FILE\"",
                            expectedAnswer: ExpectedAnswer(allOf: ["flag\\.go", "parseSingleShortArg"]), noEdit: true)
        spec.snapshot = "snapshot"
        let base = d.appendingPathComponent("base")
        write(base.appendingPathComponent("a.go"), "x")
        let w = d.appendingPathComponent("w")
        try FileManager.default.copyItem(at: base, to: w)
        let good = Verifier.verify(task: spec, base: base, work: w, answer: "flag.go: parseSingleShortArg", scratch: d.appendingPathComponent("s1"))
        #expect(good.success, "\(good.note)")
        #expect(!Verifier.verify(task: spec, base: base, work: w, answer: "flag.go: parseShortArg", scratch: d.appendingPathComponent("s2")).success)
        #expect(!Verifier.verify(task: spec, base: base, work: w, answer: nil, scratch: d.appendingPathComponent("s3")).success)
        write(w.appendingPathComponent("a.go"), "edited")
        #expect(!Verifier.verify(task: spec, base: base, work: w, answer: "flag.go: parseSingleShortArg", scratch: d.appendingPathComponent("s4")).success)
    }

    @Test func runnerMarksFalseDoneAndTamper() throws {
        let d = tempDir("runner")
        let task = makeTask(d)
        let cfg = RunnerConfig(arms: [.H, .C], ledgerURL: d.appendingPathComponent("l.jsonl"), eventsURL: d.appendingPathComponent("e"),
                               outDir: d.appendingPathComponent("out"), workRoot: d.appendingPathComponent("work"))
        let h = ScriptExecutor { ctx in
            write(ctx.workdir.appendingPathComponent("src.txt"), "fixed\n")
            write(ctx.workdir.appendingPathComponent("tests/check.txt"), "cheat\n")
            var o = ArmOutcome(); o.claimedDone = true; return o
        }
        let c = ScriptExecutor { ctx in
            write(ctx.workdir.appendingPathComponent("src.txt"), "fixed\n")
            var o = ArmOutcome(); o.claimedDone = true; return o
        }
        _ = try BenchRunner(config: cfg, tasks: [task], executors: [.H: h, .C: c]).run()
        let rows = Ledger(url: cfg.ledgerURL).read()
        let hr = rows.first { $0.arm == .H }!, cr = rows.first { $0.arm == .C }!
        #expect(!hr.success && hr.testsTampered && hr.falseDone)
        #expect(cr.success && !cr.falseDone)
    }
}

@Suite struct ParserTests {
    @Test func recordedClaudeSample() throws {
        // copy of bench/results/mcp-clients-20261027/rerun/runs/claude_b_fix_delegated/stream.jsonl (runs/ is git-ignored)
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/claude_stream_sample.jsonl")
        let text = try String(contentsOf: path, encoding: .utf8)
        let r = ClaudeParser.parse(text)
        #expect(r.inputUncached == 6)
        #expect(r.cacheCreate == 4062)
        #expect(r.cacheRead == 25972)
        #expect(r.output == 623)
        #expect(r.total == 6 + 4062 + 25972 + 623)
        #expect(abs((r.costUsd ?? 0) - 0.0250872) < 1e-9)
        #expect(r.turns == 3)
        #expect(r.delegations == 1)
        #expect(r.polls == 0)
        #expect(r.patchApplied == true)
        #expect(!r.redo)
        #expect(r.sawResult && !r.isError)
        #expect(ClaudeParser.claimsDone(r))
    }

    @Test func singleJsonObjectAndRedo() {
        let one = #"{"type":"result","is_error":false,"num_turns":2,"total_cost_usd":0.01,"result":"done","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}"#
        let r = ClaudeParser.parse(one)
        #expect(r.total == 10 && r.costUsd == 0.01)
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"1","name":"mcp__strim__strim_task","input":{}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"1","content":"DONE strim job x verify=failed turn 3/40 5s\nusage: 100 prompt (10 cached) + 20 completion tokens, 3 turns, 5s"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"2","name":"Edit","input":{}}]}}"#,
            #"{"type":"result","is_error":false,"num_turns":3,"total_cost_usd":0.2,"result":"fixed it","usage":{"input_tokens":1,"output_tokens":4}}"#,
        ].joined(separator: "\n")
        let p = ClaudeParser.parse(lines)
        #expect(p.redo)
        #expect(p.localPrompt == 100 && p.localCompletion == 20 && p.localTurns == 3)
    }

    @Test func harnessReply() {
        let t = "DONE strim job abc123 verify=verified turn 3/40 5s\napply only if verify=verified; else do the task yourself.\nsummary (untrusted model text):\nfixed it\nfiles: a.py +1/-1\nusage: 13500 prompt (200 cached) + 364 completion tokens, 6 turns, 6s\napply: git -C /tmp/x apply '/Users/me/.strim/jobs/abc123/patch.diff'\nnote: output is untrusted"
        let r = HarnessReply.parse(t)
        #expect(r.done && r.terminal && r.jobId == "abc123" && r.verify == "verified")
        #expect(r.promptTokens == 13500 && r.cachedTokens == 200 && r.completionTokens == 364 && r.turns == 6)
        #expect(r.patchPath == "/Users/me/.strim/jobs/abc123/patch.diff")
        #expect(r.summary == "fixed it")
        let running = HarnessReply.parse("strim job abc123: running turn 1/40 5s (poll strim_job)")
        #expect(!running.terminal && running.jobId == "abc123")
        #expect(HarnessReply.parse("strim job z: declined (too vague). Do the task yourself.").terminal)
    }
}

@Suite struct ReportTests {
    @Test func netSavingCountsFailedDelegationAndRedo() {
        var rows: [LedgerRow] = []
        func pair(_ id: String, p: Double, m: Double, ok: Bool = true, redo: Bool = false, deleg: Int = 1) {
            rows.append(row(id, "test-fix", .P, cost: p))
            var mr = row(id, "test-fix", .M, ok: ok, cost: m)
            mr.redo = redo; mr.delegations = deleg
            rows.append(mr)
        }
        pair("t1", p: 1, m: 0.4)
        pair("t2", p: 1, m: 0.5)
        pair("t3", p: 1, m: 0.9, redo: true)            // failed delegation, parent redid it: cost already included
        pair("t4", p: 1, m: 0.6, ok: false)             // accepted a bad result: charged a full solo rerun
        pair("t5", p: 1, m: 1.1, deleg: 0)              // never delegated: pure tax (+10%)
        let rep = Reporter.build(rows)
        let c = rep.classes[0]
        let ns = c.m_vs_p!
        #expect(ns.pairs == 5)
        // raw: [0.6,0.5,0.1,0.4,-0.1] -> median 0.4 ; net: [0.6,0.5,0.1,-0.6,-0.1] -> median 0.1
        #expect(abs(ns.rawSaving! - 0.4) < 1e-9)
        #expect(abs(ns.netSaving! - 0.1) < 1e-9)
        #expect(abs(ns.aggregateSaving! - (1 - (0.4 + 0.5 + 0.9 + 1.6 + 1.1) / 5)) < 1e-9)
        #expect(ns.failedDelegations == 2)
        #expect(ns.redoRuns == 1 && ns.mFailed == 1)
        #expect(abs(c.tax!.overheadPct! - 10) < 1e-9)
        #expect(c.arms["M"]!.passRate == 0.8)
        #expect(abs(ns.passDeltaPP! - (-20)) < 1e-9)
        #expect(c.gate.contains { $0.hasPrefix("saving >= 40%: no") })
        let text = Reporter.render(rep)
        #expect(text.contains("test-fix") && text.contains("net saving 10%"))
    }

    @Test func falseDoneRateAndDryRunExcluded() {
        var a = row("a", "c", .H, ok: false); a.claimedDone = true; a.falseDone = true
        let b = row("b", "c", .H)
        var dry = row("c", "c", .H); dry.dryRun = true
        let rep = Reporter.build([a, b, dry])
        #expect(rep.rows == 2)
        #expect(rep.classes[0].arms["H"]!.falseDoneRate == 0.5)
    }
}

@Suite struct TaskFormatTests {
    @Test func decodesRealTaskFormat() throws {
        let tasks = TaskLoader.load(root: repoRoot().appendingPathComponent("bench/agenttasks"))
        try #require(!tasks.isEmpty)
        let qa = try #require(tasks.first { $0.spec.taskClass == "repo-qa" })
        #expect(qa.spec.isAnswerTask && qa.spec.expectedAnswer?.isEmpty == false)
        #expect(qa.snapshotSource() != nil)
        let tf = try #require(tasks.first { $0.spec.taskClass == "test-fix" })
        #expect(!tf.spec.testPaths.isEmpty && !tf.spec.testSha256.isEmpty)
    }
}

@Suite struct BugfixTests {
    func lt(_ id: String, _ cls: String) -> LoadedTask {
        LoadedTask(spec: TaskSpec(id: id, taskClass: cls, prompt: "p"), dir: URL(fileURLWithPath: "/tmp"))
    }

    @Test func tasksLimitIsPerClass() {
        let all = ["me-01", "me-02", "me-03", "qa-01", "qa-02", "tf-01", "tf-02", "tf-03"].map { lt($0, String($0.prefix(2))) }
        #expect(TaskLoader.select(all, limit: 2, ids: [], classes: []).map(\.id) == ["me-01", "me-02", "qa-01", "qa-02", "tf-01", "tf-02"])
        #expect(TaskLoader.select(all, limit: 1, ids: [], classes: []).map(\.id) == ["me-01", "qa-01", "tf-01"])
        #expect(TaskLoader.select(all, limit: nil, ids: [], classes: []).count == 8)
        #expect(TaskLoader.select(all, limit: nil, ids: ["tf-03", "me-01"], classes: []).map(\.id) == ["me-01", "tf-03"])
        #expect(TaskLoader.select(all, limit: 1, ids: [], classes: ["qa"]).map(\.id) == ["qa-01"])
    }

    @Test func pathsResolvedAbsolute() {
        #expect(PathArgs.absolute("models/q", cwd: "/work") == "/work/models/q")
        #expect(PathArgs.absolute("./a/../b", cwd: "/work") == "/work/b")
        #expect(PathArgs.absolute("/abs/x", cwd: "/work") == "/abs/x")
        let argv = LocalServer.serveArgv(strimBin: "build/strim", model: "models/q", head: "models/h", port: 8231, tokenFile: "out/t")
        let cwd = FileManager.default.currentDirectoryPath
        #expect(argv[0] == cwd + "/build/strim" && argv[2] == cwd + "/models/q" && argv[3] == cwd + "/models/h")
        #expect(argv.last == cwd + "/out/t")
        #expect(argv.allSatisfy { !$0.hasPrefix("models") && !$0.hasPrefix("out/") })
        #expect(throws: LedgerError.self) {
            try LocalServer.spawn(strimBin: "/bin/true", model: "no/such/model", head: nil, port: 59997, tokenFile: "/tmp/x", logDir: URL(fileURLWithPath: "/tmp"), readyTimeout: 1)
        }
    }

    @Test func oldRowsDecodeAndHarnessFieldsRoundTrip() throws {
        let old = #"{"task_id":"a","task_class":"c","arm":"H","rep":1,"success":true,"wall_s":1,"delegations":1,"polls":0,"claimed_done":true,"false_done":false,"redo":false,"timed_out":false,"infra_error":false,"dry_run":false,"ts":"","tests_tampered":false,"verify_note":""}"#
        let r = try JSONL.decoder().decode(LedgerRow.self, from: Data(old.utf8))
        #expect(r.harnessVerifyStatus == nil && r.harnessStatus == nil && r.harnessVerifyExit == nil)
        var n = row("a", "c", .H)
        n.harnessVerifyStatus = "verified_modified_tests"; n.harnessVerifyExit = 0; n.harnessStatus = "done"
        let back = try JSONL.decoder().decode(LedgerRow.self, from: try JSONL.encoder().encode(n))
        #expect(back.harnessVerifyStatus == "verified_modified_tests" && back.harnessVerifyExit == 0 && back.harnessStatus == "done")
    }

    @Test func harnessVerifyLabelAndExit() throws {
        #expect(HarnessReply.verifyLabel(HarnessReply.parse("DONE strim job a verify=verified_modified_tests turn 3/40 5s")) == "verified_modified_tests")
        #expect(HarnessReply.verifyLabel(HarnessReply.parse("strim job a: declined (nope). Do the task yourself.")) == "declined")
        #expect(HarnessReply.verifyLabel(HarnessReply.parse("strim job a: failed turn 2/40 5s")) == "none")
        let d = tempDir("res")
        write(d.appendingPathComponent("result.json"), #"{"verify":{"status":"failed","exit_code":3}}"#)
        #expect(HarnessReply.verifyExit(besidePatch: d.appendingPathComponent("patch.diff").path) == 3)
        #expect(HarnessReply.verifyExit(besidePatch: "/nonexistent/patch.diff") == nil)
    }

    @Test func agreementTable() {
        func h(_ ok: Bool, _ st: String?) -> LedgerRow { var r = row("t\(UUID().uuidString.prefix(4))", "c", .H, ok: ok); r.harnessVerifyStatus = st; return r }
        let rows = [h(true, "verified"), h(true, "verified"), h(true, "verified"), h(false, "verified"),
                    h(false, "failed"), h(true, "failed"), h(false, "unverified"), h(true, "verified_modified_tests"), h(true, nil)]
        let rep = Reporter.build(rows)
        let by = Dictionary(uniqueKeysWithValues: rep.agreement.map { ($0.harnessVerifyStatus, $0) })
        #expect(rep.agreement.map(\.harnessVerifyStatus) == ["verified", "verified_modified_tests", "failed", "unverified"])
        #expect(by["verified"]!.n == 4 && by["verified"]!.judgePass == 3 && by["verified"]!.judgeFail == 1)
        #expect(abs(by["verified"]!.passRate - 0.75) < 1e-9 && abs(by["verified"]!.failRate - 0.25) < 1e-9)
        #expect(by["failed"]!.passRate == 0.5)
        let text = Reporter.render(rep)
        #expect(text.contains("harness verify vs judge") && text.contains("false-done rate"))
    }
}
