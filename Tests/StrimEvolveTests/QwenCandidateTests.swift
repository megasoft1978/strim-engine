import Foundation
import Testing
import StrimHarness
@testable import StrimAgentBench
@testable import StrimEvolve

@Suite struct QwenCandidateTests {
    static let full = #"{"system_prompt":"ambitious","context":"long","thinking":"all_turns_xhigh","sampling":"qwen","preserve_thinking":"on"}"#

    @Test func allNewVariantsRoundTripAndReachHarness() throws {
        let c = try PairedEvaluation.decode(Self.full)
        #expect(c.systemPrompt == .ambitious && c.context == .long && c.thinking == .allTurnsXhigh && c.sampling == .qwen && c.preserveThinking == .on)
        #expect(try JSONDecoder().decode(PackCandidate.self, from: Canonical.json(c)) == c)
        let k = try HarnessKnobs.decode(Canonical.json(PackLibrary.render(c).knobs))
        #expect(k.context == .long && k.thinking == .allTurns && k.reasoningEffort == "xhigh" && k.sampling == .qwen && k.preserve_thinking == .on)
        #expect(PackLibrary.render(c).knobs.decoding == "sampled")
        for coordinate in [Coordinate.context, .thinking, .sampling, .preserveThinking] {
            for variant in coordinate.variants(of: .baseline) {
                #expect(try JSONDecoder().decode(PackCandidate.self, from: Canonical.json(variant)) == variant)
                _ = try HarnessKnobs.decode(Canonical.json(PackLibrary.render(variant).knobs))
                if variant != .baseline { #expect(PackLibrary.fingerprint(variant) != PackLibrary.fingerprint(.baseline)) }
            }
        }
    }

    @Test func explicitDefaultKeysKeepLegacyBytes() throws {
        for raw in ["{}", #"{"thinking":"all_turns_medium","temperature":"warm"}"#, #"{"system_prompt":"verify_first","progress_gate":"on","thinking":"on_stall_medium"}"#] {
            let c = try PairedEvaluation.decode(raw)
            var object = try #require(JSONSerialization.jsonObject(with: Canonical.json(c)) as? [String: Any])
            object["context"] = "standard"; object["sampling"] = "greedy"; object["preserve_thinking"] = "off"
            let explicit = try JSONDecoder().decode(PackCandidate.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(Canonical.json(explicit) == Canonical.json(c))
            #expect(Canonical.json(PackLibrary.render(explicit).knobs) == Canonical.json(PackLibrary.render(c).knobs))
            #expect(PackLibrary.fingerprint(explicit) == PackLibrary.fingerprint(c))
        }
    }

    @Test func ambitiousReplacesDeclinesAndKeepsSafetyAndWorkflow() throws {
        let c = try PairedEvaluation.decode(#"{"system_prompt":"ambitious"}"#)
        let p = PackLibrary.render(c)
        for text in ["sandbox workspace root", "No network", "no way to verify", "short numbered plan", "running checklist", "Read before editing", "all needed files", "re-read the source named in the failure", "Never touch tests when", "verification passes", "report blocked honestly"] {
            #expect(p.system.contains(text), "ambitious is missing \(text)")
        }
        for text in ["6 files", "100 changed lines", "needs design", "best at small"] { #expect(!p.system.contains(text)) }
        #expect(p.guardrails == PackLoader.shipped().guardrails && p.toolGuidance == PackLoader.shipped().toolGuidance)
    }

    @Test func effortAliasesAreSupportedByTheTemplate() {
        for t in [ThinkingPolicy.allTurnsHigh, .allTurnsXhigh, .onStallHigh, .onStallXhigh] {
            #expect(t.reasoningEffort == "xhigh")
        }
        #expect(ThinkingPolicy.onStallHigh.harnessValue == "on_stall")
        #expect(ThinkingPolicy.allTurnsHigh.harnessValue == "all_turns")
    }

    @Test func livePackUsesEachRowSeedEvenWhenFingerprintIsReused() throws {
        let root = URL(fileURLWithPath: "/tmp/qk1/seed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("task")
        try FileManager.default.createDirectory(at: taskDir.appendingPathComponent("snapshot"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: taskDir.appendingPathComponent("snapshot/a.txt"))
        let task = LoadedTask(spec: TaskSpec(id: "q", taskClass: "repo-qa", prompt: "answer ok",
                                             expectedAnswer: ExpectedAnswer(allOf: ["^ok$"])), dir: taskDir)
        let live = root.appendingPathComponent("live")
        let executor = QwenSeedExecutor(live: live)
        let runner = BenchTaskRunner(tasks: [task], executor: executor, liveDir: live,
                                     workRoot: root.appendingPathComponent("work"), outDir: root.appendingPathComponent("out"))
        let c = try PairedEvaluation.decode(Self.full)
        for (rep, seed) in [(1, UInt64(42)), (2, UInt64(99))] {
            let request = TaskRunRequest(candidate: c, fingerprint: PackLibrary.fingerprint(c), taskId: "q", taskClass: "repo-qa", split: .train, rep: rep, seed: seed)
            let result = runner.runSync(request)
            #expect(result.pass && !result.infraError)
        }
        #expect(executor.seeds == [42, 99])
        #expect(PackLibrary.render(c).knobs.seed == nil)
    }

    @Test func qwenRowsRecordSamplingAndSeed() throws {
        let c = try PairedEvaluation.decode(Self.full)
        let request = TaskRunRequest(candidate: c, fingerprint: PackLibrary.fingerprint(c), taskId: "t", taskClass: "test-fix", split: .train, rep: 1, seed: 77)
        let row = RowBuilder.row(for: request, result: TaskRunResult(pass: true, claimedDone: true), round: 0, coordinate: "sampling", phase: .paired, dryRun: true)
        #expect(row.seed == 77 && row.decoding == "sampled")
    }
}

private final class QwenSeedExecutor: ArmExecutor {
    let live: URL
    var seeds: [UInt64] = []
    init(live: URL) { self.live = live }
    func execute(_ ctx: RunContext) -> ArmOutcome {
        do {
            let knobs = try HarnessKnobs.decode(Data(contentsOf: live.appendingPathComponent("knobs.json")))
            seeds.append(knobs.seed)
            #expect(knobs.seed == ctx.seed && knobs.sampling == .qwen)
        } catch { Issue.record("cannot read live pack: \(error)") }
        var outcome = ArmOutcome(); outcome.claimedDone = true; outcome.answer = "ok"
        return outcome
    }
}
