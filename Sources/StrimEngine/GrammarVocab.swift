import Foundation

/// Byte trie over the tokenizer vocabulary (preorder arrays, ~9 bytes per node). Built lazily, once per
/// engine, the first time a constrained request arrives; unconstrained engines never build it.
final class GrammarVocab {
    let byteOf: [UInt8]
    let firstChild: [Int32]
    let nextSibling: [Int32]
    let tokenAt: [Int32]
    /// Extra ids whose byte string equals another token's (rare; special/added duplicates).
    let dupTokens: [Int32: [Int32]]
    /// Highest token id in the trie + 1.
    let idCount: Int

    /// - Parameter skip: ids that never appear in a mask (control tokens such as `<|im_end|>`).
    init(count: Int, bytes: (Int) -> [UInt8], skip: (Int) -> Bool) {
        var toks = [[UInt8]](repeating: [], count: count)
        var order: [Int] = []
        order.reserveCapacity(count)
        for i in 0 ..< count {
            let b = bytes(i)
            if b.isEmpty || skip(i) { continue }
            toks[i] = b
            order.append(i)
        }
        order.sort { toks[$0].lexicographicallyPrecedes(toks[$1]) }
        var by: [UInt8] = [0], fc: [Int32] = [-1], ns: [Int32] = [-1], tk: [Int32] = [-1], last: [Int32] = [-1]
        var dups: [Int32: [Int32]] = [:]
        var path: [Int32] = [0]
        var prev: [UInt8] = []
        for id in order {
            let t = toks[id]
            var l = 0
            let m = min(prev.count, t.count)
            while l < m && prev[l] == t[l] { l += 1 }
            path.removeLast(path.count - 1 - l)
            for d in l ..< t.count {
                let n = Int32(by.count)
                by.append(t[d]); fc.append(-1); ns.append(-1); tk.append(-1); last.append(-1)
                let p = Int(path.last!)
                if fc[p] < 0 { fc[p] = n } else { ns[Int(last[p])] = n }
                last[p] = n
                path.append(n)
            }
            let node = Int(path.last!)
            if tk[node] < 0 { tk[node] = Int32(id) } else { dups[tk[node], default: []].append(Int32(id)) }
            prev = t
        }
        byteOf = by; firstChild = fc; nextSibling = ns; tokenAt = tk; dupTokens = dups
        idCount = count
    }

    var nodeCount: Int { byteOf.count }
}

/// One compiled grammar plus its DFA and cached token masks (bitsets over the logits width).
final class GrammarRuntime {
    let dfa: GrammarDFA
    let width: Int
    private let vocab: GrammarVocab
    private let eos: [Int32]
    private(set) var masks: [Int32: [UInt64]] = [:]
    private(set) var maskBytes = 0
    var lastUsed = 0
    private(set) var maskBuilds = 0

    init(program: GrammarProgram, vocab: GrammarVocab, width: Int, eos: [Int32]) {
        dfa = GrammarDFA(program: program); self.vocab = vocab; self.width = width; self.eos = eos
    }

    var start: Int32 { dfa.start }

    func dropMasks() { masks.removeAll(); maskBytes = 0 }

    /// Allowed-token bitset for DFA state `s`: tokens whose bytes keep the grammar alive, plus the
    /// end-of-turn ids when the state accepts. Never empty for a live state.
    func mask(_ s: Int32) -> [UInt64] {
        if let m = masks[s] { return m }
        maskBuilds += 1
        var bits = [UInt64](repeating: 0, count: (width + 63) / 64)
        if dfa.consuming[Int(s)] { walk(0, s, &bits) }
        if dfa.accepting[Int(s)] { for e in eos where Int(e) < width { bits[Int(e) >> 6] |= 1 << UInt64(Int(e) & 63) } }
        masks[s] = bits
        maskBytes += bits.count * 8
        return bits
    }

    private func walk(_ node: Int, _ state: Int32, _ bits: inout [UInt64]) {
        var c = Int(vocab.firstChild[node])
        while c >= 0 {
            let t = dfa.next(state, vocab.byteOf[c])
            if t >= 0 {
                let id = Int(vocab.tokenAt[c])
                if id >= 0 && id < width {
                    bits[id >> 6] |= 1 << UInt64(id & 63)
                    if let d = vocab.dupTokens[Int32(id)] { for x in d where Int(x) < width { bits[Int(x) >> 6] |= 1 << UInt64(Int(x) & 63) } }
                }
                if vocab.firstChild[c] >= 0 { walk(c, t, &bits) }
            }
            c = Int(vocab.nextSibling[c])
        }
    }

    /// True when `s` accepts and nothing more can be consumed (only end-of-turn is valid).
    func isTerminal(_ s: Int32) -> Bool { dfa.accepting[Int(s)] && !dfa.consuming[Int(s)] }

    /// Feeds a token's bytes; `dead` when the token is not allowed.
    func advance(_ s: Int32, bytes: [UInt8]) -> Int32 {
        var st = s
        for b in bytes { st = dfa.next(st, b); if st < 0 { return GrammarDFA.dead } }
        return st
    }
}

/// Engine-wide grammar services: the vocabulary trie, compiled programs (LRU) and a mask byte budget.
final class GrammarEngine {
    let tokenBytes: (Int32) -> [UInt8]
    let eos: [Int32]
    private let count: Int
    private let skip: (Int) -> Bool
    private var vocab: GrammarVocab?
    private var programs: [String: GrammarRuntime] = [:]
    private var tick = 0
    static let maxPrograms = 16
    static let maskBudget = 32 << 20
    private(set) var width = 0

    init(vocabCount: Int, tokenBytes: @escaping (Int32) -> [UInt8], eos: [Int32], skip: @escaping (Int) -> Bool) {
        count = vocabCount; self.tokenBytes = tokenBytes; self.eos = eos; self.skip = skip
    }

    /// `logitsWidth` is the model's logits dimension (bitsets are sized to it).
    func runtime(for spec: ConstraintSpec, logitsWidth: Int) throws -> GrammarRuntime {
        if width == 0 { width = logitsWidth }
        let key = spec.cacheKey
        tick += 1
        if let r = programs[key] { r.lastUsed = tick; return r }
        let program = try GrammarProgram.compile(spec)
        if vocab == nil { vocab = GrammarVocab(count: count, bytes: { [tokenBytes] in tokenBytes(Int32($0)) }, skip: skip) }
        let r = GrammarRuntime(program: program, vocab: vocab!, width: width, eos: eos)
        r.lastUsed = tick
        programs[key] = r
        if programs.count > Self.maxPrograms, let old = programs.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            programs[old.key] = nil
        }
        return r
    }

    /// Keeps the cached masks under budget by dropping the least recently used program's masks.
    func trim() {
        var total = programs.values.reduce(0) { $0 + $1.maskBytes }
        while total > Self.maskBudget, let old = programs.values.filter({ $0.maskBytes > 0 }).min(by: { $0.lastUsed < $1.lastUsed }) {
            total -= old.maskBytes
            old.dropMasks()
        }
    }
}
