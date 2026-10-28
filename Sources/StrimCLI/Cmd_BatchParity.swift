import Foundation
import MLX
import StrimCore

// strim checkbatchparity <model> <ctx> <B> [steps=16]
//
// B sequences with different prompts (length ctx - 2*b, so lengths differ) are prefilled
// one by one (B=1 path), then decoded `steps` tokens twice from identical state: each at
// B=1 (ModelCache) and all together through BatchModel.forward. The batched run is teacher
// forced with the B=1 tokens so every step compares like with like. Reports token equality,
// the max logit difference, and for every argmax mismatch the top1-top2 margin of the B=1
// logits (batched qmm tiling drifts logits ~0.15-0.45, so a mismatch with a margin below
// the measured drift is a near-tie flip, otherwise a bug).
func runBatchParity(_ args: [String]) {
    if args.count >= 5, args[2] == "kvbench", let ctx = Int(args[3]), let B = Int(args[4]) {
        runKVBench(ctx: ctx, B: B); return
    }
    guard args.count >= 5, let ctx = Int(args[3]), let B0 = Int(args[4]), ctx >= 8, B0 >= 1 else {
        print("usage: strim checkbatchparity <model> <ctx> <B> [steps]")
        return
    }
    let steps = args.count >= 6 ? Int(args[5]) ?? 16 : 16
    // STRIM_PARITY_IDS=FILE: one prompt per line (comma-separated token ids, e.g. from `strim tokenize --chat`) instead of the
    // synthetic prompts; B is then the line count.
    let fileIds: [[Int32]]? = ProcessInfo.processInfo.environment["STRIM_PARITY_IDS"].flatMap { p in
        (try? String(contentsOfFile: p, encoding: .utf8))?.split(separator: "\n").map { $0.split(separator: ",").compactMap { Int32($0) } }
    }
    let B = fileIds?.count ?? B0
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        var caches: [ModelCache] = []
        var nexts: [Int32] = []
        for b in 0 ..< B {
            let len = ctx - 2 * b
            let prompt: [Int32] = fileIds?[b] ?? (0 ..< len).map { i in
                Int32((i * 7919 + b * 104_729 + 17) % 100_000 + 1)
            }
            let c = ModelCache()
            let (_, lg) = try QwenModel.forwardAll(tokens: prompt, store: store, cache: c,
                                                   lastTokenOnly: true)
            eval(lg)
            caches.append(c)
            nexts.append(Int32(argMax(lg.reshaped([-1])).item(Int32.self)))
        }
        let single = caches.map { $0.snapshot() }
        let bc = BatchModel.from(caches.map { $0.snapshot() })

        var toks = nexts
        var maxDiff: Float = 0
        var mismatches: [(step: Int, b: Int, margin: Float, ref: Int32, got: Int32)] = []
        var maxMargin: Float = 0
        var total = 0
        var step0Diff: Float = 0
        var sumMean: Float = 0
        for step in 0 ..< steps {
            var refLogits: [MLXArray] = []
            for b in 0 ..< B {
                let r = try QwenModel.forward(tokens: [toks[b]], store: store, cache: single[b])
                refLogits.append(r.logits.reshaped([-1]).asType(.float32))
            }
            let lb = try BatchModel.forward(tokens: toks.map { [$0] }, store: store, cache: bc)
            let batched = lb.reshaped([B, -1]).asType(.float32)
            eval(refLogits + [batched])
            var next = toks
            for b in 0 ..< B {
                let ref = refLogits[b]
                let got = batched[b]
                let d = abs(ref - got)
                let dm = d.max().item(Float.self)
                maxDiff = max(maxDiff, dm)
                if step == 0 { step0Diff = max(step0Diff, dm) }
                sumMean += d.mean().item(Float.self)
                let rTop = argMax(ref).item(Int32.self)
                let gTop = argMax(got).item(Int32.self)
                total += 1
                if rTop != gTop {
                    let top2 = sorted(ref, axis: 0)[(ref.shape[0] - 2) ..< ref.shape[0]]
                    let margin = (top2[1] - top2[0]).item(Float.self)
                    mismatches.append((step, b, margin, rTop, gTop))
                    maxMargin = max(maxMargin, margin)
                }
                next[b] = rTop
            }
            toks = next
        }
        print("checkbatchparity ctx=\(ctx) B=\(B) steps=\(steps) lens=\(fileIds?.map { $0.count } ?? (0 ..< B).map { ctx - 2 * $0 })")
        print(String(format: "tokens: %d/%d equal (teacher-forced), max logit diff %.4f (step 0: %.4f), mean abs diff %.4f",
                     total - mismatches.count, total, maxDiff, step0Diff, sumMean / Float(max(total, 1))))
        for m in mismatches {
            print(String(format: "  MISMATCH step %d seq %d ref=%d batched=%d top1-top2 margin %.4f",
                         m.step, m.b, m.ref, m.got, m.margin))
        }
        print(mismatches.isEmpty ? "RESULT PASS (all tokens equal)"
              : String(format: "RESULT %d mismatches, max margin %.4f vs max logit diff %.4f -> %@",
                       mismatches.count, maxMargin, maxDiff,
                       maxMargin <= maxDiff ? "explainable near-ties" : "SUSPECT (margin above drift)"))
    } catch {
        FileHandle.standardError.write(Data("checkbatchparity failed: \(error)\n".utf8))
        exit(1)
    }
}

// strim checkbatchparity kvbench <ctx> <B>: synthetic 16-layer decode-step KV handling
// (append + SDPA, S=1) for three layouts. No model weights; q/k/v are ones-scaled noise.
//   old      per-sequence concat append + batch concat gather + one batched SDPA
//   perseq   per-sequence preallocated AttentionCache (append in place) + B SDPAs + concat
//   stacked  one [B,Hkv,cap,D] buffer per layer: one slice update, one SDPA (.none)
//   stackedM stacked + [B,1,1,len] additive array mask (needed when lengths differ)
func runKVBench(ctx: Int, B: Int) {
    let Hq = 24, Hkv = 4, D = 256, layers = 16, warm = 3, iters = 12
    let dt = DType.bfloat16
    let q = MLXRandom.normal([B, Hq, 1, D]).asType(dt)
    let k = MLXRandom.normal([B, Hkv, 1, D]).asType(dt)
    let v = MLXRandom.normal([B, Hkv, 1, D]).asType(dt)
    let base = MLXRandom.normal([1, Hkv, ctx, D]).asType(dt)
    eval(q, k, v, base)
    let scale = pow(Float(D), -0.5)
    func timeIt(_ name: String, _ step: () -> [MLXArray]) -> Double {
        for _ in 0 ..< warm { let o = step(); eval(o); Stream.gpu.synchronize() }
        var ms: [Double] = []
        for _ in 0 ..< iters {
            let t0 = Date()
            let o = step(); eval(o); Stream.gpu.synchronize()
            ms.append(Date().timeIntervalSince(t0) * 1000)
        }
        let m = ms.reduce(0, +) / Double(ms.count)
        print(String(format: "%-9@ ctx=%d B=%d: %.3f ms/step (16 layers)", name as NSString, ctx, B, m))
        return m
    }
    // old
    var oldK = [[MLXArray]](repeating: [MLXArray](repeating: base, count: B), count: layers)
    var oldV = oldK
    _ = timeIt("old") {
        var outs: [MLXArray] = []
        for l in 0 ..< layers {
            for b in 0 ..< B {
                oldK[l][b] = concatenated([oldK[l][b], k[b ..< (b + 1)]], axis: 2)
                oldV[l][b] = concatenated([oldV[l][b], v[b ..< (b + 1)]], axis: 2)
            }
            outs.append(MLXFast.scaledDotProductAttention(
                queries: q, keys: concatenated(oldK[l], axis: 0), values: concatenated(oldV[l], axis: 0),
                scale: scale, mask: .none))
        }
        return outs
    }
    // perseq
    let per: [BatchedAttentionCache] = (0 ..< layers).map { _ in
        let bc = BatchedAttentionCache(B: B)
        bc.seqs = (0 ..< B).map { _ in let c = AttentionCache(); c.keys = base; c.values = base; return c }
        return bc
    }
    _ = timeIt("perseq") {
        var outs: [MLXArray] = []
        for l in 0 ..< layers {
            var parts: [MLXArray] = []
            for b in 0 ..< B {
                let (kk, vv) = per[l].append(b, k[b ..< (b + 1)], v[b ..< (b + 1)])
                parts.append(MLXFast.scaledDotProductAttention(
                    queries: q[b ..< (b + 1)], keys: kk, values: vv, scale: scale, mask: .none))
            }
            outs.append(concatenated(parts, axis: 0))
        }
        return outs
    }
    // stacked (+ optional array mask)
    for withMask in [false, true] {
        let cap = ((ctx + iters + warm + 256) / 256) * 256
        let stackedBase = concatenated([base, MLXArray.zeros([1, Hkv, cap - ctx, D], dtype: dt)], axis: 2)
        var kb = [MLXArray](repeating: tiled(stackedBase, repetitions: [B, 1, 1, 1]), count: layers)
        var vb = kb
        eval(kb + vb)
        var off = ctx
        _ = timeIt(withMask ? "stackedM" : "stacked") {
            var outs: [MLXArray] = []
            let end = off + 1
            let mask: MLXFast.ScaledDotProductAttentionMaskMode = withMask
                ? .array(MLXArray.zeros([B, 1, 1, end], dtype: dt)) : .none
            for l in 0 ..< layers {
                kb[l][0..., 0..., off ..< end] = k
                vb[l][0..., 0..., off ..< end] = v
                outs.append(MLXFast.scaledDotProductAttention(
                    queries: q, keys: kb[l][0..., 0..., 0 ..< end], values: vb[l][0..., 0..., 0 ..< end],
                    scale: scale, mask: mask))
            }
            off = end
            return outs
        }
    }
}
