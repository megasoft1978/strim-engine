import Foundation
import Testing
import StrimEngine
import StrimTemplate
@testable import StrimHarness

@Suite struct TestProgressTests {
    @Test(arguments: [
        "go test -count=1 ./... 2>&1 | tail -20", "node --test | head", "bun test 2>&1 | grep fail",
        "cargo test --offline --quiet", "swift test --filter Foo", "pytest -q tests", "python3 -m pytest",
        "ruby -Ilib -Itest test/all_test.rb | tail", "rake test:units", "sh scripts/javatest.sh",
        "./scripts/javatest.sh", "tsc --noEmit | tail", "cd lib && env CI=1 go test ./...", "bash -c 'swift test | tail'",
    ]) func recognizesRunnersIncludingPipes(_ command: String) { #expect(TestCommand.isTest(command)) }

    @Test(arguments: ["echo 'go test ./...'", "grep 'bun test' README.md", "cat tests.txt | tail", "swift build", "git status", "ruby lib/run.rb", "go run main.go", "go run test", "cargo build --test sample"])
    func ignoresInspections(_ command: String) { #expect(!TestCommand.isTest(command)) }

    @Test func recognizesTaskVerify() {
        #expect(TestCommand.isTest("cd project && ./check --fast 2>&1 | head", verify: "./check --fast"))
        #expect(!TestCommand.isTest("echo './check --fast'", verify: "./check --fast"))
        #expect(!TestCommand.isTest("cd project && cat file", verify: "cd project && ./check --fast | tail"))
        #expect(TestCommand.isTest("./check --fast | head", verify: "cd project && ./check --fast | tail"))
    }

    @Test func signatureNormalizesTimingAndPathsButKeepsAssertionValuesAndNames() {
        func output(_ dir: String, _ line: Int, _ time: String) -> String {
            "--- FAIL: TestBytes/promotion (\(time)s)\n    \(dir)/bytes_test.go:\(line): got 1000 kB, want 1.00 MB\nFAIL package \(time)s"
        }
        let a = TestEvidence(output: output("/tmp/job-a", 12, "0.003"), exit: 1)
        let b = TestEvidence(output: output("/Users/test/job-b", 89, "9.123"), exit: 1)
        #expect(a.signature == b.signature)
        #expect(a.signature.contains("TestBytes/promotion"))
        #expect(a.signature.contains("1000 kB, want 1.00 MB"))
        #expect(!a.signature.contains("job-a") && !a.signature.contains("0.003"))
        #expect(a.signature != TestEvidence(output: output("/tmp/job-a", 12, "0.003").replacingOccurrences(of: "1000", with: "1024"), exit: 1).signature)
        #expect(a.signature != TestEvidence(output: output("/tmp/job-a", 12, "0.003").replacingOccurrences(of: "promotion", with: "rounding"), exit: 1).signature)
    }

    @Test func gateAllowsRunsNudgesOnceThenBlocksAndNeverClaimsDone() {
        var progress = TestProgress()
        progress.read(path: "src/bytes.go")
        let failure = TestEvidence(output: "--- FAIL: TestBytes\nbytes_test.go:10: got 1000, want 1", exit: 1)
        let a = progress.record(failure, gate: true, sourcePaths: [])
        #expect(a.note?.contains("failing assertion → source file/symbol → intended change") == true && a.blocked == nil)
        let idle = progress.takeThinkingTurn()
        #expect(!idle)
        let b = progress.record(failure, gate: true, sourcePaths: [])
        #expect(b.note?.contains("Unchanged evidence:") == true && b.note?.contains("src/bytes.go") == true)
        let recovery = progress.takeThinkingTurn()
        #expect(b.blocked == nil && recovery)
        let backedOff = progress.takeThinkingTurn()
        #expect(!backedOff)
        let c = progress.record(failure, gate: true, sourcePaths: [])
        #expect(c.note == nil && c.blocked?.hasPrefix("blocked:") == true)
    }

    @Test func editsSuccessAndChangedEvidenceResetTheStreak() {
        var p = TestProgress()
        let a = TestEvidence(output: "Expected: 1\nActual: 2", exit: 1)
        let b = TestEvidence(output: "Expected: 3\nActual: 2", exit: 1)
        _ = p.record(a, gate: true, sourcePaths: [])
        p.edited()
        #expect(p.editedSinceTest)
        _ = p.record(a, gate: true, sourcePaths: [])
        #expect(!p.editedSinceTest && p.unchangedFailures == 1)
        _ = p.record(b, gate: true, sourcePaths: [])
        #expect(p.unchangedFailures == 1)
        _ = p.record(TestEvidence(output: "ok", exit: 0), gate: true, sourcePaths: [])
        #expect(p.unchangedFailures == 0)
        _ = p.record(b, gate: false, sourcePaths: [])
        #expect(p.unchangedFailures == 1)
        _ = p.record(b, gate: false, sourcePaths: [])
        let recovery = p.takeThinkingTurn()
        #expect(recovery)
        p.stallNudged()
        let nudged = p.takeThinkingTurn()
        let backedOff = p.takeThinkingTurn()
        #expect(nudged && !backedOff)
    }

    @Test func digestsForFiveRunners() {
        let fixtures: [(String, String, Int?, Int?)] = [
            ("--- FAIL: TestBytes (0.01s)\n bytes_test.go:13: got 1000, want 1\nFAIL example 0.01s", "TestBytes", nil, 1),
            ("not ok 2 - rounds bytes\n  expected: 1\n  actual: 1000\n  stack: 'src/bytes.test.js:18:3'\n# pass 4\n# fail 1", "rounds bytes", 4, 1),
            ("(fail) rounds bytes\nExpected: 1\nReceived: 1000\n at src/bytes.test.ts:18:3\n 4 pass\n 1 fail", "rounds bytes", 4, 1),
            ("test bytes::rounds ... FAILED\nthread panicked at src/bytes.rs:18:3\nassertion `left == right` failed\n left: 1000\n right: 1\ntest result: FAILED. 4 passed; 1 failed; 0 ignored", "bytes::rounds", 4, 1),
            ("Test Case '-[BytesTests testRounds]' failed (0.003 seconds).\n/tmp/project/BytesTests.swift:18: error: XCTAssertEqual failed: (1000) is not equal to (1)\nExecuted 5 tests, with 1 failure (0 unexpected) in 0.003 seconds", "testRounds", 4, 1),
        ]
        for (output, name, pass, fail) in fixtures {
            let e = TestEvidence(output: output, exit: 1)
            #expect(e.isFailure && e.names.joined().contains(name))
            #expect(e.passed == pass && e.failed == fail)
            #expect(e.digest.contains("exit code: 1") && e.digest.contains("1000") && e.digest.contains("refs:"))
            #expect(e.digest.utf8.count <= 1500)
        }
        let piped = TestEvidence(output: "(fail) rounds bytes\n1 fail", exit: 0)
        #expect(TestEvidence(output: "bytes_test.go:3: undefined: NewBytes", exit: 0).isFailure)
        #expect(!TestEvidence(output: "# pass 5\n# fail 0\n", exit: 0).isFailure)
        #expect(piped.isFailure) // The plain mode gate still recognizes a masked failure.
        let huge = TestEvidence(output: String(repeating: "Expected: " + String(repeating: "x", count: 1200) + "\n", count: 50), exit: 1)
        #expect(huge.digest.utf8.count <= 1500)
    }

    @Test func knobJSONRoundTripAndDefaultBytes() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacy = #"{"reasoningEffort":"medium","result_shape":"head_tail","seed":20261027,"stall_nudge":"off","temperature":0,"thinking":"off"}"#
        #expect(String(decoding: try encoder.encode(HarnessKnobs()), as: UTF8.self) == legacy)
        let k = try HarnessKnobs.decode(Data(#"{"progress_gate":"on","test_status":"structured","thinking":"on_stall","reasoningEffort":"high","resultCapChars":999999}"#.utf8))
        #expect(k.progress_gate == .on && k.test_status == .structured && k.thinking == .onStall && k.toolOutputCap == 8000)
        #expect(try HarnessKnobs.decode(encoder.encode(k)) == k)
        for bad in [#"{"progress_gate":true}"#, #"{"test_status":"on"}"#] {
            #expect(throws: DecodingError.self) { try HarnessKnobs.decode(Data(bad.utf8)) }
        }
    }
}

private struct ProgressTool: HarnessTool {
    let name: String
    var spec: ToolSpec { ToolSpec(name: name, description: "fake", parameters: .ordered([])) }
    func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult {
        let error = args["error"] == .bool(true)
        return ToolResult(output: args["output"]?.stringValue ?? "ok", isError: error)
    }
}

@Suite struct ProgressLoopTests {
    private let failure = "--- FAIL: TestBytes (0.01s)\nbytes_test.go:10: got 1000, want 1\n[exit code: 1]"
    private func call(_ engine: FakeEngine, _ name: String, _ args: [(String, OrderedJSON)] = []) {
        engine.script([.event(.toolCallBegin(name: name))] + args.map { .event(.toolCallArg(key: $0.0, value: $0.1)) }
                      + [.event(.toolCallEnd), .event(.finished(.stop, makeUsage()))])
    }
    private func test(_ engine: FakeEngine, command: String = "go test ./... | tail", output: String? = nil) {
        call(engine, "bash", [("command", .string(command)), ("output", .string(output ?? failure)), ("error", .bool(true))])
    }
    private func run(_ engine: FakeEngine, knobs: HarnessKnobs) async -> HarnessJobResult {
        let root = "/tmp/pg1/fake-workspace"
        let loop = AgentLoop(engine: engine, tools: [ProgressTool(name: "bash"), ProgressTool(name: "edit_file"), ProgressTool(name: "write_file"), ProgressTool(name: "read_file")], systemPrompt: "SYS", knobs: knobs)
        return await loop.run(spec: HarnessJobSpec(task: "fix bytes", cwd: root, files: ["bytes.go"], access: .write), workspace: Workspace(root: root, base: "base"), onEvent: { _ in })
    }
    private func outputs(_ engine: FakeEngine) -> [String] {
        engine.snapshot { e in e.appends.flatMap { _, input -> [String] in
            let messages: [Message]
            switch input { case .messages(let m), .history(let m): messages = m; default: return [] }
            return messages.compactMap { m in guard m.role == .tool, case .text(let t) = m.content else { return nil }; return t }
        } }
    }

    @Test func threeIdenticalCallsActuallyExecuteAndBlock() async {
        let e = FakeEngine()
        for _ in 0..<3 { test(e) }
        let r = await run(e, knobs: HarnessKnobs(progress_gate: .on))
        #expect(r.status == .failed && r.summary.hasPrefix("blocked:"))
        #expect(r.commands.count == 3 && r.commands.allSatisfy { $0.exit == 1 })
        #expect(r.usage.turns == 3)
        #expect(outputs(e).filter { $0.contains("Unchanged evidence:") }.count == 1)
        #expect(outputs(e).contains { $0.contains("bytes.go") })
    }

    @Test func onStallAloneKeepsIdenticalCallGuard() async {
        let e = FakeEngine()
        test(e)
        let r = await run(e, knobs: HarnessKnobs(thinking: .onStall))
        #expect(r.status == .limit && r.summary.contains("aborted: identical bash call repeated"))
        #expect(r.commands.count == 3)
        #expect(outputs(e).contains { $0.contains("Do not repeat") })
    }

    @Test func refusedTestsAreNotFailureEvidence() async {
        let e = FakeEngine()
        for _ in 0..<3 { test(e, output: "bash: refused: toolchain guard") }
        call(e, "finish", [("summary", .string("finished"))])
        let r = await run(e, knobs: HarnessKnobs(stall_nudge: .on, progress_gate: .on, test_status: .structured))
        #expect(r.status == .done && r.summary == "finished")
        #expect(r.commands.count == 3)
        #expect(!outputs(e).contains { $0.contains("[test status]") || $0.contains("[harness progress gate]") || $0.contains("stall") })
    }

    @Test(arguments: ["edit_file", "write_file"])
    func onlySuccessfulEditsResetGate(_ tool: String) async {
        for failedEdit in [false, true] {
            let e = FakeEngine()
            test(e)
            call(e, tool, [("error", .bool(failedEdit))])
            test(e, command: "go test ./... | head")
            test(e, command: "go test ./... | grep FAIL")
            call(e, "finish", [("summary", .string("blocked")), ("status", .string("failed"))])
            let r = await run(e, knobs: HarnessKnobs(progress_gate: .on))
            #expect(failedEdit ? r.summary.hasPrefix("blocked:") : r.summary == "blocked")
            #expect(r.status == .failed)
        }
    }

    @Test func onStallTurnsThinkingOnOnceThenBackOff() async {
        let e = FakeEngine()
        test(e); test(e, command: "go test ./... | head")
        call(e, "read_file", [("path", .string("bytes.go"))])
        call(e, "edit_file")
        call(e, "finish", [("summary", .string("blocked")), ("status", .string("failed"))])
        let r = await run(e, knobs: HarnessKnobs(thinking: .onStall, reasoningEffort: "high"))
        #expect(r.usage.turns == 5)
        let budgets = e.snapshot { $0.generates.map { $0.params.maxTokens } }
        #expect(budgets == [4096, 4096, HarnessKnobs.thinkingTurnTokens, 4096, 4096])
        let configs = e.snapshot { $0.opened.map { $0.1 } }
        #expect(configs.count == 3 && configs[0].enableThinking != true && configs[1].enableThinking == true && configs[2].enableThinking != true)
        #expect(configs[1].reasoningEffort == "high")
        #expect(e.snapshot { $0.opened.count == $0.closed.count })
        #expect(outputs(e).contains { $0.contains("TestBytes") }) // Evidence survives replay.
    }

    @Test func stallNudgeAlsoTriggersOneRecoveryTurn() async {
        let e = FakeEngine()
        test(e); call(e, "edit_file"); test(e); call(e, "write_file"); test(e)
        call(e, "read_file", [("path", .string("bytes.go"))]); call(e, "finish", [("summary", .string("done"))])
        let r = await run(e, knobs: HarnessKnobs(thinking: .onStall, stall_nudge: .on))
        #expect(r.status == .done)
        #expect(e.snapshot { $0.generates.map { $0.params.maxTokens } } == [4096, 4096, 4096, 4096, 4096, 8192, 4096])
    }
}

@Suite struct StructuredExecutionTests {
    private func dir() throws -> URL {
        let d = URL(fileURLWithPath: "/tmp/pg1").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func pipefailPreservesFailureAndCommandGuard() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        try Data("#!/bin/sh\nprintf 'not ok 1 - failure\\nexpected: 1\\nactual: 2\\n'\nexit 7\n".utf8).write(to: d.appendingPathComponent("javatest.sh"))
        let runner = BashTool.makeRunner(workspaceRoot: d.path, access: .write, jobTmp: d.appendingPathComponent("tmp").path, sandboxed: false)
        let tool = BashTool(runner: runner)
        let context = ToolContext(root: d.path, access: .write)
        let args: [String: OrderedJSON] = ["command": .string("sh javatest.sh 2>&1 | tail -3")]
        let plain = try await tool.run(args, context: context)
        let structured = try await tool.run(args, context: context, structuredTest: true)
        #expect(plain.output.hasSuffix("[exit code: 0]") && !plain.isError)
        #expect(structured.output.hasSuffix("[exit code: 7]") && structured.isError)
        let refused = try await tool.run(["command": .string("node -e 'process.exit(0)' | tail")], context: context, structuredTest: true)
        #expect(refused.isError && refused.output.contains("refused"))
    }

    @Test func loopStructuredModePreservesRealStatusAndRawCap() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let script = "sh check.sh"
        try Data("printf 'not ok 1 - rounds bytes\\nexpected: 1\\nactual: 1000\\n'\nexit 9\n".utf8).write(to: d.appendingPathComponent("check.sh"))
        let runner = BashTool.makeRunner(workspaceRoot: d.path, access: .write, jobTmp: d.appendingPathComponent("tmp").path, sandboxed: false)
        let e = FakeEngine()
        e.script([.event(.toolCallBegin(name: "bash")), .event(.toolCallArg(key: "command", value: .string(script + " | tail -3"))), .event(.toolCallEnd), .event(.finished(.stop, makeUsage()))])
        e.script([.event(.toolCallBegin(name: "finish")), .event(.toolCallArg(key: "summary", value: .string("blocked"))), .event(.toolCallArg(key: "status", value: .string("failed"))), .event(.toolCallEnd), .event(.finished(.stop, makeUsage()))])
        let loop = AgentLoop(engine: e, tools: [BashTool(runner: runner)], systemPrompt: "SYS", knobs: HarnessKnobs(resultCapChars: 200, test_status: .structured))
        let r = await loop.run(spec: HarnessJobSpec(task: "fix", cwd: d.path, access: .write, verify: script), workspace: Workspace(root: d.path, base: "abc"), onEvent: { _ in })
        #expect(r.status == .failed && r.commands == [CommandRecord(cmd: script + " | tail -3", exit: 9)])
        let outputs = e.snapshot { f in f.appends.flatMap { _, input -> [String] in
            guard case .messages(let messages) = input else { return [] }
            return messages.compactMap { m in guard m.role == .tool, case .text(let t) = m.content else { return nil }; return t }
        } }
        let output = try #require(outputs.first)
        #expect(output.hasPrefix("[test status] exit code: 9"))
        #expect(output.contains("rounds bytes") && output.contains("actual: 1000"))
        #expect(output.components(separatedBy: "\n\n").last!.count <= 200)
    }

    @Test func trackedShellEditAndReadOnlyCommandSnapshots() async throws {
        let d = try dir(); defer { try? FileManager.default.removeItem(at: d) }
        let git = try GitWorktreeIsolation.gitExecutable()
        for args in [["init", "-q"], ["add", "source.go"]] {
            if args.first == "add" { try Data("one".utf8).write(to: d.appendingPathComponent("source.go")) }
            let r = try await GitWorktreeIsolation.exec(git, GitWorktreeIsolation.hardening + args, cwd: d.path, env: GitWorktreeIsolation.env, timeout: 5, maxOut: 1000)
            #expect(r.status == 0)
        }
        let snapshot = await TrackedFileSnapshot.load(root: d.path)
        #expect(snapshot.paths == ["source.go"])
        let before = snapshot.capture()
        #expect(before == snapshot.capture())
        let runner = BashTool.makeRunner(workspaceRoot: d.path, access: .write, jobTmp: d.appendingPathComponent("tmp").path, sandboxed: false)
        let e = FakeEngine()
        for command in ["sh check.sh", "printf two > source.go", "sh check.sh", "sh check.sh"] {
            e.script([.event(.toolCallBegin(name: "bash")), .event(.toolCallArg(key: "command", value: .string(command))), .event(.toolCallEnd), .event(.finished(.stop, makeUsage()))])
        }
        e.script([.event(.toolCallBegin(name: "finish")), .event(.toolCallArg(key: "summary", value: .string("blocked after edit"))), .event(.toolCallArg(key: "status", value: .string("failed"))), .event(.toolCallEnd), .event(.finished(.stop, makeUsage()))])
        try Data("printf 'Expected: 1\\nActual: 2\\n'\nexit 1\n".utf8).write(to: d.appendingPathComponent("check.sh"))
        let loop = AgentLoop(engine: e, tools: [BashTool(runner: runner)], systemPrompt: "SYS", knobs: HarnessKnobs(progress_gate: .on))
        let result = await loop.run(spec: HarnessJobSpec(task: "fix", cwd: d.path, access: .write, verify: "sh check.sh"), workspace: Workspace(root: d.path, base: "abc"), onEvent: { _ in })
        #expect(result.status == .failed && result.summary == "blocked after edit")
        #expect(result.commands.count == 4)
        #expect(before != snapshot.capture())

        // Test runners may rewrite tracked snapshots; that must not count as a source edit.
        try Data("printf x >> source.go\nprintf 'Expected: 1\\nActual: 2\\n'\nexit 1\n".utf8).write(to: d.appendingPathComponent("check.sh"))
        let e2 = FakeEngine()
        for _ in 0..<3 {
            e2.script([.event(.toolCallBegin(name: "bash")), .event(.toolCallArg(key: "command", value: .string("sh check.sh"))), .event(.toolCallEnd), .event(.finished(.stop, makeUsage()))])
        }
        let loop2 = AgentLoop(engine: e2, tools: [BashTool(runner: runner)], systemPrompt: "SYS", knobs: HarnessKnobs(progress_gate: .on))
        let result2 = await loop2.run(spec: HarnessJobSpec(task: "fix", cwd: d.path, access: .write, verify: "sh check.sh"), workspace: Workspace(root: d.path, base: "abc"), onEvent: { _ in })
        #expect(result2.status == .failed && result2.summary.hasPrefix("blocked:"))
        #expect(result2.commands.count == 3)
        #expect(try String(contentsOf: d.appendingPathComponent("source.go"), encoding: .utf8) == "twoxxx")
    }
}
