import Foundation
import MLX
import StrimCore

/// Device-side token masks, shared by all constrained requests of the engine. Created lazily: an engine that
/// never sees a constrained request allocates nothing here.
final class DeviceMasks {
    private var grammar: [GrammarKey: MLXArray] = [:]
    private var order: [GrammarKey] = []
    private var forced: [Int32: MLXArray] = [:]
    private var ones: [Int: MLXArray] = [:]
    static let capacity = 24

    private struct GrammarKey: Hashable { let rt: ObjectIdentifier; let state: Int32 }

    private static let expandTable: [UInt64] = (0 ..< 256).map { b in
        var w: UInt64 = 0
        for i in 0 ..< 8 where b >> i & 1 == 1 { w |= 1 << UInt64(8 * i) }
        return w
    }

    /// Bitset (bit i = token i) to a `[width]` bool array.
    static func expand(_ bits: [UInt64], width: Int) -> MLXArray {
        var out = [UInt64](repeating: 0, count: bits.count * 8)
        let t = expandTable
        for (i, w) in bits.enumerated() {
            let o = i * 8
            for j in 0 ..< 8 { out[o + j] = t[Int((w >> UInt64(8 * j)) & 0xFF)] }
        }
        return out.withUnsafeBytes { raw in
            MLXArray(UnsafeBufferPointer(start: raw.baseAddress!.assumingMemoryBound(to: Bool.self), count: width), [width])
        }
    }

    func allowed(_ rt: GrammarRuntime, _ state: Int32) -> MLXArray {
        let k = GrammarKey(rt: ObjectIdentifier(rt), state: state)
        if let a = grammar[k] { return a }
        let a = Self.expand(rt.mask(state), width: rt.width)
        grammar[k] = a
        order.append(k)
        if order.count > Self.capacity { grammar[order.removeFirst()] = nil }
        return a
    }

    func only(_ id: Int32, width: Int) -> MLXArray {
        if let a = forced[id] { return a }
        var v = [Bool](repeating: false, count: width)
        if id >= 0 && Int(id) < width { v[Int(id)] = true }
        let a = MLXArray(v)
        forced[id] = a
        return a
    }

    func all(width: Int) -> MLXArray {
        if let a = ones[width] { return a }
        let a = MLXArray([Bool](repeating: true, count: width))
        ones[width] = a
        return a
    }
}

/// Per-request constraint state: grammar position (once reasoning is closed), thinking budget accounting.
/// Tracks the tokens the engine has emitted; `verifyMask` answers for the speculative rows ahead of them.
final class RequestConstraint: VerifyConstraint {
    enum Key { case free, forced(Int32), grammar(Int32) }
    struct State { var g: Int32; var inThink: Bool; var count: Int }

    let rt: GrammarRuntime?
    let engine: GrammarEngine
    let masks: DeviceMasks
    let budget: Int?
    let closeId: Int32
    let width: Int
    private(set) var state: State
    /// Set once an emitted token fell outside the grammar (cannot happen through the masks); the request
    /// continues unconstrained rather than failing.
    private(set) var violated = false

    init(rt: GrammarRuntime?, engine: GrammarEngine, masks: DeviceMasks, width: Int, budget: Int?, closeId: Int32, startsInThink: Bool) {
        self.rt = rt; self.engine = engine; self.masks = masks; self.width = width
        self.budget = budget; self.closeId = closeId
        state = State(g: rt?.start ?? GrammarDFA.dead, inThink: startsInThink, count: 0)
    }

    func key(_ s: State) -> Key {
        if s.inThink {
            if let b = budget, s.count >= b { return .forced(closeId) }
            return .free
        }
        guard rt != nil, s.g >= 0 else { return .free }
        return .grammar(s.g)
    }

    func step(_ s: State, _ t: Int32) -> State {
        var n = s
        if s.inThink {
            if t == closeId { n.inThink = false } else { n.count += 1 }
        } else if let rt, s.g >= 0 {
            n.g = rt.advance(s.g, bytes: engine.tokenBytes(t))
        }
        return n
    }

    /// Called for every token the engine emits (stop tokens excluded).
    func advance(_ t: Int32) {
        let n = step(state, t)
        if !state.inThink, rt != nil, state.g >= 0, n.g < 0 { violated = true }
        state = n
    }

    var currentKey: Key { key(state) }

    func deviceMask(_ k: Key) -> MLXArray {
        switch k {
        case .free: return masks.all(width: width)
        case let .forced(id): return masks.only(id, width: width)
        case let .grammar(s): return masks.allowed(rt!, s)
        }
    }

    /// `[V]` mask for the next token, or nil when unconstrained right now (the common case in a thinking phase).
    func nextMask() -> MLXArray? {
        let k = key(state)
        if case .free = k { return nil }
        return deviceMask(k)
    }

    func apply(_ logits: MLXArray) -> MLXArray {
        guard let m = nextMask() else { return logits }
        engine.trim()
        return maskLogits(logits, m)
    }

    func verifyMask(drafts: [Int32]) -> MLXArray? {
        var s = state
        var keys: [Key] = [key(s)]
        var live = true
        for d in drafts {
            if live {
                let prev = s
                s = step(s, d)
                if !prev.inThink, rt != nil, prev.g >= 0, s.g < 0 { live = false }
            }
            keys.append(live ? key(s) : .free)
        }
        var constrained = false
        for k in keys { if case .free = k {} else { constrained = true } }
        guard constrained else { return nil }
        engine.trim()
        let rows = keys.map { deviceMask($0) }
        return rows.count == 1 ? rows[0].reshaped([1, width]) : stacked(rows, axis: 0)
    }
}
