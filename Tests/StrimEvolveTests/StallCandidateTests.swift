import Foundation
import Testing
import StrimHarness
@testable import StrimEvolve

@Suite struct StallCandidateTests {
    @Test func convergeIsOnlyATestFixOptionAndKeepsOldText() {
        let variants = Coordinate.playbookTestFix.variants(of: .baseline)
        #expect(variants.map(\.playbookTestFix) == [.off, .concise, .stepwise, .converge])
        var c = PackCandidate.baseline; c.playbookTestFix = .converge
        let text = PackLibrary.render(c).memory
        #expect(text.contains(Variants.testFixConverge))
        #expect(text.contains("after two edits") && text.contains("one-line root-cause hypothesis"))
        #expect(Coordinate.playbookRepoQA.variants(of: .baseline).count == 3)
        #expect(Coordinate.playbookMechanicalEdit.variants(of: .baseline).count == 3)
        c.playbookTestFix = .stepwise
        #expect(PackLibrary.render(c).memory.hasSuffix(Variants.testFixStepwise))
    }

    @Test func optInCoordinatesRoundTripThroughPackKnobs() throws {
        var c = PackCandidate.baseline; c.stallNudge = .on; c.resultShape = .errorsFirst
        let encoded = Canonical.json(c)
        #expect(try JSONDecoder().decode(PackCandidate.self, from: encoded) == c)
        #expect(c.label == "stall_nudge=on,result_shape=errors_first")
        for name in ["stall_nudge", "result_shape"] {
            #expect(Coordinate(rawValue: name)?.consumedByHarness == true)
        }
        let dir = tempDir("stall-pack"); defer { try? FileManager.default.removeItem(at: dir) }
        try Canonical.json(PackLibrary.render(c).knobs).write(to: dir.appendingPathComponent("knobs.json"))
        let knobs = try #require(try PackLoader.knobs(inDirectory: dir))
        #expect(knobs.stall_nudge == .on && knobs.result_shape == .errorsFirst)
        #expect(PackLibrary.fingerprint(c) != PackLibrary.fingerprint(.baseline))
    }

    @Test func legacyCandidateAndKnobBytesOmitNewDefaults() throws {
        let legacy = Coordinate.allCases.filter { $0 != .stallNudge && $0 != .resultShape }
            .flatMap { $0.variants(of: .baseline) }.filter { $0.playbookTestFix != .converge }
        for c in legacy {
            let bytes = Canonical.json(c)
            let knobs = Canonical.json(PackLibrary.render(c).knobs)
            for data in [bytes, knobs] {
                let text = String(decoding: data, as: UTF8.self)
                #expect(!text.contains("stall_nudge") && !text.contains("result_shape"))
            }
            #expect(try JSONDecoder().decode(PackCandidate.self, from: bytes) == c)
            // Explicit default keys decode but encode back to precisely the legacy bytes.
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["stall_nudge"] = "off"; object["result_shape"] = "head_tail"
            let decoded = try JSONDecoder().decode(PackCandidate.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(Canonical.json(decoded) == bytes)
            #expect(PackLibrary.fingerprint(decoded) == PackLibrary.fingerprint(c))
        }
    }
}
