import Foundation

struct GFrame: Hashable {
    var n: Int32
    var s: Int32
}
typealias GStack = [GFrame]

/// Lazily built DFA over a `GrammarProgram`. A DFA state is the set of live pushdown stacks (the
/// grammar is nondeterministic across `anyOf` / optional members); sets are interned to Int32 ids
/// and byte transitions are memoized, so a token-mask walk is table lookups.
/// Not thread safe: owned by the engine thread.
final class GrammarDFA {
    static let dead: Int32 = -1
    private static let unknown: Int32 = -2
    static let maxStates = 200_000

    let program: GrammarProgram
    private var sets: [Set<GStack>] = []
    private var ids: [Set<GStack>: Int32] = [:]
    private var table: [Int32] = []
    private(set) var accepting: [Bool] = []
    /// True when the state has stacks that can still consume input.
    private(set) var consuming: [Bool] = []
    private(set) var overflowed = false
    var stateCount: Int { sets.count }

    init(program: GrammarProgram) { self.program = program }

    lazy var start: Int32 = {
        var out = Set<GStack>()
        expand([GFrame(n: program.root, s: 0)], into: &out)
        return intern(out)
    }()

    func next(_ s: Int32, _ b: UInt8) -> Int32 {
        guard s >= 0 else { return Self.dead }
        let i = Int(s) &* 256 &+ Int(b)
        let t = table[i]
        if t != Self.unknown { return t }
        var out = Set<GStack>()
        for st in sets[Int(s)] { step(st, b, into: &out) }
        let r: Int32 = out.isEmpty ? Self.dead : intern(out)
        table[i] = r
        return r
    }

    private func intern(_ set: Set<GStack>) -> Int32 {
        if let i = ids[set] { return i }
        if sets.count >= Self.maxStates { overflowed = true; return Self.dead }
        let id = Int32(sets.count)
        sets.append(set)
        ids[set] = id
        table.append(contentsOf: repeatElement(Self.unknown, count: 256))
        accepting.append(set.contains { $0.isEmpty })
        consuming.append(set.contains { !$0.isEmpty })
        return id
    }

    // MARK: closure

    /// Epsilon closure: every stack reachable from `stack` whose top frame consumes a byte, plus the
    /// empty stack (accept).
    private func expand(_ stack: GStack, into out: inout Set<GStack>) {
        var work = [stack]
        var seen = Set<GStack>()
        while var st = work.popLast() {
            if !seen.insert(st).inserted { continue }
            loop: while true {
                guard let top = st.last else { out.insert(st); break loop }
                switch program.nodes[Int(top.n)] {
                case let .seq(items):
                    let k = Int(top.s)
                    if k >= items.count { st.removeLast(); continue loop }
                    if k + 1 == items.count { st.removeLast() } else { st[st.count - 1].s += 1 }
                    st.append(GFrame(n: items[k], s: 0))
                case let .alt(items):
                    st.removeLast()
                    for it in items { var b = st; b.append(GFrame(n: it, s: 0)); work.append(b) }
                    break loop
                case let .lit(bytes):
                    if bytes.isEmpty { st.removeLast(); continue loop }
                    out.insert(st); break loop
                case .ws:
                    if top.s < GrammarProgram.maxWS { out.insert(st) }
                    st.removeLast()                   // exit (the run may be empty or end here)
                case let .num(integer):
                    if Self.numAccepting(top.s) { var e = st; e.removeLast(); work.append(e) }
                    _ = integer
                    out.insert(st); break loop
                case .str, .raw:
                    out.insert(st); break loop
                }
            }
        }
    }

    // MARK: byte transitions

    private func step(_ st: GStack, _ b: UInt8, into out: inout Set<GStack>) {
        guard var top = st.last else { return }
        var next = st
        switch program.nodes[Int(top.n)] {
        case let .lit(bytes):
            let k = Int(top.s)
            guard k < bytes.count, bytes[k] == b else { return }
            if k + 1 == bytes.count { next.removeLast() } else { top.s += 1; next[next.count - 1] = top }
        case .ws:
            guard top.s < GrammarProgram.maxWS, b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D else { return }
            top.s += 1; next[next.count - 1] = top
        case .str:
            guard let ns = Self.strStep(top.s, b) else { return }
            if ns < 0 { next.removeLast() } else { top.s = ns; next[next.count - 1] = top }
        case let .num(integer):
            guard let ns = Self.numStep(top.s, b, integer: integer) else { return }
            top.s = ns; next[next.count - 1] = top
        case .raw:
            // s = terminator progress p (0...13) + 16 * UTF-8 continuation code
            let end = GrammarProgram.paramEnd
            let p = Int(top.s & 15), u = top.s >> 4
            if u > 0 {
                guard let n = Self.utf8Next(u, b) else { return }
                top.s = n << 4
            } else if b >= 0x80 {
                guard let c = Self.utf8Lead(b) else { return }
                top.s = c << 4
            } else if b == end[p] {
                if p + 1 == end.count { next.removeLast(); expand(next, into: &out); return }
                top.s += 1
            } else {
                top.s = b == 0x0A ? 1 : 0
            }
            next[next.count - 1] = top
        case .seq, .alt:
            return
        }
        expand(next, into: &out)
    }

    /// String substates: 0 expect opening quote, 1 body, 2 after backslash, 3...6 hex digits left (4...1),
    /// 7...13 UTF-8 continuation state (code + 6, see `utf8Lead`). Returns -1 when the closing quote is consumed.
    static func strStep(_ s: Int32, _ b: UInt8) -> Int32? {
        switch s {
        case 0: return b == 0x22 ? 1 : nil
        case 1:
            switch b {
            case 0x22: return -1
            case 0x5C: return 2
            case 0x00 ..< 0x20: return nil
            case 0x20 ..< 0x80: return 1
            default: return utf8Lead(b).map { $0 + 6 }
            }
        case 2:
            switch b {
            case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: return 1
            case 0x75: return 3
            default: return nil
            }
        case 3 ... 6:
            let hex = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
            guard hex else { return nil }
            return s == 6 ? 1 : s + 1
        case 7 ... 13:
            guard let n = utf8Next(s - 6, b) else { return nil }
            return n == 0 ? 1 : n + 6
        default: return nil
        }
    }

    /// Number substates: 0 start, 1 after '-', 2 after leading 0, 3 int digits, 4 after '.', 5 fraction digits,
    /// 6 after e/E, 7 after exponent sign, 8 exponent digits.
    static func numStep(_ s: Int32, _ b: UInt8, integer: Bool) -> Int32? {
        let digit = b >= 0x30 && b <= 0x39
        let nz = b >= 0x31 && b <= 0x39
        switch s {
        case 0: return b == 0x2D ? 1 : b == 0x30 ? 2 : nz ? 3 : nil
        case 1: return b == 0x30 ? 2 : nz ? 3 : nil
        case 2: return integer ? nil : (b == 0x2E ? 4 : (b == 0x65 || b == 0x45) ? 6 : nil)
        case 3:
            if digit { return 3 }
            return integer ? nil : (b == 0x2E ? 4 : (b == 0x65 || b == 0x45) ? 6 : nil)
        case 4: return digit ? 5 : nil
        case 5: return digit ? 5 : (b == 0x65 || b == 0x45) ? 6 : nil
        case 6: return (b == 0x2B || b == 0x2D) ? 7 : digit ? 8 : nil
        case 7: return digit ? 8 : nil
        case 8: return digit ? 8 : nil
        default: return nil
        }
    }

    /// UTF-8 states: 1, 2, 3 = that many any-continuation bytes left; 4 after E0, 5 after ED, 6 after F0, 7 after F4.
    static func utf8Lead(_ b: UInt8) -> Int32? {
        switch b {
        case 0xC2 ... 0xDF: return 1
        case 0xE0: return 4
        case 0xED: return 5
        case 0xE1 ... 0xEC, 0xEE, 0xEF: return 2
        case 0xF0: return 6
        case 0xF4: return 7
        case 0xF1 ... 0xF3: return 3
        default: return nil
        }
    }

    /// Next UTF-8 state after continuation byte `b` (0 = character complete), nil when invalid.
    static func utf8Next(_ code: Int32, _ b: UInt8) -> Int32? {
        switch code {
        case 1, 2, 3: return b >= 0x80 && b <= 0xBF ? code - 1 : nil
        case 4: return b >= 0xA0 && b <= 0xBF ? 1 : nil
        case 5: return b >= 0x80 && b <= 0x9F ? 1 : nil
        case 6: return b >= 0x90 && b <= 0xBF ? 2 : nil
        case 7: return b >= 0x80 && b <= 0x8F ? 2 : nil
        default: return nil
        }
    }

    static func numAccepting(_ s: Int32) -> Bool { s == 2 || s == 3 || s == 5 || s == 8 }
}
