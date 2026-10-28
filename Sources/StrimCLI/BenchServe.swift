import Foundation
import MLX
import StrimCore

/// Continuous-batching scheduler prototype: serial prefill, batched lockstep decode,
/// per-request finish and admission of queued requests into freed slots. No MTP.
///
/// Usage: strim benchserve <model> <requests> <maxTokens> [slots] [mix] [ctx] [sharedPrefix]
///   maxTokens     decode steps per request after its prefill token (same for every request)
///   slots         batch slots, clamped to 1...4
///   mix           non-zero: odd ids are background priority; TTFT is also split by class
///   ctx           prompt length (0: legacy short prompts of 24/31/38 tokens)
///   sharedPrefix  non-zero: all requests share a ctx-16 prefix (prefix-cache test)
/// Env:
///   STRIM_BENCH_PROMPTS=distinct (default) | legacy
///     distinct: per-request seeded token streams over common ids, equal length, no shared prefix
///     legacy:   repeated 8-token pattern, lengths ctx-2r (unequal), as before
///   STRIM_DUMP_TOKENS=<path>: decode ids per request (the prefill token is not included, as before)
///
/// Per-request timing, all requests arriving together at the start of the batched phase:
///   queue wait    admission start - arrival
///   prefill       admission start -> first generated token (prefill argmax, device-synced)
///   TTFT          arrival -> first generated token (= queue wait + prefill)
///   end           arrival -> last generated token (total latency)
///   decode tok/s  (completion - 1) / (last - first)
/// completion tokens = prefill token + decode steps.
private func distinctPrompt(seed: Int, length: Int) -> [Int32] {
    // splitmix64 over the common-id head of the vocab [100, 20000): deterministic per seed.
    var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1B5_4A32_D192_ED03
    var out: [Int32] = []
    out.reserveCapacity(length)
    for _ in 0 ..< length {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        out.append(Int32(100 + z % 19_900))
    }
    return out
}

private func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
}

private func equalOrRange(_ xs: [Int], unit: String) -> String {
    guard let lo = xs.min(), let hi = xs.max() else { return "none" }
    return lo == hi ? "equal, \(lo) \(unit) each" : "unequal, \(lo)..\(hi)"
}

private struct BenchRow {
    let id: Int
    let promptTokens: Int
    let priority: Int
    let queueWait: Double
    let prefill: Double
    let ttft: Double
    let end: Double
    let decodeTps: Double
    let completion: Int
}

func runBenchServe(_ args: [String]) {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let requests = args.count >= 4 ? Int(args[3]) ?? 8 : 8
        let maxTokens = args.count >= 5 ? Int(args[4]) ?? 24 : 24
        let slots = min(max(args.count >= 6 ? Int(args[5]) ?? 2 : 2, 1), 4)
        let mix = args.count >= 7 ? (Int(args[6]) ?? 0) : 0
        let ctx = args.count >= 8 ? (Int(args[7]) ?? 0) : 0
        let prefixMode = args.count >= 9 ? (Int(args[8]) ?? 0) != 0 : false
        let promptMode = ProcessInfo.processInfo.environment["STRIM_BENCH_PROMPTS"] ?? "distinct"
        guard promptMode == "distinct" || promptMode == "legacy" else {
            FileHandle.standardError.write(Data("benchserve: STRIM_BENCH_PROMPTS must be distinct or legacy\n".utf8))
            exit(1)
        }
        let legacy = promptMode == "legacy"
        let pattern: [Int32] = [9707, 1234, 5678, 198, 2, 220, 17, 15]
        struct Req { let id: Int; let prompt: [Int32]; let max: Int; let priority: Int
                     var arrival: Date }
        var pending: [Req] = []
        var sharedPrefix: [Int32]? = nil
        if prefixMode, ctx > 32 {
            var p: [Int32] = []
            while p.count < ctx { p.append(contentsOf: pattern) }
            sharedPrefix = Array(p.prefix(ctx - 16))
        }
        for r in 0 ..< requests {
            let prompt: [Int32]
            if let sp = sharedPrefix {
                // Same repo/system prefix, unique question suffix per request.
                var full: [Int32] = []
                while full.count < sp.count + 64 { full.append(contentsOf: pattern) }
                prompt = sp + Array(full[(sp.count + 3 * r) ..< (sp.count + 3 * r + 16)])
            } else if legacy {
                let len = ctx > 0 ? max(8, ctx - 2 * r) : 24 + (r % 3) * 7
                var p: [Int32] = []
                while p.count < len { p.append(contentsOf: pattern) }
                prompt = Array(p.prefix(len))
            } else {
                prompt = distinctPrompt(seed: r, length: ctx > 0 ? ctx : 24)
            }
            pending.append(Req(id: r, prompt: prompt, max: maxTokens,
                               priority: (mix != 0 && r % 2 == 1) ? 1 : 0, arrival: Date()))
        }
        let promptsAll = pending.map { $0.prompt }
        let promptDesc = sharedPrefix != nil ? "shared ctx-16 prefix + unique suffix"
            : legacy ? "legacy repeated pattern" : "distinct seeded streams, no shared prefix"

        // Warm weights/kernels before the timed requests so TTFT does not include model load.
        _ = try QwenModel.forward(tokens: Array(pattern.prefix(24)), store: store, cache: ModelCache())
        var prefixCache: ModelCache? = nil
        var prefixWarmS = 0.0
        if let sp = sharedPrefix {
            let pc = ModelCache()
            let t = Date()
            let lg = try QwenModel.forwardAll(tokens: sp, store: store, cache: pc, lastTokenOnly: true).logits
            eval(lg)
            prefixWarmS = Date().timeIntervalSince(t)
            prefixCache = pc.snapshot()
        }

        // Sequential baseline.
        var seqOut = [[Int32]](repeating: [], count: requests)
        let ts0 = Date()
        for r in pending {
            let c = ModelCache()
            var lg = try QwenModel.forwardAll(tokens: r.prompt, store: store, cache: c, lastTokenOnly: true).logits
            var tok = Int32(argMax(lg[0, 0]).item(Int32.self))
            for _ in 0 ..< r.max {
                lg = try QwenModel.forward(tokens: [tok], store: store, cache: c).logits
                tok = Int32(argMax(lg).item(Int32.self))
                seqOut[r.id].append(tok)
                if tok == 248044 || tok == 248046 { break }
            }
        }
        let seqWall = Date().timeIntervalSince(ts0)
        let seqCompletion = seqOut.reduce(0) { $0 + $1.count + 1 }

        // Batched scheduler. All requests arrive together here; timings are measured from tb0.
        let tb0 = Date()
        for i in pending.indices { pending[i].arrival = tb0 }
        struct Active { let id: Int; let priority: Int; let cache: ModelCache; var next: Int32
                        let promptTokens: Int; let max: Int; let arrival: Date; let admit: Date
                        let first: Date; var emitted: Int; var out: [Int32] }
        var active: [Active] = []
        let bc = BatchedModelCache()
        var rows: [BenchRow] = []
        var done = 0
        var batchedOut = [[Int32]](repeating: [], count: requests)
        let eos: Set<Int32> = [248044, 248046]
        while !pending.isEmpty || !active.isEmpty {
            while !pending.isEmpty && active.count < slots {
                let pick = pending.firstIndex(where: { $0.priority == 0 }) ?? 0
                let r = pending.remove(at: pick)
                let admit = Date()
                var c = ModelCache()
                let tok: Int32
                if let pc = prefixCache, let sp = sharedPrefix {
                    c = pc.snapshot()
                    let suffix = Array(r.prompt.dropFirst(sp.count))
                    let lg = try QwenModel.forwardAll(tokens: suffix, store: store, cache: c,
                                                      lastTokenOnly: true).logits
                    tok = Int32(argMax(lg[0, 0]).item(Int32.self))
                } else {
                    let lg = try QwenModel.forwardAll(tokens: r.prompt, store: store, cache: c,
                                                      lastTokenOnly: true).logits
                    tok = Int32(argMax(lg[0, 0]).item(Int32.self))
                }
                let first = Date()
                bc.append(c)
                active.append(Active(id: r.id, priority: r.priority, cache: c, next: tok,
                                     promptTokens: r.prompt.count, max: r.max, arrival: r.arrival,
                                     admit: admit, first: first, emitted: 0, out: []))
            }
            if active.isEmpty { break }
            let lg = try BatchModel.forward(tokens: active.map { [$0.next] },
                                            store: store, cache: bc)
            let vals = argMax(lg, axis: -1).asArray(Int32.self)
            let now = Date()
            var drop = Set<Int>()
            for b in active.indices {
                active[b].next = vals[b]
                active[b].out.append(vals[b])
                active[b].emitted += 1
                if active[b].emitted >= active[b].max || eos.contains(vals[b]) {
                    let a = active[b]
                    batchedOut[a.id] = a.out
                    let completion = a.emitted + 1
                    let decodeS = now.timeIntervalSince(a.first)
                    rows.append(BenchRow(
                        id: a.id, promptTokens: a.promptTokens, priority: a.priority,
                        queueWait: a.admit.timeIntervalSince(a.arrival),
                        prefill: a.first.timeIntervalSince(a.admit),
                        ttft: a.first.timeIntervalSince(a.arrival),
                        end: now.timeIntervalSince(a.arrival),
                        decodeTps: completion > 1 && decodeS > 0 ? Double(completion - 1) / decodeS : 0,
                        completion: completion))
                    drop.insert(b); done += 1
                }
            }
            if !drop.isEmpty {
                bc.remove(indices: drop)
                active = active.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
            }
        }
        let batchWall = Date().timeIntervalSince(tb0)
        rows.sort { $0.id < $1.id }
        let completionTotal = rows.reduce(0) { $0 + $1.completion }

        print(String(format: "requests %ld  slots %ld  maxTokens %ld  done %ld  prefixWarm %.2fs",
                     requests, slots, maxTokens, done, prefixWarmS))
        print("prompts: \(promptDesc)")
        print(String(format: "sequential wall %.2f s  %.1f tok/s aggregate", seqWall,
                     Double(seqCompletion) / seqWall))
        print("")
        print("  id  prompt  queue_s  prefill_s    ttft_s     end_s  decode_tok/s  completion" + (mix != 0 ? "  class" : ""))
        for r in rows {
            let cls = mix != 0 ? (r.priority == 0 ? "  int" : "  bg") : ""
            print(String(format: "%4ld %7ld %8.3f %10.3f %9.3f %9.3f %13.1f %11ld",
                         r.id, r.promptTokens, r.queueWait, r.prefill, r.ttft, r.end, r.decodeTps,
                         r.completion) + cls)
        }
        print("")
        let ttfts = rows.map { $0.ttft }, ends = rows.map { $0.end }
        print(String(format: "batched    wall %.2f s  %.1f tok/s aggregate  (%ld completion tokens)  decode median %.1f tok/s/req",
                     batchWall, Double(completionTotal) / batchWall, completionTotal,
                     median(rows.map { $0.decodeTps })))
        print(String(format: "TTFT median %.3f s  max %.3f s   end-to-end median %.3f s  max %.3f s",
                     median(ttfts), ttfts.max() ?? .nan, median(ends), ends.max() ?? .nan))
        if mix != 0 {
            let inter = rows.filter { $0.priority == 0 }.map { $0.ttft }
            let bg = rows.filter { $0.priority != 0 }.map { $0.ttft }
            print(String(format: "TTFT median interactive %.3f s (%ld)  background %.3f s (%ld)",
                         median(inter), inter.count, median(bg), bg.count))
        }
        let uniquePrefixes = Set(promptsAll.map { Array($0.prefix(16)) }).count
        print("prompt lengths: " + equalOrRange(promptsAll.map { $0.count }, unit: "tokens")
              + "   completion tokens: " + equalOrRange(rows.map { $0.completion }, unit: "tokens")
              + "   first-16 prefixes unique: " + (sharedPrefix != nil ? "n/a (shared)"
                  : (uniquePrefixes == requests ? "yes" : "no (\(uniquePrefixes)/\(requests))")))

        var firstDiff = "none"
        for i in 0 ..< requests where seqOut[i] != batchedOut[i] {
            var j = 0
            while j < min(seqOut[i].count, batchedOut[i].count) && seqOut[i][j] == batchedOut[i][j] { j += 1 }
            let a = j < seqOut[i].count ? "\(seqOut[i][j])" : "end"
            let b = j < batchedOut[i].count ? "\(batchedOut[i][j])" : "end"
            firstDiff = "req \(i) at \(j): seq \(a) batched \(b)"
            break
        }
        if let dumpPath = ProcessInfo.processInfo.environment["STRIM_DUMP_TOKENS"] {
            let lines = (0 ..< requests).map { id in
                "\(id): " + batchedOut[id].map { String($0) }.joined(separator: " ")
            }
            try (lines.joined(separator: "\n") + "\n").write(toFile: dumpPath, atomically: true, encoding: .utf8)
        }
        print("tokens match sequential:", firstDiff == "none" ? "yes" : "no — \(firstDiff)")
    } catch {
        FileHandle.standardError.write(Data("benchserve failed: \(error)\n".utf8)); exit(1)
    }
}
