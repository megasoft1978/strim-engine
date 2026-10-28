import Foundation
import MLX
import StrimCore

// Pre-screen microbenches (2026-10-28). No engine code is changed; each subcommand answers one kill-rule question.
//   strim benchprescreen zoverlap <model> [layers=48] [M=1024] [reps=8]
//       GDN blocked recurrence + in_proj_z (+ norm/gate + out_proj) chained over `layers` layers (weights rotated
//       over 12 real GDN layers), with and without a data dependency z <- rec. Reports ms/layer saved by overlap.
//   strim benchprescreen head <model> [reps=30]
//       final norm + quantized lm_head + argmax at M=1 and M=3: full vs logits-only vs chunked-argmax variants.
//   strim benchprescreen kvq8 [T1,T2,...=16384,32768] [reps=15]
//       16 distinct full-attention layers' decode SDPA (Hq=24 Hkv=4 D=256), M=1 and M=3: bf16 fused SDPA vs
//       affine-q8 K/V via dequantize+SDPA and via quantizedMatmul (mlx-lm style), plus max abs error vs bf16.
//   strim benchprescreen sdpa [qL:kL,...] [reps=10]
//       one causal prefill SDPA call (16 layers' worth, distinct K/V) per qL:kL, reports ms and ns per (q,k) pair.

private func ms(_ f: () -> Void) -> Double {
    let t0 = Date(); f(); return Date().timeIntervalSince(t0) * 1000
}

func runPrescreen(_ args: [String]) {
    guard args.count >= 3 else {
        print("usage: strim benchprescreen zoverlap|head|kvq8|sdpa ..."); return
    }
    do {
        switch args[2] {
        case "zoverlap": try prescreenZ(args)
        case "head": try prescreenHead(args)
        case "kvq8": prescreenKV(args)
        case "sdpa": prescreenSDPA(args)
        default: print("unknown subcommand \(args[2])")
        }
    } catch {
        FileHandle.standardError.write(Data("benchprescreen failed: \(error)\n".utf8)); exit(1)
    }
}

// MARK: B2 z-projection overlap

private func prescreenZ(_ args: [String]) throws {
    guard args.count >= 4 else { print("usage: strim benchprescreen zoverlap <model> [layers] [M] [reps]"); return }
    let store = try WeightStore(dir: URL(fileURLWithPath: args[3]))
    let nLayers = args.count >= 5 ? Int(args[4]) ?? 48 : 48
    let M = args.count >= 6 ? Int(args[5]) ?? 1024 : 1024
    let reps = args.count >= 7 ? Int(args[6]) ?? 8 : 8
    let gdn = [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14]
    struct L { var z: (MLXArray, MLXArray, MLXArray, QuantSpec); var o: (MLXArray, MLXArray, MLXArray, QuantSpec); var nw: MLXArray }
    func qw(_ p: String) throws -> (MLXArray, MLXArray, MLXArray, QuantSpec) {
        let w = try store.tensor(p + ".weight"), s = try store.tensor(p + ".scales"), b = try store.tensor(p + ".biases")
        return (w, s, b, try store.quantSpec(p, w: w, s: s))
    }
    var layers: [L] = []
    for l in gdn {
        let p = "language_model.model.layers.\(l).linear_attn."
        layers.append(L(z: try qw(p + "in_proj_z"), o: try qw(p + "out_proj"), nw: try store.tensor(p + "norm.weight")))
    }
    let Hk = 16, Hv = 48, D = 128
    let q = (MLXRandom.normal([1, M, Hk, D]) * 0.1).asType(.bfloat16)
    let k = (MLXRandom.normal([1, M, Hk, D]) * 0.1).asType(.bfloat16)
    let v = (MLXRandom.normal([1, M, Hv, D]) * 0.1).asType(.bfloat16)
    let g = MLXArray.ones([1, M, Hv]) * 0.97
    let beta = MLXArray.ones([1, M, Hv]) * 0.5
    let ssm = MLXArray.zeros([1, Hv, D, D], dtype: .float32)
    let x0 = (MLXRandom.normal([1, M, 5120]) * 0.1).asType(.bfloat16)
    let zero = MLXArray.zeros([1, 1, 1], dtype: .bfloat16)
    eval(q, k, v, g, beta, ssm, x0, zero)

    enum Mode { case indep, dep, recOnly, zOnly, depOutOnly }
    func chain(_ mode: Mode, zFirstOperand: Bool = true) -> MLXArray {
        var x = x0
        for i in 0 ..< nLayers {
            let w = layers[i % layers.count]
            let r = GDNMetal.runBlocked(q: q, k: k, v: v, g: g, beta: beta, ssm: ssm)
            let xz: MLXArray
            switch mode {
            case .dep: xz = x + r.y[0..., 0 ..< 1, 0 ..< 1, 0 ..< 1].reshaped([1, 1, 1]) * zero
            default: xz = x + zero * zero
            }
            let z = store.qmm(xz, w.z.0, w.z.1, w.z.2, spec: w.z.3).reshaped([1, M, Hv, D])
            let normed = MLXFast.rmsNorm(r.y, weight: w.nw, eps: 1e-6)
            let gated = zFirstOperand ? (z * sigmoid(z)) * normed : normed * (z * sigmoid(z))
            let out = store.qmm(gated.reshaped([1, M, Hv * D]), w.o.0, w.o.1, w.o.2, spec: w.o.3)
            x = x + out
        }
        return x
    }
    _ = chain(.indep); eval(chain(.indep)); eval(chain(.dep))
    var best: [String: Double] = [:]
    func rec(_ name: String, _ f: () -> MLXArray) {
        let t = ms { eval(f()) }
        best[name] = min(best[name] ?? .infinity, t)
    }
    for _ in 0 ..< reps {
        rec("indep") { chain(.indep) }
        rec("dep") { chain(.dep) }
        rec("indep_swapped_operands") { chain(.indep, zFirstOperand: false) }
        rec("dep_swapped_operands") { chain(.dep, zFirstOperand: false) }
    }
    let n = Double(nLayers)
    print(String(format: "zoverlap M=%d layers=%d reps=%d (min of reps; chained, rotated weights over %d real GDN layers)", M, nLayers, reps, gdn.count))
    for key in ["indep", "dep", "indep_swapped_operands", "dep_swapped_operands"] {
        print(String(format: "  %-24@ total %.2f ms  %.3f ms/layer", key as NSString, best[key]!, best[key]! / n))
    }
    let saved = (best["dep"]! - best["indep"]!) / n
    let saved2 = (best["dep_swapped_operands"]! - best["indep_swapped_operands"]!) / n
    print(String(format: "RESULT overlap saving dep-indep = %.3f ms/layer (operand order A), %.3f ms/layer (order B); kill if < 0.3", saved, saved2))
}

// MARK: B3 lm_head + argmax

private func prescreenHead(_ args: [String]) throws {
    guard args.count >= 4 else { print("usage: strim benchprescreen head <model> [reps]"); return }
    let store = try WeightStore(dir: URL(fileURLWithPath: args[3]))
    let reps = args.count >= 5 ? Int(args[4]) ?? 30 : 30
    let p = "language_model.lm_head"
    let w = try store.tensor(p + ".weight"), s = try store.tensor(p + ".scales"), b = try store.tensor(p + ".biases")
    let spec = try store.quantSpec(p, w: w, s: s)
    let normW = try store.tensor("language_model.model.norm.weight")
    let V = w.shape[0]
    print("lm_head vocab rows \(V), spec \(spec), norm weight \(normW.shape)")
    var chunks = 1
    for c in [16, 8, 4, 2] where V % c == 0 { chunks = c; break }
    for M in [1, 3] {
        let h = (MLXRandom.normal([1, M, 5120])).asType(.bfloat16)
        // distinct activations per rep so nothing is cached
        let hs = (0 ..< 8).map { _ in (MLXRandom.normal([1, M, 5120])).asType(.bfloat16) }
        eval(h); eval(hs)
        func logits(_ x: MLXArray) -> MLXArray {
            store.qmm(MLXFast.rmsNorm(x, weight: normW, eps: 1e-6), w, s, b, spec: spec)
        }
        let variants: [(String, (MLXArray) -> MLXArray)] = [
            ("logits_only", { x in logits(x) }),
            ("full_argmax", { x in argMax(logits(x), axis: -1) }),
            ("chunked_argmax", { x in
                let l = logits(x).reshaped([M, chunks, V / chunks])
                let a = argMax(l, axis: -1)                       // [M,chunks]
                let m = l.max(axis: -1)                           // [M,chunks]
                let bc = argMax(m, axis: -1)                      // [M]
                let inner = takeAlong(a, bc.reshaped([M, 1]), axis: 1).reshaped([M])
                return bc * Int32(V / chunks) + inner
            }),
            ("max_then_eq_argmax", { x in
                // single reduction pass for the max, then first index equal to it (two cheap kernels)
                let l = logits(x)
                let m = l.max(axis: -1, keepDims: true)
                return argMax((l .== m).asType(.uint8), axis: -1)
            }),
        ]
        for (_, f) in variants { eval(f(hs[0])) }
        var best: [String: Double] = [:]
        for r in 0 ..< reps {
            for (name, f) in variants {
                let x = hs[(r + 1) % hs.count]
                let t = ms { eval(f(x)) }
                best[name] = min(best[name] ?? .infinity, t)
            }
        }
        // correctness: all variants return the same token ids
        let ref = variants[1].1(h); let chk = variants.dropFirst(2).map { $0.1(h) }
        eval(ref); eval(chk)
        var same = true
        for c in chk where !arrayEqual(c.asType(.int32), ref.asType(.int32)).item(Bool.self) { same = false }
        print(String(format: "head M=%d: logits_only %.3f ms, full_argmax %.3f ms (argmax cost %.3f), chunked(%d) %.3f ms (%.3f vs full), max_then_eq %.3f ms (%.3f vs full), ids_equal=%@",
                     M, best["logits_only"]!, best["full_argmax"]!, best["full_argmax"]! - best["logits_only"]!,
                     chunks, best["chunked_argmax"]!, best["full_argmax"]! - best["chunked_argmax"]!,
                     best["max_then_eq_argmax"]!, best["full_argmax"]! - best["max_then_eq_argmax"]!, (same ? "YES" : "NO") as NSString))
    }
    print("RESULT upper bound of any fused argmax gain = argmax cost (full_argmax - logits_only); kill if < 0.15 ms/round")
}

// MARK: B4 q8 KV

private func prescreenKV(_ args: [String]) {
    let Ts = args.count >= 4 ? args[3].split(separator: ",").compactMap { Int($0) } : [16384, 32768]
    let reps = args.count >= 5 ? Int(args[4]) ?? 15 : 15
    let Hq = 24, Hkv = 4, D = 256, nL = 16, gs = 64, bits = 8
    let scale = Float(1.0 / 16.0)
    for T in Ts {
        var ks: [MLXArray] = [], vs: [MLXArray] = []
        var kq: [(MLXArray, MLXArray, MLXArray?)] = [], vq: [(MLXArray, MLXArray, MLXArray?)] = []
        for _ in 0 ..< nL {
            let kk = (MLXRandom.normal([1, Hkv, T, D])).asType(.bfloat16)
            let vv = (MLXRandom.normal([1, Hkv, T, D])).asType(.bfloat16)
            ks.append(kk); vs.append(vv)
            kq.append(quantized(kk, groupSize: gs, bits: bits)); vq.append(quantized(vv, groupSize: gs, bits: bits))
            eval(kk, vv, kq.last!.0, kq.last!.1, kq.last!.2!, vq.last!.0, vq.last!.1, vq.last!.2!)
        }
        for M in [1, 3] {
            let qs = (0 ..< nL).map { _ in MLXRandom.normal([1, Hq, M, D]).asType(.bfloat16) }
            eval(qs)
            func bf16() -> MLXArray {
                var acc = qs[0]
                for l in 0 ..< nL {
                    acc = MLXFast.scaledDotProductAttention(queries: qs[l] + acc * 0, keys: ks[l], values: vs[l], scale: scale, mask: .none)
                }
                return acc
            }
            func deq() -> MLXArray {
                var acc = qs[0]
                for l in 0 ..< nL {
                    let k = dequantized(kq[l].0, scales: kq[l].1, biases: kq[l].2, groupSize: gs, bits: bits)
                    let v = dequantized(vq[l].0, scales: vq[l].1, biases: vq[l].2, groupSize: gs, bits: bits)
                    acc = MLXFast.scaledDotProductAttention(queries: qs[l] + acc * 0, keys: k, values: v, scale: scale, mask: .none)
                }
                return acc
            }
            func qmmAttn(_ l: Int, _ q: MLXArray) -> MLXArray {
                let rep = Hq / Hkv
                // [1,Hq,M,D] -> [1,Hkv,rep*M,D]
                let qq = (q * scale).reshaped([1, Hkv, rep * M, D])
                let sc = quantizedMatmul(qq, kq[l].0, scales: kq[l].1, biases: kq[l].2, transpose: true, groupSize: gs, bits: bits)
                let pr = softmax(sc.asType(.float32), axis: -1, precise: true).asType(.bfloat16)
                let o = quantizedMatmul(pr, vq[l].0, scales: vq[l].1, biases: vq[l].2, transpose: false, groupSize: gs, bits: bits)
                return o.reshaped([1, Hq, M, D])
            }
            func qmmPath() -> MLXArray {
                var acc = qs[0]
                for l in 0 ..< nL { acc = qmmAttn(l, qs[l] + acc * 0) }
                return acc
            }
            eval(bf16()); eval(deq()); eval(qmmPath())
            var tb = Double.infinity, td = Double.infinity, tq = Double.infinity
            for _ in 0 ..< reps {
                tb = min(tb, ms { eval(bf16()) }); td = min(td, ms { eval(deq()) }); tq = min(tq, ms { eval(qmmPath()) })
            }
            // error of q8 paths vs bf16 on a single layer with the same query
            let ref = MLXFast.scaledDotProductAttention(queries: qs[0], keys: ks[0], values: vs[0], scale: scale, mask: .none).asType(.float32)
            let e1 = abs(qmmAttn(0, qs[0]).asType(.float32) - ref).max().item(Float.self)
            let e2 = abs(MLXFast.scaledDotProductAttention(queries: qs[0],
                         keys: dequantized(kq[0].0, scales: kq[0].1, biases: kq[0].2, groupSize: gs, bits: bits),
                         values: dequantized(vq[0].0, scales: vq[0].1, biases: vq[0].2, groupSize: gs, bits: bits),
                         scale: scale, mask: .none).asType(.float32) - ref).max().item(Float.self)
            let refMag = abs(ref).max().item(Float.self)
            print(String(format: "kvq8 T=%d M=%d (16 layers, ms/pass): bf16 fused %.2f | q8 dequant+sdpa %.2f (%+.2f) | q8 qmm-attn %.2f (%+.2f) | maxabs err qmm %.4f dequant %.4f (ref max %.3f)",
                         T, M, tb, td, tb - td, tq, tb - tq, e1, e2, refMag))
        }
    }
    print("RESULT saving = bf16 - best q8 path (ms per pass); kill if < 3% of the pass (~55 ms at 32K => 1.65 ms)")
}

// MARK: A3 follow-up: prefill SDPA per-pair rate by qL

private func prescreenSDPA(_ args: [String]) {
    let specs = args.count >= 4 ? args[3].split(separator: ",").map { s -> (Int, Int) in
        let p = s.split(separator: ":"); return (Int(p[0]) ?? 1024, Int(p[1]) ?? 4096) }
        : [(1024, 32768), (1536, 32768), (523, 32779), (11, 32779), (1035, 16395)]
    let reps = args.count >= 5 ? Int(args[4]) ?? 10 : 10
    let Hq = 24, Hkv = 4, D = 256, nL = 4
    for (qL, kL) in specs {
        let ks = (0 ..< nL).map { _ in MLXRandom.normal([1, Hkv, kL, D]).asType(.bfloat16) }
        let vs = (0 ..< nL).map { _ in MLXRandom.normal([1, Hkv, kL, D]).asType(.bfloat16) }
        let q = MLXRandom.normal([1, Hq, qL, D]).asType(.bfloat16)
        eval(ks, vs, q)
        func run() -> MLXArray {
            var acc = q
            for l in 0 ..< nL {
                acc = MLXFast.scaledDotProductAttention(queries: q + acc * 0, keys: ks[l], values: vs[l], scale: 1.0 / 16.0, mask: .causal)
            }
            return acc
        }
        eval(run())
        var t = Double.infinity
        for _ in 0 ..< reps { t = min(t, ms { eval(run()) }) }
        let pairs = Double(qL) * Double(kL - qL) + Double(qL) * Double(qL + 1) / 2
        let per = t / Double(nL)
        print(String(format: "sdpa qL=%5d kL=%6d: %.3f ms/layer, %.2f ns per (q,k) pair per layer, 16-layer call %.1f ms", qL, kL, per, per * 1e6 / pairs, per * 16))
    }
}
