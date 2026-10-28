import Foundation
import Testing
@testable import StrimEngine

@Suite struct SchedulerTests {
    @Test func interactivePreemptsBackgroundPrefill() {
        var s = Scheduler()
        s.add(id: 1, priority: .background)
        #expect(s.pick() == .prefill(1))
        s.add(id: 2, priority: .interactive)
        // the very next unit after the arrival is the interactive one
        #expect(s.pick() == .prefill(2))
        #expect(s.pick() == .prefill(2))
        s.remove(2)
        #expect(s.pick() == .prefill(1))   // background resumes, nothing was evicted
    }

    @Test func prefillsAreFIFOWithinClass() {
        var s = Scheduler()
        s.add(id: 5, priority: .interactive)
        s.add(id: 6, priority: .interactive)
        #expect(s.pick() == .prefill(5))
        #expect(s.pick() == .prefill(5))
        s.remove(5)
        #expect(s.pick() == .prefill(6))
    }

    @Test func decodeNeverWaitsMoreThanOneChunk() {
        var s = Scheduler()
        s.burst = .legacy   // default is the gap cap (PrefillBurstTests); this pins the legacy alternation
        s.add(id: 1, priority: .interactive, phase: .decode)
        s.add(id: 2, priority: .interactive)
        var sinceDecode = 0
        var maxGap = 0
        for _ in 0 ..< 40 {
            switch s.pick() {
            case .prefill?: sinceDecode += 1; maxGap = max(maxGap, sinceDecode)
            case .decodeSolo?, .decodeBatch?: sinceDecode = 0
            case nil: Issue.record("idle with work pending")
            }
        }
        #expect(maxGap <= 1)
    }

    @Test func backgroundDecodePausedWhileInteractiveExists() {
        var s = Scheduler()
        s.add(id: 1, priority: .background, phase: .decode)
        #expect(s.pick() == .decodeSolo(1))
        s.add(id: 2, priority: .interactive, phase: .decode)
        for _ in 0 ..< 5 { #expect(s.pick() == .decodeSolo(2)) }
        s.remove(2)
        #expect(s.pick() == .decodeSolo(1))
    }

    @Test func twoDecodersShareABatchAndStayThere() {
        var s = Scheduler()
        s.add(id: 1, priority: .interactive, phase: .decode)
        s.add(id: 2, priority: .interactive, phase: .decode)
        #expect(s.pick() == .decodeBatch(join: [1, 2]))
        #expect(s.isBatched(1) && s.isBatched(2))
        s.remove(1)
        // one member left: still the batch (plain decode), not back to solo/MTP
        #expect(s.pick() == .decodeBatch(join: []))
        s.add(id: 3, priority: .interactive, phase: .decode)
        #expect(s.pick() == .decodeBatch(join: [3]))
        #expect(s.batchMembers == [2, 3])
    }

    @Test func soloAlongsideForeignClassBatchStaysSolo() {
        var s = Scheduler()
        s.add(id: 1, priority: .background, phase: .decode)
        s.add(id: 2, priority: .background, phase: .decode)
        #expect(s.pick() == .decodeBatch(join: [1, 2]))
        s.add(id: 3, priority: .interactive, phase: .decode)
        #expect(s.pick() == .decodeSolo(3))       // interactive keeps MTP; the paused batch is untouched
        #expect(s.isBatched(1))
    }

    @Test func removedRequestsAreNeverPicked() {
        var s = Scheduler()
        s.add(id: 1, priority: .interactive)
        s.add(id: 2, priority: .background)
        s.remove(1); s.remove(2)
        #expect(s.pick() == nil)
        #expect(s.isEmpty)
    }

    /// Fake runner: prefill = 4 chunks then decode for 10 passes; checks TTFT ordering under load.
    @Test func simulatedLoadInteractiveFinishesFirstAndBackgroundCompletes() {
        struct Job { var chunks: Int; var decodes: Int }
        var s = Scheduler()
        var jobs: [Int: Job] = [:]
        for id in 1 ... 3 { s.add(id: id, priority: .background); jobs[id] = Job(chunks: 4, decodes: 10) }
        var step = 0
        var firstDecodeStep: [Int: Int] = [:]
        var doneStep: [Int: Int] = [:]
        while !s.isEmpty && step < 1000 {
            if step == 3 { s.add(id: 9, priority: .interactive); jobs[9] = Job(chunks: 1, decodes: 10) }
            step += 1
            guard let u = s.pick() else { break }
            func decode(_ id: Int) {
                firstDecodeStep[id] = firstDecodeStep[id] ?? step
                jobs[id]!.decodes -= 1
                if jobs[id]!.decodes == 0 { doneStep[id] = step; s.remove(id) }
            }
            switch u {
            case let .prefill(id):
                jobs[id]!.chunks -= 1
                if jobs[id]!.chunks == 0 { s.setPhase(id, .decode) }
            case let .decodeSolo(id): decode(id)
            case let .decodeBatch(join):
                _ = join
                for id in s.batchMembers { decode(id) }
            }
        }
        #expect(doneStep.count == 4)
        #expect(doneStep[9]! < doneStep[1]! && doneStep[9]! < doneStep[2]! && doneStep[9]! < doneStep[3]!)
        #expect(firstDecodeStep[9]! <= 6)   // arrived at step 3: one chunk, then decoding
    }
}

@Suite struct DecodePolicyTests {
    private func decoders(_ n: Int, policy: DecodePolicy) -> Scheduler {
        var s = Scheduler(); s.policy = policy
        for i in 1 ... n { s.add(id: i, priority: .interactive, phase: .decode) }
        return s
    }

    @Test func roundRobinAlternatesFairlyAndNeverBatches() {
        var s = decoders(3, policy: .roundrobin)
        var seq: [Int] = []
        for _ in 0 ..< 9 { if case let .decodeSolo(id)? = s.pick() { seq.append(id) } else { Issue.record("not solo") } }
        #expect(seq == [1, 2, 3, 1, 2, 3, 1, 2, 3])
        #expect(s.batchMembers.isEmpty)
        s.remove(2)
        var after: [Int] = []
        for _ in 0 ..< 4 { if case let .decodeSolo(id)? = s.pick() { after.append(id) } }
        #expect(Set(after) == [1, 3] && after[0] != after[1])
    }

    @Test func roundRobinKeepsInteractiveBeforeBackground() {
        var s = decoders(2, policy: .roundrobin)
        s.add(id: 9, priority: .background, phase: .decode)
        for _ in 0 ..< 6 { if case let .decodeSolo(id)? = s.pick() { #expect(id != 9) } }
        s.remove(1); s.remove(2)
        #expect(s.pick() == .decodeSolo(9))
    }

    @Test func autoPicksRoundRobinForHighAcceptanceAndBatchForLow() {
        var hi = decoders(2, policy: .auto)
        for id in 1 ... 2 { for _ in 0 ..< 4 { hi.record(id, tokens: 4, ms: 40) } }
        if case .decodeSolo? = hi.pick() {} else { Issue.record("expected round robin") }
        var lo = decoders(2, policy: .auto)
        for id in 1 ... 2 { for _ in 0 ..< 4 { lo.record(id, tokens: 1, ms: 40) } }
        #expect(lo.pick() == .decodeBatch(join: [1, 2]))
    }

    @Test func autoSwitchesToBatchOnlyAfterWarmupAndStaysThere() {
        var s = decoders(2, policy: .auto)           // priors favor round robin at B=2
        if case .decodeSolo? = s.pick() {} else { Issue.record("expected round robin at prior") }
        s.record(1, tokens: 1, ms: 40); s.record(2, tokens: 1, ms: 40)   // low acceptance but not warm yet
        if case .decodeSolo? = s.pick() {} else { Issue.record("must not switch before warm-up") }
        for _ in 0 ..< 4 { s.record(1, tokens: 1, ms: 40); s.record(2, tokens: 1, ms: 40) }
        #expect(s.pick() == .decodeBatch(join: [1, 2]))
        #expect(s.isBatched(1) && s.isBatched(2))
        s.add(id: 3, priority: .interactive, phase: .decode)
        #expect(s.pick() == .decodeBatch(join: [3]))   // arrivals join the live batch
    }

    @Test func autoHysteresisDoesNotThrashNearBreakEven() {
        var s = decoders(2, policy: .auto)
        // batch B=2 = 1000*2/42 = 47.6 tok/s; round robin at tpu 2.2, 40 ms = 55 tok/s: stays rr at 5-10% noise
        for _ in 0 ..< 5 { for id in 1 ... 2 { s.record(id, tokens: 2, ms: 40) } }
        var solos = 0
        for _ in 0 ..< 10 { if case .decodeSolo? = s.pick() { solos += 1 } }
        #expect(solos == 10)
    }

    @Test func policyBatchIsDefault() {
        var s = decoders(2, policy: .batch)
        #expect(Scheduler().policy == .batch)
        #expect(s.pick() == .decodeBatch(join: [1, 2]))
    }
}

/// Manual clock: the engine calls pick() at every unit start, so the test advances time by each unit's duration.
final class SchedulerFakeClock { var t = 0.0 }

@Suite struct PrefillBurstTests {
    private func sched(_ b: PrefillBurst) -> (Scheduler, SchedulerFakeClock) {
        var s = Scheduler()
        let c = SchedulerFakeClock()
        s.burst = b; s.clock = { c.t }
        return (s, c)
    }

    private func letter(_ u: Scheduler.Unit?) -> String {
        switch u {
        case .prefill?: return "P"
        case .decodeSolo?, .decodeBatch?: return "D"
        case nil: return "-"
        }
    }

    @Test func envParsing() {
        #expect(PrefillBurst.from(env: [:]) == PrefillBurst(units: Int.max, gapSeconds: 3.0))   // default on
        #expect(Scheduler().burst == PrefillBurst(units: Int.max, gapSeconds: 3.0))
        #expect(PrefillBurst.from(env: ["STRIM_PREFILL_GAP_MS": "0"]) == .legacy)
        #expect(PrefillBurst.from(env: ["STRIM_PREFILL_GAP_MS": "off"]) == .legacy)
        #expect(PrefillBurst.from(env: ["STRIM_PREFILL_GAP_MS": "3000"]) == PrefillBurst(units: Int.max, gapSeconds: 3.0))
        #expect(PrefillBurst.from(env: ["STRIM_PREFILL_GAP_MS": "1500"]) == PrefillBurst(units: Int.max, gapSeconds: 1.5))
        #expect(PrefillBurst.from(env: ["STRIM_PREFILL_BURST": "3"]) == PrefillBurst(units: 3, gapSeconds: 3.0))
        #expect(PrefillBurst.from(env: ["STRIM_PREFILL_BURST": "0"]).units == 1)
        #expect(PrefillBurst.from(env: ["STRIM_PREFILL_BURST": "2", "STRIM_PREFILL_GAP_MS": "250"])
            == PrefillBurst(units: 2, gapSeconds: 0.25))
    }

    /// Ordering guarantee: up to N prefill units run back to back while a decoder waits, then one decode unit.
    @Test func burstRunsNPrefillUnitsBeforeEachDecode() {
        let (s0, c) = sched(PrefillBurst(units: 3, gapSeconds: .infinity))
        var s = s0
        s.add(id: 1, priority: .interactive, phase: .decode)
        s.add(id: 2, priority: .interactive)
        var seq = ""
        for _ in 0 ..< 8 { c.t += 0.6; seq += letter(s.pick()) }
        #expect(seq == "PPPDPPPD")
    }

    /// Ordering guarantee: prefill wall time since the last decode unit is capped (inter-token gap).
    @Test func gapCapForcesDecodeAfterPrefillTime() {
        let (s0, c) = sched(PrefillBurst(units: Int.max, gapSeconds: 1.5))
        var s = s0
        s.add(id: 1, priority: .interactive, phase: .decode)
        s.add(id: 2, priority: .interactive)
        var seq = ""
        for _ in 0 ..< 6 { c.t += 0.6; seq += letter(s.pick()) }   // each unit lasts 0.6 s
        #expect(seq == "PPDPPD")   // unit 0.6 s, cap 1.5 s: decode when prefill run + predicted unit reaches the cap
    }

    /// Ordering guarantee: a prefill-only period (no decoder) does not charge the gap of a decoder that arrives later.
    @Test func prefillWithoutDecodersDoesNotCountAgainstTheGap() {
        let (s0, c) = sched(PrefillBurst(units: Int.max, gapSeconds: 1.5))
        var s = s0
        s.add(id: 2, priority: .interactive)
        for _ in 0 ..< 5 { c.t += 0.6; #expect(s.pick() == .prefill(2)) }
        s.add(id: 1, priority: .interactive, phase: .decode)
        c.t += 0.6
        #expect(s.pick() == .prefill(2))
        c.t += 0.6
        #expect(s.pick() == .prefill(2))
        c.t += 0.6
        #expect(s.pick() == .decodeSolo(1))
    }

    /// Invariant over a longer run: between two decode units, prefill wall time never exceeds the cap (predicted-unit rule).
    @Test func decodeNeverWaitsPastTheCapPlusOneUnit() {
        let cap = 1.5, unit = 0.6
        let (s0, c) = sched(PrefillBurst(units: Int.max, gapSeconds: cap))
        var s = s0
        s.add(id: 1, priority: .interactive, phase: .decode)
        for id in 2 ... 6 { s.add(id: id, priority: .interactive) }
        var sinceDecode = 0.0, worst = 0.0, decodes = 0
        for _ in 0 ..< 60 {
            switch s.pick() {
            case .prefill?: c.t += unit; sinceDecode += unit; worst = max(worst, sinceDecode)
            case .decodeSolo?, .decodeBatch?: c.t += 0.05; sinceDecode = 0; decodes += 1
            case nil: Issue.record("idle with work pending")
            }
        }
        #expect(decodes > 0)
        #expect(worst <= cap + 1e-9)
    }

    /// Legacy default is unchanged: one prefill unit, then one decode unit, regardless of the clock.
    @Test func legacyDefaultAlternatesOneToOne() {
        let (s0, c) = sched(.legacy)
        var s = s0
        s.add(id: 1, priority: .interactive, phase: .decode)
        s.add(id: 2, priority: .interactive)
        var seq = ""
        for _ in 0 ..< 6 { c.t += 5.0; seq += letter(s.pick()) }
        #expect(seq == "PDPDPD")
    }
}
