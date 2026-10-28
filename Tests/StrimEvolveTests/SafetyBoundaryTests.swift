import CryptoKit
import Foundation
import Testing
@testable import StrimEvolve

/// The evolve code must not be able to change policy: the sources of the sandbox, workspace policy, redactor,
/// process runner and host policy are hashed before and after a full run on fake data.
@Suite struct SafetyBoundaryTests {
    static let guarded = [
        "Sources/StrimHarness/Sandbox.swift", "Sources/StrimHarness/WorkspacePolicy.swift", "Sources/StrimHarness/Redactor.swift",
        "Sources/StrimHarness/ProcessRunner.swift", "Sources/StrimHost/HostConfig.swift",
    ]

    static func hashes() -> [String: String] {
        let root = repoRoot()
        var out: [String: String] = [:]
        for p in guarded {
            let d = try? Data(contentsOf: root.appendingPathComponent(p))
            out[p] = d.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "MISSING"
        }
        return out
    }

    @Test func guardedFilesExist() {
        for (p, h) in Self.hashes() { #expect(h != "MISSING", "\(p) moved: update the guarded list") }
        let hostPolicy = (try? String(contentsOf: repoRoot().appendingPathComponent("Sources/StrimHost/HostConfig.swift"), encoding: .utf8)) ?? ""
        #expect(hostPolicy.contains("struct HostPolicy"))
    }

    @Test func evolveRunLeavesPolicySourcesUntouched() async throws {
        let before = Self.hashes()
        let dir = tempDir("safety")
        let tasks = syntheticTasks()
        let split = try CorpusSplit.frozen(dir: dir, tasks: tasks)
        var cfg = EvolveConfig(); cfg.coordinates = Coordinate.allCases
        let ledger = FitnessLedger(url: dir.appendingPathComponent("ledger.dry-run.jsonl"))
        let classes = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.taskClass) })
        let ev = Evaluator(runner: FakeTaskRunner.standard, ledger: ledger, split: split, classes: classes, config: cfg, dryRun: true)
        let summary = try await ev.run()
        #expect(summary.finished)
        let st = SearchPlanner.replay(rows: ledger.read(), split: split, config: cfg)
        let store = PackStore(root: dir.appendingPathComponent("packs"))
        _ = try store.save(st.incumbent, provenance: Provenance(fingerprint: st.chosenFingerprint, dryRun: true))
        _ = try await ev.releaseEval(chosen: st.incumbent, reps: 1)
        #expect(Self.hashes() == before)
        // everything the run wrote is under its own directory
        let wrote = FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []
        #expect(!wrote.isEmpty)
    }

    @Test func storedPackContainsOnlyPromptKnobsAndProvenance() throws {
        let store = PackStore(root: tempDir("only"))
        var c = PackCandidate.baseline; c.playbookRepoQA = .stepwise; c.temperature = .warm; c.thinking = .firstPlanningTurn
        let dir = try store.save(c, provenance: Provenance(fingerprint: PackLibrary.fingerprint(c)))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(names == ["system.md", "tool_guidance.md", "memory.md", "knobs.json", "candidate.json", "FINGERPRINT", "pack.sha256", "provenance.jsonl"])
        let knobs = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("knobs.json"))) as? [String: Any]
        let allowed: Set<String> = ["compactionThreshold", "compactionSummaryPrompt", "resultCapChars", "thinking", "temperature", "decoding"]
        #expect(Set((knobs ?? [:]).keys).isSubset(of: allowed))
        #expect(knobs?["temperature"] as? Double == 0.6)
    }
}
