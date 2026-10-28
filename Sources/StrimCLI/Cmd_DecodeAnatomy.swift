import Foundation
import MLX
import MLXFast
import StrimCore

// `strim benchdecodeanatomy <model> <mtp-head> [n=5]`: where does a decode pass go?
//
// Top-down: the real engine code (QwenModel.forwardAll / BatchModel.forward / DecoderLayer) on a
// synthetic cache of ctx tokens, split into graph-build (host) and eval (host blocked on GPU) time,
// by layer type (GDN layers incl. their MLP, attention layers incl. their MLP, tail, embed).
// Bottom-up: serial chains over all layers with real weights (nothing cache resident) pricing each
// component as the difference between a chain with and without it (same link op in both), plus an
// empty-kernel chain for the per-kernel fixed cost and a commit-boundary chain.
// Env: DA_CTX=4096,16384  DA_CFG=m1,m3,m5,b4,b8  DA_PARTS=cal,dot,top,proj,glue,head,sdpa,pipe
// No engine/kernel changes; everything here only calls public StrimCore API or replicates op sequences.

private func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

private struct DACfg {
    let key: String
    let B: Int
    let S: Int
    let rec: Bool
    var rows: Int { B * S }
}

private let daAll: [String: DACfg] = [
    "m1": DACfg(key: "M1", B: 1, S: 1, rec: false),
    "m3": DACfg(key: "M3rec", B: 1, S: 3, rec: true),
    "m5": DACfg(key: "M5rec", B: 1, S: 5, rec: true),
    "b4": DACfg(key: "B4", B: 4, S: 1, rec: false),
    "b8": DACfg(key: "B8", B: 8, S: 1, rec: false),
]

private func isGDN(_ l: Int) -> Bool { (l + 1) % 4 != 0 }

/// min over `n` runs of eval(build()) in ms; the graph is built outside the timer.
private func minEval(_ n: Int, _ build: () -> [MLXArray]) -> Double {
    var best = Double.infinity
    for i in 0 ... n {
        let outs = build()
        let t0 = nowMs(); eval(outs); let t = nowMs() - t0
        if i > 0 { best = min(best, t) }
    }
    return best
}

private func rnd(_ shape: [Int], _ scale: Float = 0.5, _ dt: DType = .bfloat16) -> MLXArray {
    (MLXRandom.normal(shape) * scale).asType(dt)
}

private func makeModelCache(ctx: Int) -> ModelCache {
    let c = ModelCache()
    for l in 0 ..< 64 {
        if isGDN(l) {
            let s = c.gdnState(l)
            s.conv = rnd([1, 3, 10240], 0.5)
            s.ssm = rnd([1, 48, 128, 128], 0.02, .float32)
            eval(s.conv!, s.ssm!)
        } else {
            let a = c.attentionCache(l)
            let k = rnd([1, 4, ctx, 256], 0.5), v = rnd([1, 4, ctx, 256], 0.5)
            eval(k, v)
            a.keys = k; a.values = v
        }
    }
    c.position = ctx
    return c
}

func runDecodeAnatomy(_ args: [String]) {
    guard args.count >= 4 else { print("usage: strim benchdecodeanatomy <model> <mtp-head> [n]"); return }
    setvbuf(stdout, nil, _IOLBF, 0)
    let n = args.count >= 5 ? Int(args[4]) ?? 5 : 5
    let env = ProcessInfo.processInfo.environment
    let ctxs = (env["DA_CTX"] ?? "4096,16384").split(separator: ",").map { Int($0)! }
    let cfgs = (env["DA_CFG"] ?? "m1,m3,m5,b4,b8").split(separator: ",").compactMap { daAll[String($0)] }
    let parts = Set((env["DA_PARTS"] ?? "cal,dot,top,proj,glue,head,sdpa,pipe").split(separator: ",").map(String.init))
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let head = try WeightStore(dir: URL(fileURLWithPath: args[3]))
        head.useIntegratedMTPPrefixIfNeeded()
        let L = "language_model.model.layers."
        // materialise all weights + fused MLP exactly as the engine does on first use
        for l in 0 ..< 64 { _ = try store.mlpFused(l) }
        _ = try store.tensor("language_model.lm_head.weight")
        eval(try store.tensor("language_model.lm_head.weight"))

        var cAdd = 0.005  // ms per dependent tiny kernel; set by calibration
        // ---------------------------------------------------------------- calibration
        if parts.contains("cal") {
            let x0 = rnd([1, 1, 5120]), c = rnd([1, 1, 5120], 0.001)
            eval(x0, c)
            var prev: (Int, Double)? = nil
            for N in [256, 1024, 4096] {
                let t = minEval(n) { var y = x0; for _ in 0 ..< N { y = y + c }; return [y] }
                print(String(format: "CAL addchain_dep N=%d total=%.3f ms per_op=%.2f us", N, t, t / Double(N) * 1000))
                if let p = prev { cAdd = (t - p.1) / Double(N - p.0); print(String(format: "CAL add_dep_slope %.2f us/kernel", cAdd * 1000)) }
                prev = (N, t)
            }
            for N in [256, 1024] {
                let t = minEval(n) { (0 ..< N).map { _ in x0 + c } }
                print(String(format: "CAL addchain_indep N=%d total=%.3f ms per_op=%.2f us", N, t, t / Double(N) * 1000))
            }
            let w = try store.tensor(L + "0.input_layernorm.weight")
            for N in [256, 1024] {
                let t = minEval(n) { var y = x0; for _ in 0 ..< N { y = MLXFast.rmsNorm(y, weight: w, eps: 1e-6) }; return [y] }
                print(String(format: "CAL rmsnorm_dep N=%d total=%.3f ms per_op=%.2f us", N, t, t / Double(N) * 1000))
            }
            // sync round trip: one tiny op per eval
            var rt = Double.infinity
            for _ in 0 ..< 50 { let y = x0 + c; let t0 = nowMs(); eval(y); rt = min(rt, nowMs() - t0) }
            print(String(format: "CAL roundtrip_one_tiny_eval %.3f ms", rt))
            // commit boundary: 2048 dependent adds, split into chunks that are evaluated one after another
            let N = 2048
            let single = minEval(n) { var y = x0; for _ in 0 ..< N { y = y + c }; return [y] }
            print(String(format: "CAL chunk single N=%d %.3f ms", N, single))
            for k in [512, 128, 32, 8] {
                var bestSync = Double.infinity, bestAsync = Double.infinity
                for i in 0 ... n {
                    var ends: [MLXArray] = []
                    var y = x0
                    for j in 0 ..< N { y = y + c; if (j + 1) % k == 0 { ends.append(y) } }
                    let t0 = nowMs(); for e in ends { eval(e) }; let t = nowMs() - t0
                    if i > 0 { bestSync = min(bestSync, t) }
                    var ends2: [MLXArray] = []
                    var y2 = x0
                    for j in 0 ..< N { y2 = y2 + c; if (j + 1) % k == 0 { ends2.append(y2) } }
                    let t1 = nowMs(); for e in ends2.dropLast() { asyncEval(e) }; eval(ends2.last!); let ta = nowMs() - t1
                    if i > 0 { bestAsync = min(bestAsync, ta) }
                }
                let nb = Double(N / k - 1)
                print(String(format: "CAL chunk k=%d boundaries=%d eval_each=%.3f ms (+%.1f us/boundary) asyncEval_each=%.3f ms (+%.1f us/boundary)",
                             k, N / k - 1, bestSync, (bestSync - single) / nb * 1000, bestAsync, (bestAsync - single) / nb * 1000))
            }
        }
        // ---------------------------------------------------------------- graph node census
        if parts.contains("dot") {
            let cache = makeModelCache(ctx: 1024)
            for cfg in [daAll["m1"]!, daAll["m3"]!] {
                if cfg.rec { cache.beginVerify() }
                let toks = (0 ..< cfg.S).map { Int32(1000 + $0) }
                let r = try QwenModel.forwardAll(tokens: toks, store: store, cache: cache)
                let am = argMax(r.logits, axis: -1)
                let dot = exportToDot([am])
                if cfg.rec { cache.endVerify() }
                var counts: [String: Int] = [:]
                var total = 0
                for line in dot.split(separator: "\n") {
                    guard let r = line.range(of: "label") else { continue }
                    let rest = line[r.upperBound...]
                    let parts = rest.split(separator: "\"", omittingEmptySubsequences: false)
                    guard parts.count >= 2 else { continue }
                    let name = String(parts[1])
                    if name.isEmpty || name.hasPrefix("array") || name.hasPrefix("A") && name.count < 5 { continue }
                    counts[name, default: 0] += 1; total += 1
                }
                print("DOT cfg=\(cfg.key) labeled_nodes=\(total)")
                for (k, v) in counts.sorted(by: { $0.value > $1.value }).prefix(40) { print("DOT cfg=\(cfg.key) \(k) \(v)") }
                if env["DA_DOTDEBUG"] != nil { print(dot.split(separator: "\n").prefix(30).joined(separator: "\n")) }
                eval(am)
            }
        }

        let rowsList = Array(Set(cfgs.map { $0.rows })).sorted()
        // ---------------------------------------------------------------- projection chain
        struct Q { var w: MLXArray; var s: MLXArray; var b: MLXArray }
        func q(_ name: String, _ st: WeightStore = store) throws -> Q {
            Q(w: try st.tensor(name + ".weight"), s: try st.tensor(name + ".scales"), b: try st.tensor(name + ".biases"))
        }
        func mm1(_ x: MLXArray, _ w: Q) -> MLXArray {
            quantizedMatmul(x, w.w, scales: w.s, biases: w.b, transpose: true, groupSize: 64, bits: 4)
        }
        struct Lay { var gdn: Bool; var a: [Q]; var ba: [Q]; var gu: Q; var down: Q }
        var lays: [Lay] = []
        for l in 0 ..< 64 {
            let g = isGDN(l)
            let a: [Q] = g
                ? [try q(L + "\(l).linear_attn.in_proj_qkv"), try q(L + "\(l).linear_attn.in_proj_z"), try q(L + "\(l).linear_attn.out_proj")]
                : [try q(L + "\(l).self_attn.q_proj"), try q(L + "\(l).self_attn.k_proj"), try q(L + "\(l).self_attn.v_proj"), try q(L + "\(l).self_attn.o_proj")]
            let ba: [Q] = g ? [try q(L + "\(l).linear_attn.in_proj_b"), try q(L + "\(l).linear_attn.in_proj_a")] : []
            let f = try store.mlpFused(l)
            lays.append(Lay(gdn: g, a: a, ba: ba, gu: Q(w: f.w, s: f.s, b: f.b), down: try q(L + "\(l).mlp.down_proj")))
        }
        let nmm = 48 * 5 + 16 * 4 + 64 * 2
        var projPure: [Int: Double] = [:]
        if parts.contains("proj") || parts.contains("glue") {
            for M in rowsList {
                let x = (MLXRandom.normal([1, M, 5120]) * 0.1).asType(.bfloat16); eval(x)
                var yc: [Int: MLXArray] = [:]
                for N in [10240, 6144, 5120, 12288, 1024, 48, 34816] { yc[N] = MLXArray.zeros([1, M, N], dtype: .bfloat16) }
                eval(Array(yc.values))
                func chain(fake: Bool) -> [MLXArray] {
                    func mm(_ h: MLXArray, _ w: Q) -> MLXArray {
                        fake ? yc[w.w.shape[0]]! + h[0..., 0..., 0 ..< 1] : mm1(h, w)
                    }
                    var h = x
                    var keep: [MLXArray] = []
                    for ly in lays {
                        if ly.gdn {
                            let qkv = mm(h, ly.a[0]), z = mm(h, ly.a[1])
                            keep.append(mm(h, ly.ba[0])); keep.append(mm(h, ly.ba[1]))
                            let t = qkv[0..., 0..., 0 ..< 6144] * z * 0.05
                            h = h + mm(t, ly.a[2]) * 0.05
                        } else {
                            let qq = mm(h, ly.a[0]), k = mm(h, ly.a[1]), v = mm(h, ly.a[2])
                            let t = qq[0..., 0..., 0 ..< 6144] * 0.05 + concatenated([k, v, k, v, k, v], axis: 2)[0..., 0..., 0 ..< 6144] * 0.05
                            h = h + mm(t, ly.a[3]) * 0.05
                        }
                        let gu = mm(h, ly.gu)
                        let act = gu[0..., 0..., 0 ..< 17408] * gu[0..., 0..., 17408 ..< 34816] * 0.05
                        h = h + mm(act, ly.down) * 0.05
                    }
                    return keep + [h]
                }
                let real = minEval(n) { chain(fake: false) }
                let fake = minEval(n) { chain(fake: true) }
                projPure[M] = real - fake + Double(nmm) * cAdd
                print(String(format: "PROJ M=%d chain_real=%.2f ms chain_fake(same glue, matmul->add)=%.2f ms pure_projection=%.2f ms (nmm=%d, cAdd=%.1f us)",
                             M, real, fake, projPure[M]!, nmm, cAdd * 1000))
            }
        }

        // bytes model for the roofline: every tensor touched by the 64 layers + lm_head
        var weightBytes = 0
        for l in 0 ..< 64 {
            let ly = lays[l]
            for w in ly.a + ly.ba + [ly.gu, ly.down] { weightBytes += w.w.nbytes + w.s.nbytes + w.b.nbytes }
        }
        let lmw = try q("language_model.lm_head")
        let lmBytes = lmw.w.nbytes + lmw.s.nbytes + lmw.b.nbytes
        print(String(format: "BYTES layer_weights=%.3f GB lm_head=%.3f GB total=%.3f GB -> roofline@530GB/s %.2f ms",
                     Double(weightBytes) / 1e9, Double(lmBytes) / 1e9, Double(weightBytes + lmBytes) / 1e9,
                     Double(weightBytes + lmBytes) / 530e9 * 1000))

        // ---------------------------------------------------------------- per (ctx, cfg)
        for ctx in ctxs {
            for cfg in cfgs {
                let B = cfg.B, S = cfg.S
                let tag = "ctx=\(ctx) cfg=\(cfg.key)"
                var topFull = Double.nan
                // ------------------------------------------------------------ top-down
                if parts.contains("top") {
                    var runner: ((String) throws -> (Double, Double))! = nil
                    var keepAlive: [Any] = []
                    let h0 = rnd([B, S, 5120]); eval(h0)
                    let toks = (0 ..< S).map { Int32(1000 + $0) }
                    if B == 1 {
                        let cache = makeModelCache(ctx: ctx)
                        keepAlive.append(cache)
                        runner = { kind in
                            if cfg.rec { cache.beginVerify() }
                            let t0 = nowMs()
                            let res: MLXArray
                            switch kind {
                            case "full": res = argMax(try QwenModel.forwardAll(tokens: toks, store: store, cache: cache).logits, axis: -1)
                            case "gdn", "attn":
                                var h = h0
                                for l in 0 ..< 64 where isGDN(l) == (kind == "gdn") { h = try DecoderLayer.forward(h, store: store, layer: l, cache: cache) }
                                res = h
                            case "tail": res = argMax(try store.linear("language_model.lm_head", try store.rmsNorm("language_model.model.norm", h0)), axis: -1)
                            default: res = try store.embedding("language_model.model.embed_tokens", tokens: toks)
                            }
                            let tb = nowMs() - t0
                            let t1 = nowMs(); eval(res); let te = nowMs() - t1
                            if cfg.rec { cache.endVerify() }
                            return (tb, te)
                        }
                    } else {
                        let caches = (0 ..< B).map { _ in makeModelCache(ctx: ctx) }
                        let bc = BatchModel.from(caches)
                        keepAlive.append(bc)
                        let tk = (0 ..< B).map { [Int32(1000 + $0)] }
                        runner = { kind in
                            let t0 = nowMs()
                            let res: MLXArray
                            switch kind {
                            case "full": res = argMax(try BatchModel.forward(tokens: tk, store: store, cache: bc), axis: -1)
                            case "gdn", "attn":
                                var h = h0
                                for l in 0 ..< 64 where isGDN(l) == (kind == "gdn") { h = try DecoderLayer.forwardBatched(h, store: store, layer: l, cache: bc) }
                                res = h
                            case "tail": res = argMax(try store.linear("language_model.lm_head", try store.rmsNorm("language_model.model.norm", h0)), axis: -1)
                            default: res = try store.embedding("language_model.model.embed_tokens", indices: MLXArray(tk.map { $0[0] }).reshaped([B, 1]))
                            }
                            let tb = nowMs() - t0
                            let t1 = nowMs(); eval(res); let te = nowMs() - t1
                            return (tb, te)
                        }
                    }
                    for kind in ["full", "gdn", "attn", "tail", "embed"] {
                        _ = try runner(kind); _ = try runner(kind)
                        var bb = Double.infinity, be = Double.infinity, bt = Double.infinity
                        var evs: [Double] = [], tts: [Double] = []
                        for _ in 0 ..< n + 4 {
                            let (b, e) = try runner(kind)
                            bb = min(bb, b); be = min(be, e); bt = min(bt, b + e)
                            evs.append(e); tts.append(b + e)
                        }
                        if kind == "full" { topFull = be }
                        print(String(format: "TOP %@ kind=%@ build=%.2f eval=%.2f total_min=%.2f ms | median eval=%.2f total=%.2f", tag as NSString, kind as NSString, bb, be, bt, evs.sorted()[evs.count / 2], tts.sorted()[tts.count / 2]))
                    }
                    keepAlive.removeAll(); runner = nil
                    Memory.clearCache()
                }
                // ------------------------------------------------------------ bottom-up glue chains
                if parts.contains("glue") {
                    let rows = cfg.rows
                    // ---- norms and residual adds (natural chains)
                    let hN = rnd([B, S, 5120]); eval(hN)
                    var normWs: [MLXArray] = []
                    for l in 0 ..< 64 { normWs.append(try store.tensor(L + "\(l).input_layernorm.weight")); normWs.append(try store.tensor(L + "\(l).post_attention_layernorm.weight")) }
                    normWs.append(try store.tensor("language_model.model.norm.weight"))
                    let tNorm = minEval(n) { var h = hN; for w in normWs { h = MLXFast.rmsNorm(h, weight: w, eps: 1e-6) }; return [h] }
                    let ms_ = (0 ..< 8).map { _ in rnd([B, S, 5120], 0.01) }; eval(ms_)
                    let tRes = minEval(n) { var h = hN; for i in 0 ..< 128 { h = h + ms_[i % 8] }; return [h] }
                    print(String(format: "GLUE %@ norms(129 rmsNorm, serial)=%.3f ms (%.1f us each)  resid_adds(128, serial)=%.3f ms (%.1f us each)",
                                 tag as NSString, tNorm, tNorm / 129 * 1000, tRes, tRes / 128 * 1000))
                    // ---- swiglu (64 per pass), link-only baseline subtracted
                    let alls = (0 ..< 8).map { _ in rnd([B, S, 34816], 0.5) }; eval(alls)
                    func swChain(_ on: Bool) -> [MLXArray] {
                        var link = MLXArray.zeros([B, S, 1], dtype: .bfloat16)
                        for i in 0 ..< 64 {
                            let all = alls[i % 8] + link
                            if on {
                                let act = Fused.swiglu(all[0..., 0..., 0 ..< 17408], all[0..., 0..., 17408 ..< 34816])
                                link = act[0..., 0..., 0 ..< 1]
                            } else { link = all[0..., 0..., 0 ..< 1] }
                        }
                        return [link]
                    }
                    let tSw = minEval(n) { swChain(true) } - minEval(n) { swChain(false) }
                    print(String(format: "GLUE %@ swiglu(64 per pass)=%.3f ms (%.1f us each)", tag as NSString, tSw, tSw / 64 * 1000))
                    // ---- GDN glue chain
                    do {
                        let J = 48
                        let qS = MLXArray.ones([128], dtype: .bfloat16) * (pow(Float(128), -0.5) * pow(Float(128), -0.5))
                        let kS = MLXArray.ones([128], dtype: .bfloat16) * pow(Float(128), -0.5)
                        var idx: [Int32] = []
                        for h in 0 ..< 16 { for _ in 0 ..< 3 { idx.append(Int32(h)) } }
                        let rep = MLXArray(idx)
                        var qkv0: [MLXArray] = [], zz: [MLXArray] = [], bb: [MLXArray] = [], aa: [MLXArray] = [], cs: [MLXArray] = [], ss: [MLXArray] = []
                        var cw: [MLXArray] = [], aL: [MLXArray] = [], dtb: [MLXArray] = [], nw: [MLXArray] = []
                        let gl = (0 ..< 64).filter(isGDN)
                        for l in gl {
                            let p = L + "\(l).linear_attn."
                            qkv0.append(rnd([B, S, 10240])); zz.append(rnd([B, S, 48, 128])); bb.append(rnd([B, S, 48])); aa.append(rnd([B, S, 48]))
                            cs.append(rnd([B, 3, 10240])); ss.append(rnd([B, 48, 128, 128], 0.02, .float32))
                            cw.append(try store.tensor(p + "conv1d.weight")); aL.append(try store.tensor(p + "A_log").asType(.float32))
                            dtb.append(try store.tensor(p + "dt_bias").asType(.float32)); nw.append(try store.tensor(p + "norm.weight"))
                        }
                        eval(qkv0 + zz + bb + aa + cs + ss + aL + dtb)
                        func gchain(_ stage: Int, rec: Bool) -> [MLXArray] {
                            var link = MLXArray.zeros([B, S, 1], dtype: .bfloat16)
                            var keep: [MLXArray] = []
                            for j in 0 ..< J {
                                let qkv = qkv0[j] + link
                                if stage < 0 { link = qkv[0..., 0..., 0 ..< 1]; continue }
                                let convIn = concatenated([cs[j], qkv], axis: 1)
                                let conv = B > 1 ? GDNMetal.convSiluBatch(convIn: convIn, weight: cw[j]) : GDNMetal.convSilu(convIn: convIn, weight: cw[j])
                                link = conv[0..., 0..., 0 ..< 1]
                                if stage >= 1 {
                                    let qRaw = conv[0..., 0..., 0 ..< 2048].reshaped([B, S, 16, 128])
                                    let kRaw = conv[0..., 0..., 2048 ..< 4096].reshaped([B, S, 16, 128])
                                    let qn = MLXFast.rmsNorm(qRaw, weight: qS, eps: 1e-6)
                                    let kn = MLXFast.rmsNorm(kRaw, weight: kS, eps: 1e-6)
                                    let (beta, g) = Fused.betaG(bb[j], aa[j], aLog: aL[j], dtBias: dtb[j])
                                    keep.append(kn); keep.append(beta); keep.append(g)
                                    link = qn[0..., 0..., 0 ..< 1, 0 ..< 1].reshaped([B, S, 1])
                                    if stage >= 2 {
                                        let qr = qn.take(rep, axis: 2), kr = kn.take(rep, axis: 2)
                                        let v = conv[0..., 0..., 4096 ..< 10240].reshaped([B, S, 48, 128])
                                        keep.append(kr); keep.append(v)
                                        link = qr[0..., 0..., 0 ..< 1, 0 ..< 1].reshaped([B, S, 1])
                                        if stage >= 3 {
                                            let y: MLXArray
                                            if B == 1 {
                                                let r = GDNMetal.run(q: qr, k: kr, v: v, g: g, beta: beta, ssm: ss[j], recordStack: rec)
                                                y = r.y; keep.append(r.ssm); if rec { keep.append(r.stack) }
                                            } else {
                                                let r = GDNMetal.runBatch(q: qr, k: kr, v: v, g: g, beta: beta, ssm: ss[j])
                                                y = r.y; keep.append(r.ssm)
                                            }
                                            link = y[0..., 0..., 0 ..< 1, 0 ..< 1].reshaped([B, S, 1])
                                            if stage >= 4 {
                                                let normed = MLXFast.rmsNorm(y, weight: nw[j], eps: 1e-6)
                                                let gated = Fused.gatedNorm(zz[j], normed)
                                                link = gated[0..., 0..., 0 ..< 1, 0 ..< 1].reshaped([B, S, 1])
                                            }
                                        }
                                    }
                                }
                            }
                            return keep + [link]
                        }
                        let rec = cfg.rec
                        let t0 = minEval(n) { gchain(-1, rec: rec) }
                        var prev = t0
                        var tot = 0.0
                        let names = ["concat+conv", "+qknorm+betaG", "+rep take(q,k)+v view", "+recurrence", "+rmsnorm+gate"]
                        var lastT = t0
                        for st in 0 ... 4 {
                            let t = minEval(n) { gchain(st, rec: rec) }
                            print(String(format: "GDNGLUE %@ stage%d %@ cum=%.3f delta=%.3f ms per_layer=%.1f us", tag as NSString, st, names[st] as NSString, t - t0, t - prev, (t - prev) / Double(J) * 1000))
                            prev = t; lastT = t
                        }
                        tot = lastT - t0
                        print(String(format: "GDNGLUE %@ total_48_layers=%.3f ms (link-only baseline %.3f ms)", tag as NSString, tot, t0))
                        gdnTotal = tot
                        if rec {
                            let tn = minEval(n) { gchain(4, rec: false) }
                            print(String(format: "GDNGLUE %@ recordStack cost = %.3f ms (total with rec=%.3f, without=%.3f)", tag as NSString, lastT - tn, lastT - t0, tn - t0))
                        }
                    }
                    // ---- attention glue chain (+ real KV caches)
                    do {
                        let J = 16
                        var caches: [BatchedAttentionCache] = []
                        var qP: [MLXArray] = [], kP: [MLXArray] = [], vP: [MLXArray] = [], qN: [MLXArray] = [], kN: [MLXArray] = []
                        for j in 0 ..< J {
                            let l = 4 * j + 3
                            let p = L + "\(l).self_attn."
                            let bc = BatchedAttentionCache(B: B)
                            for _ in 0 ..< B {
                                let a = AttentionCache()
                                let k = rnd([1, 4, ctx, 256]), v = rnd([1, 4, ctx, 256]); eval(k, v)
                                a.keys = k; a.values = v
                                bc.seqs.append(a)
                            }
                            caches.append(bc)
                            qP.append(rnd([B, S, 12288])); kP.append(rnd([B, S, 1024])); vP.append(rnd([B, S, 1024]))
                            qN.append(try store.tensor(p + "q_norm.weight")); kN.append(try store.tensor(p + "k_norm.weight"))
                        }
                        eval(qP + kP + vP)
                        let scale = pow(Float(256), -0.5)
                        let mask: MLXFast.ScaledDotProductAttentionMaskMode = S > 1 ? .causal : .none
                        func achain(_ stage: Int) -> [MLXArray] {
                            var link = MLXArray.zeros([B, 1, 1], dtype: .bfloat16)
                            var keep: [MLXArray] = []
                            for j in 0 ..< J {
                                let qProj = qP[j] + link
                                if stage < 0 { link = qProj[0..., 0 ..< 1, 0 ..< 1]; continue }
                                let halves = qProj.reshaped([B, S, 24, 2, 256]).split(parts: 2, axis: 3)
                                let queries0 = halves[0].squeezed(axis: 3)
                                let gate = halves[1].squeezed(axis: 3).reshaped([B, S, 6144])
                                let qn = MLXFast.rmsNorm(queries0, weight: qN[j], eps: 1e-6).transposed(0, 2, 1, 3)
                                let kn = MLXFast.rmsNorm(kP[j].reshaped([B, S, 4, 256]), weight: kN[j], eps: 1e-6).transposed(0, 2, 1, 3)
                                let vn = vP[j].reshaped([B, S, 4, 256]).transposed(0, 2, 1, 3)
                                keep.append(kn); keep.append(vn)
                                link = qn[0..., 0 ..< 1, 0 ..< 1, 0 ..< 1].reshaped([B, 1, 1])
                                if stage < 1 { continue }
                                var outs: [MLXArray] = []
                                var lastQ = qn
                                for b in 0 ..< B {
                                    let sc = caches[j].seqs[b]
                                    let off = sc.offset
                                    let qb = MLXFast.RoPE(B == 1 ? qn : qn[b ..< (b + 1), 0..., 0..., 0...], dimensions: 64, traditional: false, base: 10_000_000, scale: 1.0, offset: off)
                                    let kb = MLXFast.RoPE(B == 1 ? kn : kn[b ..< (b + 1), 0..., 0..., 0...], dimensions: 64, traditional: false, base: 10_000_000, scale: 1.0, offset: off)
                                    let vb = B == 1 ? vn : vn[b ..< (b + 1), 0..., 0..., 0...]
                                    lastQ = qb
                                    if stage < 2 { keep.append(kb); keep.append(vb); continue }
                                    let (kk, vv) = caches[j].append(b, kb, vb)
                                    if stage < 3 { keep.append(kk); keep.append(vv); continue }
                                    outs.append(MLXFast.scaledDotProductAttention(queries: qb, keys: kk, values: vv, scale: scale, mask: mask))
                                }
                                if stage < 3 { link = lastQ[0..., 0 ..< 1, 0 ..< 1, 0 ..< 1].reshaped([1, 1, 1]) ; continue }
                                let out = B == 1 ? outs[0] : concatenated(outs, axis: 0)
                                link = out[0..., 0 ..< 1, 0 ..< 1, 0 ..< 1].reshaped([B, 1, 1])
                                if stage >= 4 {
                                    let flat = out.transposed(0, 2, 1, 3).reshaped([B, S, 6144])
                                    let gated = Fused.attnGate(flat, gate)
                                    link = gated[0..., 0 ..< 1, 0 ..< 1]
                                }
                            }
                            return keep + [link]
                        }
                        // stage: 0 qk-norm/split/transposes, 1 +RoPE, 2 +KV append, 3 +SDPA, 4 +output gate
                        let t0 = minEval(n) { achain(-1) }
                        var prev = t0
                        let names = ["split+qknorm+transposes", "+RoPE q,k", "+KV append", "+SDPA", "+attn gate"]
                        var last = t0
                        for st in 0 ... 4 {
                            let t = minEval(n) { achain(st) }
                            print(String(format: "ATTNGLUE %@ stage%d %@ cum=%.3f delta=%.3f ms per_layer=%.1f us", tag as NSString, st, names[st] as NSString, t - t0, t - prev, (t - prev) / Double(J) * 1000))
                            prev = t; last = t
                        }
                        attnTotal = last - t0
                        print(String(format: "ATTNGLUE %@ total_16_layers=%.3f ms (link-only baseline %.3f ms)", tag as NSString, attnTotal, t0))
                    }
                    // ---- tail (final norm + lm_head + argmax) and embed, repeated chains: slope over k
                    do {
                        let lw = lmw
                        let nw = try store.tensor("language_model.model.norm.weight")
                        let x0 = rnd([1, rows, 5120]); eval(x0)
                        func tailChain(_ k: Int) -> [MLXArray] {
                            var x = x0
                            for _ in 0 ..< k {
                                let lg = mm1(MLXFast.rmsNorm(x, weight: nw, eps: 1e-6), lw)
                                let am = argMax(lg, axis: -1).asType(.bfloat16).reshaped([1, rows, 1])
                                x = x0 + am
                            }
                            return [x]
                        }
                        let t1 = minEval(n) { tailChain(1) }, t4 = minEval(n) { tailChain(4) }
                        tailMs = (t4 - t1) / 3
                        print(String(format: "TAIL %@ norm+lm_head(full vocab)+argmax+link = %.3f ms (k=1 %.3f, k=4 %.3f; roundtrip incl. in k=1)", tag as NSString, tailMs, t1, t4))
                        if let dv = store.draftVocab {
                            func dchain(_ k: Int) -> [MLXArray] {
                                var x = x0
                                for _ in 0 ..< k {
                                    let lg = store.qmm(MLXFast.rmsNorm(x, weight: nw, eps: 1e-6), dv.w, dv.s, dv.b, spec: dv.spec)
                                    x = x0 + argMax(lg, axis: -1).asType(.bfloat16).reshaped([1, rows, 1])
                                }
                                return [x]
                            }
                            let d4 = minEval(n) { dchain(4) }, d1 = minEval(n) { dchain(1) }
                            print(String(format: "TAIL %@ norm+draft-vocab head(%d rows)+argmax+link = %.3f ms", tag as NSString, dv.idx.size, (d4 - d1) / 3))
                        }
                        let emb: (Int) -> [MLXArray] = { k in
                            var idx = MLXArray((0 ..< rows).map { Int32(1000 + $0) })
                            var keep: [MLXArray] = []
                            for _ in 0 ..< k {
                                let e = try! store.embedding("language_model.model.embed_tokens", indices: idx)
                                keep.append(e)
                                idx = idx + (e[0..., 0 ..< 1].reshaped([rows]) * 0).asType(.int32)
                            }
                            return keep + [idx]
                        }
                        let e1 = minEval(n) { emb(1) }, e4 = minEval(n) { emb(4) }
                        embedMs = (e4 - e1) / 3
                        print(String(format: "EMBED %@ dequantized embedding rows (+link) = %.3f ms", tag as NSString, embedMs))
                    }
                    // ---- reconcile
                    let pp = projPure[rows] ?? .nan
                    let sum = pp + gdnTotal + attnTotal + tNorm + tRes + tSw + tailMs + embedMs
                    print(String(format: "RECON %@ proj=%.2f gdnGlue=%.2f attnGlue=%.2f norms=%.2f resid=%.2f swiglu=%.2f tail=%.2f embed=%.2f  bottom-up sum=%.2f  top-down eval=%.2f  residual=%.2f ms (%.1f%%)",
                                 tag as NSString, pp, gdnTotal, attnTotal, tNorm, tRes, tSw, tailMs, embedMs, sum, topFull, topFull - sum, (topFull - sum) / topFull * 100))
                    Memory.clearCache()
                }
            }
        }

        // ---------------------------------------------------------------- MTP head
        if parts.contains("head") {
            for ctx in ctxs {
                let st = MTPState()
                let k = rnd([1, 4, ctx, 256]), v = rnd([1, 4, ctx, 256]); eval(k, v)
                st.attention.keys = k; st.attention.values = v
                for R in [1, 3] {
                    let hid = rnd([1, R, 5120]); eval(hid)
                    func hchain(_ steps: Int) -> [MLXArray] {
                        var h = hid
                        var tok = MLXArray((0 ..< R).map { Int32(2000 + $0) })
                        var keep: [MLXArray] = []
                        for s in 0 ..< steps {
                            let o = try! MTP.stepIndex(tokens: tok, hidden: h, target: store, head: head, state: st)
                            let on = try! MTP.normalized(o, head: head)
                            let ti = try! MTP.nextTokenIndex(o, target: store, head: head)
                            keep.append(on)
                            tok = ti.reshaped([1]).asType(.int32)
                            if s + 1 < steps && R > 1 { tok = MLXArray((0 ..< R).map { Int32(2000 + $0) }) + tok }
                            if R == 1 { h = on } else { h = hid + on[0..., (R - 1) ..< R, 0...] }
                        }
                        return keep + [tok]
                    }
                    let t1 = minEval(n) { hchain(1) }, t4 = minEval(n) { hchain(4) }
                    print(String(format: "HEAD ctx=%d rows=%d step(norm+draft head+argmax incl)=%.3f ms (k=1 %.3f incl sync, k=4 %.3f)", ctx, R, (t4 - t1) / 3, t1, t4))
                }
                Memory.clearCache()
            }
        }

        // ---------------------------------------------------------------- SDPA alternatives
        if parts.contains("sdpa") {
            for ctx in ctxs {
                let J = 16
                var ks: [MLXArray] = [], vs: [MLXArray] = []
                for _ in 0 ..< J { let k = rnd([1, 4, ctx, 256]), v = rnd([1, 4, ctx, 256]); eval(k, v); ks.append(k); vs.append(v) }
                let scale = pow(Float(256), -0.5)
                for S in [1, 3, 5] {
                    let q0 = rnd([1, 24, S, 256]); eval(q0)
                    func chain(_ kind: String) -> [MLXArray] {
                        var q = q0
                        for j in 0 ..< J {
                            let o: MLXArray
                            switch kind {
                            case "fast":
                                o = MLXFast.scaledDotProductAttention(queries: q, keys: ks[j], values: vs[j], scale: scale, mask: S > 1 ? .causal : .none)
                            case "unfused":
                                let qg = q.reshaped([1, 4, 6 * S, 256])
                                var sc = matmul(qg, ks[j].transposed(0, 1, 3, 2)) * scale
                                if S > 1 {
                                    // causal: query s (of S) sees keys 0 ... ctx-S+s; rows ordered (g, s)
                                    let qi = (MLXArray(Array(0 ..< Int32(6 * S))) % Int32(S)).reshaped([1, 1, 6 * S, 1])
                                    let ki = MLXArray(Array(0 ..< Int32(ctx))).reshaped([1, 1, 1, ctx])
                                    sc = MLX.where(ki .<= (qi + Int32(ctx - S)), sc, MLXArray(-Float.infinity).asType(sc.dtype))
                                }
                                let p = softmax(sc, axis: -1, precise: true)
                                o = matmul(p, vs[j]).reshaped([1, 24, S, 256])
                            default: // per-token S=1 calls on growing prefixes (what a no-mask decode would do)
                                var parts: [MLXArray] = []
                                for s in 0 ..< S {
                                    parts.append(MLXFast.scaledDotProductAttention(queries: q[0..., 0..., s ..< (s + 1), 0...], keys: ks[j][0..., 0..., 0 ..< (ctx - S + s + 1), 0...], values: vs[j][0..., 0..., 0 ..< (ctx - S + s + 1), 0...], scale: scale, mask: .none))
                                }
                                o = concatenated(parts, axis: 2)
                            }
                            q = o
                        }
                        return [q]
                    }
                    var line = String(format: "SDPA ctx=%d S=%d (16 layers, serial, KV %.2f GB -> %.2f ms @530GB/s):", ctx, S, Double(J * 2 * 4 * ctx * 256 * 2) / 1e9, Double(J * 2 * 4 * ctx * 256 * 2) / 530e9 * 1000)
                    for kind in S == 1 ? ["fast", "unfused"] : ["fast", "unfused", "split"] {
                        line += String(format: " %@=%.3f ms", kind as NSString, minEval(n) { chain(kind) })
                    }
                    print(line)
                }
                Memory.clearCache()
            }
        }

        // ---------------------------------------------------------------- whole spec round on a synthetic cache
        if parts.contains("round") {
            let depthR = Int(env["DA_DEPTH"] ?? "") ?? 2
            for ctx in ctxs {
                let cache = makeModelCache(ctx: ctx)
                let mtp = MTPState()
                let k = rnd([1, 4, ctx, 256]), v = rnd([1, 4, ctx, 256]); eval(k, v)
                mtp.attention.keys = k; mtp.attention.values = v
                mtp.seedHidden = rnd([1, 1, 5120]); mtp.seedTokenIndex = MLXArray([Int32(7)]).reshaped([1, 1])
                eval(mtp.seedHidden!, mtp.seedTokenIndex!)
                let stream = SpecStream(store: store, head: head, cache: cache, mtp: mtp, seedToken: 1000,
                                        lastHidden: rnd([1, 1, 5120]), depth: depthR, adaptive: false, maxDepth: depthR, maintainHead: true)
                for _ in 0 ..< 4 { _ = try stream.step(remaining: 100_000) }
                var ts: [Double] = []
                var emitted = 0
                for _ in 0 ..< n * 6 {
                    let t0 = nowMs(); let r = try stream.step(remaining: 100_000); ts.append(nowMs() - t0); emitted += r.count
                }
                print(String(format: "ROUND ctx=%d depth=%d (synthetic cache, real SpecStream, timing_env=%@) rounds=%d mean=%.2f median=%.2f min=%.2f ms/round tokens/round=%.2f",
                             ctx, depthR, (env["STRIM_TIMING"] ?? "off") as NSString, ts.count, ts.reduce(0, +) / Double(ts.count),
                             ts.sorted()[ts.count / 2], ts.min()!, Double(emitted) / Double(ts.count)))
                stream.printTiming()
                Memory.clearCache()
            }
        }

        // ---------------------------------------------------------------- pipelined graph build
        if parts.contains("pipe") {
            for ctx in ctxs {
                for cfg in cfgs where cfg.B == 1 {
                    let S = cfg.S
                    let cache = makeModelCache(ctx: ctx)
                    let toks = (0 ..< S).map { Int32(1000 + $0) }
                    func run(_ chunks: Int) throws -> (Double, Double, MLXArray) {
                        if cfg.rec { cache.beginVerify() }
                        let t0 = nowMs()
                        var h = try store.embedding("language_model.model.embed_tokens", tokens: toks).reshaped([1, S, 5120])
                        let per = 64 / max(chunks, 1)
                        for l in 0 ..< 64 {
                            h = try DecoderLayer.forward(h, store: store, layer: l, cache: cache)
                            if chunks > 1 && (l + 1) % per == 0 && l < 63 { asyncEval(h) }
                        }
                        let lg = try store.linear("language_model.lm_head", try store.rmsNorm("language_model.model.norm", h))
                        let am = argMax(lg, axis: -1)
                        let tb = nowMs() - t0
                        eval(am)
                        let tt = nowMs() - t0
                        if cfg.rec { cache.endVerify() }
                        return (tb, tt, lg)
                    }
                    let variants = [1, 2, 4, 8, 16]
                    var best: [Int: Double] = [:], bestB: [Int: Double] = [:]
                    for v in variants { _ = try run(v) }
                    for _ in 0 ..< n + 3 {
                        for v in variants {
                            let (tb, tt, _) = try run(v)
                            best[v] = min(best[v] ?? .infinity, tt); bestB[v] = min(bestB[v] ?? .infinity, tb)
                        }
                    }
                    var line = "PIPE ctx=\(ctx) cfg=\(cfg.key) wall(build+eval) ms by chunks(asyncEval every 64/chunks layers):"
                    for v in variants { line += String(format: " c%d=%.2f(host-return %.2f)", v, best[v]!, bestB[v]!) }
                    print(line)
                    if ctx == ctxs[0] {
                        // exactness: identical logits from identical snapshots, plain vs pipelined
                        eval(cache)
                        let snap = cache.snapshot()
                        let (_, _, a) = try run(1); eval(a)
                        cache.restore(snap)
                        let (_, _, b) = try run(8); eval(b)
                        print("PIPE ctx=\(ctx) cfg=\(cfg.key) logits bit-identical plain vs c8: \(arrayEqual(a, b).item(Bool.self))")
                    }
                    Memory.clearCache()
                }
            }
        }
    } catch {
        FileHandle.standardError.write(Data("benchdecodeanatomy failed: \(error)\n".utf8)); exit(1)
    }
}

// shared per-cfg scratch (filled by the glue sections, read by the reconcile line)
nonisolated(unsafe) private var gdnTotal = Double.nan
nonisolated(unsafe) private var attnTotal = Double.nan
nonisolated(unsafe) private var tailMs = Double.nan
nonisolated(unsafe) private var embedMs = Double.nan
