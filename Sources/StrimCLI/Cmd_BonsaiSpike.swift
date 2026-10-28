import Darwin
import Foundation
import MLX
import StrimCore
import StrimPrompt
import StrimTokenizer

// Lane L17 spike: Prism Ternary-Bonsai-2-27B (2-bit g128 affine + blockwise Hadamard activation rotation).
//   strim bonsaispike unit                         Hadamard transform vs brute-force matrix (bit-exact)
//   strim bonsaispike load <dir>                   every quantized tensor passes the config-driven shape check;
//                                                  per-module .signs tensors equal hadamard.json; footprint
//   strim bonsaispike layers <dir> <ids.txt> [n]   per-layer hidden stats (rms / absmax / non-finite) on n tokens
//   strim bonsaispike nll <dir> <ids.txt> [n]      teacher-forced NLL / ppl of n tokens (rotation-orientation probe)
//   strim bonsaispike gen <dir> <chat.json> [max]  greedy generation (no MTP), prefill / decode tok/s, footprint
//   strim bonsaispike ctx <dir> <ids.txt> <n> [d]  prefill n tokens (2048-chunks), then d decode steps: footprint, tok/s
// Env: STRIM_BONSAI_ORDER (0 = H(x*s), 1 = s*H(x)), STRIM_BONSAI_ACT (bf16 default, the engine GDN Metal kernels are bf16-only; f16, f32),
//      STRIM_BONSAI_CACHE_MB (MLX cache limit), STRIM_BONSAI_CHUNK (prefill chunk, default 2048).

private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

private func gib(_ b: Int) -> String { String(format: "%.2f GiB", Double(b) / 1_073_741_824) }

private func memLine(_ tag: String) -> String {
    "[mem] \(tag) footprint=\(gib(footprint())) mlxActive=\(gib(Memory.activeMemory)) mlxPeak=\(gib(Memory.peakMemory)) mlxCache=\(gib(Memory.cacheMemory))"
}

private func readIds(_ path: String, _ n: Int?) throws -> [Int32] {
    let raw = try String(contentsOfFile: path, encoding: .utf8)
    var ids = raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Int32($0) }
    if let n { while ids.count < n { ids += ids }; ids = Array(ids.prefix(n)) }
    return ids
}

private func unitCheck() -> Bool {
    var ok = true
    for n in [8, 64, 1024] {
        let h = Hadamard.referenceMatrix(n)
        // small integer inputs: every partial sum is exactly representable and the scale is 2^-k for n = 4^k...
        // for n = 8, 1/sqrt(8) is not a power of two, so compare with the matrix applied in float32 with a tolerance of 1 ulp-ish
        var rng = SystemRandomNumberGenerator()
        let rows = 3
        var xs = [Float](repeating: 0, count: rows * n)
        for i in xs.indices { xs[i] = Float(Int.random(in: -8 ... 8, using: &rng)) }
        let signs = (0 ..< n).map { _ in Float(Bool.random(using: &rng) ? 1 : -1) }
        let y = Hadamard.transform(MLXArray(xs, [rows, n]), signs: MLXArray(signs), block: n, outDType: .float32)
        let back = Hadamard.inverse(y, signs: MLXArray(signs), block: n, outDType: .float32)
        eval(y, back)
        let yv = y.asArray(Float.self), bv = back.asArray(Float.self)
        var maxErr: Float = 0, bitExact = true, maxRound: Float = 0
        for r in 0 ..< rows {
            for i in 0 ..< n {
                var acc = 0.0 as Double
                for j in 0 ..< n { acc += Double(h[i * n + j]) * Double(xs[r * n + j] * signs[j]) }
                let ref = Float(acc)
                maxErr = max(maxErr, abs(ref - yv[r * n + i]))
                if ref.bitPattern != yv[r * n + i].bitPattern { bitExact = false }
            }
            for i in 0 ..< n { maxRound = max(maxRound, abs(bv[r * n + i] - xs[r * n + i])) }
        }
        // n = 1024: 1/32 is a power of two and integer sums are exact => must be bit-identical.
        let pass = (n == 1024 ? bitExact : maxErr < 1e-4) && maxRound < 1e-4
        print("hadamard n=\(n) maxErr=\(maxErr) bitExact=\(bitExact) invRoundTripErr=\(maxRound) \(pass ? "PASS" : "FAIL")")
        ok = ok && pass
    }
    return ok
}

private func loadCheck(_ store: WeightStore) throws {
    guard let rot = store.rotation else { throw HadamardError.bad("no hadamard.json in \(store.dir.path)") }
    let names = store.index.weightMap.keys.filter { !$0.hasPrefix("vision_tower") }.sorted()
    var quantized = 0, specs: [String: Int] = [:], signMismatch = 0, signs = 0
    for n in names where n.hasSuffix(".scales") {
        let prefix = String(n.dropLast(".scales".count))
        let spec = try store.quantSpec(prefix)   // validates against the packed shape
        specs["\(spec)", default: 0] += 1
        quantized += 1
    }
    for n in names where n.hasSuffix(".signs") {
        let t = try store.tensor(n)
        let k = t.shape[0]
        guard let ref = rot.signsByWidth[k] else { print("signs \(n): width \(k) not in hadamard.json"); signMismatch += 1; continue }
        if !allClose(t, ref, rtol: 0, atol: 0).item(Bool.self) { signMismatch += 1 }
        signs += 1
    }
    let declared = rot.weightNames.count
    let have = names.filter { $0.hasSuffix(".weight") && rot.weightNames.contains($0) }.count
    print("load: tensors=\(names.count) quantizedModules=\(quantized) specs=\(specs) signTensors=\(signs) signMismatch=\(signMismatch)")
    print("hadamard.json weight_names=\(declared) present=\(have) inverse=\(rot.inverseWeightNames.sorted()) block=\(rot.block) widths=\(rot.signsByWidth.keys.sorted())")
    // every declared module must be quantized; every quantized module must be declared (else the width rule would mis-rotate it)
    let quantNames = Set(names.filter { $0.hasSuffix(".scales") }.map { String($0.dropLast(".scales".count)) + ".weight" })
    let undeclared = quantNames.subtracting(rot.weightNames).subtracting(rot.inverseWeightNames)
    print("quantized-but-undeclared=\(undeclared.count) \(undeclared.sorted().prefix(3)) declared-but-missing=\(rot.weightNames.subtracting(quantNames).count)")
}

private func forwardStats(_ store: WeightStore, tokens: [Int32]) throws {
    var h = try store.embedding("language_model.model.embed_tokens", tokens: tokens).reshaped([1, tokens.count, 5120])
    let cache = ModelCache()
    func stat(_ tag: String, _ h: MLXArray) {
        let f = h.asType(.float32)
        let rms = sqrt((f * f).mean()), mx = abs(f).max()
        let bad = (1 - isFinite(f).asType(.float32)).sum()
        eval(rms, mx, bad)
        print(String(format: "%@ rms=%.3f absmax=%.1f nonfinite=%.0f", tag, rms.item(Float.self), mx.item(Float.self), bad.item(Float.self)))
    }
    stat("embed   ", h)
    for i in 0 ..< 64 {
        h = try DecoderLayer.forward(h, store: store, layer: i, cache: cache)
        eval(h)
        if i < 4 || i % 8 == 7 { stat(String(format: "layer %2d", i), h) }
    }
    let n = try store.rmsNorm("language_model.model.norm", h)
    stat("final   ", n)
}

private func nll(_ store: WeightStore, _ ids: [Int32]) throws -> (Double, Double) {
    let r = try QwenModel.forwardAll(tokens: ids, store: store, cache: ModelCache())
    let lg = r.logits[0, 0 ..< (ids.count - 1), 0...].asType(.float32)
    let lp = lg - lg.logSumExp(axis: -1, keepDims: true)
    let tgt = MLXArray(Array(ids[1...])).reshaped([ids.count - 1, 1])
    let picked = takeAlong(lp, tgt, axis: -1).reshaped([ids.count - 1])
    let top1 = (argMax(lg, axis: -1) .== MLXArray(Array(ids[1...]))).asType(.float32).mean()
    let m = (-picked).mean()
    eval(m, top1)
    return (Double(m.item(Float.self)), Double(top1.item(Float.self)))
}

private func decodeLoop(_ store: WeightStore, prompt: [Int32], max: Int, stop: Set<Int32>, chunk: Int = Int(ProcessInfo.processInfo.environment["STRIM_BONSAI_CHUNK"] ?? "") ?? 2048)
    throws -> (out: [Int32], prefill: Double, decode: Double, tokps: Double, peakFootprint: Int) {
    let cache = ModelCache()
    var peak = footprint()
    let t0 = Date()
    var logits = MLXArray(0)
    var p = 0
    while p < prompt.count {
        let e = Swift.min(prompt.count, p + chunk)
        logits = try QwenModel.forwardAll(tokens: Array(prompt[p ..< e]), store: store, cache: cache, lastTokenOnly: true).logits
        eval(logits)
        Memory.clearCache()
        peak = Swift.max(peak, footprint())
        p = e
    }
    let prefill = Date().timeIntervalSince(t0)
    var out: [Int32] = []
    let t1 = Date()
    var next = Int32(argMax(logits.reshaped([-1])).item(Int32.self))
    while out.count < max {
        out.append(next)
        if stop.contains(next) { break }
        logits = try QwenModel.forwardAll(tokens: [next], store: store, cache: cache, lastTokenOnly: true).logits
        next = Int32(argMax(logits.reshaped([-1])).item(Int32.self))
        peak = Swift.max(peak, footprint())
    }
    let dec = Date().timeIntervalSince(t1)
    return (out, prefill, dec, Double(out.count) / dec, peak)
}

func runBonsaiSpike(_ args: [String]) {
    setvbuf(stdout, nil, _IOLBF, 0)
    let usage = "usage: strim bonsaispike unit | load <dir> | layers <dir> <ids> [n] | nll <dir> <ids> [n] | gen <dir> <chat.json> [max] | ctx <dir> <ids> <n> [decode]"
    guard args.count >= 3 else { print(usage); return }
    do {
        if args[2] == "unit" { exit(unitCheck() ? 0 : 1) }
        guard args.count >= 4 else { print(usage); return }
        let t0 = Date()
        if let mb = Int(ProcessInfo.processInfo.environment["STRIM_BONSAI_CACHE_MB"] ?? "") { Memory.cacheLimit = mb << 20 }
        let store = try WeightStore(dir: URL(fileURLWithPath: args[3]))
        switch args[2] {
        case "load":
            try loadCheck(store)
            // materialise the whole text model, as a real run would (forward touches every tensor)
            let ids = [Int32](repeating: 561, count: 8)
            let lg = try QwenModel.forwardAll(tokens: ids, store: store, cache: ModelCache(), lastTokenOnly: true).logits; eval(lg)
            print(memLine("after first forward (resident weights)"), String(format: "load+fwd %.1fs", Date().timeIntervalSince(t0)))
        case "layers":
            let ids = try readIds(args[4], args.count > 5 ? Int(args[5]) : 64)
            try forwardStats(store, tokens: ids)
        case "nll":
            let ids = try readIds(args[4], args.count > 5 ? Int(args[5]) : 512)
            let (m, t1) = try nll(store, ids)
            print(String(format: "order=%d n=%d nll=%.4f ppl=%.3f top1=%.3f", ActivationRotation.order, ids.count, m, exp(m), t1))
        case "gen":
            let tok = try Tokenizer.load(modelDir: args[3])
            let text = try String(contentsOfFile: args[4], encoding: .utf8)
            let chat = try TokenizeTool.chatInput(json: text)
            let prompt = try TokenizeTool.chatIds(messages: chat.messages, tools: chat.tools, tokenizer: tok)
            let maxT = args.count > 5 ? Int(args[5]) ?? 256 : 256
            let stop = Set(["<|im_end|>", "<|endoftext|>"].compactMap { tok.specialIds[$0] })
            let r = try decodeLoop(store, prompt: prompt, max: maxT, stop: stop)
            print("=== \(args[4]) promptTokens=\(prompt.count) gen=\(r.out.count)")
            print(tok.decode(r.out))
            print(String(format: "=== prefill %.2fs (%.0f tok/s) decode %.2f tok/s peakFootprint=%@", r.prefill,
                         Double(prompt.count) / r.prefill, r.tokps, gib(r.peakFootprint)))
        case "ctx":
            guard args.count >= 6, let n = Int(args[5]) else { print(usage); return }
            let d = args.count > 6 ? Int(args[6]) ?? 32 : 32
            let ids = try readIds(args[4], n)
            print(memLine("loaded (lazy)"))
            let r = try decodeLoop(store, prompt: ids, max: d, stop: [])
            print(memLine("after ctx \(n)"))
            print(String(format: "ctx=%d prefill %.2fs (%.0f tok/s) decode %.2f tok/s peakFootprint=%@", n, r.prefill,
                         Double(n) / r.prefill, r.tokps, gib(r.peakFootprint)))
        default: print(usage)
        }
    } catch {
        FileHandle.standardError.write(Data("bonsaispike failed: \(error)\n".utf8)); exit(1)
    }
}
