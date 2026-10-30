import Foundation
import MLX
import StrimCore
import StrimEngine
import StrimTemplate
import StrimTokenizer

// strim enginebench <model> [mtpHead] [--only=single,four,prio,cancel,session,parity,concurrent-decode]
// strim chat <model> [mtpHead]
//
// Both drive the engine ONLY through LocalEngineClient (one engine thread owns MLX); this
// process's main thread never touches MLX.

private func blocking(_ body: @escaping @Sendable () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await body(); sem.signal() }
    sem.wait()
}

private func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
private func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

private func parseModelArgs(_ args: [String]) -> (model: String, head: String?, only: Set<String>?) {
    let model = args[2]
    var head: String? = nil
    var only: Set<String>? = nil
    for a in args.dropFirst(3) {
        if a.hasPrefix("--only=") { only = Set(a.dropFirst(7).split(separator: ",").map(String.init)) }
        else if !a.hasPrefix("--") { head = a }
    }
    return (model, head, only)
}

// MARK: helpers

private func distinct(seed: Int, length: Int) -> [Int32] {
    var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1B5_4A32_D192_ED03
    var o: [Int32] = []
    o.reserveCapacity(length)
    for _ in 0 ..< length {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        o.append(Int32(100 + z % 19_900))
    }
    return o
}

private let words = ["server", "request", "cache", "token", "buffer", "kernel", "latency", "engine", "session",
                     "prefix", "ledger", "stream", "thread", "memory", "batch", "decode", "prefill", "model",
                     "layer", "queue", "error", "retry", "commit", "branch", "deploy", "config", "metric",
                     "index", "socket", "worker", "trace", "build"]

private func synthText(seed: Int, words n: Int) -> String {
    var s = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
    var out: [String] = []
    for i in 0 ..< n {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        out.append(words[Int(s >> 33) % words.count])
        if i % 17 == 16 { out[out.count - 1] += "." }
    }
    return out.joined(separator: " ")
}

private func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted(); let m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
}

private struct RunResult: Sendable {
    var gen: [Int32] = []
    var content = ""
    var reasoning = ""
    var usage = Usage()
    var reason: FinishReason?
    var tFirst = Double.nan
    var tEnd = 0.0
    var decodeTps: Double {
        usage.decodeSeconds > 0 ? Double(max(usage.completionTokens - 1, 0)) / usage.decodeSeconds : 0
    }
}

private func collect(_ c: LocalEngineClient, _ s: SessionID, _ p: GenParams, t0: Date = Date()) async throws -> RunResult {
    var r = RunResult()
    for try await ev in c.generate(s, p) {
        switch ev {
        case let .tokens(ids, text):
            if r.tFirst.isNaN { r.tFirst = Date().timeIntervalSince(t0) }
            r.gen += ids; r.content += text
        case let .reasoning(t):
            if r.tFirst.isNaN { r.tFirst = Date().timeIntervalSince(t0) }
            r.reasoning += t
        case .toolCallBegin, .toolCallArg, .toolCallEnd, .toolCallError: break
        case let .finished(reason, u): r.reason = reason; r.usage = u
        }
    }
    r.tEnd = Date().timeIntervalSince(t0)
    return r
}

private func scenario(_ label: String, _ body: () async throws -> Int) async -> Int {
    print("== \(label)")
    do { return try await body() } catch {
        print("  FAILED: \(error)")
        return 1
    }
}

private func check(_ ok: Bool, _ msg: String) -> Int {
    print("  [\(ok ? "PASS" : "FAIL")] \(msg)")
    return ok ? 0 : 1
}

// MARK: enginebench

func runEngineBench(_ args: [String]) {
    guard args.count >= 3 else { err("usage: strim enginebench <model> [mtpHead] [--only=...]"); exit(1) }
    let (model, headDir, only) = parseModelArgs(args)
    @Sendable func want(_ n: String) -> Bool { only?.contains(n) ?? true }
    blocking {
        do {
            let cfg = EngineConfig.fromEnvironment(modelDir: model, headDir: headDir)
            let t0 = Date()
            let c = try await LocalEngineClient.start(cfg)
            print(String(format: "engine ready in %.1fs  head=%@  hot=%d  trie=%@  budget=%.0f GB", Date().timeIntervalSince(t0),
                         headDir ?? "none", cfg.hotSessions, cfg.prefixCacheBytes.map { "\($0 >> 20) MB" } ?? "off",
                         Double(cfg.memoryBudgetBytes) / 1e9))
            var failures = 0
            if only?.contains("concurrent-decode") == true { failures += await benchConcurrentDecode(c, hasHead: headDir != nil) }
            if want("single") { failures += await benchSingle(c, hasHead: headDir != nil) }
            if only?.contains("sampled") == true { failures += await benchSampled(c, hasHead: headDir != nil) }
            if want("parity") { failures += await benchParity(c, hasHead: headDir != nil) }
            if only?.contains("long") == true { failures += await benchLong(c) }
            if want("four") { failures += await benchFour(c) }
            if want("prio") { failures += await benchPriority(c) }
            if want("cancel") { failures += await benchCancel(c) }
            if want("session") { failures += await benchSession(c, hasHead: headDir != nil) }
            let st = c.stats()
            print(String(format: "stats: healthy=%@ units=%d trie=%d MB/%d nodes mlxPeak=%.1f GB",
                         st.healthy ? "yes" : "NO", st.unitsRun, st.trieBytes >> 20, st.trieNodes, Double(st.mlxPeakBytes) / 1e9))
            await c.shutdown()
            print(failures == 0 ? "enginebench: ALL PASS" : "enginebench: \(failures) FAILED")
            if failures > 0 { exit(2) }
        } catch {
            err("enginebench failed: \(error)"); exit(1)
        }
    }
}

/// Opt-in (`--only=concurrent-decode`): B concurrent short-prompt requests under each decode policy
/// (batch / roundrobin / auto), interleaved rounds. Env: STRIM_CD_ROUNDS (4), STRIM_CD_TOKENS (160),
/// STRIM_CD_B ("2,3,4"), STRIM_CD_MIX ("code,prose,mixed"), STRIM_CD_MODE ("greedy,sampled"),
/// STRIM_CD_POLICIES ("batch,roundrobin,auto").
private func benchConcurrentDecode(_ c: LocalEngineClient, hasHead: Bool) async -> Int {
    guard hasHead else { print("== concurrent-decode: skipped (needs head)"); return 0 }
    return await scenario("concurrent decode: batch vs roundrobin vs auto") {
        let env = ProcessInfo.processInfo.environment
        func list(_ k: String, _ d: String) -> [String] { (env[k] ?? d).split(separator: ",").map(String.init) }
        let rounds = Int(env["STRIM_CD_ROUNDS"] ?? "") ?? 4
        let nTok = Int(env["STRIM_CD_TOKENS"] ?? "") ?? 160
        let bs = list("STRIM_CD_B", "2,3,4").compactMap(Int.init)
        let mixes = list("STRIM_CD_MIX", "code,prose,mixed")
        let modes = list("STRIM_CD_MODE", "greedy,sampled")
        let policies = list("STRIM_CD_POLICIES", "batch,roundrobin,auto")
        let code = [
            "Write a Python class implementing a binary search tree with insert, search, delete and in-order traversal methods, with type hints and docstrings.",
            "Write a TypeScript module that defines an LRU cache class with get, set and delete methods, generics, and unit tests using vitest.",
            "Write a Swift struct implementing a thread-safe ring buffer with push, pop, count and capacity, and a few XCTest cases.",
            "Write a Go package with an HTTP middleware that logs request method, path, status and duration, plus a table-driven test.",
        ]
        let prose = [
            "Write a reflective essay about the feeling of the first cold morning of autumn and what it does to memory.",
            "Describe, in flowing prose, a walk through a night market in a city you have invented. Focus on smells and sounds.",
            "Write a short story about a lighthouse keeper who discovers that the light has been answering someone.",
            "Explain in plain language why people argue about whether a hot dog is a sandwich, and what it says about categories.",
        ]
        func prompts(_ mix: String, _ b: Int) -> [String] {
            (0 ..< b).map { i in
                switch mix {
                case "code": return code[i % 4]
                case "prose": return prose[i % 4]
                default: return i % 2 == 0 ? code[(i / 2) % 4] : prose[(i / 2) % 4]
                }
            }
        }
        func params(_ mode: String, _ i: Int) -> GenParams {
            mode == "greedy" ? GenParams(maxTokens: nTok)
                : GenParams(maxTokens: nTok, temperature: 1.0, topP: 0.95, topK: 20, seed: UInt64(100 + i))
        }
        let cfg = SessionConfig(enableThinking: false)
        struct Run { var agg = 0.0; var per: [Double] = []; var ttft: [Double] = []; var gens: [[Int32]] = [] }
        func run(_ policy: String, _ ps: [String], _ mode: String, seeds: [Int]? = nil) async throws -> Run {
            setenv("STRIM_DECODE_POLICY", policy, 1)
            defer { unsetenv("STRIM_DECODE_POLICY") }
            try await c.resetPrefixCache()
            var sessions: [SessionID] = []
            for p in ps {
                let s = try await c.openSession(cfg)
                _ = try await c.append(s, .messages([.user(p)]))
                sessions.append(s)
            }
            let t0 = Date()
            let res: [RunResult] = try await withThrowingTaskGroup(of: (Int, RunResult).self) { g in
                for (i, s) in sessions.enumerated() { let gp = params(mode, seeds?[i] ?? i); g.addTask { (i, try await collect(c, s, gp, t0: t0)) } }
                var o = [RunResult](repeating: RunResult(), count: ps.count)
                for try await (i, r) in g { o[i] = r }
                return o
            }
            for s in sessions { await c.close(s) }
            let total = res.reduce(0) { $0 + $1.usage.completionTokens }
            let wall = res.map { $0.tEnd }.max() ?? 1
            var r = Run()
            r.agg = Double(total) / wall
            r.per = res.map { Double($0.usage.completionTokens) / max($0.tEnd, 1e-9) }
            r.ttft = res.map { $0.usage.ttft }
            r.gens = res.map { $0.gen }
            return r
        }
        func rng(_ xs: [Double]) -> String { String(format: "%.1f [%.1f-%.1f]", median(xs), xs.min() ?? 0, xs.max() ?? 0) }
        var fails = 0
        // single-stream references (one request = no batching), per sequence index (sampled seed = index)
        var solo: [String: [Int32]] = [:]
        for mode in modes { for mix in mixes {
            let ps = prompts(mix, bs.max() ?? 2)
            for (i, p) in ps.enumerated() where solo["\(mode)|\(i)|\(p)"] == nil {
                solo["\(mode)|\(i)|\(p)"] = try await run("batch", [p], mode, seeds: [i]).gens[0]
            }
        } }
        var table: [String] = []
        for mode in modes { for mix in mixes { for b in bs {
            let ps = prompts(mix, b)
            var agg: [String: [Double]] = [:], per: [String: [Double]] = [:], tt: [String: [Double]] = [:]
            var identical: [String: Int] = [:]
            var loads: [Double] = []
            _ = try await run("batch", Array(ps.prefix(1)), mode)   // warm
            for rd in 0 ..< rounds {
                let order = policies.indices.map { policies[($0 + rd) % policies.count] }
                for pol in order {
                    var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); loads.append(l[0])
                    let r = try await run(pol, ps, mode)
                    agg[pol, default: []].append(r.agg); per[pol, default: []] += r.per; tt[pol, default: []] += r.ttft
                    for (i, g) in r.gens.enumerated() where g == solo["\(mode)|\(i)|\(ps[i])"] { identical[pol, default: 0] += 1 }
                }
            }
            let base = median(agg["batch"] ?? [])
            for pol in policies {
                let line = String(format: "%@ %@ B=%d %@: agg %@ tok/s (%.2fx)  per-seq %@  ttft %.2fs  identical-to-solo %d/%d",
                                  mode, mix, b, pol.padding(toLength: 10, withPad: " ", startingAt: 0), rng(agg[pol] ?? []),
                                  median(agg[pol] ?? []) / max(base, 1e-9), rng(per[pol] ?? []), median(tt[pol] ?? []),
                                  identical[pol] ?? 0, rounds * b)
                print("  " + line); table.append(line)
            }
            print(String(format: "  (load avg1 min/max %.1f/%.1f)", loads.min() ?? 0, loads.max() ?? 0))
            if mode == "greedy", policies.contains("roundrobin") {
                fails += check(identical["roundrobin"] == rounds * b, "greedy \(mix) B=\(b): roundrobin sequences bitwise == single-stream")
            }
        } } }
        return fails
    }
}

/// Single stream: engine decode rate vs the in-process generateSpec loop on the same thread.
private func benchSingle(_ c: LocalEngineClient, hasHead: Bool) async -> Int {
    await scenario("single stream decode (short prompt, 96 tokens, greedy)") {
        var fails = 0
        let prompt: [Int32] = [9707, 1234, 5678]
        let n = 96
        let ref: ([Int32], [Double]) = try await c.perform { ctx in
            guard let head = ctx.head else {
                let g = try QwenModel.generate(prompt: prompt, maxTokens: n, store: ctx.store)
                return (Array(g.dropFirst(prompt.count)), [])
            }
            var rates: [Double] = []
            var ids: [Int32] = []
            for _ in 0 ..< 4 {
                let (o, st) = try QwenModel.generateSpec(prompt: prompt, maxTokens: n, store: ctx.store, head: head, depth: 2)
                ids = Array(o.dropFirst(prompt.count)); rates.append(st.decodeTokensPerSecond)
            }
            return (ids, Array(rates.dropFirst()))
        }
        var rates: [Double] = []
        var exact = true
        for _ in 0 ..< 4 {
            let s = try await c.openSession(SessionConfig())
            _ = try await c.append(s, .ids(prompt))
            let r = try await collect(c, s, GenParams(maxTokens: n))
            rates.append(r.decodeTps)
            exact = exact && r.gen == ref.0
            await c.close(s)
        }
        rates.removeFirst()
        let eng = median(rates)
        let base = median(ref.1)
        print(String(format: "  engine decode %.1f tok/s (median of 3)   in-process generateSpec %.1f tok/s   ratio %.3f",
                     eng, base, base > 0 ? eng / base : .nan))
        fails += check(exact, "engine greedy ids == in-process reference (\(ref.0.count) tokens)")
        if hasHead { fails += check(base > 0 && eng >= 0.95 * base, "engine decode >= 95% of in-process") }
        // Cold 4K TTFT (also gives the prefill chunk time used to judge cancel latency).
        let p4 = distinct(seed: 77, length: 4096)
        try await c.resetPrefixCache()
        let s = try await c.openSession(SessionConfig())
        _ = try await c.append(s, .ids(p4))
        let r = try await collect(c, s, GenParams(maxTokens: 8))
        print(String(format: "  cold 4K TTFT %.2f s (%.0f tok/s, chunk ~%.0f ms)", r.usage.ttft, 4096 / r.usage.ttft, r.usage.ttft / 4 * 1000))
        let s2 = try await c.openSession(SessionConfig())
        _ = try await c.append(s2, .ids(p4))
        let r2 = try await collect(c, s2, GenParams(maxTokens: 8))
        print(String(format: "  warm 4K TTFT %.2f s cached=%d", r2.usage.ttft, r2.usage.cachedTokens))
        fails += check(r2.gen == r.gen, "trie hit tokens == cold tokens")
        fails += check(r2.usage.cachedTokens == 3072, "trie hit reuses 3 aligned chunks (got \(r2.usage.cachedTokens))")
        await c.close(s); await c.close(s2)
        // Sampling: seeded runs repeat, different seeds differ (plain depth-0 decode).
        func sampled(_ seed: UInt64) async throws -> [Int32] {
            let x = try await c.openSession(SessionConfig())
            _ = try await c.append(x, .ids([9707, 1234, 5678]))
            let r = try await collect(c, x, GenParams(maxTokens: 24, temperature: 0.9, topP: 0.9, topK: 50, seed: seed))
            await c.close(x)
            return r.gen
        }
        let a1 = try await sampled(1), a2 = try await sampled(1), b1 = try await sampled(2)
        fails += check(a1 == a2 && a1.count == 24, "sampled run is reproducible for a fixed seed")
        fails += check(a1 != b1, "different seed -> different sample")
        return fails
    }
}

/// Sampled decode (Qwen defaults: T 1.0, top_k 20, top_p 0.95): speculative sampling with MTP vs
/// sampled depth-0 (STRIM_SAMPLED_DEPTH0), plus a text sanity print. Opt-in: `--only=sampled`.
private func benchSampled(_ c: LocalEngineClient, hasHead: Bool) async -> Int {
    guard hasHead else { print("== sampled: skipped (needs head)"); return 0 }
    return await scenario("sampled decode T=1.0 top_k=20 top_p=0.95 (single stream, 256 tokens)") {
        var fails = 0
        let prompts = [
            "Write a SQL query that returns the top 10 customers by total order value in the last 90 days, including their email and country, ordered descending.",
            "Write a Rust function that reads a file line by line, counts word frequencies, and returns the ten most common words as a Vec of tuples.",
            "A train travels 120 km in 2 hours. If it then travels at the same speed for another 1.5 hours, how far does it travel in total? Show your work.",
            "The key to fast local inference is reading each weight exactly once per token. Continue this essay in two paragraphs.",
        ]
        struct Agg { var tps: [Double] = []; var acc: [Double] = []; var tpp: [Double] = []; var texts: [String] = [] }
        func run(_ label: String, depth0: Bool) async throws -> Agg {
            if depth0 { setenv("STRIM_SAMPLED_DEPTH0", "1", 1) } else { unsetenv("STRIM_SAMPLED_DEPTH0") }
            defer { unsetenv("STRIM_SAMPLED_DEPTH0") }
            var a = Agg()
            for rep in 0 ..< 2 {
                for (i, p) in prompts.enumerated() {
                    let s = try await c.openSession(SessionConfig())
                    _ = try await c.append(s, .messages([.user(p)]))
                    let r = try await collect(c, s, GenParams(maxTokens: 256, temperature: 1.0, topP: 0.95, topK: 20,
                                                              seed: UInt64(1000 * rep + i + 1)))
                    await c.close(s)
                    if rep == 0 && i == 0 { continue }          // warm-up
                    a.tps.append(r.decodeTps)
                    if let m = r.usage.mtpAccept { a.acc.append(m) }
                    if r.usage.mtpPasses > 0 { a.tpp.append(Double(r.usage.completionTokens) / Double(r.usage.mtpPasses)) }
                    if rep == 0 && i < 2 || (rep == 0 && i == 2) { a.texts.append(String((r.reasoning + r.content).prefix(200))) }
                }
            }
            print(String(format: "  %@: %.1f tok/s (median of %d)  accept %.0f%%  tokens/pass %.2f", label, median(a.tps), a.tps.count,
                         a.acc.isEmpty ? 0 : median(a.acc) * 100, a.tpp.isEmpty ? 1 : median(a.tpp)))
            return a
        }
        let spec = try await run("sampled + MTP    ", depth0: false)
        let base = try await run("sampled depth-0  ", depth0: true)
        let ratio = median(spec.tps) / max(median(base.tps), 1e-9)
        print(String(format: "  speedup vs sampled depth-0: %.2fx", ratio))
        for (i, t) in spec.texts.prefix(2).enumerated() {
            print("  sample \(i) (first 200 chars): " + t.replacingOccurrences(of: "\n", with: "\\n"))
        }
        fails += check(!spec.acc.isEmpty && median(spec.acc) > 0, "sampled MTP actually ran speculative rounds")
        fails += check(ratio >= 1.5, "sampled MTP >= 1.5x sampled depth-0")
        return fails
    }
}

/// Chunk stepper vs SpecPrefill.run + SpecStream on the engine thread: cold, then trie hit.
private func benchParity(_ c: LocalEngineClient, hasHead: Bool) async -> Int {
    guard hasHead else { print("== prefill parity: skipped (needs head)"); return 0 }
    return await scenario("engine prefill vs SpecPrefill.run (2600-token prompt, 48 tokens)") {
        var fails = 0
        let p = distinct(seed: 5, length: 2600)
        let n = 48
        try await c.resetPrefixCache()
        let ref: [Int32] = try await c.perform { ctx in
            guard let head = ctx.head else { return [] }
            let o = try SpecPrefill.run(tokens: p, store: ctx.store, head: head, cache: nil)
            let st = SpecStream(store: ctx.store, head: head, cache: o.cache, mtp: o.mtp, seedToken: o.seedToken,
                                lastHidden: o.seedHidden, depth: 2)
            var out: [Int32] = [st.pending]
            while out.count < n { out += try st.step(remaining: n - out.count).dropFirst() + [st.pending] }
            return Array(out.prefix(n))
        }
        var results: [RunResult] = []
        for _ in 0 ..< 2 {
            let s = try await c.openSession(SessionConfig())
            _ = try await c.append(s, .ids(p))
            results.append(try await collect(c, s, GenParams(maxTokens: n)))
            await c.close(s)
        }
        fails += check(results[0].gen == ref, "engine cold == SpecPrefill+SpecStream (\(ref.count) tokens)")
        fails += check(results[1].gen == results[0].gen && results[1].usage.cachedTokens > 0,
                       "engine trie-hit (cached \(results[1].usage.cachedTokens)) == cold")
        return fails
    }
}

/// Opt-in (`--only=long`): one ~40K-token prompt cold, then again; cached tokens show the trie capacity.
private func benchLong(_ c: LocalEngineClient) async -> Int {
    await scenario("40K-token cached session (trie capacity)") {
        var fails = 0
        let n = 40 * 1024 + 100
        let p = distinct(seed: 4040, length: n)
        try await c.resetPrefixCache()
        let s = try await c.openSession(SessionConfig())
        _ = try await c.append(s, .ids(p))
        let r = try await collect(c, s, GenParams(maxTokens: 8))
        print(String(format: "  cold %d tokens TTFT %.1f s", n, r.usage.ttft))
        let st = c.stats()
        print("  trie \(st.trieBytes >> 20) MB / \(st.trieNodes) nodes")
        await c.close(s)
        let s2 = try await c.openSession(SessionConfig())
        _ = try await c.append(s2, .ids(p))
        let r2 = try await collect(c, s2, GenParams(maxTokens: 8))
        print(String(format: "  warm TTFT %.1f s cached=%d", r2.usage.ttft, r2.usage.cachedTokens))
        fails += check(r2.gen == r.gen, "trie hit tokens == cold tokens")
        fails += check(r2.usage.cachedTokens > 19_456, "cached tokens grow past the old 19,456 stall (got \(r2.usage.cachedTokens))")
        await c.close(s2)
        return fails
    }
}

/// 4 concurrent distinct 4K cold requests (benchserve: `benchserve <m> 4 64 4 0 4096`).
private func benchFour(_ c: LocalEngineClient) async -> Int {
    await scenario("4-way cold 4K aggregate (65 completion tokens each; benchserve ref ~13.5 tok/s)") {
        var fails = 0
        try await c.resetPrefixCache()
        var sessions: [SessionID] = []
        for r in 0 ..< 4 {
            let s = try await c.openSession(SessionConfig())
            _ = try await c.append(s, .ids(distinct(seed: r, length: 4096)))
            sessions.append(s)
        }
        let t0 = Date()
        let res: [RunResult] = try await withThrowingTaskGroup(of: (Int, RunResult).self) { g in
            for (i, s) in sessions.enumerated() { g.addTask { (i, try await collect(c, s, GenParams(maxTokens: 65), t0: t0)) } }
            var o = [RunResult](repeating: RunResult(), count: 4)
            for try await (i, r) in g { o[i] = r }
            return o
        }
        let wall = Date().timeIntervalSince(t0)
        let total = res.reduce(0) { $0 + $1.usage.completionTokens }
        for (i, r) in res.enumerated() {
            print(String(format: "  req %d ttft %.2f s end %.2f s completion %d mtpAccept %@", i, r.usage.ttft, r.tEnd,
                         r.usage.completionTokens, r.usage.mtpAccept.map { String(format: "%.2f", $0) } ?? "-"))
        }
        print(String(format: "  wall %.2f s  %.1f tok/s aggregate (%d completion tokens)", wall, Double(total) / wall, total))
        fails += check(res.allSatisfy { $0.usage.completionTokens == 65 }, "all requests completed 65 tokens")
        for s in sessions { await c.close(s) }
        return fails
    }
}

private func benchPriority(_ c: LocalEngineClient) async -> Int {
    await scenario("priority: interactive 512-token request arriving under 3 background 4K requests") {
        var fails = 0
        try await c.resetPrefixCache()
        var bg: [SessionID] = []
        for r in 0 ..< 3 {
            let s = try await c.openSession(SessionConfig())
            _ = try await c.append(s, .ids(distinct(seed: 100 + r, length: 4096)))
            bg.append(s)
        }
        let si = try await c.openSession(SessionConfig())
        _ = try await c.append(si, .ids(distinct(seed: 200, length: 512)))
        let t0 = Date()
        let res: [(Int, RunResult)] = try await withThrowingTaskGroup(of: (Int, RunResult).self) { g in
            for (i, s) in bg.enumerated() {
                g.addTask {
                    var p = GenParams(maxTokens: 32); p.priority = .background
                    return (i, try await collect(c, s, p, t0: t0))
                }
            }
            g.addTask {
                try await Task.sleep(nanoseconds: 700_000_000)
                return (9, try await collect(c, si, GenParams(maxTokens: 32)))
            }
            var o: [(Int, RunResult)] = []
            for try await x in g { o.append(x) }
            return o
        }
        let inter = res.first { $0.0 == 9 }!.1
        let bgs = res.filter { $0.0 != 9 }.map { $0.1 }
        print(String(format: "  interactive ttft %.2f s (end %.2f)", inter.usage.ttft, inter.tEnd))
        for (i, r) in bgs.enumerated() { print(String(format: "  background %d ttft %.2f s (end %.2f)", i, r.usage.ttft, r.tEnd)) }
        fails += check(bgs.allSatisfy { inter.usage.ttft < $0.usage.ttft }, "interactive TTFT < every background TTFT")
        fails += check(bgs.allSatisfy { $0.usage.completionTokens == 32 }, "background requests still complete (paused, not evicted)")
        for s in bg + [si] { await c.close(s) }
        return fails
    }
}

private func benchCancel(_ c: LocalEngineClient) async -> Int {
    await scenario("cancel latency") {
        var fails = 0
        // (a) during a 4K prefill
        try await c.resetPrefixCache()
        let s = try await c.openSession(SessionConfig())
        _ = try await c.append(s, .ids(distinct(seed: 300, length: 4096)))
        let t0 = Date()
        let task = Task { try await collect(c, s, GenParams(maxTokens: 64), t0: t0) }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let tc = Date()
        await c.cancel(s)
        let r = try await task.value
        let lat = r.tEnd - tc.timeIntervalSince(t0)
        print(String(format: "  cancel during prefill: finished(%@) %.0f ms after cancel (one chunk ~1.1 s)", r.reason?.rawValue ?? "?", lat * 1000))
        fails += check(r.reason == .cancelled && lat <= 1.6, "prefill cancel <= one chunk")
        // (b) during decode
        let s2 = try await c.openSession(SessionConfig())
        _ = try await c.append(s2, .ids([9707, 1234, 5678]))
        var tCancel: Date? = nil
        var tokensAfter = 0
        var tEnd = Date()
        var reason: FinishReason?
        var count = 0
        for try await ev in c.generate(s2, GenParams(maxTokens: 4000)) {
            switch ev {
            case let .tokens(ids, _):
                count += ids.count
                if tCancel != nil { tokensAfter += ids.count }
                if count >= 24 && tCancel == nil { tCancel = Date(); await c.cancel(s2) }
            case let .finished(rs, _): reason = rs; tEnd = Date()
            default: break
            }
        }
        let l2 = tEnd.timeIntervalSince(tCancel ?? tEnd)
        print(String(format: "  cancel during decode: finished(%@) %.0f ms after cancel, %d tokens after", reason?.rawValue ?? "?", l2 * 1000, tokensAfter))
        fails += check(reason == .cancelled && l2 < 0.25, "decode cancel <= one decode unit (+ stream hop)")
        // (c) consumer abandons the stream: the engine must release the request
        let s3 = try await c.openSession(SessionConfig())
        _ = try await c.append(s3, .ids([9707, 1234, 5678]))
        let t = Task { for try await _ in c.generate(s3, GenParams(maxTokens: 4000)) {} }
        try await Task.sleep(nanoseconds: 400_000_000)
        t.cancel()
        try await Task.sleep(nanoseconds: 600_000_000)
        fails += check(c.stats().activeRequests == 0, "abandoned stream releases the request (active=\(c.stats().activeRequests))")
        for x in [s, s2, s3] { await c.close(x) }
        return fails
    }
}

private struct Margin: Sendable { var top: Int32; var second: Int32; var margin: Float }

/// 6-turn agent session: ledger + hot state vs cold trie path, teacher-forced on the hot run's ledgers.
private func benchSession(_ c: LocalEngineClient, hasHead: Bool) async -> Int {
    await scenario("6-turn agent session: hot (ledger + resident state) vs cold (trie) path") {
        var fails = 0
        let tool = ToolSpec(name: "run_shell", description: "Run a shell command",
                            parameters: .ordered([("type", .string("object")),
                                                  ("properties", .ordered([("cmd", .ordered([("type", .string("string"))]))])),
                                                  ("required", .array([.string("cmd")]))]))
        let cfg = SessionConfig(tools: [tool])
        let turns = 6
        let gen = GenParams(maxTokens: 32)
        try await c.resetPrefixCache()
        await c.setHotSessions(2)
        let s = try await c.openSession(cfg)
        var hot: [RunResult] = []
        var prompts: [[Int32]] = []
        for t in 0 ..< turns {
            let body = synthText(seed: t, words: 300 + 350 * t)
            let user = Message.user("Turn \(t + 1). Here is the log output:\n" + body + "\nSummarise it in one sentence.")
            _ = try await c.append(s, .messages(t == 0 ? [.system("You are a coding agent. Be concise."), user] : [user]))
            prompts.append(try await c.ledger(s).ids)
            hot.append(try await collect(c, s, gen))
        }
        // cold replay: fresh session per turn on the same ids, hot sessions off, empty trie
        await c.setHotSessions(0)
        try await c.resetPrefixCache()
        var cold: [RunResult] = []
        for t in 0 ..< turns {
            let cs = try await c.openSession(cfg)
            _ = try await c.append(cs, .ids(prompts[t]))
            cold.append(try await collect(c, cs, gen))
            await c.close(cs)
        }
        await c.setHotSessions(2)
        print("  turn  prompt  | hot: cached  ttft_s | cold: cached  ttft_s | speedup | tokens")
        var allEqual = true
        for t in 0 ..< turns {
            let eq = hot[t].gen == cold[t].gen
            allEqual = allEqual && eq
            print(String(format: "  %4d %7d  | %10d %7.3f | %11d %7.3f | %6.2fx | %@", t + 1, prompts[t].count,
                         hot[t].usage.cachedTokens, hot[t].usage.ttft, cold[t].usage.cachedTokens, cold[t].usage.ttft,
                         cold[t].usage.ttft / max(hot[t].usage.ttft, 1e-6), eq ? "identical" : "DIFFER"))
        }
        if hasHead {
            fails += check(hot.dropFirst().allSatisfy { $0.usage.cachedTokens > 0 }, "hot turns 2..6 continue from resident state")
        }
        if !allEqual {
            print("  hot vs cold differ (documented: hot-continue is near-tie-equivalent, not bitwise). Margins on the cold context:")
            for t in 0 ..< turns where hot[t].gen != cold[t].gen {
                let a = hot[t].gen, b = cold[t].gen
                let k = (0 ..< min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
                let ctx = prompts[t] + Array(a.prefix(k))
                let m: Margin = try await c.perform { cx in
                    let r = try PrefixPrefill.run(tokens: ctx, store: cx.store, cache: nil)
                    let v = r.logits.asType(.float32).asArray(Float.self)
                    let idx = v.indices.sorted { v[$0] > v[$1] }
                    return Margin(top: Int32(idx[0]), second: Int32(idx[1]), margin: v[idx[0]] - v[idx[1]])
                }
                print(String(format: "    turn %d: first difference at token %d (hot %d, cold %d); cold top1=%d top2=%d logit margin %.4f",
                             t + 1, k, k < a.count ? a[k] : -1, k < b.count ? b[k] : -1, m.top, m.second, m.margin))
            }
        } else {
            print("  hot and cold greedy tokens identical on all \(turns) turns")
        }
        await c.close(s)
        return fails
    }
}

// MARK: chat

func runEngineChat(_ args: [String]) {
    guard args.count >= 3 else { err("usage: strim chat <model> [mtpHead]"); exit(1) }
    let (model, headDir, _) = parseModelArgs(args)
    blocking {
        do {
            let cfg = EngineConfig.fromEnvironment(modelDir: model, headDir: headDir)
            let c = try await LocalEngineClient.start(cfg)
            let tty = isatty(0) != 0
            var cfgS = SessionConfig()
            var s = try await c.openSession(cfgS)
            let env = ProcessInfo.processInfo.environment
            let maxTokens = Int(env["STRIM_CHAT_MAX"] ?? "") ?? 512
            let temp = Float(env["STRIM_TEMP"] ?? "") ?? 0
            if tty { out("strim chat  (/fork /reset /think on|off /quit)\n") }
            while true {
                if tty { out("> ") }
                guard let line = readLine() else { break }
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if t == "/quit" { break }
                if t == "/reset" {
                    await c.close(s); s = try await c.openSession(cfgS); out("[reset]\n"); continue
                }
                if t == "/fork" {
                    let snap = try await c.ledger(s)
                    s = try await c.fork(s, at: nil)
                    out("[forked at \(snap.messageCount) messages, \(snap.ids.count) ids -> \(s)]\n"); continue
                }
                if t.hasPrefix("/think") {
                    cfgS.enableThinking = t.hasSuffix("off") ? false : t.hasSuffix("on") ? true : nil
                    await c.close(s); s = try await c.openSession(cfgS)
                    out("[thinking \(cfgS.enableThinking.map { $0 ? "on" : "off" } ?? "default"), session reset]\n"); continue
                }
                _ = try await c.append(s, .messages([.user(t)]))
                var inReasoning = false
                for try await ev in c.generate(s, GenParams(maxTokens: maxTokens, temperature: temp, topP: temp > 0 ? 0.95 : 1)) {
                    switch ev {
                    case let .reasoning(r):
                        if !inReasoning { out(tty ? "\u{1B}[2m" : "<think>"); inReasoning = true }
                        out(r)
                    case let .tokens(_, text):
                        if text.isEmpty { break }
                        if inReasoning { out(tty ? "\u{1B}[0m\n" : "</think>\n"); inReasoning = false }
                        out(text)
                    case let .toolCallBegin(name): out("\n[tool_call \(name)]")
                    case let .toolCallArg(k, v): out(" \(k)=\(v.serialized())")
                    case .toolCallEnd: out("\n")
                    case let .toolCallError(message): out("\n\(message)\n")
                    case let .finished(reason, u):
                        if inReasoning { out(tty ? "\u{1B}[0m" : "</think>"); inReasoning = false }
                        out("\n")
                        err(String(format: "[%@ | prompt %d cached %d | %d tokens | ttft %.2fs | %.1f tok/s%@]", reason.rawValue,
                                   u.promptTokens, u.cachedTokens, u.completionTokens, u.ttft,
                                   u.decodeSeconds > 0 ? Double(max(u.completionTokens - 1, 0)) / u.decodeSeconds : 0,
                                   u.mtpAccept.map { String(format: " | mtp %.0f%%", $0 * 100) } ?? ""))
                    }
                }
            }
            await c.shutdown()
        } catch {
            err("chat failed: \(error)"); exit(1)
        }
    }
}
