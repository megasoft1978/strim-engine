import Foundation
import Testing
@testable import StrimBenchHTTP

@Suite struct PerfProfileTests {
    @Test func parsesPrefillLine() {
        let s = PerfParse.prefillLine("n=4096 chunk=2048 4.12 s  994 tok/s  (rep 2)")
        #expect(s == PrefillSample(n: 4096, chunk: 2048, seconds: 4.12, tokPerSec: 994, rep: 2))
        #expect(PerfParse.prefillLine("warming up") == nil)
    }

    @Test func parsesSpecRepAndTiming() {
        let l = "rep 1 spec: passes 40  emitted 128  3.20 tok/pass  50.1 tok/s  55.3 decode  accept 80% (96/120)  18.5 ms/pass  2.55s"
        let s = PerfParse.specRepLine(l)
        #expect(s?.passes == 40 && s?.emitted == 128 && s?.decodeTokPerSec == 55.3 && s?.msPerPass == 18.5 && s?.seconds == 2.55 && s?.accept == 80)
        #expect(PerfParse.specRepLine("parity: EXACT (128 tokens)") == nil)
        let t = PerfParse.timingLine("ms/pass: mtp_draft 3.1, verify 14.2, reseed 0.4, rounds 40, depth avg 2.50, syncs/round 1.00")
        #expect(t == TimingSample(draftMs: 3.1, verifyMs: 14.2, reseedMs: 0.4, rounds: 40, depthAvg: 2.5, syncsPerRound: 1.0))
        #expect(PerfParse.timingLine("something else") == nil)
    }

    @Test func statAndCV() throws {
        let s = try #require(PerfStat.of([100, 110, 90]))
        #expect(s.n == 3 && s.median == 100 && abs(s.mean - 100) < 1e-9)
        #expect(abs(s.cv - 10) < 1e-9)
        #expect(PerfStat.of([]) == nil)
        #expect(PerfStat.of([5])?.cv == 0)
    }

    @Test func planSkipsClampedChunksAndAddsWarmup() {
        var c = PerfConfig(); c.lengths = [1024, 4096]; c.chunks = [512, 1024, 2048, 4096]; c.reps = 3
        c.sections = ["prefill"]
        let steps = PerfPlan.steps(c) { "ids\($0)" }
        #expect(steps.filter { $0.length == 1024 }.compactMap { $0.chunk } == [512, 1024])
        #expect(steps.filter { $0.length == 4096 }.compactMap { $0.chunk } == [512, 1024, 2048, 4096])
        #expect(steps[0].args == ["benchprefill", "models/qwen38-4bit", "1024", "4", "512"])  // reps+1
    }

    @Test func planLabelsAblationsAndEnv() {
        var c = PerfConfig(); c.lengths = [4096]; c.sections = ["ablate", "decode"]; c.decodeLengths = [4096, 32768]
        let steps = PerfPlan.steps(c) { "ids\($0)" }
        let abl = steps.filter { $0.section == "gdn-ablation" }
        #expect(abl.map { $0.label } == ["default", "skip_rec", "tensor", "tensor_skip_rec"])
        #expect(abl.map { $0.ablation } == [false, true, false, true])
        #expect(abl[3].env == ["STRIM_GDN_METAL_MAX_S": "8", "STRIM_SKIP_REC": "1"])
        let dec = steps.filter { $0.section == "decode" }
        #expect(dec.count == 2 && dec.allSatisfy { $0.env["STRIM_TIMING"] == "1" } && dec[1].args[5] == "ids32768")
    }

    @Test func rowsDropWarmupRep() throws {
        let step = PerfStep(section: "prefill-chunk", label: "chunk", ablation: false, length: 4096, chunk: 1024, args: [], env: [:])
        let out = PerfProcOutput(stdout: """
        n=4096 chunk=1024 5.00 s  819 tok/s  (rep 0)
        n=4096 chunk=1024 4.10 s  1000 tok/s  (rep 1)
        n=4096 chunk=1024 4.00 s  1024 tok/s  (rep 2)
        n=4096 chunk=1024 4.20 s  975 tok/s  (rep 3)

        """, stderr: "", status: 0)
        let (rows, problems) = PerfPlan.rows(for: step, out: out, reps: 3)
        #expect(problems.isEmpty)
        #expect(rows.count == 1 && rows[0].samples == [1000, 1024, 975])
        let (_, p2) = PerfPlan.rows(for: step, out: PerfProcOutput(stdout: "", stderr: "", status: 1), reps: 3)
        #expect(p2.count == 2)  // exit status + short reps
    }

    @Test func decodeRowsPairTimingLinesFromTail() {
        let step = PerfStep(section: "decode", label: "depth2", ablation: false, length: 4096, chunk: nil, args: [], env: [:])
        func rep(_ i: Int, _ d: Double) -> String { "rep \(i) spec: passes 40  emitted 128  3.20 tok/pass  50.1 tok/s  \(d) decode  accept 80% (96/120)  18.5 ms/pass  2.55s" }
        func tm(_ v: Double) -> String { "ms/pass: mtp_draft 3.0, verify \(v), reseed 0.4, rounds 40, depth avg 2.50, syncs/round 1.00" }
        let out = PerfProcOutput(stdout: [rep(1, 60), rep(2, 61), rep(3, 62)].joined(separator: "\n"),
                                 stderr: [tm(99), tm(14), tm(15), tm(16)].joined(separator: "\n"), status: 0)  // first = warm-up round
        let (rows, problems) = PerfPlan.rows(for: step, out: out, reps: 3)
        #expect(problems.isEmpty)
        #expect(rows.first { $0.metric == "decode tok/s" }?.samples == [60, 61, 62])
        #expect(rows.first { $0.metric == "verify ms" }?.samples == [14, 15, 16])
    }

    private func row(_ section: String, _ label: String, _ len: Int, chunk: Int? = nil, abl: Bool = false, metric: String, _ s: [Double]) -> PerfRow {
        PerfRow(section: section, label: label, ablation: abl, length: len, chunk: chunk, env: [:], metric: metric, unit: "", samples: s)
    }

    @Test func derivedChunkGainAndGDNShare() throws {
        let rows = [
            row("prefill-chunk", "chunk", 4096, chunk: 1024, metric: "prefill tok/s", [1000, 1000, 1000]),
            row("prefill-chunk", "chunk", 4096, chunk: 4096, metric: "prefill tok/s", [1010, 1010, 1010]),
            row("gdn-ablation", "tensor", 4096, chunk: 1024, metric: "prefill tok/s", [800, 800, 800]),
            row("gdn-ablation", "tensor_skip_rec", 4096, chunk: 1024, abl: true, metric: "prefill tok/s", [1000, 1000, 1000]),
            row("gdn-ablation", "default", 4096, chunk: 1024, metric: "prefill tok/s", [1000, 1000, 1000]),
            row("gdn-ablation", "skip_rec", 4096, chunk: 1024, abl: true, metric: "prefill tok/s", [1000, 1000, 1000]),
        ]
        let d = PerfAnalysis.derive(rows)
        let g = try #require(d.first { $0.name == "chunk 4096 vs 1024" }?.value)
        #expect(abs(g - 1.0) < 1e-9)
        let tensor = try #require(d.first { $0.name.hasPrefix("GDN recurrence share, tensor") }?.value)
        #expect(abs(tensor - 20) < 1e-9)  // 1/800 vs 1/1000 -> 20% of time removed
        let blocked = try #require(d.first { $0.name.hasPrefix("GDN recurrence share, blocked") }?.value)
        #expect(abs(blocked) < 1e-9)
        let kc = PerfAnalysis.killCriteria(d).joined(separator: "\n")
        #expect(kc.contains("KILL (below +2%)") && kc.contains("INCONCLUSIVE"))
    }

    @Test func derivedDecodeSlowdown() throws {
        let rows = [
            row("decode", "depth2", 4096, metric: "decode tok/s", [60, 60, 60]),
            row("decode", "depth2", 32768, metric: "decode tok/s", [48, 48, 48]),
            row("decode", "depth2", 4096, metric: "verify ms", [20, 20, 20]),
            row("decode", "depth2", 32768, metric: "verify ms", [30, 30, 30]),
        ]
        let d = PerfAnalysis.derive(rows)
        #expect(abs(try #require(d.first { $0.name.hasPrefix("decode tok/s slowdown") }?.value) - 20) < 1e-9)
        #expect(try #require(d.first { $0.name.hasPrefix("verify ms delta") }?.value) == 10)
    }

    @Test func renderMarksAblationsAndJSONRoundTrips() throws {
        var m = PerfMachine(); m.cpu = "Apple M5 Max"; m.date = "2026-10-27T00:00:00Z"
        let r = PerfReport(machine: m, config: ["reps": "3"],
                           rows: [row("gdn-ablation", "skip_rec", 4096, chunk: 1024, abl: true, metric: "prefill tok/s", [1, 2, 3])],
                           derived: [], skipped: ["x"])
        let md = PerfRender.markdown(r)
        #expect(md.contains("**ABLATION**") && md.contains("Not measured"))
        let v = try JSON.parse(Data(PerfRender.json(r).utf8))
        let row0 = try #require(v["rows"].array?.first)
        #expect(row0["ablation"] == .bool(true) && row0["valid_output"] == .bool(false) && row0["n"] == .int(3))
    }

    @Test func orchestrationWithFakeRunner() async throws {
        var c = PerfConfig(); c.strim = "/x/strim"; c.lengths = [1024]; c.chunks = [1024]; c.sections = ["prefill"]; c.reps = 3
        let runner: PerfRunner = { _, args, _ in
            PerfProcOutput(stdout: (0 ... 3).map { "n=1024 chunk=1024 1.00 s  \(1000 + $0) tok/s  (rep \($0))" }.joined(separator: "\n"), stderr: "", status: 0)
        }
        let rep = try await PerfProfile.run(c, ids: { _ in "1,2" }, runner: runner, served: nil, repoRoot: "/nonexistent", log: { _ in })
        #expect(rep.rows.count == 1 && rep.rows[0].samples == [1001, 1002, 1003])
        #expect(rep.skipped.contains { $0.contains("attention vs MLP") })
    }
}
