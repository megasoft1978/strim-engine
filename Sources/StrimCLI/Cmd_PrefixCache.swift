import Foundation
import MLX
import StrimCore

// Usage: strim checkprefix <model dir> [N=4096] [sharedBlocks=3] [mtp head dir]
// Exactness check for the aligned-chunk prefix cache: hit must equal miss (last-position
// logit hash + 16 greedy tokens), eviction keeps parity, unrelated prompts miss.

private func synth(_ n: Int, seed: Int) -> [Int32] {
    (0 ..< n).map { Int32(((($0 &+ seed &* 104_729) &* 7919) &+ 17 &+ seed) % 150_000) }
}

private func hashLogits(_ a: MLXArray) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for x in a.asType(.float32).asArray(Float.self) { h = (h ^ UInt64(x.bitPattern)) &* 0x0000_0100_0000_01b3 }
    return String(format: "%016llx", h)
}

private struct Out {
    var hash: String
    var tokens: [Int32]
    var seconds: Double
    var matched: Int
    var hit: Bool
}

private func greedy(_ prompt: [Int32], model: WeightStore, store: PrefixStore?, steps: Int = 16) throws -> Out {
    let t0 = Date()
    let r = try PrefixPrefill.run(tokens: prompt, store: model, cache: store)
    let dt = Date().timeIntervalSince(t0)
    let hash = hashLogits(r.logits)
    var tok = Int32(argMax(r.logits).item(Int32.self))
    var toks = [tok]
    for _ in 1 ..< steps {
        let l = try QwenModel.forward(tokens: [tok], store: model, cache: r.cache).logits
        tok = Int32(argMax(l).item(Int32.self))
        toks.append(tok)
    }
    return Out(hash: hash, tokens: toks, seconds: dt, matched: r.matchedTokens, hit: r.hit)
}

private func topTwo(_ logits: MLXArray) -> (idx: Int, margin: Float) {
    let v = logits.asType(.float32).asArray(Float.self)
    var bi = 0, b1 = -Float.infinity, b2 = -Float.infinity
    for (i, x) in v.enumerated() {
        if x > b1 { b2 = b1; b1 = x; bi = i } else if x > b2 { b2 = x }
    }
    return (bi, b1 - b2)
}

/// Chunked (policy) prefill onto `cache`; returns pre-norm hidden over all tokens and last logits.
private func chunkedPrefill(_ tokens: [Int32], model: WeightStore, cache: ModelCache) throws -> (MLXArray, MLXArray) {
    var hs: [MLXArray] = []
    var logits: MLXArray! = nil
    var pos = 0
    while pos < tokens.count {
        let end = min(pos + PrefixPrefill.chunk, tokens.count)
        let r = try QwenModel.forwardAll(tokens: Array(tokens[pos ..< end]), store: model, cache: cache,
                                         lastTokenOnly: true)
        hs.append(r.hidden); logits = r.logits; eval(r.hidden, cache); pos = end
    }
    return (hs.count == 1 ? hs[0] : concatenated(hs, axis: 1), logits[0, 0])
}

/// Hot session continuation vs a cold run over the same ids. Reports, never asserts: the
/// verify pass writes KV through a different kernel shape than prefill, so float noise is
/// expected; the question is whether it ever flips a token.
private func hotContinue(model: WeightStore, head: WeightStore, nA: Int = 1300, nB: Int = 900, steps: Int = Int(ProcessInfo.processInfo.environment["STRIM_HOT_STEPS"] ?? "") ?? 20) throws {
    let env = ProcessInfo.processInfo.environment
    let sd = Int(env["STRIM_HOT_SEED"] ?? "") ?? 3
    let a = synth(nA, seed: sd), bToks = synth(nB, seed: sd + 2)
    let cache = ModelCache()
    let (hid, lg) = try chunkedPrefill(a, model: model, cache: cache)
    let b0 = Int32(argMax(lg).item(Int32.self))
    let mtp = MTPState()
    try SpecStream.seedHead(tokens: a, next: b0, hidden: hid, store: model, head: head, mtp: mtp,
                            chain: QwenModel.defaultDraftChain)
    let lastH = try model.rmsNorm("language_model.model.norm", hid[0..., (nA - 1) ..< nA, 0...])
    let stream = SpecStream(store: model, head: head, cache: cache, mtp: mtp, seedToken: b0, lastHidden: lastH)
    var out1: [Int32] = []
    while out1.count < steps { out1 += try stream.step(remaining: steps - out1.count) }
    let pend = stream.pending
    let turn2 = [pend] + bToks
    let hotLogits = try stream.appendTokens(turn2)
    var out2: [Int32] = []
    while out2.count < steps { out2 += try stream.step(remaining: steps - out2.count) }
    print("  hot: turn1 \(out1.count) tokens, append \(turn2.count), turn2 \(out2) head pos \(mtp.position) cache pos \(cache.position)")

    // cold: same ids, policy-chunked prefill, plain greedy decode
    let ids = a + out1 + turn2
    let cold = ModelCache()
    let (_, cl) = try chunkedPrefill(ids, model: model, cache: cold)
    let dmax = abs(cl.asType(.float32) - hotLogits.asType(.float32)).max().item(Float.self)
    let (ci, cm) = topTwo(cl)
    let (hi, _) = topTwo(hotLogits)
    print(String(format: "  append-logits: max|hot-cold| %.4f  argmax hot %d cold %d  cold margin %.3f", dmax, hi, ci, cm))
    var tok = Int32(ci)
    var coldOut: [Int32] = []
    var margins: [Float] = []
    for _ in 0 ..< steps {
        coldOut.append(tok)
        let l = try QwenModel.forward(tokens: [tok], store: model, cache: cold).logits
        let t = topTwo(l)
        margins.append(t.margin); tok = Int32(t.idx)
    }
    if coldOut == out2 {
        print("  hot-continue vs cold: IDENTICAL over \(steps) tokens (min cold margin \(String(format: "%.3f", margins.min() ?? 0)))")
    } else {
        let i = (0 ..< steps).first { coldOut[$0] != out2[$0] } ?? 0
        let m = i == 0 ? cm : margins[i - 1]
        print("  hot-continue vs cold: first divergence at token \(i): hot \(out2[i]) cold \(coldOut[i]), cold logit margin there \(String(format: "%.4f", m))")
        print("  hot  \(out2)\n  cold \(coldOut)")
    }
}

private func fnv(_ h: inout UInt64, _ a: MLXArray) {
    for x in a.asType(.float32).asArray(Float.self) { h = (h ^ UInt64(x.bitPattern)) &* 0x0000_0100_0000_01b3 }
}

private struct SpecPrint: Equatable {
    var cache: UInt64, mtp: UInt64, seed: UInt64, logits: UInt64, token: Int32
}

private func fingerprint(_ o: SpecPrefill.Outcome) -> SpecPrint {
    var hc: UInt64 = 0xcbf2_9ce4_8422_2325
    for l in o.cache.attention.keys.sorted() {
        fnv(&hc, o.cache.attention[l]!.keys!); fnv(&hc, o.cache.attention[l]!.values!)
    }
    for l in o.cache.gdn.keys.sorted() {
        fnv(&hc, o.cache.gdn[l]!.conv!); fnv(&hc, o.cache.gdn[l]!.ssm!)
    }
    var hm: UInt64 = 0xcbf2_9ce4_8422_2325
    fnv(&hm, o.mtp.attention.keys!); fnv(&hm, o.mtp.attention.values!)
    if let s = o.mtp.seedHidden { fnv(&hm, s) }
    if let t = o.mtp.seedTokenIndex { fnv(&hm, t.asType(.float32)) }
    var hs: UInt64 = 0xcbf2_9ce4_8422_2325
    fnv(&hs, o.seedHidden)
    var hl: UInt64 = 0xcbf2_9ce4_8422_2325
    fnv(&hl, o.logits)
    return SpecPrint(cache: hc, mtp: hm, seed: hs, logits: hl, token: o.seedToken)
}

private struct SpecRun {
    var print: SpecPrint
    var tokens: [Int32]
    var prefillSeconds: Double
    var decodeTokS: Double
    var accept: Double
    var tokPerPass: Double
    var matched: Int
    var hit: Bool
}

private func specRun(_ prompt: [Int32], model: WeightStore, head: WeightStore, store: PrefixStore?,
                     n: Int = 64) throws -> SpecRun {
    let t0 = Date()
    let o = try SpecPrefill.run(tokens: prompt, store: model, head: head, cache: store)
    eval(o.logits, o.seedHidden)
    let tp = Date().timeIntervalSince(t0)
    let fp = fingerprint(o)
    let stream = SpecStream(store: model, head: head, cache: o.cache, mtp: o.mtp, seedToken: o.seedToken,
                            lastHidden: o.seedHidden)
    var out: [Int32] = []
    let t1 = Date()
    while out.count < n { out += try stream.step(remaining: n - out.count) }
    let td = Date().timeIntervalSince(t1)
    return SpecRun(print: fp, tokens: out, prefillSeconds: tp, decodeTokS: Double(n) / td,
                   accept: stream.stats.acceptRate, tokPerPass: stream.stats.tokensPerPass,
                   matched: o.matchedTokens, hit: o.hit)
}

private func checkSpecPrefill(model: WeightStore, head: WeightStore, base: [Int32], k: Int, n: Int,
                              check: (String, Bool, String) -> Void) throws {
    let C = PrefixPrefill.chunk
    let warm = Array(base[0 ..< (k * C + 200)])
    _ = try specRun(Array(base[0 ..< 600]), model: model, head: head, store: nil, n: 8)   // warmup
    print("(g) MTP over the prefix cache, N=\(n)")
    let ref = try specRun(base, model: model, head: head, store: nil)
    print("  miss ref: \(ref.tokens.prefix(8))...  prefill \(String(format: "%.3f", ref.prefillSeconds)) s")

    let ps = PrefixStore(budgetBytes: 64 << 30)
    let cold = try specRun(base, model: model, head: head, store: ps)
    check("cold-store spec miss == ref", cold.print == ref.print && cold.tokens == ref.tokens && !cold.hit, "")

    let ps2 = PrefixStore(budgetBytes: 64 << 30)
    _ = try specRun(warm, model: model, head: head, store: ps2, n: 4)
    let hit = try specRun(base, model: model, head: head, store: ps2)
    check("spec hit == miss (cache, head KV, seed hidden, logits, token)", hit.print == ref.print,
          "cache \(hit.print.cache == ref.print.cache) mtp \(hit.print.mtp == ref.print.mtp) seed \(hit.print.seed == ref.print.seed) logits \(hit.print.logits == ref.print.logits) tok \(hit.print.token == ref.print.token)")
    check("64 speculative tokens identical (hit)", hit.tokens == ref.tokens, "")
    check("matched == \(k * C)", hit.hit && hit.matched == k * C, "")
    let hit2 = try specRun(base, model: model, head: head, store: ps2)
    check("second spec hit unchanged", hit2.print == ref.print && hit2.tokens == ref.tokens, "")

    var fork = base; for i in (k * C + 5) ..< fork.count { fork[i] = Int32((Int(fork[i]) + 31) % 150_000) }
    let missFork = try specRun(fork, model: model, head: head, store: nil)
    let hitFork = try specRun(fork, model: model, head: head, store: ps2)
    check("forked tail spec hit == miss", hitFork.print == missFork.print && hitFork.tokens == missFork.tokens
          && hitFork.matched == k * C, "")

    let other = synth(n, seed: 9)
    let missO = try specRun(other, model: model, head: head, store: nil)
    let hitO = try specRun(other, model: model, head: head, store: ps2)
    check("unrelated spec -> miss, identical", !hitO.hit && hitO.print == missO.print && hitO.tokens == missO.tokens, "")

    // Nodes stored by a head-less prefill must not be used for a spec hit, and gain head state afterwards.
    let ps3 = PrefixStore(budgetBytes: 64 << 30)
    _ = try PrefixPrefill.run(tokens: warm, store: model, cache: ps3)
    let plainBytes = ps3.totalBytes
    let mixed = try specRun(base, model: model, head: head, store: ps3)
    check("head-less nodes -> spec miss, identical", !mixed.hit && mixed.print == ref.print && mixed.tokens == ref.tokens, "")
    let upgraded = try specRun(base, model: model, head: head, store: ps3)
    check("after upgrade spec hit == miss", upgraded.hit && upgraded.print == ref.print && upgraded.tokens == ref.tokens,
          "matched \(upgraded.matched)")

    // eviction with a budget of ~2.5 spec nodes
    // budget derived from the real trie size of a full-prompt insert (cold store): 0.6x forces eviction
    // whatever the cut policy produced, yet keeps >= 1 node resident for the post-eviction hit.
    let tiny = PrefixStore(budgetBytes: ps.totalBytes * 6 / 10)
    let e1 = try specRun(base, model: model, head: head, store: tiny)
    check("tiny budget insert run == ref", e1.print == ref.print && e1.tokens == ref.tokens, "")
    check("budget respected", tiny.totalBytes <= tiny.budgetBytes && tiny.evictions > 0,
          "bytes \(tiny.totalBytes >> 20) MB budget \(tiny.budgetBytes >> 20) MB nodes \(tiny.nodeCount) evictions \(tiny.evictions)")
    let e2 = try specRun(base, model: model, head: head, store: tiny)
    check("post-eviction spec hit == ref", e2.hit && e2.print == ref.print && e2.tokens == ref.tokens, "matched \(e2.matched)")

    print("  --- numbers")
    let withMTP = ps2.totalBytes, nodes = ps2.nodeCount
    let plain = PrefixStore(budgetBytes: 64 << 30)
    _ = try PrefixPrefill.run(tokens: warm, store: model, cache: plain)
    let nodeP = plain.totalBytes / max(plain.nodeCount, 1), nodeS = withMTP / max(nodes, 1)
    print(String(format: "  bytes/node: plain %.1f MB, with MTP %.1f MB, MTP +%.2f MB (+%.2f%%); plain store before upgrade %d MB",
                 Double(nodeP) / 1048576, Double(nodeS) / 1048576, Double(nodeS - nodeP) / 1048576,
                 Double(nodeS - nodeP) / Double(nodeP) * 100, plainBytes >> 20))
    var tPlain: [Double] = [], tSpec: [Double] = []
    for _ in 0 ..< 3 {
        let t0 = Date()
        let r = try PrefixPrefill.run(tokens: base, store: model, cache: nil); eval(r.logits)
        tPlain.append(Date().timeIntervalSince(t0))
        let t1 = Date()
        let o = try SpecPrefill.run(tokens: base, store: model, head: head, cache: nil); eval(o.logits, o.seedHidden)
        if let s = o.mtp.seedHidden { eval(s) }
        tSpec.append(Date().timeIntervalSince(t1))
    }
    let bp = tPlain.dropFirst().min()!, bs = tSpec.dropFirst().min()!
    print(String(format: "  prefill N=%d: plain %.0f tok/s (%.3f s)  with head pass %.0f tok/s (%.3f s)  head overhead %.2f%%",
                 base.count, Double(base.count) / bp, bp, Double(base.count) / bs, bs, (bs / bp - 1) * 100))
    let m = try specRun(base, model: model, head: head, store: nil)
    let h = try specRun(base, model: model, head: head, store: ps2)
    print(String(format: "  TTFT(prefill+seed): miss %.3f s  hit %.3f s  speedup %.2fx", m.prefillSeconds, h.prefillSeconds,
                 m.prefillSeconds / h.prefillSeconds))
    print(String(format: "  spec decode 64 tok: miss %.1f tok/s accept %.0f%% %.2f tok/pass | hit %.1f tok/s accept %.0f%% %.2f tok/pass",
                 m.decodeTokS, m.accept * 100, m.tokPerPass, h.decodeTokS, h.accept * 100, h.tokPerPass))
}

func runPrefixCache(_ args: [String]) {
    guard args.count >= 3 else { print("usage: strim checkprefix <model dir> [N=4096] [sharedBlocks=3]"); return }
    Memory.cacheLimit = 2 << 30   // CLI check: the unbounded MLX buffer cache otherwise grows to ~40 GB and swaps
    let n = args.count >= 4 ? Int(args[3]) ?? 4096 : 4096
    let k = args.count >= 5 ? Int(args[4]) ?? 3 : 3
    let mtpPath: String? = args.count >= 6 ? args[5] : nil
    let C = PrefixPrefill.chunk
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  " + detail)")
        if !ok { failures += 1 }
    }
    do {
        let model = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let base = synth(n, seed: 1)
        let warmPrompt = Array(base[0 ..< (k * C + 200)])
        print("checkprefix model=\(args[2]) N=\(n) shared=\(k * C) chunk=\(C)")
        _ = try greedy(Array(base[0 ..< 600]), model: model, store: nil, steps: 2)   // kernel warmup

        print("(a) miss reference (no store)")
        let miss = try greedy(base, model: model, store: nil)
        print("  hash \(miss.hash)  tokens \(miss.tokens)  \(String(format: "%.3f", miss.seconds)) s")

        print("(b) hit vs miss")
        let ps = PrefixStore(budgetBytes: 64 << 30)
        let cold = try greedy(base, model: model, store: ps)        // miss that populates
        check("cold-store miss == reference", cold.hash == miss.hash && cold.tokens == miss.tokens && !cold.hit)
        let ps2 = PrefixStore(budgetBytes: 64 << 30)
        _ = try greedy(warmPrompt, model: model, store: ps2)
        print("  store after warm: nodes \(ps2.nodeCount) bytes \(ps2.totalBytes >> 20) MB")
        let hit = try greedy(base, model: model, store: ps2)
        check("hit == miss (hash+tokens)", hit.hash == miss.hash && hit.tokens == miss.tokens,
              "hit hash \(hit.hash) matched \(hit.matched)")
        check("matched == \(k * C)", hit.hit && hit.matched == k * C)
        let hit2 = try greedy(base, model: model, store: ps2)      // after previous run decoded on its cache
        check("second hit unchanged (no aliasing)", hit2.hash == miss.hash && hit2.tokens == miss.tokens)
        // other direction: populate with the long prompt, then the shorter prompt hits
        let missShort = try greedy(warmPrompt, model: model, store: nil)
        let hitShort = try greedy(warmPrompt, model: model, store: ps)
        check("reverse: short prompt hit == short miss", hitShort.hit && hitShort.hash == missShort.hash
              && hitShort.tokens == missShort.tokens, "matched \(hitShort.matched)")
        // diverging tail after the shared blocks
        var fork = base; for i in (k * C + 5) ..< fork.count { fork[i] = Int32((Int(fork[i]) + 31) % 150_000) }
        let missFork = try greedy(fork, model: model, store: nil)
        let hitFork = try greedy(fork, model: model, store: ps2)
        check("forked tail hit == miss", hitFork.hash == missFork.hash && hitFork.tokens == missFork.tokens
              && hitFork.matched == k * C)

        print("(c) eviction with tiny budget")
        let nodeBytes = ps2.totalBytes / max(ps2.nodeCount, 1)
        // 0.6x the real trie bytes of the full-prompt insert (cold store): eviction must fire for any cut policy.
        let tiny = PrefixStore(budgetBytes: ps.totalBytes * 6 / 10)
        let e1 = try greedy(base, model: model, store: tiny)
        check("insert run == reference", e1.hash == miss.hash && e1.tokens == miss.tokens)
        check("budget respected", tiny.totalBytes <= tiny.budgetBytes && tiny.evictions > 0,
              "bytes \(tiny.totalBytes >> 20) MB budget \(tiny.budgetBytes >> 20) MB nodes \(tiny.nodeCount) evictions \(tiny.evictions)")
        let e2 = try greedy(base, model: model, store: tiny)
        check("post-eviction hit == reference", e2.hit && e2.hash == miss.hash && e2.tokens == miss.tokens,
              "matched \(e2.matched)")

        print("(d) unrelated prompt")
        let other = synth(n, seed: 9)
        let missO = try greedy(other, model: model, store: nil)
        let hitO = try greedy(other, model: model, store: ps2)
        check("unrelated -> miss, identical", !hitO.hit && hitO.matched == 0 && hitO.hash == missO.hash
              && hitO.tokens == missO.tokens)

        print("(e) TTFT N=\(n), shared \(k * C)")
        let m2 = try greedy(base, model: model, store: nil, steps: 1)
        let h2 = try greedy(base, model: model, store: ps2, steps: 1)
        print(String(format: "  miss %.3f s  hit %.3f s  speedup %.2fx", m2.seconds, h2.seconds, m2.seconds / h2.seconds))
        let node = ps2.lookup(base, maxTokens: n - 1)
        if let node {
            let rc = try ps2.restore(node)
            print("  bytes: total store \(ps2.totalBytes >> 20) MB over \(ps2.nodeCount) nodes (~\(nodeBytes >> 20) MB/node); restored ModelCache.byteSize \(rc.byteSize >> 20) MB")
        }

        print("(f) policy-prefill cost vs one-shot, N=\(n)")
        var tp: [Double] = [], to: [Double] = []
        for _ in 0 ..< 3 {
            let t0 = Date()
            let r = try PrefixPrefill.run(tokens: base, store: model, cache: nil); eval(r.logits)
            tp.append(Date().timeIntervalSince(t0))
            let t1 = Date()
            let o = try QwenModel.forwardAll(tokens: base, store: model, cache: ModelCache(), lastTokenOnly: true); eval(o.logits)
            to.append(Date().timeIntervalSince(t1))
        }
        let bp = tp.dropFirst().min()!, bo = to.dropFirst().min()!
        print(String(format: "  chunked %.0f tok/s (%.3f s)  one-shot %.0f tok/s (%.3f s)  cost %.1f%%",
                     Double(n) / bp, bp, Double(n) / bo, bo, (bp / bo - 1) * 100))

        if let mtpPath {
            let head = try WeightStore(dir: URL(fileURLWithPath: mtpPath))
            head.useIntegratedMTPPrefixIfNeeded()
            try checkSpecPrefill(model: model, head: head, base: base, k: k, n: n, check: check)
            print("(h) hot session continuation (informational)")
            try hotContinue(model: model, head: head)
        }
    } catch {
        print("checkprefix failed: \(error)"); exit(1)
    }
    print(failures == 0 ? "checkprefix: ALL PASS" : "checkprefix: \(failures) FAILED")
    if failures > 0 { exit(2) }
}
