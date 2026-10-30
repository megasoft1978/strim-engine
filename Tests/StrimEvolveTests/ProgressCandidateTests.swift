import Foundation
import Testing
import StrimHarness
import StrimAgentBench
@testable import StrimEvolve

@Suite struct ProgressCandidateTests {
    @Test func exactCandidateParsesRendersAndRoundTrips() throws {
        let raw = #"{"progress_gate":"on","test_status":"structured","thinking":"on_stall_medium"}"#
        let c = try PairedEvaluation.decode(raw)
        #expect(c.progressGate == .on && c.testStatus == .structured && c.thinking == .onStallMedium)
        #expect(try JSONDecoder().decode(PackCandidate.self, from: Canonical.json(c)) == c)
        let k = try HarnessKnobs.decode(Canonical.json(PackLibrary.render(c).knobs))
        #expect(k.progress_gate == .on && k.test_status == .structured && k.thinking == .onStall && k.reasoningEffort == "medium")
        #expect(Coordinate.progressGate.variants(of: .baseline).map(\.progressGate) == [.off, .on])
        #expect(Coordinate.testStatus.variants(of: .baseline).map(\.testStatus) == [.plain, .structured])
        #expect(PackLibrary.fingerprint(c) != PackLibrary.fingerprint(.baseline))
    }

    @Test func legacyCorpusFingerprintsAndBytesStayIdentical() throws {
        // Fixed pre-progress surface, intentionally independent of the growing Coordinate/Thinking allCases.
        let legacyCoordinates: [Coordinate] = [.systemPrompt, .toolGuidance, .playbookTestFix, .playbookRepoQA,
            .playbookMechanicalEdit, .resultCap, .compactionThreshold, .compactionSummary, .thinking, .temperature, .stallNudge, .resultShape]
        let corpus = legacyCoordinates.flatMap { $0.variants(of: .baseline) }.filter { $0.thinking != .onStallMedium }
        for candidate in corpus {
            let bytes = Canonical.json(candidate)
            let knobs = Canonical.json(PackLibrary.render(candidate).knobs)
            for data in [bytes, knobs] {
                let s = String(decoding: data, as: UTF8.self)
                #expect(!s.contains("progress_gate") && !s.contains("test_status"))
            }
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["progress_gate"] = "off"; object["test_status"] = "plain"
            let decoded = try JSONDecoder().decode(PackCandidate.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(Canonical.json(decoded) == bytes)
            #expect(PackLibrary.fingerprint(decoded) == PackLibrary.fingerprint(candidate))
        }
        #expect(PackLibrary.fingerprint(.baseline) == "010498d957b46c4f")
        var allTurns = PackCandidate.baseline; allTurns.thinking = .allTurnsMedium
        #expect(PackLibrary.fingerprint(allTurns) == "45e18dfdad89bb8c")
    }

    @Test func failedGateOutcomeDoesNotCreateFalseDonePenalty() {
        // HarnessArm only claims completion for DONE replies; gate termination is FAILED.
        let reply = HarnessReply.parse("FAILED strim job j: failed\nsummary (untrusted model text):\nblocked: three unchanged failures")
        #expect(reply.terminal && !reply.done && reply.status == "failed")
        let r = TaskRunResult(pass: false, claimedDone: reply.done)
        let request = TaskRunRequest(candidate: .baseline, fingerprint: "gate", taskId: "t", taskClass: "test-fix", split: .train, rep: 1, seed: 7)
        let row = RowBuilder.row(for: request, result: r, round: 0, coordinate: "progress_gate", phase: .search, dryRun: true)
        #expect(!row.claimedDone && !row.falseDone && row.fitness == 0)
    }
}
