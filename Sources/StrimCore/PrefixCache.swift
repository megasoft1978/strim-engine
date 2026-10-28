import Foundation
import MLX

/// Where prefill chunk boundaries (and trie nodes) sit. The partition is a pure function of
/// the token prefix, so a miss and a hit execute identical chunks and the cache stays exact.
/// - `boundary == nil`: fixed blocks of `maxBlock` tokens (the original layout).
/// - `boundary` set (the `<|im_start|>` id): a block ends at the first boundary token at least
///   `minBlock` tokens after the block start, or `maxBlock` tokens after it, whichever is first.
///   Chunks never exceed `maxBlock`; the cut sits before the boundary token.
public struct CutPolicy: Equatable, Sendable {
    public let maxBlock: Int
    public let minBlock: Int
    public let boundary: Int32?
    /// Role token that follows `boundary` for an assistant turn (`<|im_start|>assistant`). A boundary
    /// followed by it cuts after only `assistantMin` tokens, so the end of a chat prompt (the
    /// generation prompt) is almost always a cut and the next turn reuses the whole previous prompt.
    public let assistant: Int32?
    public let assistantMin: Int
    /// Tail merge: a short prompt (`limit <= tailMergeMax`, itself at most `maxBlock`) whose last cut would
    /// leave fewer than `tailFloor` tokens is prefilled as ONE chunk. The leftover chunk (typically the
    /// `<|im_start|>assistant` generation prompt, ~11 tokens) pays a full weight-streaming pass (~66 ms)
    /// for no work. Only first blocks qualify: longer prompts keep the cut the next turn reuses.
    public let tailFloor: Int
    public let tailMergeMax: Int
    public init(maxBlock: Int, minBlock: Int = 0, boundary: Int32? = nil, assistant: Int32? = nil, assistantMin: Int = 256,
                tailFloor: Int = 0, tailMergeMax: Int = 0) {
        precondition(maxBlock > 0)
        self.maxBlock = maxBlock; self.minBlock = max(min(minBlock, maxBlock), 1); self.boundary = boundary
        self.assistant = assistant; self.assistantMin = max(min(assistantMin, self.minBlock), 1)
        self.tailFloor = max(tailFloor, 0); self.tailMergeMax = min(max(tailMergeMax, 0), maxBlock)
    }

    /// True when the cut at `e` is dropped by the tail merge. Monotone in `limit`: a smaller limit
    /// (the lookup passes count-1) merges at least whenever the chunk loop does, so a lookup never
    /// walks to a node the chunk loop would not cut.
    func tailMerged(_ e: Int, pos: Int, limit: Int) -> Bool {
        tailFloor > 0 && pos == 0 && limit <= tailMergeMax && limit - e < tailFloor
    }
    public static func fixed(_ n: Int) -> CutPolicy { CutPolicy(maxBlock: n) }
    /// Fallback `<|im_start|>` id (Qwen2.5/3); the engine overrides it from the tokenizer.
    public static let imStartId: Int32 = 151_644

    /// End (exclusive) of the block starting at `pos`, decided from `tokens[..<limit]` only;
    /// nil when those tokens do not determine it (the unaligned tail). A returned `e` is the
    /// same for every token array that agrees with `tokens` on `[pos ..< e]` (and, for a
    /// boundary cut, on `tokens[e]`), which is what makes hit and miss partitions identical.
    public func blockEnd(_ tokens: [Int32], from pos: Int, limit: Int) -> Int? {
        let limit = min(limit, tokens.count)
        let cap = pos + maxBlock
        if let b = boundary {
            var p = pos + (assistant == nil ? minBlock : assistantMin)
            while p < cap && p < limit {
                if tokens[p] == b {
                    if p - pos >= minBlock { return tailMerged(p, pos: pos, limit: limit) ? nil : p }
                    // Short block: cut only before `<|im_start|>assistant`, which needs the next token.
                    if p + 1 >= limit { return nil }
                    if tokens[p + 1] == assistant { return tailMerged(p, pos: pos, limit: limit) ? nil : p }
                }
                p += 1
            }
        }
        return cap <= limit ? cap : nil
    }
}

/// Exact prefix cache. Prefill runs in chunks whose ends are `CutPolicy` cuts, so a
/// miss and a hit execute identical arithmetic for every chunk. Snapshots exist only at
/// cut boundaries; the tail after the last determined cut is always recomputed.
///
/// Storage is a trie of blocks (<= `chunk` tokens, ending at policy cuts). A node holds only its own block's KV delta (per
/// attention layer) plus the GDN conv/ssm state at its end boundary, so entries along one
/// chain share KV by construction. Restoring concatenates the chain's blocks into fresh
/// buffers with capacity == offset (the same layout a miss has at that boundary).
public enum PrefixCacheError: Error, CustomStringConvertible {
    case emptyPrompt
    case inconsistent(String)
    public var description: String {
        switch self {
        case .emptyPrompt: return "prefix prefill needs at least one token"
        case .inconsistent(let m): return "prefix cache inconsistent: \(m)"
        }
    }
}

/// MTP head state for one aligned block: the head KV entries its prefill chunk produced
/// (entries lo-1 ..< hi-1; block 0 has no entry -1) plus the final-normed target hidden at
/// hi-1, which pairs with the NEXT block's first token to form entry hi-1.
public struct MTPBlock {
    public let k: MLXArray      // [1,Hkv,n,D]
    public let v: MLXArray
    public let hidden: MLXArray // [1,1,5120]
    /// Logical head index of the first stored entry (`lo`); -1 = unspecified (contiguous chain assumed).
    /// Blocks of a full head chain are contiguous from 0; a windowed head (MTPState.base > 0) starts later.
    public let start: Int
    public var entries: Int { k.shape[2] }
    public var bytes: Int { k.nbytes + v.nbytes + hidden.nbytes }
    public init(k: MLXArray, v: MLXArray, hidden: MLXArray, start: Int = -1) {
        self.k = k; self.v = v; self.hidden = hidden; self.start = start
    }
}

public final class PrefixStore {
    public final class Node {
        let tokens: [Int32]                    // this block's tokens (collision guard)
        /// Weak: children own their subtree, so a parent pointer must not close a cycle.
        /// Ancestors of any live trie node stay alive through their `children`.
        weak var parent: Node?
        var children: [UInt64: [Node]] = [:]
        public let depth: Int                  // blocks from root, 1-based
        public let end: Int                    // tokens from root through this block
        var hash: UInt64 = 0                   // chain hash through this block
        var k: [Int: MLXArray] = [:]           // attention layer -> [1,Hkv,C,D]
        var v: [Int: MLXArray] = [:]
        var conv: [Int: MLXArray] = [:]
        var ssm: [Int: MLXArray] = [:]
        var mtp: MTPBlock?
        var bytes = 0
        var stateBytes = 0                     // conv + ssm (dropped by `thinState` under budget pressure)
        var lastUse = 0
        var evicted = false
        /// Disk-cache key (hash chain through this block); nil when the disk cache is off.
        var diskKey: Data?
        /// A hit point needs the GDN state at its end; a thinned interior node keeps only its KV/MTP block.
        var hasState: Bool { !ssm.isEmpty }
        init(tokens: [Int32], parent: Node?, depth: Int) {
            self.tokens = tokens; self.parent = parent; self.depth = depth
            self.end = (parent?.end ?? 0) + tokens.count
        }
    }

    /// Default trie budget in MiB (57 nodes of ~215 MiB = 58K tokens).
    public static let defaultBudgetMB = 12288
    public static let defaultThinStride = 4

    public let chunk: Int                      // max block size (policy.maxBlock)
    public let policy: CutPolicy
    public let budgetBytes: Int
    public private(set) var totalBytes = 0
    public private(set) var nodeCount = 0
    public private(set) var evictions = 0
    public private(set) var thinned = 0
    /// Under budget pressure interior nodes off every `thinStride`-th block lose their GDN state first (<= 1: never).
    public let thinStride: Int
    private var rootChildren: [UInt64: [Node]] = [:]
    private var tick = 0
    /// Opt-in disk spill (`STRIM_PREFIX_DISK=1`); nil = memory-only, no extra work anywhere.
    public var disk: PrefixDisk?

    /// An explicit `chunk` means fixed blocks of that size; otherwise `policy` (default: `PrefixPrefill.defaultPolicy`).
    public init(budgetBytes: Int, chunk: Int? = nil, policy: CutPolicy? = nil, thinStride: Int? = nil) {
        let p = chunk.map { CutPolicy.fixed($0) } ?? policy ?? PrefixPrefill.defaultPolicy
        self.budgetBytes = budgetBytes; self.policy = p; self.chunk = p.maxBlock
        self.thinStride = thinStride ?? Int(ProcessInfo.processInfo.environment["STRIM_PREFIX_GDN_STRIDE"] ?? "") ?? Self.defaultThinStride
    }

    /// nil when `STRIM_PREFIX_CACHE=0`. Budget from `STRIM_PREFIX_CACHE_MB` (default `defaultBudgetMB`).
    public static func fromEnvironment() -> PrefixStore? {
        let env = ProcessInfo.processInfo.environment
        if env["STRIM_PREFIX_CACHE"] == "0" { return nil }
        let mb = Int(env["STRIM_PREFIX_CACHE_MB"] ?? "") ?? defaultBudgetMB
        return PrefixStore(budgetBytes: mb << 20)
    }

    static func blockHash(_ parent: UInt64, _ toks: ArraySlice<Int32>) -> UInt64 {
        var h = parent ^ 0xcbf2_9ce4_8422_2325
        for t in toks { h = (h ^ UInt64(UInt32(bitPattern: t))) &* 0x0000_0100_0000_01b3 }
        return h
    }

    private func find(_ children: [UInt64: [Node]], _ h: UInt64, _ toks: ArraySlice<Int32>) -> Node? {
        children[h]?.first { $0.tokens.elementsEqual(toks) }
    }

    private struct Walk { var node: Node?; var last: Node?; var pos: Int; var mtpStop: Bool }

    private func walk(_ tokens: [Int32], limit: Int, requireMTP: Bool) -> Walk {
        var w = Walk(node: nil, last: nil, pos: 0, mtpStop: false)
        var h: UInt64 = 0
        var children = rootChildren
        var prevBlock: MTPBlock? = nil
        while let e = policy.blockEnd(tokens, from: w.pos, limit: limit) {
            let blk = tokens[w.pos ..< e]
            h = Self.blockHash(h, blk)
            guard let next = find(children, h, blk) else { break }
            if requireMTP {
                // Whole chain must carry head state, and consecutive blocks must be contiguous
                // (a windowed head leaves the early nodes without blocks; see MTPBlock.start).
                guard let b = next.mtp else { w.mtpStop = true; break }
                if let p = prevBlock, p.start >= 0, b.start >= 0, p.start + p.entries != b.start { w.mtpStop = true; break }
                prevBlock = b
            }
            if next.hasState { w.node = next }
            w.last = next
            children = next.children; w.pos = e
        }
        return w
    }

    /// Deepest aligned entry matching a prefix of `tokens`, using at most `maxTokens` tokens.
    /// Marks the matched chain as recently used.
    /// With `requireMTP`, only nodes carrying head state (and whose whole chain does) count.
    /// With a disk cache, a memory miss continues on disk: verified files for the following blocks are loaded
    /// into the trie (within the memory budget) and the walk is repeated.
    public func lookup(_ tokens: [Int32], maxTokens: Int, requireMTP: Bool = false) -> Node? {
        let limit = min(tokens.count, maxTokens)
        var w = walk(tokens, limit: limit, requireMTP: requireMTP)
        if let disk, !w.mtpStop, loadFromDisk(disk, tokens: tokens, limit: limit, from: w.last, pos: w.pos) {
            w = walk(tokens, limit: limit, requireMTP: requireMTP)
        }
        let node = w.node
        tick += 1
        var n = node
        while let x = n { x.lastUse = tick; n = x.parent }
        if let disk, let k = node?.diskKey { disk.touch(k) }
        return node
    }

    /// Loads the longest run of verified disk nodes following `last` (nil = root) for `tokens[pos...]`.
    /// Each node counts against `budgetBytes` exactly like an inserted one; nothing beyond one node's tensors
    /// is transiently held. Returns true if at least one node was attached.
    private func loadFromDisk(_ disk: PrefixDisk, tokens: [Int32], limit: Int, from last: Node?, pos: Int) -> Bool {
        var pk: Data
        if let last { guard let k = last.diskKey else { return false }; pk = k } else { pk = disk.rootKey }
        var plan: [(key: Data, range: Range<Int>)] = []
        var p = pos
        while let e = policy.blockEnd(tokens, from: p, limit: limit) {
            let k = disk.key(parent: pk, tokens: tokens[p ..< e])
            guard disk.has(k) else { break }
            plan.append((k, p ..< e)); pk = k; p = e
        }
        guard !plan.isEmpty else { return false }
        let t0 = Date()
        let files = disk.readVerified(plan.map { $0.key })
        var parent = last
        var loaded = 0, bytes = 0
        for (i, f) in files.enumerated() {
            if let parent, parent.evicted { break }
            let need = f.bytes
            if need > budgetBytes { break }
            if totalBytes + need > budgetBytes {
                // Protect the chain being extended, then make room the same way an insert would.
                tick += 1
                var n = parent
                while let x = n { x.lastUse = tick; n = x.parent }
                reclaim(to: budgetBytes - need)
                if let parent, parent.evicted { break }
                if totalBytes + need > budgetBytes { break }
            }
            let blk = Array(tokens[plan[i].range])
            let h = Self.blockHash(parent?.hash ?? 0, blk[...])
            guard let node = PrefixDisk.makeNode(f, tokens: blk, parent: parent, hash: h, key: plan[i].key) else { break }
            tick += 1; node.lastUse = tick
            if let parent { parent.children[h, default: []].append(node) } else { rootChildren[h, default: []].append(node) }
            totalBytes += node.bytes; nodeCount += 1
            loaded += 1; bytes += node.bytes
            parent = node
        }
        if loaded > 0 { disk.recordLoad(nodes: loaded, bytes: bytes, seconds: Date().timeIntervalSince(t0)) }
        return loaded > 0
    }

    private func chain(of node: Node) -> [Node] {
        var chain: [Node] = []
        var n: Node? = node
        while let x = n { chain.append(x); n = x.parent }
        return chain.reversed()
    }

    /// Fresh, independent ModelCache holding the state at `node`'s boundary.
    public func restore(_ node: Node) throws -> ModelCache {
        let chain = chain(of: node)
        let c = ModelCache()
        for layer in node.k.keys {
            let a = AttentionCache()
            let kl = chain.map { $0.k[layer] }, vl = chain.map { $0.v[layer] }
            guard kl.allSatisfy({ $0 != nil }), vl.allSatisfy({ $0 != nil }) else {
                throw PrefixCacheError.inconsistent("layer \(layer) missing in chain")
            }
            let ks = kl.compactMap { $0 }, vs = vl.compactMap { $0 }
            // Fresh objects either way: never hand the stored MLXArray to a live cache.
            a.keys = ks.count == 1 ? ks[0][0..., 0..., 0...] : concatenated(ks, axis: 2)
            a.values = vs.count == 1 ? vs[0][0..., 0..., 0...] : concatenated(vs, axis: 2)
            c.attention[layer] = a
        }
        for layer in node.ssm.keys {
            let s = GDNState(); s.conv = node.conv[layer]; s.ssm = node.ssm[layer]
            c.gdn[layer] = s
        }
        c.position = node.end
        return c
    }

    /// Fresh MTPState holding head entries 0 ..< depth*chunk-1 at `node`'s boundary, and the
    /// target hidden at the boundary's last position (the carry for the next chunk).
    public func restoreMTP(_ node: Node) throws -> (state: MTPState, carry: MLXArray) {
        let blocks = chain(of: node).map { $0.mtp }
        guard blocks.allSatisfy({ $0 != nil }), let last = blocks.last, let lastBlock = last else {
            throw PrefixCacheError.inconsistent("MTP block missing in chain")
        }
        let bs = blocks.compactMap { $0 }
        let m = MTPState()
        m.attention.keys = bs.count == 1 ? bs[0].k[0..., 0..., 0...] : concatenated(bs.map { $0.k }, axis: 2)
        m.attention.values = bs.count == 1 ? bs[0].v[0..., 0..., 0...] : concatenated(bs.map { $0.v }, axis: 2)
        return (m, lastBlock.hidden)
    }

    /// Head state for a request whose MTP head covers only the last window of the prompt
    /// (`from` = first logical head entry it wants; nodes before the window carry no block).
    /// Uses the longest run of blocks ending at `node` whose entries are contiguous, drops
    /// entries before `from`, and sets `MTPState.base`. A node without a block gives an empty
    /// head positioned at `node.end` and no carry (the next chunk then starts its first
    /// entry at the chunk start instead of one before it). Never throws: a missing or
    /// non-contiguous chain only shortens the window.
    public func restoreMTPWindow(_ node: Node, from: Int) -> (state: MTPState, carry: MLXArray?) {
        let m = MTPState()
        guard let tail = node.mtp else { m.base = node.end; return (m, nil) }
        if tail.start < 0, let r = try? restoreMTP(node) { return (r.state, r.carry) }   // unspecified starts: full chain from 0
        if tail.start < 0 { m.base = node.end; return (m, nil) }
        var run: [MTPBlock] = [tail]
        var n = node.parent
        while let x = n, let b = x.mtp, b.start >= 0, run[0].start >= 0, b.start + b.entries == run[0].start {
            run.insert(b, at: 0); n = x.parent
        }
        var ks = run.map { $0.k }, vs = run.map { $0.v }
        var start = run[0].start
        if start < from {
            let total = run.reduce(0) { $0 + $1.entries }
            let cut = min(from - start, total)
            if cut >= total { m.base = start + cut; return (m, tail.hidden) }
            let k = ks.count == 1 ? ks[0] : concatenated(ks, axis: 2)
            let v = vs.count == 1 ? vs[0] : concatenated(vs, axis: 2)
            ks = [k[0..., 0..., cut..., 0...]]; vs = [v[0..., 0..., cut..., 0...]]
            start += cut
        }
        m.base = start
        m.attention.keys = ks.count == 1 ? ks[0][0..., 0..., 0...] : concatenated(ks, axis: 2)
        m.attention.values = vs.count == 1 ? vs[0][0..., 0..., 0...] : concatenated(vs, axis: 2)
        return (m, tail.hidden)
    }

    /// Store the boundary at `parent.depth + 1` blocks from the live `cache` (whose position
    /// must equal that boundary). Copies the block's KV delta; GDN arrays are immutable
    /// values, held by reference. Evicts LRU leaves to stay under budget; returns nil if the
    /// new node itself did not fit (callers then stop inserting along this chain).
    @discardableResult
    public func insert(parent: Node?, tokens: [Int32], cache: ModelCache,
                       mtp: MTPBlock? = nil, windowedHead: Bool = false, asyncEval: Bool = false) throws -> Node? {
        let depth = (parent?.depth ?? 0) + 1
        let lo = parent?.end ?? 0, hi = tokens.count
        guard hi > lo, hi - lo <= chunk, cache.position == hi else {
            throw PrefixCacheError.inconsistent("insert at depth \(depth): \(tokens.count) tokens (parent end \(lo)), cache position \(cache.position)")
        }
        if let p = parent, p.evicted { return nil }
        let blk = Array(tokens[lo ..< hi])
        let ph = parent?.hash ?? 0
        let h = Self.blockHash(ph, blk[...])
        if let existing = find(parent?.children ?? rootChildren, h, blk[...]) {
            tick += 1; existing.lastUse = tick
            if let disk, let k = existing.diskKey { disk.touch(k) }
            // A node first stored without head state can gain it, once its parent has it.
            if let mtp, existing.mtp == nil, parent == nil || parent?.mtp != nil || windowedHead {
                existing.mtp = mtp; existing.bytes += mtp.bytes; totalBytes += mtp.bytes
                eval(mtp.k, mtp.v, mtp.hidden)
                if let disk, let k = existing.diskKey, let pk = parent?.diskKey ?? (parent == nil ? disk.rootKey : nil) { disk.spill(existing, key: k, parentKey: pk, force: true) }
                evictToBudget()
                return existing.evicted ? nil : existing
            }
            return existing
        }
        let node = Node(tokens: blk, parent: parent, depth: depth)
        node.hash = h
        for (layer, a) in cache.attention {
            guard let kb = a.kbuf, let vb = a.vbuf, kb.shape[2] >= hi, vb.shape[2] >= hi else {
                throw PrefixCacheError.inconsistent("layer \(layer) KV shorter than block end \(hi)")
            }
            let k = contiguous(kb[0..., 0..., lo ..< hi, 0...])
            let v = contiguous(vb[0..., 0..., lo ..< hi, 0...])
            node.k[layer] = k; node.v[layer] = v
            node.bytes += k.nbytes + v.nbytes
        }
        for (layer, s) in cache.gdn {
            guard let conv = s.conv, let ssm = s.ssm else { continue }
            node.conv[layer] = conv; node.ssm[layer] = ssm
            node.stateBytes += conv.nbytes + ssm.nbytes
        }
        node.bytes += node.stateBytes
        if let mtp, parent == nil || parent?.mtp != nil || windowedHead {
            node.mtp = mtp; node.bytes += mtp.bytes
        }
        var toEval = Array(node.k.values) + Array(node.v.values) + Array(node.conv.values) + Array(node.ssm.values)
        if let m = node.mtp { toEval += [m.k, m.v, m.hidden] }
        // asyncEval: the block copies are queued behind the chunk that produced them (same stream, in order)
        // and the caller moves on; the arrays are ordinary lazy MLX values until they run.
        if asyncEval { MLX.asyncEval(toEval) } else { eval(toEval) }
        tick += 1; node.lastUse = tick
        if let parent { parent.children[h, default: []].append(node) }
        else { rootChildren[h, default: []].append(node) }
        totalBytes += node.bytes; nodeCount += 1
        if let disk, let pk = parent?.diskKey ?? (parent == nil ? disk.rootKey : nil) {
            let k = disk.key(parent: pk, tokens: blk[...])
            node.diskKey = k
            disk.spill(node, key: k, parentKey: pk)
        }
        evictToBudget()
        return node.evicted ? nil : node
    }

    private func leaves() -> [Node] {
        var out: [Node] = []
        func walk(_ m: [UInt64: [Node]]) {
            for list in m.values { for n in list {
                if n.children.isEmpty { out.append(n) } else { walk(n.children) }
            } }
        }
        walk(rootChildren)
        return out
    }

    /// Drops the GDN state (conv + ssm, ~147 MiB) of the least recently used interior node that has a
    /// single child and a depth off the `thinStride` grid. Such a node stays in the trie for its KV/MTP
    /// block but is no longer a hit point: a lookup snaps back to the nearest stateful ancestor and
    /// recomputes up to `thinStride - 1` blocks with the same chunking, so results stay exact.
    /// Branch points (shared prefixes) and leaves keep their state.
    /// Only when thinning alone gets the trie under `limit`: otherwise the stubs it leaves would be
    /// pruned along with an evicted tip and the whole chain would be lost, so leaf eviction runs instead.
    private func thinState(limit: Int, staleness: Int) -> Bool {
        guard thinStride > 1 else { return false }
        var best: Node? = nil
        var reclaimable = 0
        func walk(_ m: [UInt64: [Node]]) {
            for list in m.values { for n in list {
                if n.hasState, n.depth % thinStride != 0, n.children.values.reduce(0, { $0 + $1.count }) == 1 {
                    reclaimable += n.stateBytes
                    if best == nil || n.lastUse < best!.lastUse { best = n }
                }
                walk(n.children)
            } }
        }
        walk(rootChildren)
        guard let n = best, n.lastUse <= staleness, totalBytes - reclaimable <= limit else { return false }
        n.conv = [:]; n.ssm = [:]
        totalBytes -= n.stateBytes; n.bytes -= n.stateBytes; n.stateBytes = 0
        thinned += 1
        return true
    }

    /// Detaches `victim` and any ancestor left as a childless, stateless stub (it would only hold KV).
    private func remove(_ victim: Node) {
        var v: Node? = victim
        while let n = v {
            n.evicted = true
            if let p = n.parent {
                p.children = p.children.mapValues { $0.filter { $0 !== n } }.filter { !$0.value.isEmpty }
            } else {
                rootChildren = rootChildren.mapValues { $0.filter { $0 !== n } }.filter { !$0.value.isEmpty }
            }
            totalBytes -= n.bytes; nodeCount -= 1; evictions += 1
            if let p = n.parent, p.children.isEmpty, !p.hasState { v = p } else { v = nil }
        }
    }

    /// Frees bytes until `totalBytes <= limit`: first GDN states of interior nodes, then LRU leaves.
    private func reclaim(to limit: Int) {
        while totalBytes > limit {
            // A leaf staler than the thinning candidate goes first: keep the live chain's hit points and
            // thin only when nothing older is left to evict.
            let victim = leaves().min(by: { a, b in
                a.hasState != b.hasState ? !a.hasState : a.lastUse < b.lastUse
            })
            if thinState(limit: limit, staleness: victim.map { $0.hasState ? $0.lastUse : Int.max } ?? Int.max) { continue }
            guard let v = victim else { break }
            remove(v)
        }
    }

    private func evictToBudget() { reclaim(to: budgetBytes) }

    /// Memory-pressure hook: frees trie bytes down to `bytes`; true if anything was freed.
    @discardableResult
    public func shrink(to bytes: Int) -> Bool {
        let before = totalBytes
        reclaim(to: max(bytes, 0))
        return totalBytes < before
    }
}

public enum PrefixPrefill {
    /// Prefill chunk size; boundaries sit at absolute multiples of this.
    public static let chunk = 1024

    /// Cut policy shared by every cached or uncached prefill. `<|im_start|>` cuts (blocks of at
    /// least `STRIM_PREFIX_CUT_MIN` tokens, at most `STRIM_PREFIX_CUT_MAX`) make a previous turn's end a trie node;
    /// `STRIM_PREFIX_CUTS=fixed` restores plain 1024-token blocks.
    public static let defaultMaxBlock = 1536
    public static let defaultMinBlock = 1024

    public static var defaultPolicy: CutPolicy {
        let env = ProcessInfo.processInfo.environment
        if env["STRIM_PREFIX_CUTS"] == "fixed" { return .fixed(chunk) }
        let assistantMin = env["STRIM_PREFIX_ASSISTANT_MIN"] == "off" ? 0 : (Int(env["STRIM_PREFIX_ASSISTANT_MIN"] ?? "") ?? defaultAssistantMin)
        return CutPolicy(maxBlock: Int(env["STRIM_PREFIX_CUT_MAX"] ?? "") ?? defaultMaxBlock,
                         minBlock: Int(env["STRIM_PREFIX_CUT_MIN"] ?? "") ?? defaultMinBlock,
                         boundary: boundaryLock.withLock { boundaryId },
                         assistant: assistantMin > 0 ? boundaryLock.withLock { assistantId } : nil,
                         assistantMin: assistantMin,
                         tailFloor: Int(env["STRIM_PREFIX_TAIL_FLOOR"] ?? "") ?? defaultTailFloor,
                         tailMergeMax: Int(env["STRIM_PREFIX_TAIL_MAX"] ?? "") ?? defaultTailMergeMax)
    }

    /// Tail merge (see `CutPolicy.tailFloor`): prompts of at most `defaultTailMergeMax` tokens whose
    /// final chunk would be under `defaultTailFloor` tokens run as one chunk. `STRIM_PREFIX_TAIL_FLOOR=0`
    /// disables it (as does `STRIM_PREFIX_CUTS=fixed`).
    public static let defaultTailFloor = 128
    public static let defaultTailMergeMax = 768

    private static let boundaryLock = NSLock()
    nonisolated(unsafe) private static var boundaryId: Int32 = CutPolicy.imStartId
    nonisolated(unsafe) private static var assistantId: Int32 = 77_091   // "assistant" (Qwen2.5/3/3.8)

    /// Min block for a cut before `<|im_start|>assistant`; `STRIM_PREFIX_ASSISTANT_MIN=0` or `off` disables it.
    /// On by default: replay prefill sum 52.3 s -> 49.7 s (rapid-mlx 50.1 s), bench/results/cache-footprint-20261027/ab.
    public static let defaultAssistantMin = 256

    public static func configureAssistant(_ id: Int32) { boundaryLock.withLock { assistantId = id } }

    /// Sets the `<|im_start|>` id of the loaded tokenizer (Qwen3.8 is 248045, older Qwen 151644).
    /// Call before any prefill or store creation; the policy must not change while a trie holds nodes.
    public static func configureBoundary(_ id: Int32) { boundaryLock.withLock { boundaryId = id } }

    public struct Result {
        public let logits: MLXArray      // last position, [vocab]
        public let cache: ModelCache
        public let matchedTokens: Int
        public let hit: Bool
        /// Final-normed target hidden at the last position, [1,1,5120].
        public let lastHidden: MLXArray
        /// Head state when run through `SpecPrefill`; nil otherwise.
        public let mtp: MTPState?
        /// First token (argmax of `logits`); only computed on the head path.
        public let seedToken: Int32
    }

    /// Chunked prefill with exact prefix reuse. With `cache == nil` it is the plain policy
    /// prefill (same arithmetic as a miss). At least one token is always computed, so the
    /// final chunk (and hence the logits) is identical on hit and miss.
    public static func run(tokens: [Int32], store: WeightStore, cache: PrefixStore?) throws -> Result {
        try core(tokens: tokens, store: store, head: nil, cache: cache,
                 chain: QwenModel.defaultDraftChain)
    }

    /// Shared loop. With `head` set, each chunk also runs the MTP head over its entries
    /// (see `MTPBlock`) and the aligned nodes store them; a hit restores them and continues
    /// from the stored boundary hidden, so hit and miss run the same head batches.
    static func core(tokens: [Int32], store: WeightStore, head: WeightStore?, cache: PrefixStore?,
                     chain: QwenModel.DraftChain) throws -> Result {
        guard !tokens.isEmpty else { throw PrefixCacheError.emptyPrompt }
        let policy = cache?.policy ?? defaultPolicy
        var live: ModelCache
        var mtp: MTPState? = nil
        var carry: MLXArray? = nil      // normed target hidden at pos-1, pairs with tokens[pos]
        var pos = 0
        var node: PrefixStore.Node? = nil
        if let cache, let hitNode = cache.lookup(tokens, maxTokens: tokens.count - 1, requireMTP: head != nil) {
            live = try cache.restore(hitNode)
            if head != nil { let r = try cache.restoreMTP(hitNode); mtp = r.state; carry = r.carry }
            pos = hitNode.end
            node = hitNode
        } else {
            live = ModelCache()
            if head != nil { mtp = MTPState() }
        }
        let matched = pos
        var logits: MLXArray! = nil
        var lastHidden: MLXArray! = nil
        var seedToken: Int32 = -1
        var headOut: MLXArray? = nil
        var canInsert = true
        while pos < tokens.count {
            let cut = policy.blockEnd(tokens, from: pos, limit: tokens.count)
            let end = cut ?? tokens.count
            let last = end == tokens.count
            let part = Array(tokens[pos ..< end])
            var h = try store.embedding("language_model.model.embed_tokens", tokens: part)
                .reshaped([1, part.count, 5120])
            for i in 0 ..< 64 { h = try DecoderLayer.forward(h, store: store, layer: i, cache: live) }
            live.position += part.count
            let m = part.count
            if last {
                let normed = try store.rmsNorm("language_model.model.norm", h[0..., (m - 1)..., 0...])
                logits = try store.linear("language_model.lm_head", normed)[0, 0]
                eval(logits, live)
                lastHidden = normed
            }
            var block: MTPBlock? = nil
            if let head, let mtp {
                let hn = try store.rmsNorm("language_model.model.norm", h)
                var htoks = pos == 0 ? Array(tokens[1 ..< end]) : part
                var hid = carry.map { concatenated([$0, hn[0..., 0 ..< (m - 1), 0...]], axis: 1) }
                    ?? hn[0..., 0 ..< (m - 1), 0...]
                if last {
                    seedToken = Int32(argMax(logits).item(Int32.self))
                    htoks.append(seedToken)
                    hid = carry.map { concatenated([$0, hn], axis: 1) } ?? hn
                }
                let lo = pos == 0 ? 0 : pos - 1
                if !htoks.isEmpty {
                    let o = try MTP.step(tokens: htoks, hidden: hid, target: store, head: head, state: mtp)
                    headOut = o
                }
                // Owned 1-row copy (same bits): a slice would pin the whole [1,m,5120] hn.
                carry = m > 1 ? hn.take(MLXArray([Int32(m - 1)]), axis: 1) : hn[0..., (m - 1) ..< m, 0...]
                if let k = mtp.attention.kbuf, let v = mtp.attention.vbuf {
                    if cut != nil, cache != nil, end - 1 > lo {
                        block = MTPBlock(k: contiguous(k[0..., 0..., lo ..< (end - 1), 0...]),
                                         v: contiguous(v[0..., 0..., lo ..< (end - 1), 0...]),
                                         hidden: carry!, start: lo)
                    }
                    eval(k, v, carry!)
                }
            }
            if !last { eval(live) }
            pos = end
            if let cache, canInsert, cut != nil {
                node = try cache.insert(parent: node, tokens: Array(tokens[0 ..< end]), cache: live, mtp: block)
                if node == nil { canInsert = false }   // did not fit: keep computing, stop storing
            }
        }
        if let head, let mtp, let o = headOut {
            try SpecStream.setSeed(from: o, store: store, head: head, mtp: mtp, chain: chain)
        }
        return Result(logits: logits, cache: live, matchedTokens: matched, hit: matched > 0,
                      lastHidden: lastHidden, mtp: mtp, seedToken: seedToken)
    }
}

/// Prefix-cached prefill that also leaves the MTP head ready to draft.
public enum SpecPrefill {
    public struct Outcome {
        public let logits: MLXArray
        public let cache: ModelCache
        public let mtp: MTPState
        /// The target's first token (argmax of `logits`), not yet in the cache.
        public let seedToken: Int32
        /// Final-normed target hidden at the last prompt position, [1,1,5120].
        public let seedHidden: MLXArray
        public let matchedTokens: Int
        public let hit: Bool
    }

    /// Chunk-aligned prefill + head pass, reusing the deepest cached aligned prefix that
    /// carries head state. Feed the outcome to `SpecStream(... seedToken:lastHidden:)`.
    public static func run(tokens: [Int32], store: WeightStore, head: WeightStore, cache: PrefixStore?,
                           chain: QwenModel.DraftChain = QwenModel.defaultDraftChain) throws -> Outcome {
        let r = try PrefixPrefill.core(tokens: tokens, store: store, head: head, cache: cache, chain: chain)
        guard let mtp = r.mtp else { throw PrefixCacheError.inconsistent("head state missing") }
        return Outcome(logits: r.logits, cache: r.cache, mtp: mtp, seedToken: r.seedToken,
                       seedHidden: r.lastHidden, matchedTokens: r.matchedTokens, hit: r.hit)
    }
}
