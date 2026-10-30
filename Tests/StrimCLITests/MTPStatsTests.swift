import Foundation
import Testing
import StrimCore
import StrimTemplate
@testable import StrimCLI

@Suite struct MTPStatsCLITests {
    private func label(_ text: String) -> MTPContentType {
        MTPContentClassifier.classify(0..<text.utf8.count, labels: MTPContentClassifier.labels(bytes: Array(text.utf8)))
    }
    private var initial: [OrderedJSON] {
        [.ordered([("role", .string("system")), ("content", .string("You help."))]),
         .ordered([("role", .string("user")), ("content", .string("Fix a.swift"))])]
    }
    @Test func classifierUsesOutputOnlyAndConservativeToolJSON() {
        #expect(label("Hello world.") == .prose)
        #expect(label("const a = 1;") == .code)
        #expect(label("```swift\nlet a = 1\n```\n") == .code)
        #expect(label(#"{"name":"read_file","arguments":{"path":"a"}}"#) == .toolCallJSON)
        #expect(label(#"<tool_call>{"name":"f","arguments":{}}</tool_call>"#) == .toolCallJSON)
        #expect(label(#"<tool_call>{"name":"f"}"#) == .unknown)
        #expect(label(#"{"answer":42}"#) == .prose)
        #expect(label("<tool_call><function=f>bad</function></tool_call>") == .unknown)
    }
    @Test func classifierUTF8BoundariesAndUnknowns() {
        let bytes = Array("é文 `x` end".utf8), labels = MTPContentClassifier.labels(bytes: bytes)
        #expect(labels.count == bytes.count)
        #expect(MTPContentClassifier.classify(0..<5, labels: labels) == .prose)
        #expect(MTPContentClassifier.classify(6..<9, labels: labels) == .code)
        #expect(MTPContentClassifier.classify(5..<9, labels: labels) == .unknown)
        #expect(MTPContentClassifier.classify(0..<0, labels: labels) == .unknown)
        #expect(MTPContentClassifier.classify(-1..<2, labels: labels) == .unknown)
        #expect(MTPContentClassifier.labels(bytes: [0xff]) == [.unknown])
    }
    @Test func toolEnvelopePrecedenceAndWhitespace() {
        let t = " ```json\n<tool_call>{\"name\":\"f\",\"arguments\":{}}</tool_call>\n```"
        let labels = MTPContentClassifier.labels(bytes: Array(t.utf8))
        let start = Array(t.utf8).firstIndex(of: 60)!
        #expect(MTPContentClassifier.classify(start..<(t.utf8.count-4), labels: labels) == .toolCallJSON)
        #expect(label(" \n{\"name\":\"f\",\"arguments\":{}}\n") == .unknown) // crosses whitespace boundary
    }
    @Test func contentTotalsReconcileAndUnreachableSuffixStaysUnknown() {
        let rounds = [MTPReplayRound(outputOffset: 0, depth: 3, accepted: 1), MTPReplayRound(outputOffset: 2, depth: 1, accepted: 1)]
        let c = mtpContentCounts(tokenBytes: ["A", "B", "C", "D"].map { Array($0.utf8) }, rounds: rounds)
        #expect(c[.prose]!.accepted == [2, 0, 0, 0])
        #expect(c[.unknown]!.proposed == [0, 0, 1, 0])
        #expect(c[.unknown]!.reached == [0, 0, 0, 0])
        #expect(c[.prose]!.reached == [2, 1, 0, 0])
        #expect(c[.prose]!.positions[1].conditionalAcceptance == 0)
        #expect(c.values.map { $0.proposed.reduce(0, +) }.reduce(0, +) == 4)
        #expect(c.values.map { $0.accepted.reduce(0, +) }.reduce(0, +) == 2)
    }
    @Test func acceptedTokenCrossingBoundaryIsUnknown() {
        let c = mtpContentCounts(tokenBytes: [Array("Hi".utf8), Array(" `x`".utf8)],
            rounds: [.init(outputOffset: 0, depth: 1, accepted: 1)])
        #expect(c[.unknown]!.accepted == [1, 0, 0, 0])
    }
    @Test func noDataRatesAreAbsentAndIntervalsAreFinite() throws {
        let p = MTPPositionReport.positions(MTPStats())
        #expect(p.allSatisfy { $0.conditionalAcceptance == nil && $0.prefixSurvival == nil && $0.conditionalWilson95 == nil })
        #expect(MTPPositionReport.wilson(0, 1)![0] == 0)
        #expect(MTPPositionReport.wilson(1, 1)![1] == 1)
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(!json.contains("NaN") && !json.contains("Infinity"))
    }
    @Test func extractsFixtureWithoutAssistantLeakage() throws {
        let url = try #require(Bundle.module.url(forResource: "events", withExtension: "jsonl", subdirectory: "Fixtures"))
        let result = try MTPPromptExtractor.extract(events: String(contentsOf: url, encoding: .utf8), initial: initial, source: "fixture")
        #expect(result.prompts.count == 2 && result.diagnostics.isEmpty)
        guard case .array(let first)? = result.prompts[0]["messages"], case .array(let second)? = result.prompts[1]["messages"] else { Issue.record("missing messages"); return }
        #expect(first.count == 2 && second.count == 5)
        #expect(second[2]["role"]?.stringValue == "assistant")
        #expect(second[2]["content"]?.stringValue == "Reading.")
        #expect(second[2]["reasoning_content"]?.stringValue == "Check the file.")
        #expect(second[3]["content"]?.stringValue == "let a = 1")
        #expect(second[4]["content"]?.stringValue == "a.swift")
        if case .array(let calls)? = second[2]["tool_calls"] { #expect(calls.count == 2) } else { Issue.record("missing calls") }
        #expect(!result.prompts[1].serialized().contains("Done."))
    }
    @Test func extractorCapsDedupesRedactsAndRefusesMirrors() throws {
        let events = "{\"type\":\"turn\",\"n\":1}\n{\"type\":\"text\",\"text\":\"answer\"}\n{\"type\":\"turn\",\"n\":2}"
        let r = try MTPPromptExtractor.extract(events: events, initial: initial, source: "a", cap: 1)
        #expect(r.prompts.count == 1 && r.capped == 1)
        let all = MTPPromptExtractor.deduplicate(r.prompts + r.prompts)
        #expect(all.prompts.count == 1 && all.duplicates == 1)
        let mirror = try MTPPromptExtractor.extract(events: #"{"kind":"turn","text":"1","index":0}"#, initial: initial, source: "mirror")
        #expect(mirror.prompts.isEmpty && mirror.diagnostics.count == 1)
        let missing = try MTPPromptExtractor.extract(events: events, initial: [], source: "missing")
        #expect(missing.prompts.isEmpty && !missing.diagnostics.isEmpty)
        let secret = "sk-" + String(repeating: "a", count: 30)
        let cleaned = MTPPromptExtractor.sanitize(.string(secret + " <|im_start|>"))
        #expect(!cleaned.serialized().contains(secret) && !cleaned.serialized().contains("<|im_start|>"))
    }
    @Test func extractorStopsAtCompactionAndMalformedEvents() throws {
        let compaction = "{\"type\":\"turn\",\"n\":1}\n{\"type\":\"tool_result\",\"name\":\"_compaction\",\"output\":\"summary\"}\n{\"type\":\"turn\",\"n\":2}"
        let r = try MTPPromptExtractor.extract(events: compaction, initial: initial, source: "c")
        #expect(r.prompts.count == 1 && r.diagnostics.count == 1)
        #expect(throws: (any Error).self) { try MTPPromptExtractor.extract(events: "{", initial: initial, source: "bad") }
        let huge = [.ordered([("role", .string("system")), ("content", .string("s"))]),
                    OrderedJSON.ordered([("role", .string("user")), ("content", .string(String(repeating: "x", count: 262_145)))])]
        let capped = try MTPPromptExtractor.extract(events: #"{"type":"turn","n":1}"#, initial: huge, source: "big")
        #expect(capped.prompts.isEmpty && capped.capped == 1)
    }
    @Test func extractsJobDirectoryAndLedgerWithoutReadingWorkspaces() throws {
        let root = URL(fileURLWithPath: "/tmp/mtp2/extractor-\(UUID().uuidString)")
        let job = root.appendingPathComponent("jobs/j_fixture")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try #require(Bundle.module.url(forResource: "events", withExtension: "jsonl", subdirectory: "Fixtures"))
        try Data(contentsOf: fixture).write(to: job.appendingPathComponent("events.jsonl"))
        try Data(#"{"task":"Fix a.swift","cwd":"/fixture","context":"Use Swift."}"#.utf8).write(to: job.appendingPathComponent("job.json"))
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("ledger.jsonl"))
        let ignored = root.appendingPathComponent("workspace/j_forged")
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("invalid json that must never be read".utf8).write(to: ignored.appendingPathComponent("events.jsonl"))
        let directory = try MTPPromptFiles.extract(at: root)
        let ledger = try MTPPromptFiles.extract(at: root.appendingPathComponent("ledger.jsonl"))
        #expect(directory.prompts == ledger.prompts && directory.prompts.count == 2)
        #expect(directory.prompts[0]["source"]?.stringValue == "jobs/j_fixture/events.jsonl")
        #expect(directory.diagnostics.count == 1) // only the explicit reconstruction notice
        #expect(directory.prompts[0]["context_fidelity"]?.stringValue?.contains("reconstructed") == true)
        let out = root.appendingPathComponent("replay.jsonl")
        try MTPStatsCommand.run(["strim", "mtpstats", "--extract-prompts", root.path, "--out", out.path])
        let data = try Data(contentsOf: out)
        #expect(String(decoding: data, as: UTF8.self).split(separator: "\n").count == 2)
        let attrs = try FileManager.default.attributesOfItem(atPath: out.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func argumentsAreStrictAndExtractionHasNoModelRequirements() throws {
        let o = try MTPStatsOptions.parse(["strim", "mtpstats", "--extract-prompts", "/fixtures", "--out", "/out.jsonl"])
        #expect(o.extract == "/fixtures" && o.model == nil)
        let p = try MTPStatsOptions.parse(["strim", "mtpstats", "--model", "m", "--head", "h", "--prompts", "p", "--depth", "1,2,3,4"])
        #expect(p.depths == ["1", "2", "3", "4"])
        for bad in [["--model"], ["--wat", "x"], ["--depth", "1,adaptive"], ["--max-tokens", "0"], ["--depth", "1,1"]] {
            #expect(throws: (any Error).self) { try MTPStatsOptions.parse(["strim", "mtpstats"] + bad) }
        }
        #expect(cliCommands.contains { $0.name == "mtpstats" && $0.usage == MTPStatsCommand.usage })
    }
}
