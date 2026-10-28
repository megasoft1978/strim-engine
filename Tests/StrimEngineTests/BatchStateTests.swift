import Foundation
import Testing
@testable import StrimEngine

/// Batching state machine of `Scheduler` (join, leave, cancel, mixed prefill + decode) and its
/// interaction with memory admission. Pure CPU: no MLX, no model.
@Suite struct BatchStateTests {
    private func batchSched(_ ids: ClosedRange<Int>) -> Scheduler {
        var s = Scheduler(); s.policy = .batch
        for i in ids { s.add(id: i, priority: .interactive, phase: .decode) }
        return s
    }

    @Test func fourDecodersJoinOneBatchInArrivalOrder() {
        var s = batchSched(1 ... 4)
        #expect(s.pick() == .decodeBatch(join: [1, 2, 3, 4]))
        #expect(s.batchMembers == [1, 2, 3, 4])
        #expect(s.pick() == .decodeBatch(join: []))   // lockstep: the next unit steps everyone, no re-join
    }

    @Test func leaveKeepsRemainingMembersLockstep() {
        var s = batchSched(1 ... 4)
        _ = s.pick()
        s.remove(2)
        #expect(s.batchMembers == [1, 3, 4])
        #expect(s.pick() == .decodeBatch(join: []))
        s.remove(1); s.remove(3)
        #expect(s.batchMembers == [4])
        // a batch of one still steps as a batch member (state already stacked), it never goes solo again
        #expect(s.pick() == .decodeBatch(join: []))
        s.remove(4)
        #expect(s.pick() == nil && s.isEmpty)
    }

    @Test func cancelWhileQueuedAndWhileBatchedFreesTheSlot() {
        var s = Scheduler(); s.policy = .batch
        s.add(id: 1, priority: .interactive, phase: .decode)
        s.add(id: 2, priority: .interactive, phase: .decode)
        s.add(id: 3, priority: .interactive)                 // still prefilling
        s.remove(3)                                          // cancel before it ever ran
        #expect(s.pick() == .decodeBatch(join: [1, 2]))
        s.remove(1)                                          // cancel a batch member
        #expect(s.batchMembers == [2] && s.count == 1)
        s.add(id: 4, priority: .interactive, phase: .decode)
        #expect(s.pick() == .decodeBatch(join: [4]))         // freed slot is reusable
        #expect(s.batchMembers == [2, 4])
    }

    @Test func newcomerPrefillInterleavesWithBatchedDecode() {
        var s = batchSched(1 ... 3)
        s.burst = .legacy                                     // pins the 1:1 alternation (default is the gap cap)
        _ = s.pick()
        s.add(id: 9, priority: .interactive)                  // arrives mid-decode
        var trace: [String] = []
        for _ in 0 ..< 6 {
            switch s.pick() {
            case .prefill(let id)?: trace.append("p\(id)"); if trace.filter({ $0 == "p9" }).count == 2 { s.setPhase(9, .decode) }
            case .decodeBatch(let j)?: trace.append(j.isEmpty ? "b" : "b+\(j)")
            default: trace.append("?")
            }
        }
        // decode never waits more than one prefill chunk, and the newcomer joins the live batch after prefill
        #expect(trace.first == "p9")
        var gap = 0, maxGap = 0
        for t in trace { if t == "p9" { gap += 1; maxGap = max(maxGap, gap) } else { gap = 0 } }
        #expect(maxGap <= 1)
        #expect(trace.contains("b+[9]"))
        #expect(s.batchMembers == [1, 2, 3, 9])
    }

    @Test func backgroundBatchPausesForInteractiveAndResumes() {
        var s = Scheduler(); s.policy = .batch
        s.add(id: 1, priority: .background, phase: .decode)
        s.add(id: 2, priority: .background, phase: .decode)
        #expect(s.pick() == .decodeBatch(join: [1, 2]))
        s.add(id: 7, priority: .interactive, phase: .decode)
        #expect(s.pick() == .decodeSolo(7))                   // background batch is not stepped while interactive work exists
        #expect(s.batchMembers == [1, 2])                     // ... but keeps its slots/state
        s.remove(7)
        #expect(s.pick() == .decodeBatch(join: []))
    }

    @Test func admissionAccountsEveryBatchMemberAndRejectsOverflow() {
        let GB = 1 << 30
        let per = MemoryModel.requestBytes(tokens: 700, mtp: true)        // 512-token prompt + 128 out
        let fixed = 20 * GB
        var active = 0
        var admitted = 0
        for _ in 0 ..< 400 {
            let d = Admission.decide(budget: 44 * GB, fixed: fixed, active: active, hot: [], needed: per)
            guard d.outcome == .admit else { break }
            active += per; admitted += 1
        }
        // 24 GiB headroom minus the 800 MiB chunk workspace: each member costs its KV plus a full GDN state
        #expect(admitted == (24 * GB - MemoryModel.workspaceBytes) / per)
        #expect(admitted >= 8)                                  // c=8 of 512-token agent prompts must fit
        let over = Admission.decide(budget: 44 * GB, fixed: fixed, active: active, hot: [], needed: per)
        if case .reject = over.outcome {} else { Issue.record("expected reject once the batch is full") }
        // a leaving member returns exactly its bytes
        let again = Admission.decide(budget: 44 * GB, fixed: fixed, active: active - per, hot: [], needed: per)
        #expect(again.outcome == .admit)
    }
}
