import Foundation
import MLX
import Testing
@testable import StrimEngine
@testable import StrimCore

/// Model-free stand-in for the cold prefill path: state after a chunk is a deterministic
/// function of the state before it and the chunk's tokens, so a restored state equals a
/// computed one exactly iff the partition and the stored value agree.
private enum Sim {
    static func fold(_ s: Float, _ chunk: ArraySlice<Int32>) -> Float {
        var v = s
        for t in chunk { v = Float((Int(v) * 31 + Int(t)) % 100_003) }
        return v
    }
    static func cache(end: Int, state: Float) -> ModelCache {
        let c = ModelCache()
        let a = c.attentionCache(3)
        let k = MLXArray(Array((0 ..< end * 2).map { Float($0) }), [1, 1, end, 2])
        _ = a.append(k, k)
        c.gdnState(0).conv = MLXArray.ones([1, 1, 2]) * state
        c.gdnState(0).ssm = MLXArray.ones([1, 1, 2]) * state
        c.position = end
        eval(c)
        return c
    }
    static func state(_ c: ModelCache) -> Float { c.gdn[0]!.ssm!.asArray(Float.self)[0] }

    /// One cold chunk exactly like `coldChunk`: adopt, compute to the next cut, insert.
    static func step(_ j: PrefillJob, store: PrefixStore?, policy: CutPolicy) throws {
        if let store { try j.adoptCachedPrefix(store, requireMTP: false) }
        let cut = policy.blockEnd(j.tokens, from: j.pos, limit: j.tokens.count)
        let end = cut ?? j.tokens.count
        let s = fold(j.pos == 0 ? 0 : state(j.live), j.tokens[j.pos ..< end])
        j.live = cache(end: end, state: s)
        j.pos = end
        if let store, j.canInsert, cut != nil {
            j.node = try store.insert(parent: j.node, tokens: Array(j.tokens[0 ..< end]), cache: j.live)
            if j.node == nil { j.canInsert = false }
        }
    }

    static func run(_ tokens: [Int32], store: PrefixStore?, policy: CutPolicy) throws -> (state: Float, matched: Int) {
        let j = PrefillJob(tokens: tokens, live: ModelCache())
        while !j.done { try step(j, store: store, policy: policy) }
        return (state(j.live), j.matched)
    }
}

@Suite struct LazyPrefixTests {
    static let policy = CutPolicy.fixed(4)

    private func prompt(tail: Int32) -> [Int32] { (0 ..< 12).map { Int32($0 + 1) } + (0 ..< 6).map { tail + Int32($0) } }

    /// 4 simultaneous identical-prefix requests, driven by the real Scheduler (FIFO prefill):
    /// the 3 followers must hit the leader's nodes, with outputs identical to a cold run.
    @Test func simultaneousRequestsReuseTheLeadersPrefix() throws {
        let store = PrefixStore(budgetBytes: 1 << 30, chunk: 4)
        let prompts = (0 ..< 4).map { prompt(tail: 100 * Int32($0 + 1)) }
        let jobs = prompts.map { PrefillJob(tokens: $0, live: ModelCache()) }
        // admission: nothing is looked up, so every job starts empty and unmatched
        #expect(jobs.allSatisfy { $0.pos == 0 && $0.matched == 0 && $0.node == nil })
        var sched = Scheduler()
        for i in 0 ..< 4 { sched.add(id: i, priority: .interactive) }
        var order: [Int] = []
        var guardN = 0
        while !jobs.allSatisfy({ $0.done }) {
            guardN += 1; #expect(guardN < 100)
            guard case let .prefill(id)? = sched.pick() else { Issue.record("no prefill unit"); break }
            if order.last != id { order.append(id) }
            try Sim.step(jobs[id], store: store, policy: Self.policy)
            if jobs[id].done { sched.remove(id) }
        }
        #expect(order == [0, 1, 2, 3])
        let hits = jobs.filter { $0.matched >= 12 }.count
        #expect(hits >= 3)
        #expect(jobs[0].matched == 0)
        for (i, j) in jobs.enumerated() {
            let ref = try Sim.run(prompts[i], store: nil, policy: Self.policy)
            #expect(Sim.state(j.live) == ref.state, "request \(i) output differs from cold")
            #expect(j.live.position == prompts[i].count)
        }
    }

    /// A follower whose first chunk already ran before the leader finished still picks the prefix
    /// up at a later chunk boundary.
    @Test func midPrefillRelookupJumpsAhead() throws {
        let store = PrefixStore(budgetBytes: 1 << 30, chunk: 4)
        let a = prompt(tail: 100), b = prompt(tail: 200)
        let jb = PrefillJob(tokens: b, live: ModelCache())
        try Sim.step(jb, store: store, policy: Self.policy)          // follower computes chunk 1 alone
        #expect(jb.pos == 4 && jb.matched == 0)
        _ = try Sim.run(a, store: store, policy: Self.policy)        // leader fills the trie meanwhile
        try Sim.step(jb, store: store, policy: Self.policy)
        #expect(jb.matched == 12 && jb.pos == 16)                    // jumped 4 -> 12, then computed to the next cut
        while !jb.done { try Sim.step(jb, store: store, policy: Self.policy) }
        #expect(Sim.state(jb.live) == (try Sim.run(b, store: nil, policy: Self.policy)).state)
    }

    /// Message-start cuts: turn N+1 restores up to the end of turn N's history.
    @Test func messageCutsMakeThePreviousTurnANode() throws {
        let im = CutPolicy.imStartId
        let policy = CutPolicy(maxBlock: 1024, minBlock: 4, boundary: im)
        func msg(_ n: Int, _ seed: Int32) -> [Int32] { [im] + (0 ..< n).map { Int32($0) + seed } }
        let turn1 = msg(300, 1) + msg(700, 5000) + [im, 77, 78]             // ... <im_start>assistant
        let turn2 = msg(300, 1) + msg(700, 5000) + msg(40, 9000) + msg(20, 9500) + [im, 77, 78]
        let store = PrefixStore(budgetBytes: 1 << 30, policy: policy)
        let r1 = try Sim.run(turn1, store: store, policy: policy)
        #expect(r1.matched == 0)
        let r2 = try Sim.run(turn2, store: store, policy: policy)
        #expect(r2.matched == 1002)                                         // every message of turn 1's history
        #expect(r2.state == (try Sim.run(turn2, store: nil, policy: policy)).state)
        // fixed 1024 blocks would have cached only 0 tokens here (history is 1002 tokens)
        let fixed = PrefixStore(budgetBytes: 1 << 30, chunk: 1024)
        _ = try Sim.run(turn1, store: fixed, policy: .fixed(1024))
        #expect(try Sim.run(turn2, store: fixed, policy: .fixed(1024)).matched == 0)
    }
}
