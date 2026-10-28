import Foundation
import MLX
import Testing
@testable import StrimCore

private let C = 4

/// Fake live cache at `blocks * C` tokens: 2 attention layers, 1 GDN layer.
private func fakeCache(blocks: Int, fill: Float) -> ModelCache {
    let n = blocks * C
    let c = ModelCache()
    for l in [3, 7] {
        let a = c.attentionCache(l)
        let k = MLXArray.ones([1, 2, n, 8]) * (fill + Float(l))
        _ = a.append(k, k + 1)
    }
    let s = c.gdnState(0)
    s.conv = MLXArray.ones([1, 3, 16]) * fill
    s.ssm = MLXArray.ones([1, 2, 4, 4]) * (fill + 1)
    c.position = n
    eval(c)
    return c
}

private func toks(_ n: Int, _ seed: Int32) -> [Int32] { (0 ..< n).map { Int32($0) &+ seed } }

@Test func prefixLookupDeepestAndLCP() throws {
    let store = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    let t = toks(3 * C, 0)
    var node: PrefixStore.Node? = nil
    for b in 1 ... 3 { node = try store.insert(parent: node, tokens: Array(t[0 ..< b * C]), cache: fakeCache(blocks: b, fill: 1)) }
    #expect(store.nodeCount == 3)
    // full match, capped by maxTokens
    #expect(store.lookup(t, maxTokens: 3 * C)?.depth == 3)
    #expect(store.lookup(t, maxTokens: 3 * C - 1)?.depth == 2)
    // diverges inside block 3 -> LCP = 2 blocks
    var u = t; u[2 * C + 1] = 999
    #expect(store.lookup(u, maxTokens: u.count)?.depth == 2)
    // unrelated
    #expect(store.lookup(toks(3 * C, 500), maxTokens: 3 * C) == nil)
    // second prefix coexists
    let t2 = toks(2 * C, 100)
    var n2: PrefixStore.Node? = nil
    for b in 1 ... 2 { n2 = try store.insert(parent: n2, tokens: Array(t2[0 ..< b * C]), cache: fakeCache(blocks: b, fill: 2)) }
    #expect(store.lookup(t2, maxTokens: 2 * C)?.depth == 2)
    #expect(store.lookup(t, maxTokens: 3 * C)?.depth == 3)
    // restore shape/position
    let r = try store.restore(store.lookup(t, maxTokens: 3 * C)!)
    #expect(r.position == 3 * C)
    #expect(r.attention[3]!.keys!.shape == [1, 2, 3 * C, 8])
    #expect(r.gdn[0]!.ssm != nil)
}

@Test func prefixRestoreMatchesLive() throws {
    let store = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    let t = toks(2 * C, 0)
    let live = ModelCache()
    // build live cache block by block like prefill does
    var node: PrefixStore.Node? = nil
    for b in 1 ... 2 {
        for l in [3] {
            let a = live.attentionCache(l)
            let k = MLXArray(Array((0 ..< C * 16).map { Float($0 + b * 1000) }), [1, 2, C, 8])
            _ = a.append(k, k * 2)
        }
        let s = live.gdnState(0); s.conv = MLXArray.ones([1, 3, 16]) * Float(b); s.ssm = MLXArray.ones([1, 2, 4, 4]) * Float(b)
        live.position = b * C
        eval(live)
        node = try store.insert(parent: node, tokens: Array(t[0 ..< b * C]), cache: live)
    }
    let r = try store.restore(store.lookup(t, maxTokens: 2 * C)!)
    #expect(abs(r.attention[3]!.keys! - live.attention[3]!.keys!).max().item(Float.self) == 0)
    #expect(abs(r.attention[3]!.values! - live.attention[3]!.values!).max().item(Float.self) == 0)
    #expect(abs(r.gdn[0]!.ssm! - live.gdn[0]!.ssm!).max().item(Float.self) == 0)
}

@Test func prefixStoredSnapshotIndependentOfLiveCache() throws {
    let store = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    let t = toks(C, 0)
    let live = fakeCache(blocks: 1, fill: 1)
    try store.insert(parent: nil, tokens: t, cache: live)
    let before = try store.restore(store.lookup(t, maxTokens: C)!)
    let kBefore = before.attention[3]!.keys!.asArray(Float.self)
    let sBefore = before.gdn[0]!.ssm!.asArray(Float.self)
    // Mutate the live cache: append more KV in place and replace GDN state.
    let a = live.attentionCache(3)
    _ = a.append(MLXArray.ones([1, 2, 5, 8]) * 77, MLXArray.ones([1, 2, 5, 8]) * 77)
    a.kbuf![0..., 0..., 0 ..< 2] = MLXArray.ones([1, 2, 2, 8]) * -5
    live.gdnState(0).ssm = MLXArray.ones([1, 2, 4, 4]) * 123
    eval(live)
    let after = try store.restore(store.lookup(t, maxTokens: C)!)
    #expect(after.attention[3]!.keys!.asArray(Float.self) == kBefore)
    #expect(after.gdn[0]!.ssm!.asArray(Float.self) == sBefore)
    // And mutating a restored cache must not reach the store.
    after.attention[3]!.kbuf![0..., 0..., 0 ..< 1] = MLXArray.ones([1, 2, 1, 8]) * 55
    _ = after.attention[3]!.append(MLXArray.ones([1, 2, 1, 8]), MLXArray.ones([1, 2, 1, 8]))
    eval(after)
    let again = try store.restore(store.lookup(t, maxTokens: C)!)
    #expect(again.attention[3]!.keys!.asArray(Float.self) == kBefore)
}

@Test func prefixLRUEvictsLeavesUnderBudget() throws {
    // Measure one node, budget for 3.
    let probe = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    try probe.insert(parent: nil, tokens: toks(C, 0), cache: fakeCache(blocks: 1, fill: 1))
    let per = probe.totalBytes
    #expect(per > 0)
    #expect(fakeCache(blocks: 1, fill: 1).byteSize > 0)

    let store = PrefixStore(budgetBytes: per * 3 + per / 2, chunk: C)
    let a = toks(C, 0), b = toks(C, 100), c = toks(C, 200), d = toks(C, 300)
    for t in [a, b, c] { try store.insert(parent: nil, tokens: t, cache: fakeCache(blocks: 1, fill: 1)) }
    #expect(store.nodeCount == 3)
    _ = store.lookup(a, maxTokens: C)          // a is now most recent; b is LRU
    try store.insert(parent: nil, tokens: d, cache: fakeCache(blocks: 1, fill: 1))
    #expect(store.nodeCount == 3 && store.evictions == 1)
    #expect(store.totalBytes <= store.budgetBytes)
    #expect(store.lookup(b, maxTokens: C) == nil)
    #expect(store.lookup(a, maxTokens: C) != nil)
    #expect(store.lookup(d, maxTokens: C) != nil)
    // Only leaves are evicted: a parent with a child survives.
    let two = toks(2 * C, 400)
    let p = try store.insert(parent: nil, tokens: Array(two[0 ..< C]), cache: fakeCache(blocks: 1, fill: 1))
    #expect(p != nil)
    let ch = try store.insert(parent: p, tokens: two, cache: fakeCache(blocks: 2, fill: 1))
    if ch != nil { #expect(store.lookup(two, maxTokens: 2 * C)?.depth == 2) }
    #expect(store.totalBytes <= store.budgetBytes)
}

@Test func prefixCollisionGuardVerifiesTokens() throws {
    let store = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    let t = toks(C, 0)
    try store.insert(parent: nil, tokens: t, cache: fakeCache(blocks: 1, fill: 1))
    var u = t; u[C - 1] += 1
    #expect(store.lookup(u, maxTokens: C) == nil)
}

private func mtpBlock(entries: Int, fill: Float) -> MTPBlock {
    MTPBlock(k: MLXArray.ones([1, 2, entries, 8]) * fill, v: MLXArray.ones([1, 2, entries, 8]) * (fill + 1),
             hidden: MLXArray.ones([1, 1, 16]) * fill)
}

@Test func prefixMTPBlocksStoreRestoreAndUpgrade() throws {
    let store = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    let t = toks(2 * C, 0)
    // block 0 stored without head state: spec lookups must not use it
    let n1 = try store.insert(parent: nil, tokens: Array(t[0 ..< C]), cache: fakeCache(blocks: 1, fill: 1))!
    #expect(store.lookup(t, maxTokens: 2 * C, requireMTP: true) == nil)
    let plainBytes = store.totalBytes
    // upgrade in place, then a child with head state
    _ = try store.insert(parent: nil, tokens: Array(t[0 ..< C]), cache: fakeCache(blocks: 1, fill: 1),
                         mtp: mtpBlock(entries: C - 1, fill: 3))
    #expect(n1.mtp != nil && store.totalBytes > plainBytes)
    let n2 = try store.insert(parent: n1, tokens: t, cache: fakeCache(blocks: 2, fill: 1),
                              mtp: mtpBlock(entries: C, fill: 5))!
    #expect(store.lookup(t, maxTokens: 2 * C, requireMTP: true)?.depth == 2)
    let r = try store.restoreMTP(n2)
    #expect(r.state.position == 2 * C - 1)
    #expect(r.state.attention.keys!.shape == [1, 2, 2 * C - 1, 8])
    #expect(r.carry.asArray(Float.self).allSatisfy { $0 == 5 })
    // a child can't take head state when its parent has none
    let store2 = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    let p = try store2.insert(parent: nil, tokens: Array(t[0 ..< C]), cache: fakeCache(blocks: 1, fill: 1))!
    let c = try store2.insert(parent: p, tokens: t, cache: fakeCache(blocks: 2, fill: 1), mtp: mtpBlock(entries: C, fill: 5))!
    #expect(c.mtp == nil)
    #expect(throws: PrefixCacheError.self) { try store2.restoreMTP(c) }
}

@Test func prefixInsertRejectsInconsistentInput() throws {
    let store = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    #expect(throws: PrefixCacheError.self) {
        try store.insert(parent: nil, tokens: toks(C, 0), cache: fakeCache(blocks: 2, fill: 1))
    }
}

private final class WeakNode { weak var node: PrefixStore.Node?; init(_ n: PrefixStore.Node?) { node = n } }

/// A dropped store must free every node (no parent/children retain cycle).
@Test func droppedStoreFreesNodes() throws {
    var refs: [WeakNode] = []
    do {
        let store = PrefixStore(budgetBytes: 1 << 30, chunk: C)
        let t = toks(3 * C, 0)
        var node: PrefixStore.Node? = nil
        for b in 1 ... 3 {
            node = try store.insert(parent: node, tokens: Array(t[0 ..< b * C]), cache: fakeCache(blocks: b, fill: 1))
            refs.append(WeakNode(node))
        }
        node = nil
        #expect(refs.allSatisfy { $0.node != nil })
        #expect(store.nodeCount == 3)
    }
    #expect(refs.allSatisfy { $0.node == nil })
}

/// Evicted leaves are released while the surviving chain stays intact and restorable.
@Test func evictedNodesAreFreed() throws {
    let probe = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    let one = try probe.insert(parent: nil, tokens: toks(C, 0), cache: fakeCache(blocks: 1, fill: 1))!.bytes
    let store = PrefixStore(budgetBytes: one * 2 + one / 2, chunk: C, thinStride: 0)
    let t = toks(3 * C, 0)
    var node: PrefixStore.Node? = nil
    var refs: [WeakNode] = []
    for b in 1 ... 3 {
        node = try store.insert(parent: node, tokens: Array(t[0 ..< b * C]), cache: fakeCache(blocks: b, fill: 1))
        refs.append(WeakNode(node))
    }
    node = nil
    #expect(store.nodeCount == 2 && store.evictions == 1)
    // Block 3 was inserted last but is a leaf with the oldest lastUse excluded: leaf 3 evicted
    // is only possible if it is the LRU leaf; assert exactly one of the three was freed.
    #expect(refs.filter { $0.node == nil }.count == 1)
    let hit = store.lookup(t, maxTokens: 3 * C)
    #expect(hit != nil)
    _ = try store.restore(hit!)
}

// MARK: cut policy and variable-length blocks

private let IM: Int32 = 9000

@Test func cutPolicyFixedMatchesOldLayout() {
    let p = CutPolicy.fixed(4)
    let t = toks(10, 0)
    #expect(p.blockEnd(t, from: 0, limit: 10) == 4)
    #expect(p.blockEnd(t, from: 4, limit: 10) == 8)
    #expect(p.blockEnd(t, from: 8, limit: 10) == nil)     // unaligned tail
    #expect(p.blockEnd(t, from: 4, limit: 7) == nil)      // limit short of the cap
    #expect(p.blockEnd(t, from: 4, limit: 8) == 8)
}

@Test func cutPolicyCutsBeforeBoundaryTokenWithMinAndMax() {
    let p = CutPolicy(maxBlock: 8, minBlock: 3, boundary: IM)
    var t = toks(20, 0)
    t[1] = IM            // too close to the block start (< min): ignored
    t[5] = IM            // first valid cut
    t[9] = IM
    #expect(p.blockEnd(t, from: 0, limit: 20) == 5)
    #expect(p.blockEnd(t, from: 5, limit: 20) == 9)       // 9 - 5 = 4 >= min
    #expect(p.blockEnd(t, from: 9, limit: 20) == 17)      // no boundary: size cap
    // undetermined when the visible tokens end before any cut is certain
    #expect(p.blockEnd(t, from: 9, limit: 14) == nil)
    // the boundary token itself must be visible
    #expect(p.blockEnd(t, from: 0, limit: 5) == nil)
    #expect(p.blockEnd(t, from: 0, limit: 6) == 5)
}

/// The partition of a prefix is the same whether or not more tokens follow (hit == miss chunks).
@Test func cutPartitionIsPrefixStable() {
    let p = CutPolicy(maxBlock: 8, minBlock: 2, boundary: IM)
    var t = toks(40, 0)
    for i in [6, 11, 12, 30] { t[i] = IM }
    func cuts(_ x: [Int32]) -> [Int] {
        var out: [Int] = [], pos = 0
        while let e = p.blockEnd(x, from: pos, limit: x.count) { out.append(e); pos = e }
        return out
    }
    let full = cuts(t)
    for n in 1 ... 40 {
        let part = cuts(Array(t[0 ..< n]))
        #expect(part == Array(full.prefix(part.count)), "n=\(n)")
        #expect(part.allSatisfy { $0 <= n })
    }
}

@Test func variableBlocksStoreLookupAndRestore() throws {
    let p = CutPolicy(maxBlock: 8, minBlock: 2, boundary: IM)
    let store = PrefixStore(budgetBytes: 1 << 30, policy: p)
    var t = toks(30, 0)
    t[5] = IM; t[9] = IM        // cuts: 5, 9, 17, 25
    var node: PrefixStore.Node? = nil
    var pos = 0
    while let e = p.blockEnd(t, from: pos, limit: t.count) {
        let c = ModelCache()
        let a = c.attentionCache(3)
        let k = MLXArray(Array((0 ..< e * 8).map { Float($0) }), [1, 1, e, 8])
        _ = a.append(k, k)
        c.gdnState(0).conv = MLXArray.ones([1, 3, 16]) * Float(e)
        c.gdnState(0).ssm = MLXArray.ones([1, 2, 4, 4]) * Float(e)
        c.position = e
        eval(c)
        node = try store.insert(parent: node, tokens: Array(t[0 ..< e]), cache: c)
        pos = e
    }
    #expect(store.nodeCount == 4 && node?.end == 25 && node?.depth == 4)
    #expect(store.lookup(t, maxTokens: 30)?.end == 25)
    #expect(store.lookup(t, maxTokens: 24)?.end == 17)     // cap must leave the cut visible
    // same first message, different second: shares the first node only
    var u = t; u[7] = 4242
    #expect(store.lookup(u, maxTokens: 30)?.end == 5)
    let r = try store.restore(store.lookup(t, maxTokens: 30)!)
    #expect(r.position == 25)
    #expect(r.attention[3]!.keys!.shape == [1, 1, 25, 8])
    #expect(r.gdn[0]!.ssm!.asArray(Float.self).allSatisfy { $0 == 25 })
    // insert rejects a block longer than the cap
    #expect(throws: PrefixCacheError.self) {
        try store.insert(parent: nil, tokens: toks(9, 100), cache: fakeCache(blocks: 0, fill: 1))
    }
}

// MARK: assistant-start cuts

@Test func assistantStartCutsShortBlocks() {
    let b: Int32 = 900, a: Int32 = 901
    let p = CutPolicy(maxBlock: 16, minBlock: 8, boundary: b, assistant: a, assistantMin: 3)
    // `<|im_start|>assistant` 4 tokens in: short block, cuts there.
    var t: [Int32] = [1, 2, 3, 4, b, a, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]
    #expect(p.blockEnd(t, from: 0, limit: t.count) == 4)
    // a user-start that short does not cut (needs minBlock) and the next one after minBlock does
    t = [1, 2, 3, 4, b, 6, 7, 8, 9, b, 11, 12, 13, 14, 15, 16, 17, 18]
    #expect(p.blockEnd(t, from: 0, limit: t.count) == 9)
    // the decision needs the token after the boundary: undetermined while it is beyond `limit`
    t = [1, 2, 3, 4, b, a, 7]
    #expect(p.blockEnd(t, from: 0, limit: 5) == nil)
    #expect(p.blockEnd(t, from: 0, limit: 6) == 4)
    // same cut for any token array that agrees on [pos ..< e] and the two tokens after it
    var u = t; u[6] = 55
    #expect(p.blockEnd(u, from: 0, limit: u.count) == 4)
    // below assistantMin the boundary is ignored
    t = [1, 2, b, a, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]
    #expect(p.blockEnd(t, from: 0, limit: t.count) == 16)
}

// MARK: thinning GDN state under pressure

@Test func thinningKeepsKVAndSnapsHitsToStatefulAncestor() throws {
    let blocks = 8
    let t = toks(blocks * C, 0)
    // Budget that cannot hold 8 full nodes: the interior ones off the stride-4 grid get thinned.
    let probe = PrefixStore(budgetBytes: 1 << 30, chunk: C, thinStride: 4)
    var pn: PrefixStore.Node? = nil
    for b in 1 ... blocks { pn = try probe.insert(parent: pn, tokens: Array(t[0 ..< b * C]), cache: fakeCache(blocks: b, fill: 1)) }
    let full = probe.totalBytes
    #expect(probe.thinned == 0)

    let store = PrefixStore(budgetBytes: full - 3 * (full / blocks / 4), chunk: C, thinStride: 4)
    var node: PrefixStore.Node? = nil
    for b in 1 ... blocks { node = try store.insert(parent: node, tokens: Array(t[0 ..< b * C]), cache: fakeCache(blocks: b, fill: 1)) }
    #expect(store.thinned > 0)
    #expect(store.totalBytes <= store.budgetBytes)
    #expect(store.nodeCount == blocks)                       // thinning drops state, not nodes
    // the tip keeps its state; an interior thinned depth is skipped by lookup
    #expect(store.lookup(t, maxTokens: blocks * C)?.depth == blocks)
    let mid = store.lookup(Array(t[0 ..< 3 * C + 1]), maxTokens: 3 * C + 1)
    if let m = mid { #expect(m.hasState); let r = try store.restore(m); #expect(r.position == m.end); #expect(r.attention[3]!.keys!.shape[2] == m.end) }
    // restore at the tip still concatenates KV through thinned ancestors
    let tip = try store.restore(store.lookup(t, maxTokens: blocks * C)!)
    #expect(tip.position == blocks * C)
    #expect(tip.attention[3]!.keys!.shape == [1, 2, blocks * C, 8])
    // explicit shrink frees more
    let before = store.totalBytes
    #expect(store.shrink(to: before / 2))
    #expect(store.totalBytes <= before / 2)
}

// MARK: tail merge (L1b)

@Test func tailMergeRunsShortPromptAsOneChunk() {
    let b: Int32 = 900, a: Int32 = 901
    let off = CutPolicy(maxBlock: 64, minBlock: 32, boundary: b, assistant: a, assistantMin: 16)
    let on = CutPolicy(maxBlock: 64, minBlock: 32, boundary: b, assistant: a, assistantMin: 16, tailFloor: 8, tailMergeMax: 48)
    // 40-token prompt whose generation prompt (`<|im_start|>assistant\n`, 3 tokens) starts at 37.
    let t = (0 ..< 37).map { Int32($0 + 1) } + [b, a, 5]
    #expect(off.blockEnd(t, from: 0, limit: t.count) == 37)          // old: 37 + 3 tail chunk
    #expect(on.blockEnd(t, from: 0, limit: t.count) == nil)          // new: single chunk
    // tail at or above the floor still cuts
    let u = (0 ..< 30).map { Int32($0 + 1) } + [b, a, 5, 6, 7, 8, 9, 10, 11, 12]
    #expect(on.blockEnd(u, from: 0, limit: u.count) == 30)
    // prompts above tailMergeMax keep the cut the next turn reuses
    let v = (0 ..< 57).map { Int32($0 + 1) } + [b, a, 5]
    #expect(on.blockEnd(v, from: 0, limit: v.count) == 57)
    // later blocks (pos > 0) are never merged
    #expect(on.blockEnd(v, from: 20, limit: v.count) == 57)
    // max chunk invariant: tailMergeMax is clamped to maxBlock
    #expect(CutPolicy(maxBlock: 16, tailFloor: 8, tailMergeMax: 99).tailMergeMax == 16)
    // lookup (limit = count - 1) never keeps a cut that the chunk loop (limit = count) merges
    for n in 30 ... 48 {
        let w = (0 ..< n - 3).map { Int32($0 + 1) } + [b, a, 5]
        let full = on.blockEnd(w, from: 0, limit: w.count), look = on.blockEnd(w, from: 0, limit: w.count - 1)
        if full == nil { #expect(look == nil) }
    }
}

@Test func tailMergeDefaultsAndOptOut() {
    let p = PrefixPrefill.defaultPolicy
    #expect(p.tailFloor == PrefixPrefill.defaultTailFloor && p.tailMergeMax == PrefixPrefill.defaultTailMergeMax)
    #expect(CutPolicy.fixed(1024).tailFloor == 0)
    let b = p.boundary!, a = p.assistant!
    // 523-token chat prompt: 512 body, then `<|im_start|>assistant\n<think>\n` style 11-token tail
    let t: [Int32] = (0 ..< 512).map { Int32($0 % 1000 + 1) } + [b, a] + (0 ..< 9).map { Int32($0 + 3) }
    #expect(p.blockEnd(t, from: 0, limit: t.count) == nil)
}

// MARK: windowed MTP head (speed wave 2 L3b)

private func windowBlock(start: Int, entries: Int, fill: Float) -> MTPBlock {
    MTPBlock(k: MLXArray.ones([1, 2, entries, 8]) * fill, v: MLXArray.ones([1, 2, entries, 8]) * (fill + 1),
             hidden: MLXArray.ones([1, 1, 16]) * fill, start: start)
}

@Test func mtpStateBaseKeepsLogicalPositionsAligned() {
    let m = MTPState()
    m.base = 10
    _ = m.attention.append(MLXArray.ones([1, 2, 6, 8]), MLXArray.ones([1, 2, 6, 8]))
    #expect(m.position == 16)
    m.trim(to: 13)                       // drop logical entries >= 13
    #expect(m.position == 13 && m.attention.offset == 3)
    m.trim(to: 20)                       // beyond the end: nothing to drop
    #expect(m.position == 13)
    m.trim(to: 4)                        // before the window: empty head moved to 4
    #expect(m.position == 4 && m.attention.offset == 0 && m.base == 4)
    let full = MTPState()                // base 0 behaves like the old offset-based trim
    _ = full.attention.append(MLXArray.ones([1, 2, 5, 8]), MLXArray.ones([1, 2, 5, 8]))
    full.trim(to: 2)
    #expect(full.position == 2 && full.attention.offset == 2)
    full.trim(to: 0)
    #expect(full.position == 0 && full.base == 0)
}

@Test func windowedMTPBlocksSkipEarlyNodesAndRestoreFromTheWindow() throws {
    let store = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    let t = toks(3 * C, 0)
    let n1 = try store.insert(parent: nil, tokens: Array(t[0 ..< C]), cache: fakeCache(blocks: 1, fill: 1))!
    // window starts at entry C+1 (inside block 1): its block has no parent block; legacy insert refuses it
    let refused = try store.insert(parent: n1, tokens: Array(t[0 ..< 2 * C]), cache: fakeCache(blocks: 2, fill: 1),
                                   mtp: windowBlock(start: C + 1, entries: C - 2, fill: 5))!
    #expect(refused.mtp == nil)
    let store2 = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    let m1 = try store2.insert(parent: nil, tokens: Array(t[0 ..< C]), cache: fakeCache(blocks: 1, fill: 1))!
    let m2 = try store2.insert(parent: m1, tokens: Array(t[0 ..< 2 * C]), cache: fakeCache(blocks: 2, fill: 1),
                               mtp: windowBlock(start: C + 1, entries: C - 2, fill: 5), windowedHead: true)!
    let m3 = try store2.insert(parent: m2, tokens: t, cache: fakeCache(blocks: 3, fill: 1),
                               mtp: windowBlock(start: 2 * C - 1, entries: C, fill: 7), windowedHead: true)!
    #expect(m2.mtp != nil && m3.mtp != nil)
    // whole-chain lookups (non-windowed requests) stop at the headless first node
    #expect(store2.lookup(t, maxTokens: 3 * C, requireMTP: true) == nil)
    #expect(store2.lookup(t, maxTokens: 3 * C)?.depth == 3)
    // restore from the start of the stored run
    let r = store2.restoreMTPWindow(m3, from: 0)
    #expect(r.state.base == C + 1 && r.state.position == 3 * C - 1)
    #expect(r.carry!.asArray(Float.self).allSatisfy { $0 == 7 })
    // restore with a later window start drops the leading entries
    let r2 = store2.restoreMTPWindow(m3, from: 2 * C)
    #expect(r2.state.base == 2 * C && r2.state.position == 3 * C - 1)
    #expect(r2.state.attention.keys!.shape == [1, 2, C - 1, 8])
    // window starting past the stored entries: empty head at the end of the run, carry kept
    let r3 = store2.restoreMTPWindow(m3, from: 10 * C)
    #expect(r3.state.base == 3 * C - 1 && r3.state.attention.keys == nil && r3.carry != nil)
    // headless node: empty head at the node end, no carry
    let r4 = store2.restoreMTPWindow(m1, from: 0)
    #expect(r4.state.base == C && r4.state.position == C && r4.carry == nil)
}

@Test func nonContiguousMTPBlocksNeverJoin() throws {
    let store = PrefixStore(budgetBytes: 1 << 30, chunk: C)
    let t = toks(3 * C, 0)
    let a = try store.insert(parent: nil, tokens: Array(t[0 ..< C]), cache: fakeCache(blocks: 1, fill: 1),
                             mtp: windowBlock(start: 0, entries: C - 1, fill: 3))!
    // a gap: next block starts at 2C instead of C-1
    let b = try store.insert(parent: a, tokens: Array(t[0 ..< 2 * C]), cache: fakeCache(blocks: 2, fill: 1),
                             mtp: windowBlock(start: 2 * C, entries: C - 1, fill: 5))!
    #expect(store.lookup(t, maxTokens: 2 * C, requireMTP: true)?.depth == 1)
    let r = store.restoreMTPWindow(b, from: 0)
    #expect(r.state.base == 2 * C && r.state.attention.offset == C - 1)
}
