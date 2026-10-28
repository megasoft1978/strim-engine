import Foundation
import Testing
@testable import StrimEvolve

@Suite struct SelectionTests {
    let cfg = EvolveConfig()
    let train = (1...10).map { String(format: "t%02d", $0) }
    let val = (1...6).map { String(format: "v%02d", $0) }

    // MARK: train winner

    @Test func trainPicksLargestPairedGain() {
        let rows = mkRows("inc", .train, ids: train, reps: 1, passIds: ["t01", "t02", "t03"])
            + mkRows("a", .train, ids: train, reps: 1, passIds: ["t01", "t02", "t03", "t04"])
            + mkRows("b", .train, ids: train, reps: 1, passIds: ["t01", "t02", "t03", "t04", "t05", "t06"])
        let d = Selection.trainWinner(incumbent: "inc", challengers: ["a", "b"], rows: rows, taskIds: train, reps: 1, config: cfg)
        #expect(d.winner == "b")
        #expect(abs(d.challenges.first { $0.fingerprint == "b" }!.gainPP - 30) < 1e-6)
    }

    @Test func trainTieGoesToFewerTokensThenWallThenFingerprint() {
        let pass: Set<String> = ["t01", "t02", "t03", "t04"]
        var rows = mkRows("inc", .train, ids: train, reps: 1, passIds: ["t01", "t02"], tokens: 5000, wall: 100)
        rows += mkRows("a", .train, ids: train, reps: 1, passIds: pass, tokens: 5000, wall: 100)
        rows += mkRows("b", .train, ids: train, reps: 1, passIds: pass, tokens: 4000, wall: 100)
        #expect(Selection.trainWinner(incumbent: "inc", challengers: ["a", "b"], rows: rows, taskIds: train, reps: 1, config: cfg).winner == "b")
        rows = mkRows("inc", .train, ids: train, reps: 1, passIds: ["t01", "t02"])
            + mkRows("a", .train, ids: train, reps: 1, passIds: pass, wall: 50) + mkRows("b", .train, ids: train, reps: 1, passIds: pass, wall: 40)
        #expect(Selection.trainWinner(incumbent: "inc", challengers: ["a", "b"], rows: rows, taskIds: train, reps: 1, config: cfg).winner == "b")
        rows = mkRows("inc", .train, ids: train, reps: 1, passIds: ["t01", "t02"])
            + mkRows("zz", .train, ids: train, reps: 1, passIds: pass) + mkRows("aa", .train, ids: train, reps: 1, passIds: pass)
        #expect(Selection.trainWinner(incumbent: "inc", challengers: ["zz", "aa"], rows: rows, taskIds: train, reps: 1, config: cfg).winner == "aa")
    }

    @Test func trainNoWinnerWhenNoGainOnlyTokenSavings() {
        let pass: Set<String> = ["t01", "t02"]
        let rows = mkRows("inc", .train, ids: train, reps: 1, passIds: pass, tokens: 5000)
            + mkRows("a", .train, ids: train, reps: 1, passIds: pass, tokens: 1000)
            + mkRows("r", .train, ids: train, reps: 1, passIds: ["t01"])
        #expect(Selection.trainWinner(incumbent: "inc", challengers: ["a", "r"], rows: rows, taskIds: train, reps: 1, config: cfg).winner == nil)
    }

    @Test func falseDonePenaltyCountsInFitness() {
        // a passes one more task but claims done on 2 failing ones: net fitness is worse than the incumbent
        let rows = mkRows("inc", .train, ids: train, reps: 1, passIds: ["t01"])
            + mkRows("a", .train, ids: train, reps: 1, passIds: ["t01", "t02"], falseDoneIds: ["t05", "t06"])
        let d = Selection.trainWinner(incumbent: "inc", challengers: ["a"], rows: rows, taskIds: train, reps: 1, config: cfg)
        #expect(d.winner == nil)
        #expect(abs(d.challenges[0].gainPP - (-30)) < 1e-6)
        #expect(FitnessRow.fitness(pass: false, falseDone: true) == -2)
    }

    @Test func trainIgnoresChallengersWithMissingRows() {
        // b is better where it has rows but covers only 3/10 tasks
        let rows = mkRows("inc", .train, ids: train, reps: 1, passIds: ["t01"])
            + mkRows("b", .train, ids: Array(train.prefix(3)), reps: 1, passIds: ["t01", "t02", "t03"])
            + mkRows("a", .train, ids: train, reps: 1, passIds: ["t01", "t02"])
        let d = Selection.trainWinner(incumbent: "inc", challengers: ["a", "b"], rows: rows, taskIds: train, reps: 1, config: cfg)
        #expect(d.winner == "a")
        #expect(d.challenges.first { $0.fingerprint == "b" }!.coverage < 0.8)
    }

    @Test func infraRowsAreHolesNotFailures() {
        var rows = mkRows("inc", .train, ids: train, reps: 1, passIds: [])
        rows += mkRows("a", .train, ids: train, reps: 1, passIds: ["t01", "t02"])
        rows[3] = mkRow("inc", .train, "t04", pass: false, infra: true)
        let pairs = Selection.pairs("a", "inc", split: .train, rows: rows)
        #expect(pairs.count == 9)
        // a good row followed by a later infra row for the same key stays valid
        let kept = [mkRow("a", .train, "t01", pass: true), mkRow("a", .train, "t01", pass: false, infra: true)]
        #expect(Selection.score("a", split: .train, rows: kept)?.n == 1)
    }

    // MARK: val confirm

    func valRows(inc: Set<String>, cand: Set<String>, candFD: Set<String> = [], incFD: Set<String> = []) -> [FitnessRow] {
        mkRows("inc", .val, ids: val, reps: 2, passIds: inc, falseDoneIds: incFD) + mkRows("c", .val, ids: val, reps: 2, passIds: cand, falseDoneIds: candFD)
    }

    @Test func confirmAdoptsAtOrAboveFivePP() {
        // +1 task of 6, both reps: 16.7 pp
        let d = Selection.confirm(incumbent: "inc", challenger: "c", rows: valRows(inc: ["v01"], cand: ["v01", "v02"]), valIds: val, config: cfg)
        #expect(d.adopt && d.reason == .adopted)
        #expect(abs(d.gainPP - 100.0 / 6) < 1e-6)
        #expect(d.pairs == 12)
    }

    @Test func confirmBoundaryIsInclusive() {
        var c = cfg; c.minGainPP = 100.0 / 6
        let d = Selection.confirm(incumbent: "inc", challenger: "c", rows: valRows(inc: ["v01"], cand: ["v01", "v02"]), valIds: val, config: c)
        #expect(d.adopt)
        c.minGainPP = 100.0 / 6 + 0.01
        #expect(!Selection.confirm(incumbent: "inc", challenger: "c", rows: valRows(inc: ["v01"], cand: ["v01", "v02"]), valIds: val, config: c).adopt)
    }

    @Test func confirmThresholdSeparatesSignalFromNoise() {
        // 12 pairs: one extra pass in one rep is +8.3 pp mean with no rep regression -> adopted at the 5 pp default
        var rows = mkRows("inc", .val, ids: val, reps: 2, passIds: ["v01", "v02"])
        var cand = mkRows("c", .val, ids: val, reps: 2, passIds: ["v01", "v02"])
        cand[4] = mkRow("c", .val, "v03", rep: 1, pass: true)
        rows += cand
        let d = Selection.confirm(incumbent: "inc", challenger: "c", rows: rows, valIds: val, config: cfg)
        #expect(abs(d.gainPP - 100.0 / 12) < 1e-6 && d.adopt)
        // the same table with a 10 pp bar is below threshold
        var strict = cfg; strict.minGainPP = 10
        let d2 = Selection.confirm(incumbent: "inc", challenger: "c", rows: rows, valIds: val, config: strict)
        #expect(!d2.adopt && d2.reason == .gainBelowThreshold)
        // identical tables: zero gain, rejected
        let same = mkRows("inc", .val, ids: val, reps: 2, passIds: ["v01"]) + mkRows("c", .val, ids: val, reps: 2, passIds: ["v01"])
        let d3 = Selection.confirm(incumbent: "inc", challenger: "c", rows: same, valIds: val, config: cfg)
        #expect(!d3.adopt && d3.reason == .gainBelowThreshold && d3.gainPP == 0)
    }

    @Test func confirmRejectsRepRegression() {
        // rep 1: +2 tasks, rep 2: -1 task -> mean positive but one rep regressed
        var rows = mkRows("inc", .val, ids: val, reps: 2, passIds: ["v01", "v02", "v03"])
        var cand: [FitnessRow] = []
        for id in val {
            cand.append(mkRow("c", .val, id, rep: 1, pass: ["v01", "v02", "v03", "v04", "v05"].contains(id)))
            cand.append(mkRow("c", .val, id, rep: 2, pass: ["v01", "v02"].contains(id)))
        }
        rows += cand
        let d = Selection.confirm(incumbent: "inc", challenger: "c", rows: rows, valIds: val, config: cfg)
        #expect(d.gainPP > 5)
        #expect(!d.adopt && d.reason == .repRegression)
        #expect(d.perRepGainPP[2]! < 0)
    }

    @Test func confirmRejectsRegression() {
        let d = Selection.confirm(incumbent: "inc", challenger: "c", rows: valRows(inc: ["v01", "v02"], cand: ["v01"]), valIds: val, config: cfg)
        #expect(!d.adopt && d.gainPP < 0)
    }

    @Test func confirmFalseDoneGate() {
        // challenger gains passes but claims done on 2 failing tasks (2/6 = 33% of pairs > 5%): fitness gain +16.7-2*... recompute
        let cand: Set<String> = ["v01", "v02", "v03", "v04"]
        let d = Selection.confirm(incumbent: "inc", challenger: "c",
                                  rows: valRows(inc: ["v01"], cand: cand, candFD: ["v05"]), valIds: val, config: cfg)
        #expect(d.challengerFalseDoneRate > 0.05)
        #expect(!d.adopt && d.reason == .falseDoneTooHigh)
        // allowed when the incumbent is no better
        let d2 = Selection.confirm(incumbent: "inc", challenger: "c",
                                   rows: valRows(inc: ["v01"], cand: cand, candFD: ["v05"], incFD: ["v05"]), valIds: val, config: cfg)
        #expect(d2.adopt)
    }

    @Test func confirmMissingRows() {
        let rows = valRows(inc: ["v01"], cand: ["v01", "v02"]).filter { !($0.candidate == "c" && ["v04", "v05", "v06"].contains($0.taskId)) }
        let d = Selection.confirm(incumbent: "inc", challenger: "c", rows: rows, valIds: val, config: cfg)
        #expect(!d.adopt && d.reason == .insufficientData)
        #expect(Selection.confirm(incumbent: "inc", challenger: "c", rows: [], valIds: val, config: cfg).reason == .insufficientData)
        // a few holes within the coverage allowance still decide on the paired rows
        let few = valRows(inc: ["v01"], cand: ["v01", "v02"]).filter { !($0.candidate == "c" && $0.taskId == "v06" && $0.rep == 2) }
        let d3 = Selection.confirm(incumbent: "inc", challenger: "c", rows: few, valIds: val, config: cfg)
        #expect(d3.pairs == 11 && d3.adopt)
    }

    @Test func confirmIgnoresTrainAndReleaseRows() {
        let noise = mkRows("c", .train, ids: val, reps: 2, passIds: Set(val)) + mkRows("c", .val, ids: val, reps: 2, passIds: Set(val), tokens: 1).map { r -> FitnessRow in var x = r; x.phase = .release; return x }
        let rows = valRows(inc: ["v01"], cand: ["v01"]) + noise
        let d = Selection.confirm(incumbent: "inc", challenger: "c", rows: rows, valIds: val, config: cfg)
        #expect(!d.adopt && abs(d.gainPP) < 1e-9)
    }

    @Test func releaseVerdict() {
        let ids = ["x1", "x2", "x3", "x4"]
        func rel(_ fp: String, _ pass: Set<String>) -> [FitnessRow] { ids.map { mkRow(fp, .test, $0, pass: pass.contains($0), phase: .release) } }
        #expect(Selection.releaseVerdict(chosen: "c", baseline: "b", rows: []) == nil)
        let up = Selection.releaseVerdict(chosen: "c", baseline: "b", rows: rel("b", ["x1"]) + rel("c", ["x1", "x2"]))!
        #expect(!up.regressed && up.gainPP == 25)
        let down = Selection.releaseVerdict(chosen: "c", baseline: "b", rows: rel("b", ["x1", "x2"]) + rel("c", ["x1"]))!
        #expect(down.regressed)
    }
}
