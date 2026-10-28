import Foundation
import MLX

/// Gated DeltaNet sublayer of Qwen3.5/3.8, ops reference path (no cache, S tokens).
public enum GDN {
    static let Hv = 48, Hk = 16, Dk = 128, Dv = 128

    /// Head-replication index and the unit RMS-norm weight. Both were rebuilt per layer
    /// per token, which costs a host-to-device upload each time.
    nonisolated(unsafe) static let repIndex: MLXArray = {
        var idx: [Int32] = []
        for h in 0 ..< Hk { for _ in 0 ..< (Hv / Hk) { idx.append(Int32(h)) } }
        return MLXArray(idx)
    }()
    nonisolated(unsafe) static let onesBf16 = MLXArray.ones([Dk], dtype: .bfloat16)
    static let keyDim = Hk * Dk          // 2048
    static let valDim = Hv * Dv          // 6144
    static let convDim = 2 * keyDim + valDim  // 10240

    public static func silence(_ x: MLXArray) -> MLXArray { x * sigmoid(x) }

    /// Depthwise causal convolution (kernel 4, one tap per input position) as four
    /// broadcast multiply-adds. MLX's grouped `conv1d` is ~0.2 ms per call for this
    /// shape; this is ~20 us and scales with S without extra dispatches.
    /// The gated-delta recurrence over the tokens of one step. Pure function of the
    /// projected tensors and the incoming state; compiled variants avoid re-tracing
    /// the per-token dispatch chain.
    public static func recurrence(_ qr: MLXArray, _ kr: MLXArray, _ v: MLXArray,
                           _ g: MLXArray, _ beta: MLXArray, _ ssm0: MLXArray,
                           dtype: DType) -> (yAll: MLXArray, ssm: MLXArray, states: [MLXArray]) {
        let S = qr.shape[1]
        var recurrent = ssm0
        var ys: [MLXArray] = []
        var states: [MLXArray] = []
        ys.reserveCapacity(S)
        states.reserveCapacity(S)
        for t in 0 ..< S {
            let qT = at(qr, t).expandedDimensions(axis: 2)
            let kT = at(kr, t).expandedDimensions(axis: 2)
            let vT = at(v, t)
            let gT = at(g, t).expandedDimensions(axis: -1)
            let bT = at(beta, t)
            let decay = gT.expandedDimensions(axis: -1)
            recurrent = recurrent * decay
            let kvMem = (recurrent * kT).sum(axis: -1)
            let delta = (vT - kvMem) * bT.expandedDimensions(axis: -1)
            recurrent = recurrent + kT * delta.expandedDimensions(axis: -1)
            let y = (recurrent * qT).sum(axis: -1)
            ys.append(y.asType(dtype))
            states.append(recurrent)
        }
        return (stacked(ys, axis: 1), recurrent, states)
    }

    /// Compiled recurrence: returns y, final state, and the per-token state stack
    /// needed for exact speculative rollback. Cached per token count by MLX.
    nonisolated(unsafe) static let recurrenceFn: ([MLXArray]) -> [MLXArray] = compile { (a: [MLXArray]) -> [MLXArray] in
        let r = recurrenceNoState(a[0], a[1], a[2], a[3], a[4], a[5], dtype: a[2].dtype)
        return [r.0, r.1]
    }

    nonisolated(unsafe) static let recurrenceRecFn: ([MLXArray]) -> [MLXArray] = compile { (a: [MLXArray]) -> [MLXArray] in
        let r = recurrence(a[0], a[1], a[2], a[3], a[4], a[5], dtype: a[2].dtype)
        return [r.yAll, r.ssm, stacked(r.states, axis: 0)]
    }

    /// The recurrence, expressed with fused matmuls: the rank-1 state update and the two
    /// reductions become single kernels, so the 3 MB per-head state is traversed ~5 times
    /// per token instead of ~8. Measured: -1.7 ms at S=3, -1 to -3 ms at S=1 (interleaved).
    /// `STRIM_REC_ELEM=1` restores the elementwise formulation for A/B.
    public static func recurrenceMM(_ qr: MLXArray, _ kr: MLXArray, _ v: MLXArray,
                                    _ g: MLXArray, _ beta: MLXArray, _ ssm0: MLXArray,
                                    dtype: DType) -> (yAll: MLXArray, ssm: MLXArray, states: [MLXArray]) {
        let S = qr.shape[1]
        var recurrent = ssm0
        var ys: [MLXArray] = []
        var states: [MLXArray] = []
        ys.reserveCapacity(S)
        states.reserveCapacity(S)
        for t in 0 ..< S {
            let qT = at(qr, t).expandedDimensions(axis: -1)     // [B,Hv,Dk,1]
            let kT = at(kr, t).expandedDimensions(axis: -1)
            let vT = at(v, t)                                    // [B,Hv,Dv]
            let gT = at(g, t).expandedDimensions(axis: -1).expandedDimensions(axis: -1)
            let bT = at(beta, t).expandedDimensions(axis: -1)    // [B,Hv,1]
            let r0 = recurrent * gT                              // one pass over the state
            let kv = matmul(r0, kT).squeezed(axis: -1)           // [B,Hv,Dv]
            let delta = (vT - kv) * bT                           // [B,Hv,Dv]
            let r1 = r0 + matmul(delta.expandedDimensions(axis: -1),
                                 kT.transposed(0, 1, 3, 2))      // rank-1 update, one kernel
            let y = matmul(r1, qT).squeezed(axis: -1)            // [B,Hv,Dv]
            ys.append(y.asType(dtype))
            states.append(r1)
            recurrent = r1
        }
        return (stacked(ys, axis: 1), recurrent, states)
    }

    nonisolated(unsafe) static let recurrenceRecMMFn: ([MLXArray]) -> [MLXArray] = compile { (a: [MLXArray]) -> [MLXArray] in
        let r = recurrenceMM(a[0], a[1], a[2], a[3], a[4], a[5], dtype: a[2].dtype)
        return [r.yAll, r.ssm, stacked(r.states, axis: 0)]
    }

    /// Same recurrence without the per-token stack: prefill and plain decode never roll
    /// back, and at S=4k the stack would be ~13 GB per pass.
    public static func recurrenceMMNoState(_ qr: MLXArray, _ kr: MLXArray, _ v: MLXArray,
                                           _ g: MLXArray, _ beta: MLXArray, _ ssm0: MLXArray,
                                           dtype: DType) -> (yAll: MLXArray, ssm: MLXArray) {
        let S = qr.shape[1]
        var recurrent = ssm0
        var ys: [MLXArray] = []
        ys.reserveCapacity(S)
        for t in 0 ..< S {
            let qT = at(qr, t).expandedDimensions(axis: -1)
            let kT = at(kr, t).expandedDimensions(axis: -1)
            let vT = at(v, t)
            let gT = at(g, t).expandedDimensions(axis: -1).expandedDimensions(axis: -1)
            let bT = at(beta, t).expandedDimensions(axis: -1)
            let r0 = recurrent * gT
            let kv = matmul(r0, kT).squeezed(axis: -1)
            let delta = (vT - kv) * bT
            let r1 = r0 + matmul(delta.expandedDimensions(axis: -1),
                                 kT.transposed(0, 1, 3, 2))
            let y = matmul(r1, qT).squeezed(axis: -1)
            ys.append(y.asType(dtype))
            recurrent = r1
        }
        return (stacked(ys, axis: 1), recurrent)
    }

    nonisolated(unsafe) static let recurrenceNoStateMMFn: ([MLXArray]) -> [MLXArray] = compile { (a: [MLXArray]) -> [MLXArray] in
        let r = recurrenceMMNoState(a[0], a[1], a[2], a[3], a[4], a[5], dtype: a[2].dtype)
        return [r.yAll, r.ssm]
    }

    nonisolated(unsafe) static let useMM = ProcessInfo.processInfo.environment["STRIM_REC_ELEM"] == nil
    nonisolated(unsafe) static let batchMetal = ProcessInfo.processInfo.environment["STRIM_GDN_BATCH_METAL"] == "1"
    /// Default ON; STRIM_BATCH_DECODE=0 opts out. Batch-dimension GDN decode + conv kernels for B>1 (one dispatch, per-row arithmetic identical to B=1).
    nonisolated(unsafe) static let batchDecode = ProcessInfo.processInfo.environment["STRIM_BATCH_DECODE"] != "0"
nonisolated(unsafe) static let skipRec = ProcessInfo.processInfo.environment["STRIM_SKIP_REC"] != nil
    /// Default ON since 2026-10-26: the conv kernel is bit-exact and the recurrence kernel now
    /// matches MLX's gemv FMA association, so it passes `gen 16`, depth-0 EXACT and ties the tensor
    /// path 7/8 on the 8-prompt corpus while being 10–29% faster. The residual difference is that
    /// MLX's tensor path runs the recurrence matmuls in TF32 while this kernel uses full f32;
    /// `STRIM_GDN_TENSOR=1` forces the reference-TF32 path. `STRIM_GDN_METAL=1` still forces the
    /// kernel.
    nonisolated(unsafe) static let metalDefault =
        ProcessInfo.processInfo.environment["STRIM_GDN_METAL"] != nil
        || ProcessInfo.processInfo.environment["STRIM_GDN_TENSOR"] == nil
    /// Set by `benchpathS` so both recurrence paths can be timed interleaved inside one
    /// process; `nil` follows the environment.
    nonisolated(unsafe) public static var metalOverride: Bool? = nil
    static var useMetal: Bool { metalOverride ?? metalDefault }
    /// The fused kernel loops over S inside one threadgroup. It is the right shape for
    /// decode *and*, measured 2026-10-26, for prefill: at S=512 it is 688 vs 251 tok/s
    /// against the tensor recurrence, and the state never leaves registers. The default
    /// therefore covers prefill too; `STRIM_GDN_METAL_MAX_S=8` restores the tensor
    /// prefill path for A/B.
    nonisolated(unsafe) static let metalMaxS =
        Int(ProcessInfo.processInfo.environment["STRIM_GDN_METAL_MAX_S"] ?? "") ?? 1_000_000

    /// Same recurrence without keeping per-token states (the common decode path).
    public static func recurrenceNoState(_ qr: MLXArray, _ kr: MLXArray, _ v: MLXArray,
                                  _ g: MLXArray, _ beta: MLXArray, _ ssm0: MLXArray,
                                  dtype: DType) -> (MLXArray, MLXArray) {
        let S = qr.shape[1]
        var recurrent = ssm0
        var ys: [MLXArray] = []
        ys.reserveCapacity(S)
        for t in 0 ..< S {
            let qT = at(qr, t).expandedDimensions(axis: 2)
            let kT = at(kr, t).expandedDimensions(axis: 2)
            let vT = at(v, t)
            let gT = at(g, t).expandedDimensions(axis: -1)
            let bT = at(beta, t)
            let decay = gT.expandedDimensions(axis: -1)
            recurrent = recurrent * decay
            let kvMem = (recurrent * kT).sum(axis: -1)
            let delta = (vT - kvMem) * bT.expandedDimensions(axis: -1)
            recurrent = recurrent + kT * delta.expandedDimensions(axis: -1)
            let y = (recurrent * qT).sum(axis: -1)
            ys.append(y.asType(dtype))
        }
        return (stacked(ys, axis: 1), recurrent)
    }

    public static func depthwise(_ convIn: MLXArray, _ weight: MLXArray, _ S: Int) -> MLXArray {
        let C = convIn.shape[2]
        let w = weight.reshaped([C, 4])
        var out = convIn[0..., 0 ..< S, 0...] * w[0..., 0]
        for k in 1 ..< 4 {
            out = out + convIn[0..., k ..< (k + S), 0...] * w[0..., k]
        }
        return out
    }

    static func at(_ a: MLXArray, _ t: Int) -> MLXArray {
        a.take(MLXArray([Int32(t)]), axis: 1).squeezed(axis: 1)
    }


    /// Single-token step as a pure function, suitable for `compile`: no mutation,
    /// no index-array gathers, same math as `forward(S=1)`.
    public static func step1(_ x: MLXArray, conv: MLXArray, ssm: MLXArray,
                             store: WeightStore, layer: Int) throws
        -> (y: MLXArray, conv: MLXArray, ssm: MLXArray) {
        let p = "language_model.model.layers.\(layer).linear_attn."
        let B = x.shape[0]
        let dtype = x.dtype

        let qkv = try store.linear(p + "in_proj_qkv", x)
        let z = try store.linear(p + "in_proj_z", x).reshaped([B, 1, Hv, Dv])
        let bProj = try store.linear(p + "in_proj_b", x)
        let aProj = try store.linear(p + "in_proj_a", x)

        let convW = try store.tensor(p + "conv1d.weight")
        let convIn = concatenated([conv, qkv], axis: 1)          // [B,4,convDim]
        let newConv = convIn[0..., 1 ..< 4, 0...]
        let convOut = silence(depthwise(convIn, convW, 1))

        let q = convOut[0..., 0..., 0 ..< keyDim].reshaped([B, 1, Hk, Dk])
        let k = convOut[0..., 0..., keyDim ..< (2 * keyDim)].reshaped([B, 1, Hk, Dk])
        let v = convOut[0..., 0..., (2 * keyDim) ..< convDim].reshaped([B, 1, Hv, Dv])

        let ones = MLXArray.ones([Dk], dtype: dtype)
        let inv = pow(Float(Dk), -0.5)
        let qq = MLXFast.rmsNorm(q, weight: ones, eps: 1e-6) * (inv * inv)
        let kk = MLXFast.rmsNorm(k, weight: ones, eps: 1e-6) * inv

        let beta = sigmoid(bProj)
        let aLog = try store.tensor(p + "A_log").asType(.float32)
        let dtBias = try store.tensor(p + "dt_bias").asType(.float32)
        let softplus = log(1 + exp(aProj.asType(.float32) + dtBias))
        let g = exp(-exp(aLog) * softplus)

        var idx: [Int32] = []
        for h in 0 ..< Hk { for _ in 0 ..< (Hv / Hk) { idx.append(Int32(h)) } }
        let rep = MLXArray(idx)
        let qT = qq.take(rep, axis: 2).squeezed(axis: 1).expandedDimensions(axis: 2)  // [B,Hv,1,Dk]
        let kT = kk.take(rep, axis: 2).squeezed(axis: 1).expandedDimensions(axis: 2)
        let vT = v.squeezed(axis: 1)                                                  // [B,Hv,Dv]
        let gT = g.squeezed(axis: 1).expandedDimensions(axis: -1)                     // [B,Hv,1]
        let bT = beta.squeezed(axis: 1).expandedDimensions(axis: -1)                  // [B,Hv,1]

        let decay = gT.expandedDimensions(axis: -1)              // [B,Hv,1,1]
        let r0 = ssm * decay
        let kvMem = (r0 * kT).sum(axis: -1)                      // [B,Hv,Dv]
        let delta = (vT - kvMem) * bT
        let r1 = r0 + kT * delta.expandedDimensions(axis: -1)
        let y = (r1 * qT).sum(axis: -1)                          // [B,Hv,Dv]

        let yAll = y.expandedDimensions(axis: 1)                 // [B,1,Hv,Dv]
        let normW = try store.tensor(p + "norm.weight")
        let normed = MLXFast.rmsNorm(yAll, weight: normW, eps: 1e-6)
        let gate = silence(z.asType(.float32))
        let gated = (gate * normed.asType(.float32)).asType(dtype)
        let out = try store.linear(p + "out_proj", gated.reshaped([B, 1, valDim]))
        return (out, newConv, r1)
    }

    public static func forward(_ x: MLXArray, store: WeightStore, layer: Int = 0, state: GDNState? = nil) throws -> MLXArray {
        let p = "language_model.model.layers.\(layer).linear_attn."
        let B = x.shape[0], S = x.shape[1]
        let dtype = x.dtype

        let qkv = try store.linear(p + "in_proj_qkv", x)
        let z = try store.linear(p + "in_proj_z", x).reshaped([B, S, Hv, Dv])
        let bProj = try ChunkInvariantLinear.linear(store, p + "in_proj_b", x)
        let aProj = try ChunkInvariantLinear.linear(store, p + "in_proj_a", x)

        let convW = try store.tensor(p + "conv1d.weight")
        let convState = state?.conv ?? MLXArray.zeros([B, 3, convDim], dtype: dtype)
        let convIn = concatenated([convState, qkv], axis: 1)
        if let state {
            let n = convIn.shape[1]
            // Long chunks: a slice (or contiguous() of a B=1 slice) shares convIn's buffer and
            // would pin the whole [B,S+3,convDim] array. A gather writes a fresh 3-row buffer
            // with the same bits. Decode/verify (small S) keeps the free view.
            state.conv = S >= 64
                ? convIn.take(MLXArray([Int32(n - 3), Int32(n - 2), Int32(n - 1)]), axis: 1)
                : convIn[0..., (n - 3) ..< n, 0...]
        }
        let convOut = (B > 1 && GDN.batchDecode && GDN.useMetal && S < 512)
            ? GDNMetal.convSiluBatch(convIn: convIn, weight: convW)
            : (B > 1 || ProcessInfo.processInfo.environment["STRIM_CONV_TENSOR"] != nil)
            ? silence(depthwise(convIn, convW, S))
            : GDNMetal.convSilu(convIn: convIn, weight: convW)

        let qRaw = convOut[0..., 0..., 0 ..< keyDim].reshaped([B, S, Hk, Dk])
        let kRaw = convOut[0..., 0..., keyDim ..< (2 * keyDim)].reshaped([B, S, Hk, Dk])
        let v = convOut[0..., 0..., (2 * keyDim) ..< convDim].reshaped([B, S, Hv, Dv])

        let ones = dtype == .bfloat16 ? GDN.onesBf16 : MLXArray.ones([Dk], dtype: dtype)
        let inv = pow(Float(Dk), -0.5)
        let q = MLXFast.rmsNorm(qRaw, weight: ones, eps: 1e-6) * (inv * inv)
        let k = MLXFast.rmsNorm(kRaw, weight: ones, eps: 1e-6) * inv

        let aLog = try store.tensor(p + "A_log").asType(.float32)
        let dtBias = try store.tensor(p + "dt_bias").asType(.float32)
        let (beta, g) = Fused.betaG(bProj, aProj, aLog: aLog, dtBias: dtBias)   // g: [B,S,Hv]

        let rep = GDN.repIndex
        let qr = q.take(rep, axis: 2)                // [B,S,Hv,Dk]
        let kr = k.take(rep, axis: 2)

        // One graph for every decode step (speculative or not) so the arithmetic is
        // identical in both paths; the per-token stack is only consumed when recording.
        let recurrent0 = state?.ssm ?? MLXArray.zeros([B, Hv, Dv, Dk], dtype: .float32)
        let recording = state?.recording == true
        // The fused kernel loops over S tokens inside one threadgroup, which is right for
        // decode (S<=4) and wrong for prefill; use the tensor recurrence for long chunks.
        if GDN.useMetal && S >= 512 && !recording && S <= GDN.metalMaxS
            && ProcessInfo.processInfo.environment["STRIM_GDN_BLOCKED"] != "0" {
            let r = GDNMetal.runBlocked(q: q, k: k, v: v, g: g, beta: beta, ssm: recurrent0)
            let yAllM = r.y
            state?.ssm = r.ssm
            let normWM = try store.tensor(p + "norm.weight")
            let normedM = MLXFast.rmsNorm(yAllM, weight: normWM, eps: 1e-6)
            let gatedM = Fused.gatedNorm(z, normedM)
            return try store.linear(p + "out_proj", gatedM.reshaped([B, S, valDim]))
        }
        if GDN.useMetal && B == 1 && S <= GDN.metalMaxS {
            let r = GDNMetal.run(q: qr, k: kr, v: v, g: g, beta: beta, ssm: recurrent0,
                                 recordStack: recording)
            let yAllM = r.y
            state?.ssm = r.ssm
            if let state, state.recording {
                for t in 0 ..< S {
                    state.history.append((conv: convIn[0..., (t + 1) ..< (t + 4), 0...],
                                          ssm: r.stack[t]))
                }
            }
            let normWM = try store.tensor(p + "norm.weight")
            let normedM = MLXFast.rmsNorm(yAllM, weight: normWM, eps: 1e-6)
            let gatedM = Fused.gatedNorm(z, normedM)
            return try store.linear(p + "out_proj", gatedM.reshaped([B, S, valDim]))
        }
        if GDN.useMetal && GDN.batchDecode && B > 1 && S <= GDN.metalMaxS && S < 512 && !recording {
            let r = GDNMetal.runBatch(q: qr, k: kr, v: v, g: g, beta: beta, ssm: recurrent0)
            state?.ssm = r.ssm
            let normWB = try store.tensor(p + "norm.weight")
            let normedB = MLXFast.rmsNorm(r.y, weight: normWB, eps: 1e-6)
            let gatedB = Fused.gatedNorm(z, normedB)
            return try store.linear(p + "out_proj", gatedB.reshaped([B, S, valDim]))
        }
        // B>1 decode: GDNMetal.run has no batch dimension, so run the B=1 kernel per sequence
        // (same arithmetic as B=1) and stack. STRIM_GDN_BATCH_METAL=1 opts in (default stays on the tensor path: benchserve near-tie flip, see docs/BATCH-MTP-2026-10-26.md).
        if GDN.useMetal && B > 1 && S <= GDN.metalMaxS && S < 512 && !recording && GDN.batchMetal {
            var ys: [MLXArray] = [], ss: [MLXArray] = []
            ys.reserveCapacity(B); ss.reserveCapacity(B)
            for b in 0 ..< B {
                let r = GDNMetal.run(q: qr[b ..< (b + 1)], k: kr[b ..< (b + 1)], v: v[b ..< (b + 1)],
                                     g: g[b ..< (b + 1)], beta: beta[b ..< (b + 1)],
                                     ssm: recurrent0[b ..< (b + 1)].reshaped([1, Hv, Dv, Dk]),
                                     recordStack: false)
                ys.append(r.y); ss.append(r.ssm)
            }
            state?.ssm = concatenated(ss, axis: 0)
            let yM = concatenated(ys, axis: 0)
            let normWM = try store.tensor(p + "norm.weight")
            let normedM = MLXFast.rmsNorm(yM, weight: normWM, eps: 1e-6)
            let gatedM = Fused.gatedNorm(z, normedM)
            return try store.linear(p + "out_proj", gatedM.reshaped([B, S, valDim]))
        }
        let yAll: MLXArray
        let ssmOut: MLXArray
        var stackOut: MLXArray?
        if GDN.skipRec {
            // Measurement only: pass qr through in place of yAll so everything downstream
            // (norm, gate, out_proj) still runs at the same shapes. STRIM_SKIP_REC=1.
            yAll = qr; ssmOut = recurrent0
        } else {
            let fn: ([MLXArray]) -> [MLXArray]
            if recording {
                fn = GDN.useMM ? GDN.recurrenceRecMMFn : GDN.recurrenceRecFn
            } else {
                fn = GDN.useMM ? GDN.recurrenceNoStateMMFn : GDN.recurrenceFn
            }
            let out = fn([qr, kr, v, g, beta, recurrent0])
            yAll = out[0]; ssmOut = out[1]
            if recording { stackOut = out[2] }
        }
        state?.ssm = ssmOut
        if let state, state.recording, let stack = stackOut {
            for t in 0 ..< S {
                state.history.append((conv: convIn[0..., (t + 1) ..< (t + 4), 0...],
                                      ssm: stack[t]))
            }
        }
        let normW = try store.tensor(p + "norm.weight")
        let normed = MLXFast.rmsNorm(yAll, weight: normW, eps: 1e-6)
        let gated = Fused.gatedNorm(z, normed)
        return try store.linear(p + "out_proj", gated.reshaped([B, S, valDim]))
    }
}
