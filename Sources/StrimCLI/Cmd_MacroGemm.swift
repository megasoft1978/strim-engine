import Foundation
import MLX
import MLXRandom
import StrimCore
import StrimBenchHTTP
import StrimEngine
import StrimTokenizer

// Isolated S3 spike. Real weights, four 1024-row QMMs versus one 4096-row
// dequantize-to-bf16 + dense matmul. Never retains a dense weight between calls.
func runMacroGemm(_ args: [String]) {
    guard args.count >= 3 else { print("usage: strim benchmacrogemm <model> [reps=3] [layers=4]"); exit(2) }
    let reps = args.count > 3 ? Int(args[3]) ?? 3 : 3
    let layers = args.count > 4 ? Int(args[4]) ?? 4 : 4
    guard reps > 0, (1...4).contains(layers) else { exit(2) }
    let lock = GPULock(path: "/tmp/strim-bench.lock")
    // Acquire before model materialization, random initialization, or any GPU work.
    while !lock.tryAcquire() {
        if let e = lock.openError { print(e); exit(1) }
        Thread.sleep(forTimeInterval: 0.25)
    }
    defer { lock.release() }
    func emit(_ row: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
    func load() -> [Double] { var v = [Double](repeating: 0, count: 3); _ = getloadavg(&v, 3); return v }
    func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        typealias Q = (w: MLXArray, s: MLXArray, b: MLXArray)
        func q(_ name: String) throws -> Q {
            let w = try store.tensor(name + ".weight"), s = try store.tensor(name + ".scales")
            let spec = try store.quantSpec(name, w: w, s: s)
            guard spec.bits == 4, spec.groupSize == 64 else { throw WeightError.missingTensor("S3 requires affine 4-bit group64: " + name) }
            return (w, s, try store.tensor(name + ".biases"))
        }
        let L = "language_model.model.layers."
        let gd = Array([0, 1, 2, 4].prefix(layers)), at = Array([3, 7, 11, 15].prefix(layers))
        // L0 table16k pipelined costs. Split projection groups by their GEMM work.
        let shapes: [(String, Int, Int, [Int], String, Double)] = [
            ("mlp.gateup", 5120, 34816, gd, "mlp", 6510.6),
            ("mlp.down", 17408, 5120, gd, "mlp.down_proj", 3538.9),
            ("gdn.qkv", 5120, 10240, gd, "linear_attn.in_proj_qkv", 2337.0 * 10 / 16),
            ("gdn.z", 5120, 6144, gd, "linear_attn.in_proj_z", 2337.0 * 6 / 16),
            ("gdn.out", 6144, 5120, gd, "linear_attn.out_proj", 875.5),
            ("gdn.b", 5120, 48, gd, "linear_attn.in_proj_b", 43.1),
            ("gdn.a", 5120, 48, gd, "linear_attn.in_proj_a", 43.1),
            ("attn.q", 5120, 12288, at, "self_attn.q_proj", 681.2 * 12 / 14),
            ("attn.k", 5120, 1024, at, "self_attn.k_proj", 681.2 / 14),
            ("attn.v", 5120, 1024, at, "self_attn.v_proj", 681.2 / 14),
            ("attn.o", 6144, 5120, at, "self_attn.o_proj", 288.3),
        ]
        MLXRandom.seed(20261030)
        emit(["type": "meta", "device": Compute.deviceName, "reps": reps, "layers": layers,
              "macro_m": 4096, "sub_m": 1024, "cycles": 2, "schedule": "ABBAABBA",
              "A": "four qmm1024", "B": "dequant bf16 + dense4096", "load": load(),
              "lock": lock.path, "plain16k_ms": 17335.0, "noise_floor_pct": 1.5])
        var saved = 0.0, predictedA = 0.0, predictedB = 0.0
        for (name, k, n, ids, suffix, share) in shapes {
            let ws: [Q] = try ids.map { l in
                if name == "mlp.gateup" { return try store.mlpFused(l) }
                return try q(L + "\(l)." + suffix)
            }
            for w in ws {
                guard w.w.shape == [n, k / 8], w.s.dtype == .bfloat16, w.b.dtype == .bfloat16 else {
                    throw WeightError.missingTensor("unexpected S3 shape/dtype: " + name)
                }
                eval(w.w, w.s, w.b)
            }
            let x = (MLXRandom.normal([1, 4096, k]) * 0.1).asType(.bfloat16)
            eval(x)
            let xs = (0..<4).map { x[0..., ($0 * 1024)..<(($0 + 1) * 1024), 0...] }
            eval(xs)
            func run(_ arm: String, _ w: Q) {
                if arm == "A" {
                    let ys = xs.map { quantizedMatmul($0, w.w, scales: w.s, biases: w.b, transpose: true, groupSize: 64, bits: 4) }
                    eval(ys)
                } else {
                    let wd = dequantized(w.w, scales: w.s, biases: w.b, groupSize: 64, bits: 4).asType(.bfloat16)
                    eval(matmul(x, wd.transposed(-1, -2)))
                }
            }
            // Compile and warm both paths; measurements construct fresh graphs and dequantize anew.
            for arm in ["A", "B"] { for w in ws { run(arm, w) } }
            var blocksA: [Double] = [], blocksB: [Double] = []
            for (block, arm) in ["A", "B", "B", "A", "A", "B", "B", "A"].enumerated() {
                var samples: [Double] = []
                let loadBefore = load()
                for rep in 0..<reps {
                    let t = now()
                    for w in ws { run(arm, w) }
                    let dt = Double(now() - t) / 1e6 / Double(layers)
                    samples.append(dt)
                    emit(["type": "sample", "shape": name, "arm": arm, "block": block, "rep": rep,
                          "ms": dt, "tflops": 2 * Double(4096 * k * n) / dt / 1e9])
                }
                let m = median(samples)
                if arm == "A" { blocksA.append(m) } else { blocksB.append(m) }
                emit(["type": "block", "shape": name, "arm": arm, "block": block,
                      "median_ms": m, "load_before": loadBefore, "load_after": load()])
            }
            // Dedicated peak probes, outside timing. Clear allocator cache, retaining the exact
            // same quantized weights and inputs for each arm. Peak is active MLX bytes, not RSS.
            var peaks: [String: Int] = [:]
            for arm in ["A", "B"] {
                Memory.clearCache(); Memory.peakMemory = 0
                let base = Memory.activeMemory
                for w in ws { run(arm, w) }
                peaks[arm] = Memory.peakMemory
                emit(["type": "memory", "shape": name, "arm": arm, "base_bytes": base,
                      "peak_active_bytes": Memory.peakMemory, "incremental_peak_bytes": Memory.peakMemory - base,
                      "end_cache_bytes": Memory.cacheMemory])
            }
            // Dequant-only wall reported separately, never subtracted from inclusive B.
            var dq: [Double] = []
            for _ in 0..<reps {
                let t = now()
                for w in ws { eval(dequantized(w.w, scales: w.s, biases: w.b, groupSize: 64, bits: 4).asType(.bfloat16)) }
                dq.append(Double(now() - t) / 1e6 / Double(layers))
            }
            let a = exp(blocksA.map(log).reduce(0, +) / 4), b = exp(blocksB.map(log).reduce(0, +) / 4)
            saved += share * (1 - b / a)
            let count = name.hasPrefix("mlp") ? 64.0 : (name.hasPrefix("gdn") ? 48.0 : 16.0)
            predictedA += a * count * 4; predictedB += b * count * 4
            var cycleGains: [Double] = [], noise = 0.0
            for c in 0..<2 {
                let aa = Array(blocksA[(c*2)..<(c*2+2)]), bb = Array(blocksB[(c*2)..<(c*2+2)])
                cycleGains.append((sqrt(aa[0]*aa[1]/bb[0]/bb[1]) - 1)*100)
                noise = max(noise, abs(aa[1]/aa[0]-1)*100, abs(bb[1]/bb[0]-1)*100)
            }
            emit(["type": "shape", "shape": name, "K": k, "N": n, "q4x1024_ms": a,
                  "dequant_dense4096_ms": b, "dequant_only_ms": median(dq),
                  "q_tflops": 2 * Double(4096 * k * n) / a / 1e9,
                  "dense_inclusive_tflops": 2 * Double(4096 * k * n) / b / 1e9,
                  "gain_pct": (a/b-1)*100, "cycle_gain_pct": cycleGains, "same_arm_noise_pct": noise,
                  "table16k_ms": share, "saved16k_ms": share*(1-b/a),
                  "A_peak_bytes": peaks["A"]!, "B_peak_bytes": peaks["B"]!])
        }
        let gain = (17335.0 / (17335.0 - saved) - 1) * 100
        emit(["type": "projection", "method": "L0 table16k Amdahl; other regions unchanged; no macro scheduling overhead",
              "saved16k_ms": saved, "projected_prefill_gain_pct": gain,
              "micro_main_q16k_ms": predictedA, "micro_main_dense16k_ms": predictedB,
              "kill_below_pct": 1.5, "verdict": gain < 1.5 ? "KILL" : "PROMISING", "load": load()])
    } catch {
        FileHandle.standardError.write(Data("benchmacrogemm failed: \(error)\n".utf8)); exit(1)
    }
}

// Drives the actual EngineCore cold-prefill path, including default MTP head seeding,
// prefix snapshots and admission. No HTTP transport is included in the prefill metric.
func runMacroPrefillBench(_ args: [String]) {
    guard args.count >= 4 else { print("usage: strim benchmacroprefill <model> <head> [reps=2]"); exit(2) }
    let reps = args.count > 4 ? Int(args[4]) ?? 2 : 2
    exitAsync {
        let lock = GPULock(path: "/tmp/strim-bench.lock")
        guard await lock.acquire() else { throw NSError(domain: "S3 lock", code: 1) }
        defer { lock.release() }
        let c = try await LocalEngineClient.start(EngineConfig.fromEnvironment(modelDir: args[2], headDir: args[3]))
        do {
            let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "bench/ab_prompts.json"))) as! [String: String]
            let base = try await c.perform { ctx in try ctx.tokenizer.encode(corpus["natural"]!) }
            func once(_ n: Int, _ rep: Int, warm: Bool = false) async throws {
                try await c.resetPrefixCache()
                let ids = (0..<n).map { base[($0 + max(rep, 0)) % base.count] }
                let s = try await c.openSession(SessionConfig(enableThinking: false))
                _ = try await c.append(s, .ids(ids))
                let memoryBase = try await c.perform { _ in Memory.clearCache(); Memory.peakMemory = 0; return Memory.activeMemory }
                var loads = [Double](repeating: 0, count: 3); _ = getloadavg(&loads, 3)
                var usage = Usage()
                var generated: [Int32] = []
                let t = DispatchTime.now().uptimeNanoseconds
                for try await e in c.generate(s, GenParams(maxTokens: 16, seed: 20261027, ignoreEOS: true)) {
                    if case let .finished(_, u) = e { usage = u }
                    if case let .tokens(toks, _) = e { generated += toks }
                }
                let wall = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9
                let peak = try await c.perform { _ in Memory.peakMemory }
                let row: [String: Any] = ["type": warm ? "warmup" : "prefill", "macro": MacroPrefill.enabled,
                    "tokens": n, "rep": rep, "prefill_s": usage.prefillSeconds,
                    "tok_s": Double(n) / usage.prefillSeconds, "ttft_s": usage.ttft, "wall_s": wall,
                    "cached_tokens": usage.cachedTokens, "peak_active_bytes": peak, "base_active_bytes": memoryBase,
                    "load": loads, "generated": generated, "chunk": PrefixPrefill.defaultPolicy.maxBlock]
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                FileHandle.standardOutput.write(data + Data([10]))
                await c.close(s)
            }
            try await once(4096, -1, warm: true)
            for n in [4096, 16384, 32768] { for r in 0..<reps { try await once(n, r) } }
            await c.shutdown()
            return 0
        } catch {
            await c.shutdown()
            throw error
        }
    }
}

// Full-vocabulary final-position logits and greedy gen16, both the original
// bench prompts and 4096-token repetitions that actually exercise the macro path.
func runMacroQuality(_ args: [String]) {
    guard args.count >= 4 else { print("usage: strim checkmacroquality <model> <out> [reference-out]"); exit(2) }
    let lock = GPULock(path: "/tmp/strim-bench.lock")
    while !lock.tryAcquire() {
        if let e = lock.openError { print(e); exit(1) }
        Thread.sleep(forTimeInterval: 0.25)
    }
    defer { lock.release() }
    do {
        let out = URL(fileURLWithPath: args[3])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let tok = try Tokenizer.load(modelDir: args[2])
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "bench/ab_prompts.json"))) as! [String: String]
        func top5(_ a: [Float]) -> [Int] {
            var best: [Int] = []
            for i in a.indices {
                if best.count == 5 && a[i] <= a[best.last!] { continue }
                best.append(i); best.sort { a[$0] == a[$1] ? $0 < $1 : a[$0] > a[$1] }
                if best.count > 5 { best.removeLast() }
            }
            return best
        }
        for name in corpus.keys.sorted() {
            let base = tok.encode(corpus[name]!)
            for n in [base.count, 4096] {
                let ids = (0..<n).map { base[$0 % base.count] }
                let c = ModelCache()
                var lg: MLXArray! = nil
                var pos = 0
                while pos < n {
                    let cut = PrefixPrefill.defaultPolicy.blockEnd(ids, from: pos, limit: n) ?? n
                    let r = try QwenModel.forwardAll(tokens: Array(ids[pos..<cut]), store: store, cache: c, lastTokenOnly: true)
                    eval(r.logits, c); lg = r.logits[0, 0]; pos = cut
                }
                let values = lg.asType(.float32).asArray(Float.self)
                let label = "\(name)-\(n)"
                try values.withUnsafeBytes { Data($0) }.write(to: out.appendingPathComponent(label + ".bin"))
                var gen: [Int32] = [], next = argMax(lg).item(Int32.self)
                for step in 0..<16 {
                    gen.append(next)
                    if step < 15 { next = argMax(try QwenModel.forward(tokens: [next], store: store, cache: c).logits).item(Int32.self) }
                }
                var row: [String: Any] = ["label": label, "prompt_tokens": n, "generated": gen, "macro": MacroPrefill.enabled]
                if args.count > 4 {
                    let refURL = URL(fileURLWithPath: args[4]).appendingPathComponent(label + ".bin")
                    let ref = try Data(contentsOf: refURL).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    guard ref.count == values.count else { throw NSError(domain: "S3 logit count", code: 1) }
                    var maxDiff = 0.0, meanDiff = 0.0
                    let rm = Double(ref.max()!), qm = Double(values.max()!)
                    let rz = log(ref.reduce(0.0) { $0 + exp(Double($1)-rm) }) + rm
                    let qz = log(values.reduce(0.0) { $0 + exp(Double($1)-qm) }) + qm
                    var kl = 0.0
                    for i in ref.indices {
                        let d = abs(Double(ref[i])-Double(values[i])); maxDiff = max(maxDiff, d); meanDiff += d
                        let lp = Double(ref[i])-rz, lq = Double(values[i])-qz
                        kl += exp(lp)*(lp-lq)
                    }
                    let rt = top5(ref), qt = top5(values)
                    let refRow = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[4]).appendingPathComponent(label + ".json"))) as! [String: Any]
                    let refGen = (refRow["generated"] as! [NSNumber]).map { $0.int32Value }
                    row["max_abs_diff"] = maxDiff; row["mean_abs_diff"] = meanDiff / Double(ref.count)
                    row["kl_ref_to_flag"] = kl; row["top1_agree"] = rt[0] == qt[0]
                    row["top5_overlap"] = Set(rt).intersection(Set(qt)).count
                    row["top5_exact_set"] = Set(rt) == Set(qt)
                    row["greedy_agree_count"] = zip(refGen, gen).filter { $0 == $1 }.count
                    row["greedy_exact"] = refGen == gen
                }
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                try data.write(to: out.appendingPathComponent(label + ".json"))
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
    } catch {
        FileHandle.standardError.write(Data("checkmacroquality failed: \(error)\n".utf8)); exit(1)
    }
}
