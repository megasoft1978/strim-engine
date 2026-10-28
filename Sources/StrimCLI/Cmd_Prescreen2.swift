import Foundation
import MLX
import StrimCore

// Pre-screen batch 2 (2026-10-28). No engine code is changed; each subcommand answers one kill-rule question.
//   strim benchprescreen2 agree <model> <ids-file> <outdir> [refdir]
//       P1: 8 real-text prompts x (2048-token prefill in 1024-token chunks + 64 greedy decode steps). Writes the
//       greedy ids and the per-step logits (p<i>.safetensors) into outdir. With refdir (from another build) it
//       teacher-forces the ref ids and prints max |logit diff|, top-1 agreement per step, and free-run id match.
//   strim benchprescreen2 gdncap <model> <ids-file> <chunk=1024>
//       P2 helper: prefill the first 4096 ids so a snapshot build carrying the STRIM_GDN_CAPDIR hook in GDN.swift
//       writes the recurrence inputs (q,k,v,g,beta,ssm,z) of selected layers/chunks. Not usable on HEAD alone.
//   strim benchprescreen2 gdnchunk <model> <capdir> [layers=24] [reps=8]
//       P2: chunkwise (WY/UT) gated-delta recurrence in plain MLX ops (C=64) vs GDNMetal.runBlocked on captured
//       real inputs: relative error of y / final state / layer output, and chained-serial ms per layer.

func runPrescreen2(_ args: [String]) {
    guard args.count >= 3 else { print("usage: strim benchprescreen2 agree|gdncap|gdnchunk ..."); return }
    do {
        switch args[2] {
        case "agree": try p2Agree(args)
        case "gdncap": try p2Cap(args)
        case "gdnchunk": try p2Chunk(args)
        default: print("unknown subcommand \(args[2])")
        }
    } catch {
        FileHandle.standardError.write(Data("benchprescreen2 failed: \(error)\n".utf8)); exit(1)
    }
}

private func readIds(_ path: String) throws -> [Int32] {
    let s = try String(contentsOfFile: path, encoding: .utf8)
    return s.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " }).compactMap { Int32($0) }
}

// MARK: P1 agreement

private func p2Agree(_ args: [String]) throws {
    guard args.count >= 6 else { print("usage: strim benchprescreen2 agree <model> <ids> <outdir> [refdir]"); return }
    let store = try WeightStore(dir: URL(fileURLWithPath: args[3]))
    let ids = try readIds(args[4])
    let out = URL(fileURLWithPath: args[5]), ref = args.count >= 7 ? URL(fileURLWithPath: args[6]) : nil
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let nP = 8, plen = 2048, steps = 64, chunk = 1024
    guard ids.count >= nP * 1000 + plen else { print("need >= \(nP * 1000 + plen) ids, have \(ids.count)"); return }
    _ = try QwenModel.forwardAll(tokens: [9707], store: store, cache: ModelCache())
    var maxDiffAll: Float = 0, agreeTF = 0, totalTF = 0, freeMatch = 0, freeTotal = 0, firstDivs: [Int] = []
    for p in 0 ..< nP {
        let prompt = Array(ids[(p * 1000) ..< (p * 1000 + plen)])
        var forced: [Int32]? = nil
        var refLogits: MLXArray? = nil
        if let ref {
            let a = try loadArrays(url: ref.appendingPathComponent("p\(p).safetensors"))
            forced = a["ids"]!.asArray(Int32.self)
            refLogits = a["logits"]!
        }
        let cache = ModelCache()
        var start = 0
        var last = MLXArray(0)
        while start < plen {
            let end = min(start + chunk, plen)
            let o = try QwenModel.forwardAll(tokens: Array(prompt[start ..< end]), store: store, cache: cache, lastTokenOnly: true)
            eval(o.logits); last = o.logits; start = end
        }
        var logitsList: [MLXArray] = [last.reshaped([-1])]
        var gen: [Int32] = []
        var cur = argMax(logitsList[0], axis: -1).item(Int32.self)
        gen.append(cur)
        for s in 0 ..< steps - 1 {
            let feed = forced?[s] ?? cur
            let o = try QwenModel.forwardAll(tokens: [feed], store: store, cache: cache, lastTokenOnly: true)
            let l = o.logits.reshaped([-1]); eval(l)
            logitsList.append(l)
            cur = argMax(l, axis: -1).item(Int32.self)
            gen.append(cur)
        }
        let L = stacked(logitsList, axis: 0)       // [steps, V], model dtype
        eval(L)
        try save(arrays: ["ids": MLXArray(gen), "logits": L], url: out.appendingPathComponent("p\(p).safetensors"))
        if let refLogits, let forced {
            let d = abs(L.asType(.float32) - refLogits.asType(.float32)).max().item(Float.self)
            let a1 = argMax(L, axis: -1).asArray(Int32.self), a2 = argMax(refLogits, axis: -1).asArray(Int32.self)
            let ag = zip(a1, a2).filter { $0 == $1 }.count
            let fm = zip(gen, forced).filter { $0 == $1 }.count
            var div = gen.count
            for i in 0 ..< gen.count where gen[i] != forced[i] { div = i; break }
            maxDiffAll = max(maxDiffAll, d); agreeTF += ag; totalTF += a1.count; freeMatch += fm; freeTotal += gen.count
            firstDivs.append(div)
            print(String(format: "prompt %d: max|dlogit| %.4f  teacher-forced top1 %d/%d  free-run ids %d/%d (first div %d)",
                         p, d, ag, a1.count, fm, gen.count, div))
        } else {
            print("prompt \(p): ids \(gen.prefix(12))...")
        }
    }
    if ref != nil {
        print(String(format: "SUMMARY max|dlogit| %.4f  teacher-forced top1 %d/%d  free-run ids %d/%d  first-div %@",
                     maxDiffAll, agreeTF, totalTF, freeMatch, freeTotal, firstDivs.description))
    }
}

// MARK: P2 capture helper

private func p2Cap(_ args: [String]) throws {
    guard args.count >= 5 else { print("usage: strim benchprescreen2 gdncap <model> <ids> [chunk]"); return }
    let store = try WeightStore(dir: URL(fileURLWithPath: args[3]))
    let ids = try readIds(args[4])
    let chunk = args.count >= 6 ? Int(args[5]) ?? 1024 : 1024
    let n = 4096
    guard ids.count >= n else { print("need \(n) ids"); return }
    let cache = ModelCache()
    var start = 0
    while start < n {
        let end = min(start + chunk, n)
        let o = try QwenModel.forwardAll(tokens: Array(ids[start ..< end]), store: store, cache: cache, lastTokenOnly: true)
        eval(o.logits); start = end
    }
    print("captured via STRIM_GDN_CAPDIR=\(ProcessInfo.processInfo.environment["STRIM_GDN_CAPDIR"] ?? "(unset)")")
}

// MARK: P2 chunkwise GDN in plain MLX ops

private enum Chunked {
    static let Hv = 48, Hk = 16, D = 128
    nonisolated(unsafe) static let rep: MLXArray = {
        var idx: [Int32] = []
        for h in 0 ..< Hk { for _ in 0 ..< (Hv / Hk) { idx.append(Int32(h)) } }
        return MLXArray(idx)
    }()

    /// One gated-delta chunk step over the carried state. s: [H,Dv,Dk] f32.
    /// u,w: [H,C,*], qg: [H,C,Dk], aq: [H,C,C], kd: [H,C,Dk], gl: [H,1,1] (chunk-end decay).
    static func step(_ s: MLXArray, _ u: MLXArray, _ w: MLXArray, _ qg: MLXArray, _ aq: MLXArray,
                     _ kd: MLXArray, _ gl: MLXArray) -> (MLXArray, MLXArray) {
        let st = s.transposed(0, 2, 1)                        // [H,Dk,Dv]
        let C = w.shape[1]
        let both = matmul(concatenated([w, qg], axis: 1), st) // [H,2C,Dv]
        let d = u - both[0..., 0 ..< C, 0...]
        let y = both[0..., C..., 0...] + matmul(aq, d)
        let sNew = s * gl + matmul(d.transposed(0, 2, 1), kd)
        return (y, sNew)
    }
    nonisolated(unsafe) static let stepC: ([MLXArray]) -> [MLXArray] = compile { a in
        let r = step(a[0], a[1], a[2], a[3], a[4], a[5], a[6]); return [r.0, r.1]
    }

    /// q,k: [1,S,Hk,D] bf16; v [1,S,Hv,D] bf16; g,beta [1,S,Hv]; ssm [1,Hv,Dv,Dk] f32. Returns y bf16 [1,S,Hv,D], ssm.
    static func run(q: MLXArray, k: MLXArray, v: MLXArray, g: MLXArray, beta: MLXArray, ssm: MLXArray,
                    C: Int = 64, compiled: Bool = false, bf16mm: Bool = false, preOnly: Bool = false) -> (MLXArray, MLXArray) {
        let S = q.shape[1], nC = S / C
        func heads(_ x: MLXArray, _ rep: Bool) -> MLXArray {            // -> [Hv, nC, C, D] f32
            var t = x
            if rep { t = t.take(Chunked.rep, axis: 2) }
            return t.asType(.float32).transposed(0, 2, 1, 3).reshaped([Hv, nC, C, D])
        }
        let qh = heads(q, true), kh = heads(k, true), vh = heads(v, false)
        let bh = beta.asType(.float32).transposed(0, 2, 1).reshaped([Hv, nC, C, 1])
        let lg = log(g.asType(.float32)).transposed(0, 2, 1).reshaped([Hv, nC, C])
        let gc = cumsum(lg, axis: -1)                                    // [Hv,nC,C]
        let diff = gc.expandedDimensions(axis: -1) - gc.expandedDimensions(axis: -2)  // [.,C,C] i,j
        let low = tril(MLXArray.ones([C, C], dtype: .bool))
        let dec = exp(MLX.where(low, diff, MLXArray(Float(-1e30))))      // lower incl diag
        let kb = kh * bh, vb = vh * bh
        let mmIn: (MLXArray) -> MLXArray = { bf16mm ? $0.asType(.bfloat16) : $0 }
        let kt = kh.transposed(0, 1, 3, 2)
        let kk = matmul(mmIn(kb), mmIn(kt)).asType(.float32)             // [Hv,nC,C,C]
        let Lm = tril(kk * dec, k: -1)
        // T = (I + Lm)^-1 by Neumann doubling: (I+N)(I+N^2)...(I+N^32), N = -Lm
        let eye = MLXArray.eye(C)
        var N = -Lm
        var T = eye + N
        var P = N
        for _ in 0 ..< (Int(log2(Double(C))) - 1) {
            P = matmul(P, P)
            T = matmul(T, eye + P)
        }
        if ProcessInfo.processInfo.environment["PS2_DEBUG"] != nil {
            func fin(_ n: String, _ x: MLXArray) { print("DBG \(n) nan=\(isNaN(x).any().item(Bool.self)) max=\(abs(x).max().item(Float.self))") }
            fin("gc", gc); fin("dec", dec); fin("kk", kk); fin("Lm", Lm); fin("T", T); fin("vb", vb)
        }
        let gam = exp(gc).expandedDimensions(axis: -1)                   // [Hv,nC,C,1]
        let u = matmul(T, vb)                                            // [Hv,nC,C,Dv]
        let w = matmul(T, kb * gam)                                      // [Hv,nC,C,Dk]
        let qg = qh * gam
        let aq = matmul(mmIn(qh), mmIn(kt)).asType(.float32) * dec       // lower incl diag
        let glast = gc[0..., 0..., (C - 1)...]                           // [Hv,nC,1]
        let kd = kh * exp(glast.expandedDimensions(axis: -1) - gc.expandedDimensions(axis: -1))
        let gl = exp(glast).expandedDimensions(axis: -1)                 // [Hv,nC,1,1]
        if preOnly {
            let t = (u + w + qg + kd + aq.sum()).reshaped([Hv, S, D]).transposed(1, 0, 2).reshaped([1, S, Hv, D]).asType(.bfloat16)
            return (t, ssm)
        }
        var s = ssm.reshaped([Hv, D, D])
        var ys: [MLXArray] = []
        for n in 0 ..< nC {
            let a: [MLXArray] = [s, u[0..., n], w[0..., n], qg[0..., n], aq[0..., n], kd[0..., n], gl[0..., n]]
            if compiled { let r = stepC(a); ys.append(r[0]); s = r[1] }
            else { let r = step(a[0], a[1], a[2], a[3], a[4], a[5], a[6]); ys.append(r.0); s = r.1 }
        }
        if ProcessInfo.processInfo.environment["PS2_DEBUG"] != nil {
            func fin(_ n: String, _ x: MLXArray) { print("DBG2 \(n) nan=\(isNaN(x).any().item(Bool.self)) max=\(abs(x).max().item(Float.self))") }
            fin("u", u); fin("w", w); fin("qg", qg); fin("aq", aq); fin("kd", kd); fin("gl", gl); fin("s", s); fin("y0", ys[0])
        }
        let y = stacked(ys, axis: 1)                                     // [Hv,nC,C,Dv]
        let yo = y.reshaped([Hv, S, D]).transposed(1, 0, 2).reshaped([1, S, Hv, D]).asType(.bfloat16)
        return (yo, s.reshaped([1, Hv, D, D]))
    }
}

private func relErr(_ a: MLXArray, _ b: MLXArray) -> (rel: Float, maxAbs: Float, neq: Float) {
    let x = a.asType(.float32), y = b.asType(.float32)
    let d = x - y
    let rel = (sqrt((d * d).sum()) / sqrt((y * y).sum())).item(Float.self)
    let mx = abs(d).max().item(Float.self)
    let neq = (x .!= y).asType(.float32).mean().item(Float.self)
    return (rel, mx, neq)
}

private func p2Chunk(_ args: [String]) throws {
    guard args.count >= 5 else { print("usage: strim benchprescreen2 gdnchunk <model> <capdir> [layers] [reps]"); return }
    let store = try WeightStore(dir: URL(fileURLWithPath: args[3]))
    let dir = URL(fileURLWithPath: args[4])
    let nLayers = args.count >= 6 ? Int(args[5]) ?? 24 : 24
    let reps = args.count >= 7 ? Int(args[6]) ?? 8 : 8
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".safetensors") }.sorted()
    guard !files.isEmpty else { print("no captures in \(dir.path)"); return }
    struct Cap { var name: String; var a: [String: MLXArray]; var layer: Int }
    var caps: [Cap] = []
    for f in files {
        let a = try loadArrays(url: dir.appendingPathComponent(f))
        let layer = Int(f.split(separator: "_")[0].dropFirst(1)) ?? 0   // L<layer>_c<chunk>.safetensors
        caps.append(Cap(name: f, a: a, layer: layer))
    }
    eval(caps.flatMap { Array($0.a.values) })
    print("captures: \(caps.map { $0.name }.joined(separator: " "))  S=\(caps[0].a["q"]!.shape[1])")

    // accuracy
    for variant in [("f32", false), ("bf16mm", true)] {
        for c in caps {
            let a = c.a
            let ref = GDNMetal.runBlocked(q: a["q"]!, k: a["k"]!, v: a["v"]!, g: a["g"]!, beta: a["beta"]!, ssm: a["ssm"]!)
            let new = Chunked.run(q: a["q"]!, k: a["k"]!, v: a["v"]!, g: a["g"]!, beta: a["beta"]!, ssm: a["ssm"]!, C: Int(ProcessInfo.processInfo.environment["PS2_C"] ?? "64")!, bf16mm: variant.1)
            eval(ref.y, ref.ssm, new.0, new.1)
            let ey = relErr(new.0, ref.y), es = relErr(new.1, ref.ssm)
            // layer output: norm * silu(z) -> out_proj
            let p = "language_model.model.layers.\(c.layer).linear_attn."
            let nw = try store.tensor(p + "norm.weight")
            let ow = try store.tensor(p + "out_proj.weight"), os = try store.tensor(p + "out_proj.scales"), ob = try store.tensor(p + "out_proj.biases")
            let spec = try store.quantSpec(p + "out_proj", w: ow, s: os)
            let z = a["z"]!
            func layerOut(_ y: MLXArray) -> MLXArray {
                let normed = MLXFast.rmsNorm(y, weight: nw, eps: 1e-6)
                let gated = (z * sigmoid(z)) * normed
                return store.qmm(gated.reshaped([1, y.shape[1], 6144]), ow, os, ob, spec: spec)
            }
            let o1 = layerOut(ref.y), o2 = layerOut(new.0); eval(o1, o2)
            let eo = relErr(o2, o1)
            print(String(format: "ACC %-7@ %-14@ y rel %.2e max %.3e neq %.3f | state rel %.2e | layer-out rel %.2e max %.3e",
                         variant.0 as NSString, c.name as NSString, ey.rel, ey.maxAbs, ey.neq, es.rel, eo.rel, eo.maxAbs))
        }
    }
    // floor: bf16 rounding of the kernel's own f32-equivalent is ~2^-9 relative per element; shown for scale
    print("(bf16 output rounding floor: rel ~ 1.1e-3)")

    // timing, chained-serial: layer i+1's v depends on layer i's y (zero-weighted scalar) so nothing overlaps
    let zero = MLXArray.zeros([1, 1, 1, 1], dtype: .bfloat16)
    eval(zero)
    func chain(_ mode: Int) -> MLXArray {
        var dep = zero
        var last = zero
        for i in 0 ..< nLayers {
            let a = caps[i % caps.count].a
            let v = a["v"]! + dep
            switch mode {
            case 0:
                let r = GDNMetal.runBlocked(q: a["q"]!, k: a["k"]!, v: v, g: a["g"]!, beta: a["beta"]!, ssm: a["ssm"]!)
                dep = r.y[0..., 0 ..< 1, 0 ..< 1, 0 ..< 1] * zero; last = r.y
            default:
                let r = Chunked.run(q: a["q"]!, k: a["k"]!, v: v, g: a["g"]!, beta: a["beta"]!, ssm: a["ssm"]!,
                                    C: mode == 5 ? 8 : 64, compiled: mode == 2, bf16mm: mode == 3, preOnly: mode == 4)
                dep = r.0[0..., 0 ..< 1, 0 ..< 1, 0 ..< 1] * zero; last = r.0
            }
        }
        return last
    }
    let names = ["kernel (shipped)", "chunk64 f32 plain", "chunk64 f32 compiled-step", "chunk64 bf16-mm plain", "chunk64 intra-chunk part only (no state loop)", "chunk8 f32 plain (only C that is accurate)"]
    var best = [Double](repeating: .infinity, count: names.count)
    for m in 0 ..< names.count { eval(chain(m)) }
    for _ in 0 ..< reps {
        for m in 0 ..< names.count {
            let t0 = Date(); eval(chain(m))
            best[m] = min(best[m], Date().timeIntervalSince(t0) * 1000)
        }
    }
    let S = caps[0].a["q"]!.shape[1]
    print("TIMING S=\(S) chained-serial layers=\(nLayers) reps=\(reps) (min)")
    for m in 0 ..< names.count {
        print(String(format: "  %-28@ %.3f ms/layer", names[m] as NSString, best[m] / Double(nLayers)))
    }
}
