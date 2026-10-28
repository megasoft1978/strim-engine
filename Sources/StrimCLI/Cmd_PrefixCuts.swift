import Foundation
import MLX
import StrimCore
import StrimTokenizer

// Usage: strim checkprefixcuts <model dir> [mtp head dir]
// Multi-message prompts (<|im_start|> tokens) through the policy prefill: hit == miss exactness at
// message-start cuts, previous-turn reuse, and cold-prefill throughput (run once more with
// STRIM_PREFIX_CUTS=fixed to compare the small-chunk cost).

private func msgTokens(_ n: Int, seed: Int) -> [Int32] {
    [PrefixPrefill.defaultPolicy.boundary ?? CutPolicy.imStartId] + (0 ..< n - 1).map { Int32(((($0 &+ seed &* 104_729) &* 7919) &+ 17 &+ seed) % 150_000) }
}

private func hashArray(_ a: MLXArray) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for x in a.asType(.float32).asArray(Float.self) { h = (h ^ UInt64(x.bitPattern)) &* 0x0000_0100_0000_01b3 }
    return String(format: "%016llx", h)
}

private func prompt(_ lens: [Int], tail: [Int32]) -> [Int32] {
    var out: [Int32] = []
    for (i, n) in lens.enumerated() { out += msgTokens(n, seed: i + 1) }
    return out + tail
}

func runPrefixCuts(_ args: [String]) {
    guard args.count >= 3 else { print("usage: strim checkprefixcuts <model dir> [mtp head dir]"); return }
    Memory.cacheLimit = 2 << 30   // CLI check: the unbounded MLX buffer cache otherwise grows to ~40 GB and swaps
    var failures = 0
    let env = ProcessInfo.processInfo.environment
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  " + detail)")
        if !ok { failures += 1 }
    }
    do {
        let model = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        if let t = try? Tokenizer.load(modelDir: args[2]), let id = t.specialIds["<|im_start|>"] { PrefixPrefill.configureBoundary(id) }
        if let t = try? Tokenizer.load(modelDir: args[2]), let a = t.encode("assistant", allowSpecial: false).first { PrefixPrefill.configureAssistant(a) }
        var head: WeightStore? = nil
        if args.count >= 4 { head = try WeightStore(dir: URL(fileURLWithPath: args[3])); head!.useIntegratedMTPPrefixIfNeeded() }
        let policy = PrefixPrefill.defaultPolicy
        print("checkprefixcuts policy max=\(policy.maxBlock) min=\(policy.minBlock) boundary=\(policy.boundary.map(String.init) ?? "none")")
        let gen: [Int32] = [PrefixPrefill.defaultPolicy.boundary ?? CutPolicy.imStartId, PrefixPrefill.defaultPolicy.assistant ?? 77091, 198]       // <|im_start|>assistant\n
        let lens1 = [900, 300, 700, 120, 1500, 60, 400]
        let turn1 = prompt(lens1, tail: gen)
        let turn2 = prompt(lens1 + [260, 90, 800], tail: gen)       // turn 1's history + new messages
        _ = try PrefixPrefill.run(tokens: Array(turn1[0 ..< 600]), store: model, cache: nil)   // warm kernels

        func cutsOf(_ t: [Int32]) -> [Int] {
            var out: [Int] = [], pos = 0
            while let e = policy.blockEnd(t, from: pos, limit: t.count) { out.append(e); pos = e }
            return out
        }
        let expected = cutsOf(turn1).last(where: { $0 <= turn2.count - 1 }) ?? 0
        if env["STRIM_CUTS_PERF_ONLY"] == nil {
        print("(a) plain: turn-2 miss vs hit after turn 1; turn-1 cuts \(cutsOf(turn1).count), expected reuse \(expected) of \(turn1.count)")
        let miss = try PrefixPrefill.run(tokens: turn2, store: model, cache: nil)
        let mh = hashArray(miss.logits)
        let store = PrefixStore(budgetBytes: 64 << 30)
        let first = try PrefixPrefill.run(tokens: turn1, store: model, cache: store)
        let cold = try PrefixPrefill.run(tokens: turn2, store: model, cache: PrefixStore(budgetBytes: 64 << 30))
        check("cold-store == no-store", hashArray(cold.logits) == mh && !cold.hit)
        let hit = try PrefixPrefill.run(tokens: turn2, store: model, cache: store)
        check("hit == miss logits", hashArray(hit.logits) == mh, "hit \(hashArray(hit.logits)) miss \(mh)")
        check("reuse reaches turn 1's last cut", hit.matchedTokens == expected, "matched \(hit.matchedTokens) expected \(expected) (turn1 \(first.matchedTokens))")
        let hit2 = try PrefixPrefill.run(tokens: turn2, store: model, cache: store)
        check("second hit unchanged", hashArray(hit2.logits) == mh)
        // greedy continuation from the restored cache == from the miss cache
        func cont(_ c: ModelCache, _ l: MLXArray) throws -> [Int32] {
            var tok = Int32(argMax(l).item(Int32.self)), out = [tok]
            for _ in 1 ..< 16 {
                tok = Int32(argMax(try QwenModel.forward(tokens: [tok], store: model, cache: c).logits).item(Int32.self)); out.append(tok)
            }
            return out
        }
        check("16 greedy tokens identical", try cont(hit.cache, hit.logits) == cont(miss.cache, miss.logits))
        print("  store: nodes \(store.nodeCount) bytes \(store.totalBytes >> 20) MB")

        if let head {
            print("(b) MTP head path")
            let m = try SpecPrefill.run(tokens: turn2, store: model, head: head, cache: nil)
            let ms = PrefixStore(budgetBytes: 64 << 30)
            _ = try SpecPrefill.run(tokens: turn1, store: model, head: head, cache: ms)
            let h = try SpecPrefill.run(tokens: turn2, store: model, head: head, cache: ms)
            check("spec hit logits == miss", hashArray(h.logits) == hashArray(m.logits))
            check("spec seed token + hidden identical", h.seedToken == m.seedToken && hashArray(h.seedHidden) == hashArray(m.seedHidden))
            check("spec head KV identical", hashArray(h.mtp.attention.keys!) == hashArray(m.mtp.attention.keys!)
                  && hashArray(h.mtp.attention.values!) == hashArray(m.mtp.attention.values!))
            check("spec reuse", h.matchedTokens == expected, "matched \(h.matchedTokens)")
        }

        }
        if env["STRIM_CUTS_PERF_ONLY"] == nil {
        // (e) thinned GDN states: under a budget that forces thinning, a hit snaps to a stateful ancestor and stays exact.
        print("(e) thinning under budget pressure")
        let full = PrefixStore(budgetBytes: 64 << 30, thinStride: 2)
        _ = try PrefixPrefill.run(tokens: turn1, store: model, cache: full)
        let tight = PrefixStore(budgetBytes: full.totalBytes - (100 << 20), thinStride: 2)
        _ = try PrefixPrefill.run(tokens: turn1, store: model, cache: tight)
        let mref = try PrefixPrefill.run(tokens: turn2, store: model, cache: nil)
        let th = try PrefixPrefill.run(tokens: turn2, store: model, cache: tight)
        check("thinning happened under the tight budget", tight.thinned > 0 && tight.totalBytes <= tight.budgetBytes, "thinned \(tight.thinned) nodes \(tight.nodeCount)/\(full.nodeCount)")
        check("thinned hit == miss logits", hashArray(th.logits) == hashArray(mref.logits), "matched \(th.matchedTokens)")
        if let head {
            let ms = try SpecPrefill.run(tokens: turn2, store: model, head: head, cache: nil)
            let tt = PrefixStore(budgetBytes: full.totalBytes - (100 << 20), thinStride: 2)
            _ = try SpecPrefill.run(tokens: turn1, store: model, head: head, cache: tt)
            let hs = try SpecPrefill.run(tokens: turn2, store: model, head: head, cache: tt)
            check("thinned spec hit == miss", hashArray(hs.logits) == hashArray(ms.logits) && hs.seedToken == ms.seedToken)
        }
        }
        // (c) cold prefill throughput on two multi-message prompts; (d) numerics vs the old fixed-1024 partition.
        let lens16 = [900, 300, 700, 120, 1500, 60, 400, 2000, 350, 800, 1200, 90, 2500, 600, 1800, 400, 3000]
        let big = prompt(lens16, tail: gen)
        for (name, t) in [("5K", turn2), ("16K", big)] {
            var ts: [Double] = []
            for i in 0 ..< 4 {
                let t0 = Date()
                let r = try PrefixPrefill.run(tokens: t, store: model, cache: nil); eval(r.logits)
                if i > 0 { ts.append(Date().timeIntervalSince(t0)) }
            }
            ts.sort()
            print(String(format: "PERF cold_%@ policy=%d/%d tokens=%d cuts=%d tok/s median %.0f best %.0f", name, policy.minBlock, policy.maxBlock,
                         t.count, cutsOf(t).count, Double(t.count) / ts[1], Double(t.count) / ts[0]))
        }
        if env["STRIM_CUTS_SKIP_NUMERICS"] == nil {
            let fixedStore = PrefixStore(budgetBytes: 64 << 30, policy: .fixed(1024))
            let a = try PrefixPrefill.run(tokens: big, store: model, cache: fixedStore)
            let b = try PrefixPrefill.run(tokens: big, store: model, cache: nil)
            let d = abs(a.logits.asType(.float32) - b.logits.asType(.float32)).max().item(Float.self)
            let sameTop = argMax(a.logits).item(Int32.self) == argMax(b.logits).item(Int32.self)
            print("NUMERICS fixed1024 vs policy \(policy.minBlock)/\(policy.maxBlock) on 16K: max|dlogit| \(d) argmax \(sameTop ? "same" : "DIFFERENT")")
        }
    } catch {
        print("checkprefixcuts failed: \(error)"); exit(1)
    }
    print(failures == 0 ? "checkprefixcuts: ALL PASS" : "checkprefixcuts: \(failures) FAILED")
    if failures > 0 { exit(1) }
}
