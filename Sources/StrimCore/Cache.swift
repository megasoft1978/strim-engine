import Foundation
import MLX

public final class AttentionCache {
    /// Preallocated [1, Hkv, cap, D] buffers; only positions below `offset` are valid.
    /// `buf[..] = x` mutates the MLXArray object in place, so a snapshot must never hold
    /// the same object as the live cache (see `copyState`).
    var kbuf: MLXArray?
    var vbuf: MLXArray?
    public private(set) var offset = 0
    static let step = 256
    /// Capacity target in tokens (0 = grow chunk by chunk). A cold prefill sets the prompt length so the
    /// first append allocates the whole buffer once instead of reallocating and copying it at every chunk.
    /// The final capacity (prompt rounded up to `step`) equals the chunk-by-chunk one, hit or miss.
    var reserve = 0
    public init() {}

    private func view(_ b: MLXArray?) -> MLXArray? {
        guard let b else { return nil }
        return b[0..., 0..., 0 ..< offset]
    }

    public var keys: MLXArray? {
        get { view(kbuf) }
        set { kbuf = newValue; offset = newValue?.shape[2] ?? 0 }
    }
    public var values: MLXArray? {
        get { view(vbuf) }
        set { vbuf = newValue; offset = newValue?.shape[2] ?? 0 }
    }

    /// Append `k`/`v` ([B, Hkv, S, D]) and return views over all valid positions.
    func append(_ k: MLXArray, _ v: MLXArray) -> (keys: MLXArray, values: MLXArray) {
        let S = k.shape[2]
        let end = offset + S
        if kbuf == nil || vbuf == nil || end > kbuf!.shape[2] {
            // New capacity: `end` rounded up to the growth step; keep only valid positions.
            let target = max(end, reserve)
            let grow = (target + Self.step - 1) / Self.step * Self.step - offset
            func grown(_ old: MLXArray?, _ like: MLXArray) -> MLXArray {
                let z = MLXArray.zeros([like.shape[0], like.shape[1], grow, like.shape[3]], dtype: like.dtype)
                guard let old else { return z }
                return concatenated([old[0..., 0..., 0 ..< offset], z], axis: 2)
            }
            kbuf = grown(kbuf, k)
            vbuf = grown(vbuf, v)
        }
        kbuf![0..., 0..., offset ..< end] = k
        vbuf![0..., 0..., offset ..< end] = v
        offset = end
        return (kbuf![0..., 0..., 0 ..< end], vbuf![0..., 0..., 0 ..< end])
    }

    /// Drop the last `n` positions. Exact: KV entries are immutable per position and
    /// everything above `offset` is never read.
    func rollback(_ n: Int) {
        guard n > 0, kbuf != nil else { return }
        offset = max(offset - n, 0)
        if offset == 0 { kbuf = nil; vbuf = nil }
    }

    /// Independent handles: `o`'s later slice-updates must not reach this cache and vice versa.
    func copyState(from o: AttentionCache) {
        kbuf = o.kbuf.map { $0[0..., 0..., 0...] }
        vbuf = o.vbuf.map { $0[0..., 0..., 0...] }
        offset = o.offset
    }
}

public final class GDNState {
    public var conv: MLXArray?   // [B, kernel-1, convDim]
    public var ssm: MLXArray?    // [B, Hv, Dv, Dk] float32
    /// Per-step states of the current speculative pass, oldest first. Only kept while recording.
    var history: [(conv: MLXArray, ssm: MLXArray)] = []
    var recording = false
    public init() {}

    func begin() { history.removeAll(keepingCapacity: true); recording = true }
    func end() { history.removeAll(keepingCapacity: true); recording = false }

    /// Rewind to the state after the accepted prefix of the recorded pass.
    func rollback(drop n: Int) {
        guard recording, n > 0, !history.isEmpty else { return }
        let keep = history.count - n
        if keep <= 0 {
            conv = nil; ssm = nil
        } else {
            conv = history[keep - 1].conv
            ssm = history[keep - 1].ssm
        }
    }
}

public final class ModelCache {
    public var attention: [Int: AttentionCache] = [:]
    public var gdn: [Int: GDNState] = [:]
    /// Number of tokens currently represented by the cache.
    public var position = 0
    /// True while a speculative verify pass is being recorded.
    private(set) var recording = false
    public init() {}

    /// Prompt length the attention buffers are sized for (see `AttentionCache.reserve`); applies to
    /// existing and future layers. 0 = off; active only with `STRIM_KV_PREALLOC=1` until validated.
    public var kvReserve = 0 {
        didSet {
            let r = Self.preallocOn ? kvReserve : 0
            for c in attention.values { c.reserve = r }
        }
    }
    static let preallocOn = ProcessInfo.processInfo.environment["STRIM_KV_PREALLOC"] == "1"

    public func attentionCache(_ layer: Int) -> AttentionCache {
        if let c = attention[layer] { return c }
        let c = AttentionCache(); c.reserve = Self.preallocOn ? kvReserve : 0; attention[layer] = c; return c
    }

    /// Shallow snapshot: MLX arrays are immutable, so holding references is enough.
    public func snapshot() -> ModelCache {
        let c = ModelCache()
        for (k, v) in attention {
            let n = AttentionCache(); n.copyState(from: v); c.attention[k] = n
        }
        for (k, v) in gdn {
            let n = GDNState(); n.conv = v.conv; n.ssm = v.ssm; c.gdn[k] = n
        }
        c.position = position
        return c
    }

    public func restore(_ other: ModelCache) {
        attention.removeAll(); gdn.removeAll()
        for (k, v) in other.attention {
            let n = AttentionCache(); n.copyState(from: v); attention[k] = n
        }
        for (k, v) in other.gdn {
            let n = GDNState(); n.conv = v.conv; n.ssm = v.ssm; gdn[k] = n
        }
        position = other.position
    }

    /// Start a speculative verify pass: record per-token recurrent states so a
    /// rejected suffix can be dropped exactly instead of being recomputed.
    public func beginVerify() {
        recording = true
        for s in gdn.values { s.begin() }
    }

    public func endVerify() {
        recording = false
        for s in gdn.values { s.end() }
    }

    /// Drop the last `n` tokens of the verify pass from every layer.
    /// Must be called after the verify forward and before `endVerify`.
    public func rollback(drop n: Int) {
        guard n > 0 else { return }
        for c in attention.values { c.rollback(n) }
        for s in gdn.values { s.rollback(drop: n) }
        position -= n
    }

    /// Bytes held by the cache arrays (attention buffers at full capacity + GDN conv/ssm).
    public var byteSize: Int {
        var n = 0
        for c in attention.values { n += (c.kbuf?.nbytes ?? 0) + (c.vbuf?.nbytes ?? 0) }
        for s in gdn.values { n += (s.conv?.nbytes ?? 0) + (s.ssm?.nbytes ?? 0) }
        return n
    }

    public func gdnState(_ layer: Int) -> GDNState {
        if let s = gdn[layer] { return s }
        let s = GDNState(); s.recording = recording; gdn[layer] = s; return s
    }
}

extension ModelCache: Updatable, Evaluatable {
    /// Every live state array, in a deterministic order (sorted layer ids). Used by
    /// `eval` and as the `Updatable` surface for a compiled step.
    public func innerState() -> [MLXArray] {
        var out: [MLXArray] = []
        for layer in attention.keys.sorted() {
            let c = attention[layer]!
            if let k = c.kbuf, let v = c.vbuf { out.append(k); out.append(v) }
        }
        for layer in gdn.keys.sorted() {
            let s = gdn[layer]!
            if let c = s.conv { out.append(c) }
            if let ssm = s.ssm { out.append(ssm) }
        }
        return out
    }
}
