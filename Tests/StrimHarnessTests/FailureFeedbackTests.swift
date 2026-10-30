import Foundation
import Testing
import StrimEngine
import StrimTemplate
@testable import StrimHarness

private struct FeedbackTool: HarnessTool {
    let name: String
    var spec: ToolSpec { ToolSpec(name: name, description: "fake", parameters: .ordered([])) }
    func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult {
        ToolResult(output: args["output"]?.stringValue ?? "edited", isError: args["error"] == .bool(true))
    }
}

@Suite struct FailureFeedbackTests {
    // Realistic excerpts from Go, Bun, Jest, Node, pytest, Ruby and Swift; volatile fields must not obscure the assertion.
    static let fixtures = [
        "--- FAIL: TestBytes (0.01s)\n    bytes_test.go:12: got 1000 kB, want 1 MB\nFAIL\n[exit code: 1]",
        "error: expect(received).toBe(expected)\nExpected: 2\nReceived: 1\n(fail) adds [1.25ms]\n[exit code: 1]",
        "FAIL src/math.test.js\n  expect(received).toBe(expected)\n  Expected: 2\n  Received: 1\nTime: 1.25 s\n[exit code: 1]",
        "not ok 1 - adds\n  duration_ms: 1.25\n  error: '1 == 2'\n  code: 'ERR_ASSERTION'\n[exit code: 1]",
        "FAILED test_math.py::test_add - AssertionError: assert 1 == 2\n1 failed in 0.15s\n[exit code: 1]",
        "  1) Failure:\nTestOrdinal#test_suffix [/tmp/job-a/test.rb:12]:\nExpected: 11th\n  Actual: 11st\nFinished in 0.01 seconds.\n[exit code: 1]",
        "2026-10-30 10:12:13.456 Test[0x123abc] error: /tmp/job-a/Test.swift:12: XCTAssertEqual failed: (1) is not equal to (2)\nTest Case 'adds' failed (0.001 seconds).\n[exit code: 1]",
    ]

    @Test(arguments: fixtures)
    func signaturesIgnoreVolatileFields(_ fixture: String) throws {
        let changed = fixture.replacingOccurrences(of: "0.01", with: "7.89")
            .replacingOccurrences(of: "1.25", with: "99.75")
            .replacingOccurrences(of: "0.15", with: "18.25")
            .replacingOccurrences(of: "0.001", with: "3.456")
            .replacingOccurrences(of: "2026-10-30 10:12:13.456", with: "2027-01-12 20:11:10.123")
            .replacingOccurrences(of: "0x123abc", with: "0xff9988")
            .replacingOccurrences(of: "/tmp/job-a", with: "/private/var/folders/ab/random/T/job-b")
        let sig = try #require(FailureFeedback.signature(output: fixture, exitCode: 1))
        #expect(sig == FailureFeedback.signature(output: changed, exitCode: 1))
        #expect(sig.hasPrefix("exit code: 1 | "))
    }

    @Test(arguments: fixtures)
    func differentAssertionsHaveDifferentSignatures(_ fixture: String) {
        // Include the Go got/want continuation and Ruby Expected continuation in the comparison.
        let changed = fixture.replacingOccurrences(of: "1000 kB", with: "999 kB")
            .replacingOccurrences(of: "Expected: 2", with: "Expected: 3")
            .replacingOccurrences(of: "1 == 2", with: "1 == 3")
            .replacingOccurrences(of: "Expected: 11th", with: "Expected: 12th")
            .replacingOccurrences(of: "equal to (2)", with: "equal to (3)")
        #expect(fixture != changed)
        #expect(FailureFeedback.signature(output: fixture, exitCode: 1) != FailureFeedback.signature(output: changed, exitCode: 1))
    }

    @Test func successesAndUndiagnosedFailuresHaveNoSignature() {
        #expect(FailureFeedback.signature(output: "error: old log", exitCode: 0) == nil)
        #expect(FailureFeedback.signature(output: "building...\n[exit code: 1]", exitCode: 1) == nil)
        #expect(FailureFeedback.signature(output: "error: bad", exitCode: 1) != FailureFeedback.signature(output: "error: bad", exitCode: 2))
    }

    @Test func assertionDurationsRemainDistinct() {
        for (first, second) in [("expected 5 seconds, got 7 seconds", "expected 5 seconds, got 9 seconds"),
                                ("got 100ms want 200ms", "got 100ms want 300ms")] {
            #expect(FailureFeedback.signature(output: "error: " + first, exitCode: 1) !=
                    FailureFeedback.signature(output: "error: " + second, exitCode: 1))
        }
    }

    @Test func oversizedSingleLineIsBounded() {
        let output = "error: START " + String(repeating: "x", count: 5_000_000) + " TAIL"
        let start = ContinuousClock.now
        let signature = FailureFeedback.signature(output: output, exitCode: 1)
        let shaped = FailureFeedback.shape(output, tool: "bash", exitCode: 1, shape: .errorsFirst, cap: 1500)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(signature != nil && signature!.components(separatedBy: " | ").dropFirst().allSatisfy { $0.count <= 400 })
        #expect(shaped.count <= 1500 && shaped.contains("START"))
        let middle = String(repeating: "x", count: 300_000) + "\nerror: MIDDLE\n" + String(repeating: "x", count: 300_000)
        #expect(FailureFeedback.signature(output: middle, exitCode: 1) == nil)
        #expect(!FailureFeedback.shape(middle, tool: "bash", exitCode: 1, shape: .errorsFirst, cap: 1500).contains("MIDDLE"))
    }

    @Test func oversizedSuccessUsesStandardCompaction() {
        let output = "START\n" + String(repeating: "verbose output\n", count: 1000) + "0 failed\nEND"
        #expect(FailureFeedback.shape(output, tool: "bash", exitCode: 0, shape: .errorsFirst, cap: 200)
                == Compaction.capToolOutput(output, cap: 200))
    }

    @Test func recurrenceRequiresEditsAndIsThrottledPerSignature() throws {
        var tracker = StallTracker()
        #expect(tracker.note(signature: "assertion A", turn: 1) == nil)
        tracker.edited()
        #expect(tracker.note(signature: "assertion A", turn: 3) == nil)
        tracker.edited(); tracker.edited()
        let pending = tracker.note(signature: "assertion A", turn: 5)
        let note = try #require(pending)
        #expect(note == "[harness] Same failure as turn 3 after 2 edits: assertion A. Stop and re-check the root cause before editing again.")
        tracker.edited()
        #expect(tracker.note(signature: "assertion A", turn: 6) == nil)
        tracker.edited()
        #expect(tracker.note(signature: "assertion A", turn: 7) == nil)
        tracker.edited()
        #expect(tracker.note(signature: "assertion A", turn: 8) != nil)
        #expect(tracker.note(signature: "assertion A", turn: 12) == nil)
        #expect(tracker.note(signature: "assertion B", turn: 13) == nil)
        #expect(tracker.note(signature: nil, turn: 14) == nil)
    }

    private static var longOutput: String {
        (0..<500).map { i in
            switch i {
            case 90: return "context before first"
            case 92: return "AssertionError: FIRST expected 11th got 11st"
            case 94: return "context after first"
            case 180: return "error: SECOND mismatch"
            case 280: return "error: THIRD mismatch"
            case 499: return "TAIL SUMMARY: 3 failures"
            default: return "verbose log line \(i) padding padding padding"
            }
        }.joined(separator: "\n") + "\n[exit code: 1]"
    }

    @Test(arguments: [200, 1500, 8000])
    func errorsFirstKeepsDiagnosticTailAndBudget(_ cap: Int) {
        let shaped = FailureFeedback.shape(Self.longOutput, tool: "bash", exitCode: 1, shape: .errorsFirst, cap: cap)
        #expect(shaped.hasPrefix("exit code: 1\n"))
        #expect(shaped.contains("FIRST"))
        #expect(shaped.contains("TAIL SUMMARY: 3 failures"))
        #expect(shaped.contains("lines elided ...]"))
        #expect(shaped.count <= cap)
        if cap >= 1500 {
            for text in ["context before first", "context after first", "SECOND", "THIRD"] { #expect(shaped.contains(text)) }
        }
    }

    @Test func giantLinesAndNoDiagnosticsRespectBudget() {
        for output in ["error: " + String(repeating: "x", count: 30_000) + "\nTAIL\n[exit code: 1]",
                       String(repeating: "boring\n", count: 1000) + "TAIL\n[exit code: 1]"] {
            let shaped = FailureFeedback.shape(output, tool: "bash", exitCode: 1, shape: .errorsFirst, cap: 200)
            #expect(shaped.count <= 200)
            #expect(shaped.contains("TAIL"))
            #expect(shaped.contains("exit code: 1"))
        }
    }

    @Test func shortNonBashAndDefaultOutputsKeepExistingBytes() {
        let short = "error: small\n[exit code: 1]"
        #expect(FailureFeedback.shape(short, tool: "bash", exitCode: 1, shape: .errorsFirst, cap: 1500) == short)
        for tool in ["read_file", "grep", "edit_file", "write_file"] {
            #expect(FailureFeedback.shape(Self.longOutput, tool: tool, exitCode: 1, shape: .errorsFirst, cap: 1500)
                    == Compaction.capToolOutput(Self.longOutput, cap: 1500))
        }
        #expect(FailureFeedback.shape(Self.longOutput, tool: "bash", exitCode: 1, shape: .headTail, cap: 1500)
                == Compaction.capToolOutput(Self.longOutput, cap: 1500))
    }

    private func script(_ engine: FakeEngine, _ name: String, output: String = "edited", error: Bool = false) {
        engine.script([.event(.toolCallBegin(name: name)),
                       .event(.toolCallArg(key: "command", value: .string("test"))),
                       .event(.toolCallArg(key: "output", value: .string(output))),
                       .event(.toolCallArg(key: "error", value: .bool(error))),
                       .event(.toolCallEnd), .event(.finished(.stop, makeUsage()))])
    }

    private func run(_ knobs: HarnessKnobs, failedEdits: Bool = false) async -> (HarnessJobResult, [String]) {
        let engine = FakeEngine()
        for i in 0..<4 {
            script(engine, "bash", output: Self.longOutput, error: true)
            if i < 3 { script(engine, i == 1 ? "write_file" : "edit_file", error: failedEdits) }
        }
        engine.script([.event(.tokens([1], "done")), .event(.finished(.stop, makeUsage()))])
        let loop = AgentLoop(engine: engine, tools: [FeedbackTool(name: "bash"), FeedbackTool(name: "edit_file"), FeedbackTool(name: "write_file")],
                             systemPrompt: "SYS", knobs: knobs)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let result = await loop.run(spec: HarnessJobSpec(task: "fix", cwd: root, context: nil, access: .write),
                                    workspace: Workspace(root: root, base: "abc"), onEvent: { _ in })
        let outputs: [String] = engine.snapshot { f in f.appends.flatMap { _, input -> [String] in
            guard case let .messages(messages) = input else { return [] }
            return messages.compactMap { m in
                guard m.role == .tool, case let .text(t) = m.content else { return nil }
                return t
            }
        } }
        return (result, outputs)
    }

    @Test func knobsJSONReachesAgentLoopAndPreservesCommandRecords() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knobs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"stall_nudge":"on","result_shape":"errors_first","resultCapChars":1500}"#.utf8)
            .write(to: dir.appendingPathComponent("knobs.json"))
        let knobs = try #require(try PackLoader.knobs(inDirectory: dir))
        let (result, outputs) = await run(knobs)
        #expect(result.status == .done)
        #expect(result.commands.count == 4 && result.commands.allSatisfy { $0.exit == 1 })
        let bash = outputs.filter { $0.hasPrefix("exit code:") }
        #expect(bash.count == 4)
        #expect(bash.allSatisfy { $0.contains("FIRST") && $0.contains("TAIL SUMMARY") })
        #expect(outputs.filter { $0.contains("[harness]") }.count == 1)
        #expect(bash[2].contains("[harness] Same failure as turn 3 after 1 edits:"))
        #expect(bash[2].components(separatedBy: "\n\n[harness]")[0].count <= 1500)
        #expect(!bash[0].contains("[harness]") && !bash[1].contains("[harness]") && !bash[3].contains("[harness]"))
    }

    @Test func defaultsAndFailedEditsNeverNudge() async {
        let (result, outputs) = await run(HarnessKnobs())
        #expect(result.status == .done)
        #expect(!outputs.contains { $0.contains("[harness]") })
        let (_, failed) = await run(HarnessKnobs(stall_nudge: .on), failedEdits: true)
        #expect(!failed.contains { $0.contains("[harness]") })
    }

    @Test func newKnobsRejectUnsupportedValuesAndTypes() {
        for bad in [#"{"stall_nudge":true}"#, #"{"stall_nudge":"always"}"#, #"{"result_shape":"tail"}"#] {
            #expect(throws: DecodingError.self) { try HarnessKnobs.decode(Data(bad.utf8)) }
        }
        #expect(HarnessKnobs().stall_nudge == .off && HarnessKnobs().result_shape == .headTail)
    }
}
