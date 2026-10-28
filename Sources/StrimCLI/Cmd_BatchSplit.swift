import Foundation
import MLX
import StrimCore

// `strim benchbatchsplit <model> <ctx> <B>`: per-class split of one batched decode step.
//
// Prefills B sequences of length ctx (BatchModel.prefill for B>1; ModelCache for B=1), then
// times 8 warm decode steps. Each step is run twice: once with no intermediate sync (total)
// and once through `splitStep`, which copies the BatchModel.forward layer loop and forces
// every stage with an exclusive lap timer. Public StrimCore API only; nothing is changed.
//
// Assumes default env (STRIM_GDN_TENSOR, STRIM_REC_ELEM, STRIM_GDN_BLOCKED unset).
// B=1 uses the fused GDN kernels (convSilu, GDNMetal.run) in the split, matching
// GDN.forward's B==1 path; B>1 uses depthwise conv and the compiled MM recurrence.

enum BSClass {
    static let inProj = "GDN in_proj matmuls"
    static let conv = "GDN conv"
    static let rec = "GDN recurrence"
    static let outProj = "GDN out_proj"
    static let attnProj = "attn projections"
    static let kvAppend = "attn KV append (concat)"
    static let kvGather = "attn KV batch gather (concat)"
    static let mask = "attn mask construction"
    static let sdpa = "attn SDPA"
    static let mlp = "MLP"
    static let head = "final norm + lm_head"
    static let other = "other (norms, gates, RoPE, residual, embed)"
    static let all = [inProj, conv, rec, outProj, attnProj, kvAppend, kvGather, mask, sdpa,
                      mlp, head, other]
}

/// Exclusive lap timer: `lap` materialises the arrays, syncs the GPU and charges the wall time
/// since the previous lap to one class, so no time is counted twice.
final class BSLap {
    var acc: [String: Double] = [:]
    /// Number of eval+sync points per class (each carries a fixed cost, see bsLapCost).
    var counts: [String: Int] = [:]
    var mark = Date()
    func lap(_ cls: String, _ arrs: [MLXArray] = []) {
        if !arrs.isEmpty {
            eval(arrs)
            Stream.gpu.synchronize()
            counts[cls, default: 0] += 1
        }
        let now = Date()
        acc[cls, default: 0] += now.timeIntervalSince(mark)
        mark = now
    }
}

// Constants mirror GDN / Attention (internal in StrimCore).
let bsHv = 48, bsHk = 16, bsDk = 128, bsDv = 128
let bsKeyDim = bsHk * bsDk, bsValDim = bsHv * bsDv, bsConvDim = 2 * bsKeyDim + bsValDim
let bsHq = 24, bsHkv = 4, bsD = 256, bsRotaryDim = 64

nonisolated(unsafe) let bsOnes = MLXArray.ones([bsDk], dtype: .bfloat16)
nonisolated(unsafe) let bsRepIdx: MLXArray = {
    var idx: [Int32] = []
    for h in 0 ..< bsHk { for _ in 0 ..< (bsHv / bsHk) { idx.append(Int32(h)) } }
    return MLXArray(idx)
}()
/// Same compiled recurrence the B>1 GDN path runs (GDN.recurrenceNoStateMMFn is internal).
nonisolated(unsafe) let bsRecFn: ([MLXArray]) -> [MLXArray] = compile { (a: [MLXArray]) -> [MLXArray] in
    let r = GDN.recurrenceMMNoState(a[0], a[1], a[2], a[3], a[4], a[5], dtype: a[2].dtype)
    return [r.yAll, r.ssm]
}

/// Fixed cost of one eval+sync point, measured on a trivial op. Subtracting
/// laps x cost gives an overhead-corrected class time.
func bsLapCost() -> Double {
    let x = MLXArray.ones([1024], dtype: .bfloat16)
    eval(x)
    for _ in 0 ..< 20 { let y = x * 2; eval([y]); Stream.gpu.synchronize() }
    let t0 = Date()
    let n = 300
    for _ in 0 ..< n { let y = x * 2; eval([y]); Stream.gpu.synchronize() }
    return Date().timeIntervalSince(t0) * 1000 / Double(n)
}

func bsGDN(_ x: MLXArray, store: WeightStore, layer: Int, state: GDNState, fused: Bool,
           lap: BSLap?) throws -> MLXArray {
    let p = "language_model.model.layers.\(layer).linear_attn."
    let B = x.shape[0], S = x.shape[1]
    let dtype = x.dtype

    let qkv = try store.linear(p + "in_proj_qkv", x)
    lap?.lap(BSClass.inProj, [qkv])
    let z = try store.linear(p + "in_proj_z", x).reshaped([B, S, bsHv, bsDv])
    lap?.lap(BSClass.inProj, [z])
    let bProj = try store.linear(p + "in_proj_b", x)
    lap?.lap(BSClass.inProj, [bProj])
    let aProj = try store.linear(p + "in_proj_a", x)
    lap?.lap(BSClass.inProj, [aProj])

    let convW = try store.tensor(p + "conv1d.weight")
    let convState = state.conv ?? MLXArray.zeros([B, 3, bsConvDim], dtype: dtype)
    let convIn = concatenated([convState, qkv], axis: 1)
    let n = convIn.shape[1]
    state.conv = convIn[0..., (n - 3) ..< n, 0...]
    let convOut = fused
        ? GDNMetal.convSilu(convIn: convIn, weight: convW)
        : GDN.silence(GDN.depthwise(convIn, convW, S))
    lap?.lap(BSClass.conv, [convOut])

    let qRaw = convOut[0..., 0..., 0 ..< bsKeyDim].reshaped([B, S, bsHk, bsDk])
    let kRaw = convOut[0..., 0..., bsKeyDim ..< (2 * bsKeyDim)].reshaped([B, S, bsHk, bsDk])
    let v = convOut[0..., 0..., (2 * bsKeyDim) ..< bsConvDim].reshaped([B, S, bsHv, bsDv])
    let inv = pow(Float(bsDk), -0.5)
    let q = MLXFast.rmsNorm(qRaw, weight: bsOnes, eps: 1e-6) * (inv * inv)
    let k = MLXFast.rmsNorm(kRaw, weight: bsOnes, eps: 1e-6) * inv
    let beta = sigmoid(bProj)
    let aLog = try store.tensor(p + "A_log").asType(.float32)
    let dtBias = try store.tensor(p + "dt_bias").asType(.float32)
    let softplus = log(1 + exp(aProj.asType(.float32) + dtBias))
    let g = exp(-exp(aLog) * softplus)
    let qr = q.take(bsRepIdx, axis: 2)
    let kr = k.take(bsRepIdx, axis: 2)
    lap?.lap(BSClass.other, [qr, kr, beta, g])

    let recurrent0 = state.ssm ?? MLXArray.zeros([B, bsHv, bsDv, bsDk], dtype: .float32)
    let yAll: MLXArray, ssmOut: MLXArray
    if fused {
        let r = GDNMetal.run(q: qr, k: kr, v: v, g: g, beta: beta, ssm: recurrent0, recordStack: false)
        yAll = r.y; ssmOut = r.ssm
    } else {
        let out = bsRecFn([qr, kr, v, g, beta, recurrent0])
        yAll = out[0]; ssmOut = out[1]
    }
    state.ssm = ssmOut
    lap?.lap(BSClass.rec, [yAll, ssmOut])

    let normW = try store.tensor(p + "norm.weight")
    let normed = MLXFast.rmsNorm(yAll, weight: normW, eps: 1e-6)
    let gate = GDN.silence(z.asType(.float32))
    let gated = (gate * normed.asType(.float32)).asType(dtype)
    lap?.lap(BSClass.other, [gated])
    let out = try store.linear(p + "out_proj", gated.reshaped([B, S, bsValDim]))
    lap?.lap(BSClass.outProj, [out])
    return out
}

/// Copy of BatchedAttention.forward for one decode token per sequence.
func bsAttn(_ x: MLXArray, store: WeightStore, layer: Int, cache: BatchedAttentionCache,
            lap: BSLap?) throws -> MLXArray {
    let prefix = "language_model.model.layers.\(layer).self_attn."
    let B = x.shape[0], S = x.shape[1]

    let qProj = try store.linear(prefix + "q_proj", x)
    lap?.lap(BSClass.attnProj, [qProj])
    let halves = qProj.reshaped([B, S, bsHq, 2, bsD]).split(parts: 2, axis: 3)
    let queries0 = halves[0].squeezed(axis: 3)
    let gate = halves[1].squeezed(axis: 3).reshaped([B, S, bsHq * bsD])
    let kProj = try store.linear(prefix + "k_proj", x)
    lap?.lap(BSClass.attnProj, [kProj])
    let vProj = try store.linear(prefix + "v_proj", x)
    lap?.lap(BSClass.attnProj, [vProj])
    let kP = kProj.reshaped([B, S, bsHkv, bsD])
    let vP = vProj.reshaped([B, S, bsHkv, bsD])
    let qNormW = try store.tensor(prefix + "q_norm.weight")
    let kNormW = try store.tensor(prefix + "k_norm.weight")
    let q = MLXFast.rmsNorm(queries0, weight: qNormW, eps: 1e-6).transposed(0, 2, 1, 3)
    let k = MLXFast.rmsNorm(kP, weight: kNormW, eps: 1e-6).transposed(0, 2, 1, 3)
    let v = vP.transposed(0, 2, 1, 3)
    lap?.lap(BSClass.other, [q, k, v])

    // Per-sequence preallocated caches (BatchedAttention.forward): RoPE at each offset,
    // in-place append, SDPA over the valid prefix; mask/gather classes stay at zero.
    while cache.seqs.count < B { cache.seqs.append(AttentionCache()) }
    var qParts: [MLXArray] = [], kNew: [MLXArray] = [], vNew: [MLXArray] = []
    for b in 0 ..< B {
        let off = cache.seqs[b].offset
        qParts.append(MLXFast.RoPE(q[b ..< (b + 1), 0..., 0..., 0...], dimensions: bsRotaryDim,
                                   traditional: false, base: 10_000_000, scale: 1.0, offset: off))
        kNew.append(MLXFast.RoPE(k[b ..< (b + 1), 0..., 0..., 0...], dimensions: bsRotaryDim,
                                 traditional: false, base: 10_000_000, scale: 1.0, offset: off))
        vNew.append(v[b ..< (b + 1), 0..., 0..., 0...])
    }
    lap?.lap(BSClass.other, qParts + kNew)

    var kvs: [(keys: MLXArray, values: MLXArray)] = []
    for b in 0 ..< B { kvs.append(cache.append(b, kNew[b], vNew[b])) }
    lap?.lap(BSClass.kvAppend, kvs.flatMap { [$0.keys, $0.values] })

    let maskMode: MLXFast.ScaledDotProductAttentionMaskMode = S > 1 ? .causal : .none
    let outs = (0 ..< B).map { b in
        MLXFast.scaledDotProductAttention(
            queries: qParts[b], keys: kvs[b].keys, values: kvs[b].values,
            scale: pow(Float(bsD), -0.5), mask: maskMode)
    }
    let out = B == 1 ? outs[0] : concatenated(outs, axis: 0)
    lap?.lap(BSClass.sdpa, [out])
    let flat = out.transposed(0, 2, 1, 3).reshaped([B, S, bsHq * bsD])
    let gated = (flat.asType(.float32) * sigmoid(gate.asType(.float32))).asType(x.dtype)
    lap?.lap(BSClass.other, [gated])
    let o = try store.linear(prefix + "o_proj", gated)
    lap?.lap(BSClass.attnProj, [o])
    return o
}

/// One decode step: the BatchModel.forward layer loop, expanded so each stage can be timed.
/// `lap == nil` leaves the whole step lazy (single eval by the caller).
func bsDecodeStep(_ tokens: [[Int32]], store: WeightStore, cache: BatchedModelCache,
                  lap: BSLap?) throws -> MLXArray {
    let B = tokens.count
    let idx = MLXArray(tokens.map { $0[0] }).reshaped([B, 1])
    var h = try store.embedding("language_model.model.embed_tokens", indices: idx)
    lap?.lap(BSClass.other, [h])
    for layer in 0 ..< 64 {
        let p = "language_model.model.layers.\(layer)."
        let n1 = try store.rmsNorm(p + "input_layernorm", h)
        lap?.lap(BSClass.other, [n1])
        let mixed: MLXArray
        if (layer + 1) % 4 != 0 {
            mixed = try bsGDN(n1, store: store, layer: layer, state: cache.gdnState(layer),
                              fused: B == 1, lap: lap)
        } else {
            mixed = try bsAttn(n1, store: store, layer: layer,
                               cache: cache.attentionCache(layer, B: B), lap: lap)
        }
        h = h + mixed
        lap?.lap(BSClass.other, [h])
        let n2 = try store.rmsNorm(p + "post_attention_layernorm", h)
        lap?.lap(BSClass.other, [n2])
        let m = try MLP.forward(n2, store: store, layer: layer)
        lap?.lap(BSClass.mlp, [m])
        h = h + m
        lap?.lap(BSClass.other, [h])
    }
    let normed = try store.rmsNorm("language_model.model.norm", h)
    lap?.lap(BSClass.head, [normed])
    let logits = try store.linear("language_model.lm_head", normed)
    lap?.lap(BSClass.head, [logits])
    return logits
}

func runBatchSplit(_ args: [String]) {
    guard args.count >= 5, let ctx = Int(args[3]), let B = Int(args[4]), ctx >= 1, B >= 1 else {
        print("usage: strim benchbatchsplit <model> <ctx> <B>")
        return
    }
    let warm = 2, steps = 8
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let prompts: [[Int32]] = (0 ..< B).map { b in
            (0 ..< ctx).map { i in Int32((i * 7919 + b * 104_729 + 17) % 100_000 + 1) }
        }
        let cache: BatchedModelCache
        var fusedMs: Double? = nil
        if B == 1 {
            let mc = ModelCache()
            let (_, logits) = try QwenModel.forwardAll(tokens: prompts[0], store: store, cache: mc,
                                                       lastTokenOnly: true)
            eval(logits)
            // Fused reference: ModelCache single-token path, on a snapshot so the split
            // run below starts from the same prefilled state.
            let ref = mc.snapshot()
            var fused: [Double] = []
            for i in 0 ..< warm + steps {
                let t0 = Date()
                let (_, lg) = try QwenModel.forward(tokens: [Int32(100)], store: store, cache: ref)
                eval(lg); Stream.gpu.synchronize()
                if i >= warm { fused.append(Date().timeIntervalSince(t0) * 1000) }
            }
            fusedMs = fused.reduce(0, +) / Double(fused.count)
            cache = BatchModel.from([mc])
        } else {
            cache = BatchedModelCache()
            let logits = try BatchModel.prefill(tokens: prompts, store: store, cache: cache)
            eval(logits); Stream.gpu.synchronize()
        }

        let tokens: [[Int32]] = (0 ..< B).map { [Int32(100 + $0)] }
        for _ in 0 ..< warm {
            let lg = try bsDecodeStep(tokens, store: store, cache: cache, lap: nil)
            eval(lg); Stream.gpu.synchronize()
        }
        var totalMs: [Double] = []
        var classMs: [String: [Double]] = [:]
        var classLaps: [String: [Double]] = [:]
        for _ in 0 ..< steps {
            let t0 = Date()
            let lg = try bsDecodeStep(tokens, store: store, cache: cache, lap: nil)
            eval(lg); Stream.gpu.synchronize()
            totalMs.append(Date().timeIntervalSince(t0) * 1000)

            let lap = BSLap()
            let lgSplit = try bsDecodeStep(tokens, store: store, cache: cache, lap: lap)
            eval(lgSplit); Stream.gpu.synchronize()
            for c in BSClass.all {
                classMs[c, default: []].append((lap.acc[c] ?? 0) * 1000)
                classLaps[c, default: []].append(Double(lap.counts[c] ?? 0))
            }
        }
        func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(max(xs.count, 1)) }
        let total = mean(totalMs)
        let means: [String: Double] = classMs.mapValues(mean)
        let lapsPer: [String: Double] = classLaps.mapValues(mean)
        let lapCost = bsLapCost()
        let corr: [String: Double] = Dictionary(uniqueKeysWithValues: BSClass.all.map {
            ($0, (means[$0] ?? 0) - (lapsPer[$0] ?? 0) * lapCost)
        })

        // Synthetic copy of the same KV shapes: per layer, B per-sequence appends (k and v)
        // plus one batch gather (k and v), 16 attention layers.
        let base = MLXArray.ones([1, bsHkv, ctx, bsD], dtype: .bfloat16)
        let newTok = MLXArray.ones([1, bsHkv, 1, bsD], dtype: .bfloat16)
        eval(base, newTok)
        func synthStep() -> [MLXArray] {
            var outs: [MLXArray] = []
            let parts = [MLXArray](repeating: base, count: B)
            for _ in 0 ..< 16 {
                for _ in 0 ..< B {
                    outs.append(concatenated([base, newTok], axis: 2))
                    outs.append(concatenated([base, newTok], axis: 2))
                }
                outs.append(concatenated(parts, axis: 0))
                outs.append(concatenated(parts, axis: 0))
            }
            return outs
        }
        for _ in 0 ..< warm { let o = synthStep(); eval(o); Stream.gpu.synchronize() }
        var synthMs: [Double] = []
        for _ in 0 ..< steps {
            let t0 = Date()
            let o = synthStep(); eval(o); Stream.gpu.synchronize()
            synthMs.append(Date().timeIntervalSince(t0) * 1000)
        }
        let synth = mean(synthMs)

        let sum = means.values.reduce(0, +)
        let gap = (sum - total) / total * 100
        let corrSum = corr.values.reduce(0, +)
        let corrGap = (corrSum - total) / total * 100
        let pad = { (s: String) in s.padding(toLength: 44, withPad: " ", startingAt: 0) }
        print("benchbatchsplit model=\(URL(fileURLWithPath: args[2]).lastPathComponent) ctx=\(ctx) B=\(B) warm=\(warm) steps=\(steps)")
        print(pad("class") + "    ms/step      %    syncs    corr ms   corr %")
        for c in BSClass.all {
            let ms = means[c] ?? 0
            let cm = corr[c] ?? 0
            print(pad(c) + String(format: " %10.3f %6.1f %8.1f %10.3f %7.1f",
                                  ms, ms / total * 100, lapsPer[c] ?? 0, cm, cm / total * 100))
        }
        print(pad("sum of classes") + String(format: " %10.3f %6.1f %8.1f %10.3f %7.1f",
                                             sum, sum / total * 100, lapsPer.values.reduce(0, +),
                                             corrSum, corrSum / total * 100))
        print(pad("total step (no per-stage sync)") + String(format: " %10.3f %6.1f", total, 100.0))
        print(String(format: "gap: raw %+.1f%%, corrected %+.1f%% (sum vs total); eval+sync cost %.4f ms x %.0f syncs/step",
                     gap, corrGap, lapCost, lapsPer.values.reduce(0, +)))
        let concatShare = ((means[BSClass.conv] ?? 0) + (means[BSClass.rec] ?? 0)
            + (means[BSClass.kvAppend] ?? 0) + (means[BSClass.kvGather] ?? 0)
            + (means[BSClass.mask] ?? 0)) / total * 100
        let corrShare = ((corr[BSClass.conv] ?? 0) + (corr[BSClass.rec] ?? 0)
            + (corr[BSClass.kvAppend] ?? 0) + (corr[BSClass.kvGather] ?? 0)
            + (corr[BSClass.mask] ?? 0)) / total * 100
        print(String(format: "share GDN conv+recurrence + KV concat + mask: %.1f%% raw, %.1f%% corrected", concatShare, corrShare))
        print(String(format: "synthetic KV concat, same shapes (16 layers, B appends + gather): %.3f ms/step (%.1f%% of total)",
                     synth, synth / total * 100))
        if let fusedMs {
            print(String(format: "fused ModelCache reference (B=1): %.3f ms/step; split total %.3f ms (%+.1f%%)",
                         fusedMs, total, (total / fusedMs - 1) * 100))
        }
        print(String(format: "RESULT ctx=%d B=%d total %.3f ms/step", ctx, B, total))
    } catch {
        FileHandle.standardError.write(Data("benchbatchsplit failed: \(error)\n".utf8))
        exit(1)
    }
}
