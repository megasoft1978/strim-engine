import Foundation
import MLX
import StrimCore

func inspect(_ path: String) throws {
    let dir = URL(fileURLWithPath: path)
    let index = try ModelIndex(url: dir.appendingPathComponent("model.safetensors.index.json"))
    print("model:   \(dir.lastPathComponent)")
    print("tensors: \(index.weightMap.count)")
    print("declared: \(String(format: "%.2f", Double(index.totalSize) / 1e9)) GB")

    var headers: [String: SafetensorsFile] = [:]
    var bytes = 0
    var quantized = 0
    for shard in index.shards().keys.sorted() {
        let f = try SafetensorsFile(url: dir.appendingPathComponent(shard))
        headers[shard] = f
        bytes += f.tensors.values.reduce(0) { $0 + $1.dataOffsets.count }
        quantized += f.tensors.keys.filter { $0.hasSuffix(".scales") }.count
    }
    print("shards:  \(headers.count)")
    print("payload: \(String(format: "%.2f", Double(bytes) / 1e9)) GB")
    print("q-layers: \(quantized)")
    for shard in headers.keys.sorted() {
        let f = headers[shard]!
        print("  \(shard): \(f.tensors.count) tensors")
    }
}

let cfg = RuntimeConfig.measuredSpeed
let args = CommandLine.arguments
if runExtraCommand(args) { exit(0) }

/// A cache with fixed, already-evaluated state so repeated passes trace identical
/// shapes and never chain onto the previous (unevaluated) iteration.
func makePrimedCache(pos: Int) -> ModelCache {
    let c = ModelCache()
    for i in 0 ..< 64 {
        if (i + 1) % 4 == 0 {
            let a = c.attentionCache(i)
            a.keys = MLXArray.zeros([1, 4, pos, 256], dtype: .bfloat16)
            a.values = MLXArray.zeros([1, 4, pos, 256], dtype: .bfloat16)
        } else {
            let g = c.gdnState(i)
            g.conv = MLXArray.zeros([1, 3, 10240], dtype: .bfloat16)
            g.ssm = MLXArray.zeros([1, 48, 128, 128], dtype: .float32)
        }
    }
    c.position = pos
    return c
}

func evalPrimedState(_ c: ModelCache) {
    for s in c.gdn.values { eval(s.conv!, s.ssm!) }
    for a in c.attention.values { eval(a.keys!, a.values!) }
}


if args.count >= 4, args[1] == "benchlayer" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let layer = Int(args[3]) ?? 0
        let n = args.count >= 5 ? Int(args[4]) ?? 20 : 20
        let x = MLXArray.zeros([1, 1, 5120], dtype: .bfloat16)
        _ = try DecoderLayer.forward(x, store: store, layer: layer, cache: ModelCache())
        let t0 = Date()
        for _ in 0 ..< n {
            let c = ModelCache()
            eval(try DecoderLayer.forward(x, store: store, layer: layer, cache: c))
        }
        let ms = Date().timeIntervalSince(t0) / Double(n) * 1000
        print("layer \(layer): \(String(format: "%.2f", ms)) ms/step")
    } catch {
        FileHandle.standardError.write(Data("benchlayer failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "checkbatch2" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let prefix: [Int32] = [9707,1234,5678,198,2,220,17,15,17,18,95859,16,17,96212,17,17]
        let pair: [Int32] = [95971, 198]
        let c1 = ModelCache()
        _ = try QwenModel.forwardAll(tokens: prefix, store: store, cache: c1)
        let inc = try QwenModel.forwardAll(tokens: pair, store: store, cache: c1)
        let c2 = ModelCache()
        let full = try QwenModel.forwardAll(tokens: prefix + pair, store: store, cache: c2)
        let n = prefix.count
        let b = full.logits[0..., n ..< (n + 2), 0...]
        let d = abs(inc.logits - b)
        print("batch2 max", String(format: "%.5f", d.max().item(Float.self)),
              "mean", String(format: "%.6f", d.mean().item(Float.self)))
        print("cached pos0 argmax", Int32(argMax(inc.logits[0,0]).item(Int32.self)),
              "fresh", Int32(argMax(b[0,0]).item(Int32.self)))
    } catch {
        FileHandle.standardError.write(Data("checkbatch2 failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "checkbatch" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let c1 = ModelCache()
        _ = try QwenModel.forwardAll(tokens: [9707, 1234, 5678], store: store, cache: c1)
        let inc = try QwenModel.forwardAll(tokens: [198, 2], store: store, cache: c1)
        let c2 = ModelCache()
        let full = try QwenModel.forwardAll(tokens: [9707, 1234, 5678, 198, 2], store: store, cache: c2)
        let a = inc.logits
        let b = full.logits[0..., 3 ..< 5, 0...]
        let d = abs(a - b)
        print("batch-vs-recompute: max", String(format: "%.5f", d.max().item(Float.self)),
              "mean", String(format: "%.6f", d.mean().item(Float.self)))
    } catch {
        FileHandle.standardError.write(Data("checkbatch failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 4, args[1] == "genmtp" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let head = try WeightStore(dir: URL(fileURLWithPath: args[3]))
        head.useIntegratedMTPPrefixIfNeeded()
        let n = args.count >= 5 ? Int(args[4]) ?? 32 : 32
        let prompt: [Int32] = args.count >= 6
            ? args[5].split(separator: ",").map { Int32($0)! }
            : [9707, 1234, 5678]
        let depth = args.count >= 7 ? Int(args[6]) ?? 2 : 2
        let t0 = Date()
        let (ids, stats) = try QwenModel.generateSpec(prompt: prompt, maxTokens: n,
                                                      store: store, head: head, depth: depth)
        let dt = Date().timeIntervalSince(t0)
        print("ids:", ids)
        print(stats.summary)
        print("elapsed:", String(format: "%.1f", dt), "s")
    } catch {
        FileHandle.standardError.write(Data("genmtp failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 4, args[1] == "benchspec" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let head = try WeightStore(dir: URL(fileURLWithPath: args[3]))
        head.useIntegratedMTPPrefixIfNeeded()
        let n = args.count >= 5 ? Int(args[4]) ?? 32 : 32
        let depth = args.count >= 6 ? Int(args[5]) ?? 2 : 2
        let prompt: [Int32] = args.count >= 7
            ? args[6].split(separator: ",").map { Int32($0)! }
            : [9707, 1234, 5678]
        let reps = args.count >= 8 ? max(Int(args[7]) ?? 1, 1) : 1
        // Warm kernels twice, then compare every complete output to one greedy reference.
        if n > 0 {
            for _ in 0 ..< 2 {
                _ = try QwenModel.generateSpec(prompt: prompt, maxTokens: min(n, 4),
                                               store: store, head: head, depth: depth)
            }
        }
        let greedy = try QwenModel.generate(prompt: prompt, maxTokens: n, store: store)
        var samples: [SpecStats] = []
        var mismatch = false
        for rep in 1 ... reps {
            let (ids, stats) = try QwenModel.generateSpec(prompt: prompt, maxTokens: n,
                                                          store: store, head: head, depth: depth)
            samples.append(stats)
            print("rep \(rep) spec:", stats.summary)
            if ids == greedy {
                print("parity: EXACT (\(ids.count) tokens)")
            } else {
                mismatch = true
                print("parity: MISMATCH (spec \(ids.count) tokens, greedy \(greedy.count))")
                let common = min(ids.count, greedy.count)
                if let i = (0 ..< common).first(where: { ids[$0] != greedy[$0] }) {
                    print("  first diff at \(i): spec \(ids[i]) greedy \(greedy[i])")
                } else {
                    print("  outputs share a prefix; lengths differ")
                }
                print("  spec  ", ids)
                print("  greedy", greedy)
            }
        }
        let emitted = samples.reduce(0) { $0 + $1.emitted }
        let seconds = samples.reduce(0.0) { $0 + $1.seconds }
        let decodeSeconds = samples.reduce(0.0) { $0 + $1.seconds - $1.prefillSeconds }
        print(String(format: "aggregate: emitted=%d requested=%d seconds=%.2f decode_seconds=%.2f e2e_tok_s=%.2f decode_tok_s=%.2f",
                     emitted, max(n, 0) * reps, seconds, decodeSeconds,
                     seconds > 0 ? Double(emitted) / seconds : 0,
                     decodeSeconds > 0 ? Double(emitted) / decodeSeconds : 0))
        if mismatch { exit(2) }
    } catch {
        FileHandle.standardError.write(Data("benchspec failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 7, args[1] == "benchmtp" {
    // Interleaved A/B of the draft chain: host per-draft sync vs GPU-resident token ids.
    // Usage: strim benchmtp <model> <head> <n> <depth> <ids> [reps]
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let head = try WeightStore(dir: URL(fileURLWithPath: args[3]))
        let n = Int(args[4]) ?? 48
        let depth = Int(args[5]) ?? 2
        let prompt = args[6].split(separator: ",").map { Int32($0)! }
        let reps = args.count >= 8 ? Int(args[7]) ?? 4 : 4
        // Warm both paths: weights, compiled kernels, head caches.
        _ = try QwenModel.generateSpec(prompt: prompt, maxTokens: 4, store: store, head: head,
                                       depth: depth, chain: .host)
        _ = try QwenModel.generateSpec(prompt: prompt, maxTokens: 4, store: store, head: head,
                                       depth: depth, chain: .index)
        typealias Sample = (ms: Double, tps: Double, ids: [Int32], stats: SpecStats)
        var samples: [QwenModel.DraftChain: [Sample]] = [:]
        for r in 0 ..< reps {
            let order: [QwenModel.DraftChain] = r % 2 == 0 ? [.host, .index] : [.index, .host]
            for chain in order {
                let (ids, stats) = try QwenModel.generateSpec(
                    prompt: prompt, maxTokens: n, store: store, head: head, depth: depth,
                    chain: chain)
                samples[chain, default: []].append((stats.msPerPass, stats.tokensPerSecond,
                                                    ids, stats))
                print(String(format: "  rep %d %@  %6.2f ms/pass  %5.1f tok/s  accept %d/%d",
                             r, chain.rawValue, stats.msPerPass, stats.tokensPerSecond,
                             stats.acceptedDrafts, stats.drafts))
            }
        }
        func best(_ chain: QwenModel.DraftChain) -> Sample {
            let s = samples[chain]!
            var b = s[0]
            for x in s where x.ms < b.ms { b = x }
            return b
        }
        let h = best(.host), k = best(.index)
        print(String(format: "host   sync   min %6.2f ms/pass  %5.1f tok/s  accept %.0f%%",
                     h.ms, h.tps, h.stats.acceptRate * 100))
        print(String(format: "index  nosync min %6.2f ms/pass  %5.1f tok/s  accept %.0f%%",
                     k.ms, k.tps, k.stats.acceptRate * 100))
        print(String(format: "delta %+.2f ms/pass (%+.1f%%)", k.ms - h.ms, (k.ms / h.ms - 1) * 100))
        let all = samples.values.flatMap { $0 }
        let sameTokens = all.allSatisfy { $0.ids == h.ids }
        let sameCounts = all.allSatisfy {
            $0.stats.acceptedDrafts == h.stats.acceptedDrafts
                && $0.stats.drafts == h.stats.drafts && $0.stats.emitted == h.stats.emitted
        }
        print("parity:", sameTokens ? "IDENTICAL outputs" : "MISMATCH outputs",
              sameCounts ? "identical acceptance counts" : "ACCEPTANCE DIFFERS")
    } catch {
        FileHandle.standardError.write(Data("benchmtp failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 7, args[1] == "benchpathspec" {
    // Interleaved loop-level A/B of the two recurrence paths. `benchpathS` times a
    // primed pass; this runs the real speculative loop (growing KV, rollback, MTP head)
    // and checks whether the kernel's pass-level win survives it.
    // Usage: strim benchpathspec <model> <head> <n> <depth> <ids> [reps]
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let head = try WeightStore(dir: URL(fileURLWithPath: args[3]))
        let n = Int(args[4]) ?? 48
        let depth = Int(args[5]) ?? 2
        let prompt = args[6].split(separator: ",").map { Int32($0)! }
        let reps = args.count >= 8 ? Int(args[7]) ?? 4 : 4
        for metal in [false, true] {
            GDN.metalOverride = metal
            _ = try QwenModel.generateSpec(prompt: prompt, maxTokens: 4, store: store, head: head,
                                           depth: depth)
        }
        typealias Sample = (ms: Double, tps: Double, ids: [Int32], stats: SpecStats)
        var samples: [Bool: [Sample]] = [:]
        for r in 0 ..< reps {
            let order: [Bool] = r % 2 == 0 ? [false, true] : [true, false]
            for metal in order {
                GDN.metalOverride = metal
                let (ids, stats) = try QwenModel.generateSpec(
                    prompt: prompt, maxTokens: n, store: store, head: head, depth: depth)
                samples[metal, default: []].append((stats.msPerPass, stats.tokensPerSecond,
                                                    ids, stats))
                print(String(format: "  rep %d %@  %6.2f ms/pass  %5.1f tok/s  accept %d/%d",
                             r, metal ? "kernel" : "tensor", stats.msPerPass,
                             stats.tokensPerSecond, stats.acceptedDrafts, stats.drafts))
            }
        }
        GDN.metalOverride = nil
        func best(_ metal: Bool) -> Sample {
            let s = samples[metal]!
            var b = s[0]
            for x in s where x.ms < b.ms { b = x }
            return b
        }
        let t = best(false), k = best(true)
        print(String(format: "tensor min %6.2f ms/pass  %5.1f tok/s  accept %.0f%%",
                     t.ms, t.tps, t.stats.acceptRate * 100))
        print(String(format: "kernel min %6.2f ms/pass  %5.1f tok/s  accept %.0f%%",
                     k.ms, k.tps, k.stats.acceptRate * 100))
        print(String(format: "delta %+.2f ms/pass (%+.1f%%)", k.ms - t.ms, (k.ms / t.ms - 1) * 100))
        let all = samples.values.flatMap { $0 }
        let tensorDet = samples[false]!.allSatisfy { $0.ids == samples[false]![0].ids }
        let kernelDet = samples[true]!.allSatisfy { $0.ids == samples[true]![0].ids }
        let crossSame = samples[false]![0].ids == samples[true]![0].ids
        let countsSame = all.allSatisfy {
            $0.stats.acceptedDrafts == t.stats.acceptedDrafts
                && $0.stats.drafts == t.stats.drafts && $0.stats.emitted == t.stats.emitted
        }
        print("determinism:", tensorDet ? "tensor stable" : "tensor VARIES",
              kernelDet ? "kernel stable" : "kernel VARIES",
              "| cross-path:", crossSame ? "identical" : "near-tie differs",
              "| acceptance counts:", countsSame ? "identical" : "DIFFER")
    } catch {
        GDN.metalOverride = nil
        FileHandle.standardError.write(Data("benchpathspec failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchmlp" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let p = "language_model.model.layers.0.mlp."
        let gw = try store.tensor(p + "gate_proj.weight"), gs = try store.tensor(p + "gate_proj.scales"), gb = try store.tensor(p + "gate_proj.biases")
        let uw = try store.tensor(p + "up_proj.weight"), us = try store.tensor(p + "up_proj.scales"), ub = try store.tensor(p + "up_proj.biases")
        let dw = try store.tensor(p + "down_proj.weight"), ds = try store.tensor(p + "down_proj.scales"), db = try store.tensor(p + "down_proj.biases")
        func body(_ x: MLXArray) -> MLXArray {
            let g = quantizedMatmul(x, gw, scales: gs, biases: gb, transpose: true, groupSize: 64, bits: 4)
            let u = quantizedMatmul(x, uw, scales: us, biases: ub, transpose: true, groupSize: 64, bits: 4)
            let act = (g * sigmoid(g) * u).asType(x.dtype)
            return quantizedMatmul(act, dw, scales: ds, biases: db, transpose: true, groupSize: 64, bits: 4)
        }
        let compiled = compile { (a: [MLXArray]) -> [MLXArray] in [body(a[0])] }
        let x = MLXArray.zeros([1, 1, 5120], dtype: .bfloat16)
        func timeIt(_ label: String, _ f: (MLXArray) -> MLXArray, n: Int) {
            _ = f(x); eval(f(x))
            let t0 = Date()
            for _ in 0 ..< n { eval(f(x)) }
            print(label, String(format: "%.3f", Date().timeIntervalSince(t0) / Double(n) * 1000), "ms/call")
        }
        timeIt("plain   ", body, n: 20)
        timeIt("compiled", { compiled([$0])[0] }, n: 20)
    } catch {
        FileHandle.standardError.write(Data("benchmlp failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchops" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 20 : 20
        let p = "language_model.model.layers.0.linear_attn."
        let convW = try store.tensor(p + "conv1d.weight")
        func q(_ name: String) throws -> (MLXArray, MLXArray, MLXArray) {
            (try store.tensor(p + name + ".weight"), try store.tensor(p + name + ".scales"),
             try store.tensor(p + name + ".biases"))
        }
        let (qw, qs, qb) = try q("in_proj_qkv")
        let (zw, zs, zb) = try q("in_proj_z")
        let (bw, bs, bb) = try q("in_proj_b")
        let (ow, os, ob) = try q("out_proj")
        let x = MLXArray.zeros([1, 1, 5120], dtype: .bfloat16)
        let convIn = MLXArray.zeros([1, 4, 10240], dtype: .bfloat16)
        let rec = MLXArray.zeros([1, 48, 128, 128], dtype: .float32)
        let kT = MLXArray.zeros([1, 48, 1, 128], dtype: .float32)
        let qT = MLXArray.zeros([1, 48, 1, 128], dtype: .float32)
        func time(_ label: String, _ f: () -> MLXArray) {
            var a = f(); eval(a)
            let t0 = Date()
            for _ in 0 ..< n { a = f(); eval(a) }
            print(String(format: "%-12@ %8.3f ms", label as NSString,
                         Date().timeIntervalSince(t0) / Double(n) * 1000))
        }
        time("conv1d") { conv1d(convIn, convW, groups: 10240) }
        time("qmm_qkv") { quantizedMatmul(x, qw, scales: qs, biases: qb, transpose: true, groupSize: 64, bits: 4) }
        time("qmm_z") { quantizedMatmul(x, zw, scales: zs, biases: zb, transpose: true, groupSize: 64, bits: 4) }
        time("qmm_b") { quantizedMatmul(x, bw, scales: bs, biases: bb, transpose: true, groupSize: 64, bits: 4) }
        time("qmm_out") { quantizedMatmul(MLXArray.zeros([1, 1, 6144], dtype: .bfloat16), ow,
                                          scales: os, biases: ob, transpose: true, groupSize: 64, bits: 4) }
        time("ssm_mul") { (rec * kT).sum(axis: -1) }
        time("ssm_decay") { rec * kT }
        time("gdn_full") {
            try! GDN.forward(x, store: store, layer: 0, state: GDNState()).asType(.bfloat16)
        }
        let n1 = try store.rmsNorm("language_model.model.layers.0.input_layernorm", x)
        time("gdn_noral") { try! GDN.forward(n1, store: store, layer: 0, state: GDNState()) }
        let n2 = try store.rmsNorm("language_model.model.layers.0.post_attention_layernorm", x)
        time("mlp0") { try! MLP.forward(n2, store: store, layer: 0) }
        time("mlp0b") {
            let g = try! store.linear("language_model.model.layers.0.mlp.gate_proj", n2)
            let u = try! store.linear("language_model.model.layers.0.mlp.up_proj", n2)
            let act = (g * sigmoid(g) * u).asType(n2.dtype)
            return try! store.linear("language_model.model.layers.0.mlp.down_proj", act)
        }
        time("layer0") { try! DecoderLayer.forward(x, store: store, layer: 0, cache: ModelCache()) }
        let conv0 = MLXArray.zeros([1, 3, 10240], dtype: .bfloat16)
        let ssm0 = MLXArray.zeros([1, 48, 128, 128], dtype: .float32)
        time("step1") { try! GDN.step1(n1, conv: conv0, ssm: ssm0, store: store, layer: 0).y }
        let gstep = store.gdnStep(layer: 0)
        time("step1_comp") { gstep([n1, conv0, ssm0])[0] }
    } catch {
        FileHandle.standardError.write(Data("benchops failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 4, args[1] == "mtpcombo" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let head = try WeightStore(dir: URL(fileURLWithPath: args[3]))
        let prompt: [Int32] = [9707, 1234, 5678]
        let ext: [Int32] = prompt + [198, 2]
        let (pre, _) = try QwenModel.forwardAll(tokens: ext, store: store, cache: ModelCache())
        let post = try store.rmsNorm("language_model.model.norm", pre)
        func run(_ label: String, _ tokens: [Int32], _ hidden: MLXArray, _ from: Int, _ n: Int) throws {
            let st = MTPState()
            let o = try MTP.step(tokens: tokens, hidden: hidden[0..., from ..< (from + n), 0...],
                                 target: store, head: head, state: st)
            let lg = try MTP.logits(for: o, target: store, head: head)
            let preds = argMax(lg, axis: -1).asArray(Int32.self)
            print(label, "preds:", preds, "last:", try MTP.nextToken(o[0..., (n-1)..<n, 0...], target: store, head: head))
        }
        try run("A shifted/post ", Array(ext[1..<4]), post, 0, 3)
        try run("B prompt/post  ", Array(ext[0..<3]), post, 0, 3)
        try run("C seq4/post    ", Array(ext[0..<4]), post, 0, 4)
        try run("D shifted/pre  ", Array(ext[1..<4]), pre, 0, 3)
        try run("E shift h1/post", Array(ext[1..<4]), post, 1, 3)
    } catch {
        FileHandle.standardError.write(Data("mtpcombo failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 4, args[1] == "checktie" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let head = try WeightStore(dir: URL(fileURLWithPath: args[3]))
        let n = args.count >= 5 ? Int(args[4]) ?? 37 : 37
        let (ids, _) = try QwenModel.generateSpec(prompt: [9707, 1234, 5678], maxTokens: n + 3,
                                                  store: store, head: head, depth: 2)
        let prefix = Array(ids.prefix(n))
        let c = ModelCache()
        var lg: MLXArray?
        for tok in prefix {
            let r = try QwenModel.forward(tokens: [tok], store: store, cache: c)
            lg = r.logits
        }
        eval(lg!)
        let v = lg!.asArray(Float.self).enumerated().sorted { $0.element > $1.element }
        print("prefix len", prefix.count - 1, "last tokens", prefix.suffix(6))
        print("top8:", v.prefix(8).map { "\($0.offset):" + String(format: "%.3f", $0.element) })
        print("margin top1-top2:", String(format: "%.4f", v[0].element - v[1].element))
    } catch {
        FileHandle.standardError.write(Data("checktie failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "checkspec" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let prompt: [Int32] = [9707, 1234, 5678]
        func top(_ a: MLXArray, _ label: String) {
            let v = a.asArray(Float.self).enumerated().sorted { $0.element > $1.element }.prefix(5)
            print(label, v.map { "\($0.offset):" + String(format: "%.2f", $0.element) })
        }
        let c = ModelCache()
        let pre = try QwenModel.forwardAll(tokens: prompt, store: store, cache: c)
        let t1 = Int32(argMax(pre.logits[0, 2]).item(Int32.self))
        print("t1:", t1)
        // fresh full forward of prefix + [t1, 2]
        let fresh = try QwenModel.forwardAll(tokens: prompt + [t1, 2], store: store, cache: ModelCache())
        top(fresh.logits[0, 3], "fresh after t1  ")
        top(fresh.logits[0, 4], "fresh after 2   ")
        // sequential cached
        let cs = c.snapshot()
        let s1 = try QwenModel.forward(tokens: [t1], store: store, cache: cs)
        let s2 = try QwenModel.forward(tokens: [2], store: store, cache: cs)
        top(s1.logits, "seq   after t1  ")
        top(s2.logits, "seq   after 2   ")
        // batched cached
        let cb = c.snapshot()
        let b = try QwenModel.forwardAll(tokens: [t1, 2], store: store, cache: cb)
        top(b.logits[0, 0], "batch after t1  ")
        top(b.logits[0, 1], "batch after 2   ")
    } catch {
        FileHandle.standardError.write(Data("checkspec failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "checkgdn" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let x = MLXRandom.normal([1, 2, 5120]).asType(.bfloat16)
        let c0 = x[0..., 0 ..< 1, 0...], c1 = x[0..., 1 ..< 2, 0...]
        let sa = GDNState()
        let y0 = try GDN.forward(c0, store: store, layer: 0, state: sa)
        let y1 = try GDN.forward(c1, store: store, layer: 0, state: sa)
        let sb = GDNState()
        let yb = try GDN.forward(x, store: store, layer: 0, state: sb)
        eval(y0, y1, yb, sa.ssm!, sb.ssm!)
        let dy = abs(yb[0..., 1 ..< 2, 0...] - y1)
        let ds = abs(sb.ssm! - sa.ssm!)
        print("gdn y[1] max diff:", dy.max().item(Float.self), "mean:", dy.mean().item(Float.self))
        print("gdn ssm max diff:", ds.max().item(Float.self), "mean:", ds.mean().item(Float.self))
        let convA = sa.conv!, convB = sb.conv!
        let dc = abs(convA - convB)
        print("gdn conv max diff:", dc.max().item(Float.self))
    } catch {
        FileHandle.standardError.write(Data("checkgdn failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "checkconv" {
    // Is the conv+silu kernel bit-identical to `GDN.depthwise` + `GDN.silence`? Split the
    // kernel into sum-only and silu-only modes so the failing stage is named, and use real
    // projections from the prompt rather than random tensors.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let layer = args.count >= 4 ? Int(args[3]) ?? 4 : 4
        let prompt: [Int32] = [9707, 1234, 5678, 198]
        var h = try store.embedding("language_model.model.embed_tokens", tokens: prompt)
            .reshaped([1, prompt.count, 5120])
        for i in 0 ..< layer {
            let p = "language_model.model.layers.\(i)."
            let n1 = try store.rmsNorm(p + "input_layernorm", h)
            let mixed: MLXArray
            if (i + 1) % 4 != 0 {
                mixed = try GDN.forward(n1, store: store, layer: i)
            } else {
                mixed = try Attention.forward(n1, store: store, layer: i, cache: AttentionCache())
            }
            h = h + mixed
            let n2 = try store.rmsNorm(p + "post_attention_layernorm", h)
            h = h + (try MLP.forward(n2, store: store, layer: i))
        }
        let p = "language_model.model.layers.\(layer).linear_attn."
        let n1 = try store.rmsNorm("language_model.model.layers.\(layer).input_layernorm", h)
        let qkv = try store.linear(p + "in_proj_qkv", n1)
        let convState = MLXArray.zeros([1, 3, 10240], dtype: .bfloat16)
        let convIn = concatenated([convState, qkv], axis: 1)
        let w = try store.tensor(p + "conv1d.weight")
        let S = prompt.count
        let sum = GDN.depthwise(convIn, w, S)
        let refSilu = GDN.silence(sum)
        let ksum = GDNMetal.convDebug(convIn: convIn, weight: w, mode: 1)
        let ksig = GDNMetal.convDebug(convIn: sum, weight: w, mode: 2)
        let ksilu = GDNMetal.convDebug(convIn: sum, weight: w, mode: 3)
        let ksigB = GDNMetal.convDebug(convIn: sum, weight: w, mode: 4)
        let ksiluB = GDNMetal.convDebug(convIn: sum, weight: w, mode: 5)
        let kfull = GDNMetal.convDebug(convIn: convIn, weight: w, mode: 0)
        eval(sum, refSilu, ksum, ksig, ksilu, ksigB, ksiluB, kfull)
        func report(_ label: String, _ a: MLXArray, _ b: MLXArray) {
            let d = abs(a - b)
            let n = (d .> 0).sum().item(Int32.self)
            print(String(format: "%-36@ max %.7f mean %.8f differing %d/%d", label,
                         d.max().item(Float.self), d.mean().item(Float.self), n, a.size))
        }
        report("sum kernel vs depthwise", ksum, sum)
        report("sigmoid kernel vs sigmoid", ksig, sigmoid(sum))
        report("silu-on-sum vs silence", ksilu, refSilu)
        report("sigmoid bf16-step vs sigmoid", ksigB, sigmoid(sum))
        report("silu bf16-step vs silence", ksiluB, refSilu)
        report("full kernel vs reference", kfull, refSilu)
    } catch {
        FileHandle.standardError.write(Data("checkconv failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchpass" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 20 : 20
        let layers = args.count >= 5 ? Int(args[4]) ?? 64 : 64
        let cache = ModelCache()
        var r = try QwenModel.forward(tokens: [9707], store: store, cache: cache, layers: layers)
        eval(r.logits)
        var tok: Int32 = 198
        let t0 = Date()
        for _ in 0 ..< n {
            r = try QwenModel.forward(tokens: [tok], store: store, cache: cache, layers: layers)
            eval(r.logits)
            tok = 198
        }
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "pass: %.2f ms  (%.1f tok/s), %d layers",
                     dt / Double(n) * 1000, Double(n) / dt, layers))
        // per-layer-type cost with persistent caches
        var gdn = 0.0, attn = 0.0, mlp = 0.0
        let x = MLXArray.zeros([1, 1, 5120], dtype: .bfloat16)
        for i in 0 ..< min(layers, 8) {
            let p = "language_model.model.layers.\(i)."
            let n1 = try store.rmsNorm(p + "input_layernorm", x)
            let c = ModelCache()
            eval(try DecoderLayer.forward(x, store: store, layer: i, cache: c))
            let ta = Date()
            for _ in 0 ..< 5 {
                if (i + 1) % 4 != 0 {
                    eval(try GDN.forward(n1, store: store, layer: i, state: c.gdnState(i)))
                } else {
                    eval(try Attention.forward(n1, store: store, layer: i, cache: c.attentionCache(i)))
                }
            }
            let per = Date().timeIntervalSince(ta) / 5 * 1000
            if (i + 1) % 4 != 0 { gdn += per } else { attn += per }
            let n2 = try store.rmsNorm(p + "post_attention_layernorm", x)
            let tm = Date()
            for _ in 0 ..< 5 { eval(try MLP.forward(n2, store: store, layer: i)) }
            mlp += Date().timeIntervalSince(tm) / 5 * 1000
        }
        print(String(format: "gdn %.2f ms  attn %.2f ms  mlp %.2f ms (first 8 layers, persisting cache)",
                     gdn, attn, mlp))
        // same loop, but with the per-step argmax sync that `generate` does
        let cache2 = ModelCache()
        var r2 = try QwenModel.forward(tokens: [9707, 1234, 5678], store: store, cache: cache2, layers: layers)
        eval(r2.logits)
        let t1 = Date()
        for _ in 0 ..< min(n, 10) {
            let next = Int32(argMax(r2.logits).item(Int32.self))
            r2 = try QwenModel.forward(tokens: [next], store: store, cache: cache2, layers: layers)
        }
        let dt2 = Date().timeIntervalSince(t1)
        print(String(format: "with argmax sync: %.2f ms/token", dt2 / Double(min(n, 10)) * 1000))
    } catch {
        FileHandle.standardError.write(Data("benchpass failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 2, args[1] == "checkcompile" {
    // Does compile(inputs:outputs:) with an Updatable holder support a growing
    // array as state? This is the gate for the whole-step compiled graph.
    final class Holder: Updatable, @unchecked Sendable {
        var arrays: [MLXArray]
        init(_ a: [MLXArray]) { arrays = a }
        func innerState() -> [MLXArray] { arrays }
    }
    let box = Holder([MLXArray.zeros([1, 1, 0, 4])])
    let f = compile(inputs: [box], outputs: [box], shapeless: true) { (x: MLXArray) -> MLXArray in
        let next = concatenated([box.arrays[0], x], axis: 2)
        box.arrays[0] = next
        return next
    }
    for _ in 0 ..< 4 { _ = f(MLXArray.ones([1, 1, 1, 4])) }
    eval(box.arrays[0])
    print("growing state shape:", box.arrays[0].shape,
          "all ones:", box.arrays[0].asArray(Float.self).allSatisfy { $0 == 1 })
} else if args.count >= 2, args[1] == "checkmetal" {
    do {
        for S in [1, 2, 3] {
            let q = MLXRandom.normal([1, S, 48, 128]).asType(.bfloat16)
            let k = MLXRandom.normal([1, S, 48, 128]).asType(.bfloat16)
            let v = MLXRandom.normal([1, S, 48, 128]).asType(.bfloat16)
            let g = MLXRandom.normal([1, S, 48]).asType(.float32)
            let beta = MLXRandom.normal([1, S, 48]).asType(.bfloat16)
            let ssm = MLXRandom.normal([1, 48, 128, 128]).asType(.float32) * 0.1
            // The model uses the compiled matmul recurrence (recurrenceMM), not the elementwise
            // one; compare against both to see which the kernel actually tracks.
            let ref = GDN.recurrenceNoState(q, k, v, g, beta, ssm, dtype: .bfloat16)
            let mm = GDN.recurrenceMM(q, k, v, g, beta, ssm, dtype: .bfloat16)
            let mmY = mm.yAll, mmS = mm.ssm
            eval(mmY, mmS)
            let got = GDNMetal.run(q: q, k: k, v: v, g: g, beta: beta, ssm: ssm)
            eval(ref.0, ref.1, got.y, got.ssm, got.stack)
            let dy = abs(ref.0 - got.y), ds = abs(ref.1 - got.ssm)
            let lastStack = got.stack[S - 1].expandedDimensions(axis: 0)
            let dstack = abs(lastStack - got.ssm)
            let dmm = abs(mmY - got.y)
            let dmmS = abs(mmS - got.ssm)
            let refVsMM = abs(ref.0 - mmY)
            eval(dmm, dmmS, refVsMM)
            print(String(format: "S=%d y max %.6f mean %.7f | ssm max %.6f mean %.8f | stack_last max %.6f",
                         S, dy.max().item(Float.self), dy.mean().item(Float.self),
                         ds.max().item(Float.self), ds.mean().item(Float.self),
                         dstack.max().item(Float.self)))
            print(String(format: "     vs recurrenceMM: y max %.7f | ssm max %.8f || elementwise-vs-MM: y max %.7f",
                         dmm.max().item(Float.self), dmmS.max().item(Float.self),
                         refVsMM.max().item(Float.self)))
        }
    } catch {
        FileHandle.standardError.write(Data("checkmetal failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "checkrollback" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let prompt: [Int32] = args.count >= 4
            ? args[3].split(separator: ",").map { Int32($0)! } : [9707, 1234, 5678]
        let a: Int32 = 4471, b: Int32 = 303, c: Int32 = 1290
        // A: batched verify then rollback to one token
        let ca = ModelCache()
        _ = try QwenModel.forwardAll(tokens: prompt, store: store, cache: ca)
        ca.beginVerify()
        _ = try QwenModel.forwardAll(tokens: [a, b, c], store: store, cache: ca)
        ca.rollback(drop: 2)
        ca.endVerify()
        // B: one token only
        let cb = ModelCache()
        _ = try QwenModel.forwardAll(tokens: prompt, store: store, cache: cb)
        _ = try QwenModel.forwardAll(tokens: [a], store: store, cache: cb)
        let la = try QwenModel.forward(tokens: [b], store: store, cache: ca)
        let lb = try QwenModel.forward(tokens: [b], store: store, cache: cb)
        let d = abs(la.logits - lb.logits)
        print("rollback logits: max", d.max().item(Float.self), "mean", d.mean().item(Float.self))
        print("argmax A", Int32(argMax(la.logits).item(Int32.self)),
              "B", Int32(argMax(lb.logits).item(Int32.self)))
        print("positions A", ca.position, "B", cb.position)
    } catch {
        FileHandle.standardError.write(Data("checkrollback failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchpassS" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 10 : 10
        for S in 1 ... 4 {
            let cache = ModelCache()
            var r = try QwenModel.forwardAll(tokens: [9707], store: store, cache: cache)
            eval(r.logits)
            let feed = Array(repeating: Int32(198), count: S)
            let t0 = Date()
            for _ in 0 ..< n {
                r = try QwenModel.forwardAll(tokens: feed, store: store, cache: cache)
                eval(r.logits)
            }
            let ms = Date().timeIntervalSince(t0) / Double(n) * 1000
            print(String(format: "S=%d  %7.2f ms/pass  (%.1f ms/token)", S, ms, ms / Double(S)))
        }
    } catch {
        FileHandle.standardError.write(Data("benchpassS failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchpathS" {
    // Interleaved A/B of the tensor recurrence and the fused kernel at S=1..4 inside one
    // process. The env flag can only pick a path per process, which is what made earlier
    // kernel-vs-tensor comparisons cross-run noise (thermal drift hits one side first).
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 8 : 8
        let maxS = args.count >= 5 ? Int(args[4]) ?? 4 : 4
        let base = makePrimedCache(pos: 8)
        evalPrimedState(base)
        let cache = base.snapshot()
        print("S   tensor min/mean   kernel min/mean   kernel-tensor")
        for S in 1 ... maxS {
            let x = MLXArray.zeros([1, S, 5120], dtype: .bfloat16)
            eval(x)
            func one() -> MLXArray {
                cache.restore(base)
                var h: MLXArray = x
                for i in 0 ..< 64 {
                    let p = "language_model.model.layers.\(i)."
                    let n1 = try! store.rmsNorm(p + "input_layernorm", h)
                    var mixed = MLXArray.zeros([1, S, 5120], dtype: .bfloat16)
                    if (i + 1) % 4 != 0 {
                        mixed = try! GDN.forward(n1, store: store, layer: i,
                                                 state: cache.gdnState(i))
                    } else {
                        mixed = try! Attention.forward(n1, store: store, layer: i,
                                                       cache: cache.attentionCache(i))
                    }
                    h = h + mixed
                    let n2 = try! store.rmsNorm(p + "post_attention_layernorm", h)
                    h = h + (try! MLP.forward(n2, store: store, layer: i))
                }
                return h
            }
            // Warm both paths for these shapes.
            GDN.metalOverride = false; eval(one())
            GDN.metalOverride = true; eval(one())
            var tms: [Double] = [], kms: [Double] = []
            for r in 0 ..< n {
                let order: [Bool] = r % 2 == 0 ? [false, true] : [true, false]
                for metal in order {
                    GDN.metalOverride = metal
                    let t0 = Date()
                    eval(one())
                    let dt = Date().timeIntervalSince(t0) * 1000
                    if metal { kms.append(dt) } else { tms.append(dt) }
                }
            }
            GDN.metalOverride = nil
            let tMin = tms.min()!, kMin = kms.min()!
            let tMean = tms.reduce(0, +) / Double(tms.count)
            let kMean = kms.reduce(0, +) / Double(kms.count)
            print(String(format: "%d   %6.2f / %6.2f   %6.2f / %6.2f   %+6.2f (%+.1f%%)",
                         S, tMin, tMean, kMin, kMean, kMin - tMin, (kMin / tMin - 1) * 100))
        }
    } catch {
        FileHandle.standardError.write(Data("benchpathS failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "quantinfo" {
    // Per-tensor bit depth inferred from the packed weight and scale shapes. Useful for
    // mixed 4/5-bit checkpoints (oQe) and for catching a mismatched loader.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        var hist: [Int: Int] = [:]
        var names: [Int: [String]] = [:]
        for (name, _) in store.index.weightMap where name.hasSuffix(".scales") {
            let base = String(name.dropLast(".scales".count))
            let w = try store.tensor(base + ".weight")
            let s = try store.tensor(name)
            let bits = WeightStore.quantBits(w, s)
            hist[bits, default: 0] += 1
            if names[bits, default: []].count < 3 { names[bits, default: []].append(base) }
        }
        print("quantized tensors:", hist.values.reduce(0, +), "bits:", hist)
        for (bits, list) in names.sorted(by: { $0.key < $1.key }) {
            print("  \(bits)-bit e.g.", list.joined(separator: ", "))
        }
    } catch {
        FileHandle.standardError.write(Data("quantinfo failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchserve" {
    runBenchServe(args)
} else if args.count >= 3, args[1] == "benchbatchprefill" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 1024 : 1024
        let seqs = min(max(args.count >= 5 ? Int(args[4]) ?? 2 : 2, 2), 4)
        let pattern: [Int32] = [9707, 1234, 5678, 198, 2, 220, 17, 15]
        func prompt(_ shift: Int) -> [Int32] {
            var p: [Int32] = []
            while p.count < n + 8 { p.append(contentsOf: pattern) }
            return Array((Array(p.dropFirst(shift)) + Array(p.prefix(shift))).prefix(n))
        }
        let prompts = (0 ..< seqs).map { prompt($0) }
        // serial baseline
        var serialLogits: [MLXArray] = []
        let t0 = Date()
        for p in prompts {
            let c = ModelCache()
            let r = try QwenModel.forwardAll(tokens: p, store: store, cache: c, lastTokenOnly: true)
            eval(r.logits)
            serialLogits.append(r.logits)
        }
        let ts = Date().timeIntervalSince(t0)
        // batched
        let bc = BatchedModelCache()
        let t1 = Date()
        let lg = try BatchModel.prefill(tokens: prompts, store: store, cache: bc)
        eval(lg)
        let tb = Date().timeIntervalSince(t1)
        var match = true
        for b in 0 ..< seqs {
            let a = argMax(serialLogits[b][0, 0]).item(Int32.self)
            let c = argMax(lg[b, 0]).item(Int32.self)
            if a != c { match = false }
        }
        print(String(format: "seqs %d  n %d  serial %.2f s (%.0f tok/s)  batched %.2f s (%.0f tok/s)  speedup %.2fx  next-token match %@",
                     seqs, n, ts, Double(seqs * n) / ts, tb, Double(seqs * n) / tb, ts / tb,
                     match ? "yes" : "no"))
    } catch {
        FileHandle.standardError.write(Data("benchbatchprefill failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchbatch" {
    // 2-4 sequence lockstep decode: prefill each, then batch one token per sequence
    // through the shared weights. Equal-length sequences only; no MTP. This measures
    // the aggregate/per-request gain of batching, not a scheduler.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 64 : 64
        let steps = args.count >= 5 ? Int(args[4]) ?? 16 : 16
        let seqs = min(max(args.count >= 6 ? Int(args[5]) ?? 2 : 2, 2), 4)
        let pattern: [Int32] = [9707, 1234, 5678, 198, 2, 220, 17, 15]
        func prompt(_ shift: Int, _ len: Int) -> [Int32] {
            var p: [Int32] = []
            while p.count < len + 4 { p.append(contentsOf: pattern) }
            let rotated = Array(p.dropFirst(shift)) + Array(p.prefix(shift))
            return Array(rotated.prefix(len))
        }
        var caches: [ModelCache] = []
        var nexts: [Int32] = []
        for b in 0 ..< seqs {
            let len = max(8, n - 2 * b)
            let c = ModelCache()
            let r = try QwenModel.forward(tokens: prompt(b, len), store: store, cache: c)
            eval(r.logits)
            caches.append(c)
            nexts.append(Int32(argMax(r.logits).item(Int32.self)))
        }

        let bc = BatchModel.from(caches)
        let lb = try BatchModel.forward(tokens: nexts.map { [$0] }, store: store, cache: bc)
        eval(lb)
        var maxd: Float = 0
        for b in 0 ..< seqs {
            let s = try QwenModel.forward(tokens: [nexts[b]], store: store,
                                          cache: caches[b].snapshot())
            eval(s.logits)
            maxd = max(maxd, abs(lb[b, 0] - s.logits).max().item(Float.self))
        }
        print(String(format: "batch vs single logits: max %.5f", maxd))

        func sequential() -> ([[Int32]], Double) {
            let cs = caches.map { $0.snapshot() }
            var toks = nexts
            var out = [[Int32]](repeating: [], count: seqs)
            let t = Date()
            for _ in 0 ..< steps {
                for b in 0 ..< seqs {
                    let r = try! QwenModel.forward(tokens: [toks[b]], store: store, cache: cs[b])
                    toks[b] = Int32(argMax(r.logits).item(Int32.self))
                    out[b].append(toks[b])
                }
            }
            return (out, Date().timeIntervalSince(t))
        }
        func batched() -> ([[Int32]], Double) {
            let cache = BatchModel.from(caches)
            var toks = nexts
            var out = [[Int32]](repeating: [], count: seqs)
            let t = Date()
            for _ in 0 ..< steps {
                let lg = try! BatchModel.forward(tokens: toks.map { [$0] }, store: store, cache: cache)
                let v = argMax(lg, axis: -1).asArray(Int32.self)
                for b in 0 ..< seqs {
                    toks[b] = v[b]
                    out[b].append(v[b])
                }
            }
            return (out, Date().timeIntervalSince(t))
        }
        _ = sequential()
        let (st, ts) = sequential()
        let (bt, tb) = batched()
        print(String(format: "sequential %.3f s  %.1f tok/s/req  %.1f aggregate",
                     ts, Double(steps) / ts, Double(seqs * steps) / ts))
        print(String(format: "batched    %.3f s  %.1f tok/s/req  %.1f aggregate",
                     tb, Double(steps) / tb, Double(seqs * steps) / tb))
        print("tokens match:", st == bt ? "yes" : "no")
    } catch {
        FileHandle.standardError.write(Data("benchbatch failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchctx" {
    // Decode cost as context grows: prefill a context, then time single-token decodes
    // with the growing KV cache. This is the instrument for the agent long-context case.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let ctx = args.count >= 4 ? Int(args[3]) ?? 4096 : 4096
        let n = args.count >= 5 ? Int(args[4]) ?? 32 : 32
        let pattern: [Int32] = [9707, 1234, 5678, 198, 2, 220, 17, 15]
        var prompt: [Int32] = []
        while prompt.count < ctx { prompt.append(contentsOf: pattern) }
        prompt = Array(prompt.prefix(ctx))
        let cache = ModelCache()
        let t0 = Date()
        let pre = try QwenModel.forwardAll(tokens: prompt, store: store, cache: cache, lastTokenOnly: true)
        eval(pre.logits)
        let preS = Date().timeIntervalSince(t0)
        let t1 = Date()
        for _ in 0 ..< n {
            let r = try QwenModel.forward(tokens: [198], store: store, cache: cache)
            eval(r.logits)
        }
        let decS = Date().timeIntervalSince(t1)
        print(String(format: "ctx=%d  prefill %.2f s (%.0f tok/s)  decode %.1f tok/s (%d tokens)",
                     ctx, preS, Double(ctx) / preS, Double(n) / decS, n))
    } catch {
        FileHandle.standardError.write(Data("benchctx failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 4, args[1] == "benchppl" {
    // Teacher-forced NLL/perplexity on a token-id file (comma separated), for checkpoint
    // quality A/Bs. Capped at 1024 tokens so the [1,N,vocab] logits stay small.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let raw = try String(contentsOfFile: args[3], encoding: .utf8)
        var ids = raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Int32($0) }
        let cap = args.count >= 5 ? Int(args[4]) ?? 512 : 512
        if ids.count > cap { ids = Array(ids.prefix(cap)) }
        guard ids.count >= 2 else { print("need >=2 tokens"); exit(1) }
        let r = try QwenModel.forwardAll(tokens: ids, store: store, cache: ModelCache())
        eval(r.logits)
        let n = ids.count - 1
        let lg = r.logits[0..., 0 ..< n, 0...]
        let logp = lg - lg.logSumExp(axis: -1, keepDims: true)
        let targets = MLXArray(Array(ids.dropFirst())).reshaped([1, n, 1])
        let picked = takeAlong(logp, targets, axis: -1)
        let nll = -picked.mean().item(Float.self)
        print(String(format: "tokens %d  nll %.6f  ppl %.6f", ids.count, nll, exp(nll)))
    } catch {
        FileHandle.standardError.write(Data("benchppl failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchprefill" {
    // Cold-cache prefill of one chunk; the Swift engine's prefill path, not the product's.
    // STRIM_OPTIME=1 prints a per-region table for the last rep (fences make it slower than a plain run).
    // STRIM_OPTIME_MTP=<head dir> also runs the MTP head over each chunk like EngineCore.coldChunk.
    // STRIM_OPTIME_SWEEP=<n> then fences one region name at a time (n reps each, interleaved with n
    // unfenced reps) and prints raw/wall pairs so the per-call fence cost can be differenced out.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 1024 : 1024
        let reps = args.count >= 5 ? Int(args[4]) ?? 3 : 3
        let chunk = args.count >= 6 ? Int(args[5]) ?? n : n  // optional: prefill step size
        var head: WeightStore? = nil
        if OpTimer.on, let hd = ProcessInfo.processInfo.environment["STRIM_OPTIME_MTP"], !hd.isEmpty {
            let h = try WeightStore(dir: URL(fileURLWithPath: hd))
            h.useIntegratedMTPPrefixIfNeeded()
            head = h
        }
        _ = try QwenModel.forwardAll(tokens: [9707], store: store, cache: ModelCache())
        if OpTimer.on { OpTimer.calibrate() }
        let base: [Int32] = [9707, 1234, 5678, 198, 2, 220, 17, 15]
        var prompt: [Int32] = []
        while prompt.count < n { prompt.append(contentsOf: base) }
        prompt = Array(prompt.prefix(n))
        func rep() throws -> Double {
            let cache = ModelCache()
            if OpTimer.on { OpTimer.reset() }
            let mtp = head == nil ? nil : MTPState()
            var carry: MLXArray? = nil
            let t0 = Date()
            var start = 0
            var last: MLXArray? = nil
            while start < n {
                let end = min(start + chunk, n)
                let out = try QwenModel.forwardAll(tokens: Array(prompt[start ..< end]), store: store, cache: cache, lastTokenOnly: true)
                if end < n { eval(out.logits) } else { last = out.logits }
                if let head, let mtp {
                    // Mirrors coldChunk's head work (norm over the chunk, head step, carry, eval of K/V).
                    let part = Array(prompt[start ..< end]), m = part.count
                    OpTimer.ctx = "mtp"
                    let hn = try OpTimer.time("norm", flops: Double(m * 5120) * 4, bytes: Double(m * 5120 * 4),
                                              inputs: [out.hidden]) {
                        try store.rmsNorm("language_model.model.norm", out.hidden)
                    }
                    let isLast = end == n
                    var htoks = start == 0 ? Array(prompt[1 ..< end]) : part
                    var hid = carry.map { concatenated([$0, hn[0..., 0 ..< (m - 1), 0...]], axis: 1) }
                        ?? hn[0..., 0 ..< (m - 1), 0...]
                    if isLast {
                        htoks.append(prompt[0])
                        hid = carry.map { concatenated([$0, hn], axis: 1) } ?? hn
                    }
                    let inner0 = OpTimer.rawNs(ctx: "mtp")
                    let s0 = OpTimer.nowNanos()
                    let ho = try MTP.step(tokens: htoks, hidden: hid, target: store, head: head, state: mtp)
                    eval(ho)
                    let total = OpTimer.nowNanos() &- s0
                    let inner = OpTimer.rawNs(ctx: "mtp") &- inner0
                    OpTimer.recordRegion("mtp_other", ns: total > inner ? total - inner : 0, ctx: "mtp")
                    carry = hn[0..., (m - 1) ..< m, 0...]
                    if let k = mtp.attention.keys, let v = mtp.attention.values { eval(k, v, carry!) }
                    OpTimer.ctx = "main"
                }
                start = end
            }
            eval(last!)
            return Date().timeIntervalSince(t0)
        }
        var lastDt = 0.0
        for r in 0 ..< reps {
            let dt = try rep()
            lastDt = dt
            print(String(format: "n=%d chunk=%d %.2f s  %.0f tok/s  (rep %d)", n, chunk, dt, Double(n) / dt, r))
        }
        if OpTimer.on {
            print("\nSTRIM_OPTIME report (n=\(n) chunk=\(chunk), last rep, MTP head \(head == nil ? "off" : "on"))")
            print(OpTimer.report(wallSeconds: lastDt, tokens: n))
        }
        if OpTimer.on, let sw = ProcessInfo.processInfo.environment["STRIM_OPTIME_SWEEP"].flatMap({ Int($0) }), sw > 0 {
            var names: [String] = []
            for r in OpTimer.rows() where !names.contains(r.name) && r.name != "mtp_other" { names.append(r.name) }
            let calls = Dictionary(OpTimer.rows().map { ($0.name, $0.calls) }, uniquingKeysWith: +)
            if let only = ProcessInfo.processInfo.environment["STRIM_OPTIME_SWEEP_NAMES"], !only.isEmpty {
                let keep = Set(only.split(separator: ",").map(String.init))
                names = names.filter { keep.contains($0) }
            }
            print("SWEEP n=\(n) chunk=\(chunk) reps=\(sw) fence_us=\(Int(OpTimer.fenceNs / 1e3))")
            print("SWEEP_HEADER name calls raw_ms wall_x_ms wall_base_ms")
            for name in names {
                OpTimer.only = []
                var bw: [Double] = []
                for _ in 0 ..< sw { bw.append(try rep()) }
                OpTimer.only = [name]
                var xw: [Double] = [], raw: [Double] = []
                for _ in 0 ..< sw {
                    xw.append(try rep())
                    raw.append(OpTimer.rows().filter { $0.name == name }.reduce(0) { $0 + $1.rawMs })
                }
                OpTimer.only = []
                bw.append(try rep())   // trailing base brackets drift: base = mean of before/after
                let b = (bw.dropLast().reduce(0, +) / Double(sw) + bw.last!) / 2
                print(String(format: "SWEEP %@ %d %.2f %.2f %.2f", name, calls[name] ?? 0,
                             raw.reduce(0, +) / Double(sw), xw.reduce(0, +) / Double(sw) * 1e3, b * 1e3))
            }
            OpTimer.only = nil
        }
    } catch {
        FileHandle.standardError.write(Data("benchprefill failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 2, args[1] == "benchgemm" {
    // GEMM roofline microbench: bf16 8192^3 plus the real 4-bit qmm shapes of the 27B at M in {512,1024,4096}.
    // Pipelined = R independent calls evaluated together (what the plain run sees); fenced = eval per call
    // (what OpTimer sees). Optional args[2] = comma list of M values. Weights are random; only speed matters.
    let ms = args.count >= 3 ? args[2].split(separator: ",").compactMap { Int($0) } : [512, 1024, 4096]
    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    func line(_ name: String, _ m: Int, _ n: Int, _ k: Int, _ run: () -> MLXArray, outBytes: Int, wBytes: Int) {
        let flops = 2.0 * Double(m) * Double(n) * Double(k)
        let r = max(3, min(24, Int(2.5e9 / Double(max(outBytes, 1)))))
        eval(run()); eval(run())
        var pip: [Double] = [], fen: [Double] = []
        for _ in 0 ..< 3 {
            let t0 = now()
            var outs: [MLXArray] = []
            for _ in 0 ..< r { outs.append(run()) }
            eval(outs)
            pip.append((now() - t0) / Double(r))
            outs = []
            let t1 = now()
            for _ in 0 ..< r { eval(run()) }
            fen.append((now() - t1) / Double(r))
        }
        pip.sort(); fen.sort()
        let tp = pip[1], tf = fen[1]
        print(String(format: "GEMM %@ M=%d N=%d K=%d  pipelined %.3f ms %.1f TF/s %.0f GB/s(w)  fenced %.3f ms %.1f TF/s  fence %.3f ms",
                     name, m, n, k, tp * 1e3, flops / tp / 1e12, Double(wBytes) / tp / 1e9, tf * 1e3, flops / tf / 1e12, (tf - tp) * 1e3))
    }
    MLXRandom.seed(1)
    do {
        let a = MLXRandom.normal([8192, 8192]).asType(.bfloat16)
        let b = MLXRandom.normal([8192, 8192]).asType(.bfloat16)
        eval(a, b)
        line("bf16-dense", 8192, 8192, 8192, { matmul(a, b) }, outBytes: 8192 * 8192 * 2, wBytes: 8192 * 8192 * 2)
    }
    let shapes: [(String, Int, Int)] = [
        ("mlp.gateup", 34816, 5120), ("mlp.down", 5120, 17408), ("gdn.in_proj_qkv", 10240, 5120),
        ("gdn.in_proj_z", 6144, 5120), ("gdn.out_proj", 5120, 6144), ("attn.q_proj", 12288, 5120),
        ("attn.kv_proj", 1024, 5120), ("attn.o_proj", 5120, 6144),
    ]
    for (name, n, k) in shapes {
        let w = MLXRandom.normal([n, k]).asType(.bfloat16)
        let (wq, sc, bi0) = quantized(w, groupSize: 64, bits: 4)
        let bi = bi0!
        eval(wq, sc, bi)
        let wBytes = wq.nbytes + sc.nbytes + bi.nbytes
        for m in ms {
            let x = MLXRandom.normal([1, m, k]).asType(.bfloat16)
            eval(x)
            line("qmm4 " + name, m, n, k, {
                quantizedMatmul(x, wq, scales: sc, biases: bi, transpose: true, groupSize: 64, bits: 4)
            }, outBytes: m * n * 2, wBytes: wBytes)
        }
        // bf16 reference at M=1024 for the same shape (dequantized weights), to read qmm vs dense.
        let wd = dequantized(wq, scales: sc, biases: bi, groupSize: 64, bits: 4)
        let xd = MLXRandom.normal([1, 1024, k]).asType(.bfloat16)
        eval(wd, xd)
        line("bf16 " + name, 1024, n, k, { matmul(xd, wd.transposed(-1, -2)) }, outBytes: 1024 * n * 2, wBytes: n * k * 2)
    }
} else if args.count >= 2, args[1] == "benchopmicro" {
    // Non-GEMM op microbench at the chunk shapes of the 27B (S=1024): pipelined (R independent calls, one eval,
    // the plain run's regime) vs fenced (eval per call, OpTimer's regime). Random data; only speed matters.
    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    func line(_ name: String, _ run: () -> [MLXArray], r: Int = 24) {
        eval(run()); eval(run())
        var pip: [Double] = [], fen: [Double] = []
        for _ in 0 ..< 5 {
            let t0 = now()
            var outs: [MLXArray] = []
            for _ in 0 ..< r { outs.append(contentsOf: run()) }
            eval(outs)
            pip.append((now() - t0) / Double(r))
            outs = []
            let t1 = now()
            for _ in 0 ..< r { eval(run()) }
            fen.append((now() - t1) / Double(r))
        }
        pip.sort(); fen.sort()
        print(String(format: "OP %@  pipelined %.4f ms  fenced %.4f ms", name, pip[2] * 1e3, fen[2] * 1e3))
    }
    MLXRandom.seed(3)
    let S = 1024, H = 5120
    func bf(_ shape: [Int], _ scale: Float = 1) -> MLXArray { (MLXRandom.normal(shape) * scale).asType(.bfloat16) }
    let q = bf([1, S, 16, 128], 0.05), k = bf([1, S, 16, 128], 0.05), v = bf([1, S, 48, 128], 0.5)
    let g = exp(-MLXRandom.uniform(low: 0.001, high: 0.2, [1, S, 48]))
    let beta = sigmoid(MLXRandom.normal([1, S, 48]))
    let ssm = (MLXRandom.normal([1, 48, 128, 128]) * 0.1).asType(.float32)
    let convIn = bf([1, S + 3, 10240]), convW = bf([10240, 4])
    let ones = MLXArray.ones([128], dtype: .bfloat16)
    let aLog = MLXRandom.normal([48]), dtBias = MLXRandom.normal([48])
    let bProj = bf([1, S, 48]), aProj = bf([1, S, 48])
    let z = bf([1, S, 48, 128]), yRec = bf([1, S, 48, 128]), normW = MLXArray.ones([128], dtype: .bfloat16)
    let convOut = bf([1, S, 10240])
    let hid = bf([1, S, H]), hidW = MLXArray.ones([H], dtype: .bfloat16)
    let gu = bf([1, S, 34816])
    eval(q, k, v, g, beta, ssm, convIn, convW, ones, aLog, dtBias, bProj, aProj, z, yRec, normW, convOut, hid, hidW, gu)
    line("gdn.rec", { let r = GDNMetal.runBlocked(q: q, k: k, v: v, g: g, beta: beta, ssm: ssm); return [r.y, r.ssm] })
    line("gdn.conv", { [GDNMetal.convSilu(convIn: convIn, weight: convW)] })
    line("gdn.qknorm_bg", {
        let qr = convOut[0..., 0..., 0 ..< 2048].reshaped([1, S, 16, 128])
        let kr = convOut[0..., 0..., 2048 ..< 4096].reshaped([1, S, 16, 128])
        let a = MLXFast.rmsNorm(qr, weight: ones, eps: 1e-6) * Float(0.0078125)
        let b = MLXFast.rmsNorm(kr, weight: ones, eps: 1e-6) * Float(0.08838835)
        let (be, ga) = Fused.betaG(bProj, aProj, aLog: aLog, dtBias: dtBias)
        return [a, b, be, ga]
    })
    line("gdn.norm_gate", { [Fused.gatedNorm(z, MLXFast.rmsNorm(yRec, weight: normW, eps: 1e-6))] })
    do {
        let (wq, sc, bi0) = quantized(MLXRandom.normal([48, H]).asType(.bfloat16), groupSize: 64, bits: 4)
        let bi = bi0!
        eval(wq, sc, bi)
        line("gdn.proj_ba(2 calls)", {
            [quantizedMatmul(hid, wq, scales: sc, biases: bi, transpose: true, groupSize: 64, bits: 4),
             quantizedMatmul(hid, wq, scales: sc, biases: bi, transpose: true, groupSize: 64, bits: 4)]
        })
    }
    line("norm", { [MLXFast.rmsNorm(hid, weight: hidW, eps: 1e-6)] })
    line("resid", { [hid + hid] })
    line("mlp.act", { [Fused.swiglu(gu[0..., 0..., 0 ..< 17408], gu[0..., 0..., 17408 ..< 34816])] })
    let aq = bf([1, S, 24, 2, 256])
    let kp = bf([1, S, 4, 256]), vp = bf([1, S, 4, 256])
    let qn = MLXArray.ones([256], dtype: .bfloat16)
    let flat = bf([1, S, 6144]), gate = bf([1, S, 6144])
    eval(aq, kp, vp, qn, flat, gate)
    line("attn.qknorm", {
        let h = aq.split(parts: 2, axis: 3)
        let q0 = h[0].squeezed(axis: 3), gt = h[1].squeezed(axis: 3).reshaped([1, S, 6144])
        return [MLXFast.rmsNorm(q0, weight: qn, eps: 1e-6).transposed(0, 2, 1, 3),
                MLXFast.rmsNorm(kp, weight: qn, eps: 1e-6).transposed(0, 2, 1, 3), gt]
    })
    line("attn.gate", { [Fused.attnGate(flat, gate)] })
    for P in [0, 2048, 8192, 15360] {
        let qq = bf([1, 24, S, 256]), kk = bf([1, 4, P + S, 256]), vv = bf([1, 4, P + S, 256])
        eval(qq, kk, vv)
        line("attn.rope(offset=\(P))", {
            [MLXFast.RoPE(qq, dimensions: 64, traditional: false, base: 10_000_000, scale: 1.0, offset: P),
             MLXFast.RoPE(kk[0..., 0..., 0 ..< S, 0...], dimensions: 64, traditional: false, base: 10_000_000, scale: 1.0, offset: P)]
        })
        line("attn.sdpa(prefix=\(P))", {
            [MLXFast.scaledDotProductAttention(queries: qq, keys: kk, values: vv, scale: 0.0625, mask: .causal)]
        }, r: 8)
    }
} else if args.count >= 3, args[1] == "benchfuse" {
    // The GDN layer's four projections run at ~225-240 GB/s while equally sized
    // MLP GEMVs reach ~490-600. If that is a narrow-grid effect, one fused
    // [qkv;z;b;a] qmv (N=16480) should be much faster than four separate calls.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 20 : 20
        let p = "language_model.model.layers.0.linear_attn."
        let x = MLXArray.zeros([1, 1, 5120], dtype: .bfloat16)
        var w: [MLXArray] = [], s: [MLXArray] = [], b: [MLXArray] = []
        for name in ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a"] {
            w.append(try store.tensor(p + name + ".weight"))
            s.append(try store.tensor(p + name + ".scales"))
            b.append(try store.tensor(p + name + ".biases"))
        }
        let wf = concatenated(w, axis: 0), sf = concatenated(s, axis: 0), bf = concatenated(b, axis: 0)
        eval(wf, sf, bf)   // must be materialised, else every call re-does the concat
        func split() -> [MLXArray] {
            (0 ..< 4).map { quantizedMatmul(x, w[$0], scales: s[$0], biases: b[$0],
                                            transpose: true, groupSize: 64, bits: 4) }
        }
        func fused() -> MLXArray {
            quantizedMatmul(x, wf, scales: sf, biases: bf, transpose: true, groupSize: 64, bits: 4)
        }
        func bench(_ body: () -> [MLXArray]) -> Double {
            eval(body())
            let t0 = Date()
            var outs: [MLXArray] = []
            for _ in 0 ..< n { outs.append(contentsOf: body()) }
            eval(outs)
            return Date().timeIntervalSince(t0) / Double(n) * 1000
        }
        let bytes = Double(w.reduce(0) { $0 + $1.shape[0] }) * 5120 * 0.5 / 1e6
        let msS = bench { split() }, msF = bench { [fused()] }
        let ds = abs(concatenated(split(), axis: -1) - fused())
        eval(ds)
        print(String(format: "split 4 qmv  %6.3f ms  %5.1f MB  %5.0f GB/s", msS, bytes, bytes / msS))
        print(String(format: "fused 1 qmv  %6.3f ms  %5.1f MB  %5.0f GB/s   speedup %.2fx",
                     msF, bytes, bytes / msF, msS / msF))
        print(String(format: "max |split - fused| = %.6f", ds.max().item(Float.self)))
    } catch {
        FileHandle.standardError.write(Data("benchfuse failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchcompile" {
    // Direct A/B of `compile` on real weights, eager vs one compiled function with
    // the same math: the 64-layer MLP stack, or (`model`) the whole 64-layer pass.
    // `model` is stateless (no KV, offset 0) so it needs no cache refactor, but it
    // has the same op count and shapes as a decode pass — which is what `compile`
    // caches, so the delta is the real ceiling for a compiled step.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 10 : 10
        let whole = args.count >= 5 && args[4] == "model"
        let x = MLXArray.zeros([1, 1, 5120], dtype: .bfloat16)
        func stack(_ h0: MLXArray) -> MLXArray {
            var h = h0
            if whole {
                for i in 0 ..< 64 {
                    h = try! DecoderLayer.forward(h, store: store, layer: i, cache: nil)
                }
                return try! store.linear("language_model.lm_head",
                                         try! store.rmsNorm("language_model.model.norm", h))
            }
            for i in 0 ..< 64 {
                let p = "language_model.model.layers.\(i)."
                h = h + (try! MLP.forward(try! store.rmsNorm(p + "post_attention_layernorm", h),
                                          store: store, layer: i))
            }
            return h
        }
        let compiled = compile(inputs: [x], outputs: []) { (a: [MLXArray]) -> [MLXArray] in
            [stack(a[0])]
        }
        func time(_ body: () -> MLXArray) -> Double {
            eval(body())                        // warm
            var best = Double.infinity
            for _ in 0 ..< n {
                let t0 = Date()
                eval(body())
                best = min(best, Date().timeIntervalSince(t0) * 1000)
            }
            return best
        }
        let eager = time { stack(x) }
        let comp = time { compiled([x])[0] }
        _ = stack(x)
        let d = abs(stack(x) - compiled([x])[0])
        eval(d)
        print(String(format: "64-layer %@: eager %.2f ms   compiled %.2f ms   delta %+.2f ms (%.0f%%)",
                     whole ? "model pass" : "MLP stack", eager, comp, comp - eager,
                     (comp - eager) / eager * 100))
        print(String(format: "max |eager - compiled| = %.6f", d.max().item(Float.self)))
    } catch {
        FileHandle.standardError.write(Data("benchcompile failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchgvS" {
    // Batched hand GEMV (QGEMV.multi) vs MLX quantizedMatmul at M=2..4.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 12 : 12
        let p = "language_model.model.layers.0.linear_attn."
        func row(_ name: String, _ prefix: String, _ nOut: Int, _ nIn: Int) {
            let w = try! store.tensor(prefix + ".weight")
            let s = try! store.tensor(prefix + ".scales")
            let b = try! store.tensor(prefix + ".biases")
            let mb = Double(nOut) * Double(nIn) * 0.5 / 1e6
            var out = String(format: "%-6@", name as NSString)
            for M in 2 ... 4 {
                let x = MLXRandom.normal([1, M, nIn]).asType(.bfloat16)
                eval(x)
                // Interleave the two variants inside one process and take the minimum of
                // each: run-to-run variance on sub-millisecond kernels is up to 2x, but a
                // ratio measured this way repeats to a few percent.
                func timeOnce(_ f: () -> MLXArray) -> Double {
                    let t0 = Date()
                    eval((0 ..< n).map { _ in f() })   // all outputs, not just the last
                    return Date().timeIntervalSince(t0) * 1000 / Double(n)
                }
                let mlxClosure = { quantizedMatmul(x, w, scales: s, biases: b, transpose: true, groupSize: 64, bits: 4) }
                let gvClosure = { QGEMV.multi(x: x, w: w, scales: s, biases: b) }
                _ = timeOnce(mlxClosure); _ = timeOnce(gvClosure)      // warm both paths
                var mlx = Double.infinity, gv = Double.infinity
                for _ in 0 ..< 8 {
                    mlx = min(mlx, timeOnce(mlxClosure))
                    gv = min(gv, timeOnce(gvClosure))
                }
                let d = abs(gvClosure() - mlxClosure())
                eval(d)
                out += String(format: "  M%d mlx%5.0f gv%5.0f %.2fx d%.3f", M, mb / mlx, mb / gv, mlx / gv,
                              d.max().item(Float.self))
            }
            print(out)
        }
        row("qkv", p + "in_proj_qkv", 10240, 5120)
        row("z", p + "in_proj_z", 6144, 5120)
        row("gate", "language_model.model.layers.0.mlp.gate_proj", 17408, 5120)
        row("down", "language_model.model.layers.0.mlp.down_proj", 5120, 17408)
    } catch {
        FileHandle.standardError.write(Data("benchgvS failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "logithash" {
    // Per-position checksum + top-2 margin of the greedy logits, for bit-exactness
    // comparisons between two code paths (run twice, diff the output).
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 16 : 16
        let prompt: [Int32] = args.count >= 5
            ? args[4].split(separator: ",").map { Int32($0)! } : [9707, 1234, 5678]
        let cache = ModelCache()
        var r = try QwenModel.forward(tokens: prompt, store: store, cache: cache)
        var tok = Int32(argMax(r.logits).item(Int32.self))
        for step in 0 ..< n {
            let lg = r.logits
            let bits = lg.asType(.float32).asArray(Float.self)
            var h: UInt64 = 1469598103934665603
            for v in bits { h = (h ^ UInt64(v.bitPattern)) &* 1099511628211 }
            let top = lg.asArray(Float.self).enumerated().sorted { $0.element > $1.element }.prefix(2)
            print(String(format: "pos %3d tok %6d hash %016llx top1 %d %.6f top2 %d %.6f margin %.6f",
                         step, tok, h, top[0].offset, top[0].element, top[1].offset, top[1].element,
                         top[0].element - top[1].element))
            tok = Int32(argMax(r.logits).item(Int32.self))
            r = try QwenModel.forward(tokens: [tok], store: store, cache: cache)
        }
    } catch {
        FileHandle.standardError.write(Data("logithash failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchsplitS" {
    // Where does a multi-token verify pass lose time relative to S=1? It streams the
    // same weights once, so any excess is per-token work or a kernel-path switch.
    // Subtractive, like `benchsplit`, but at fixed shapes and any S.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 10 : 10
        let S = args.count >= 5 ? Int(args[4]) ?? 3 : 3
        let base = makePrimedCache(pos: 8)
        evalPrimedState(base)
        let x = MLXArray.zeros([1, S, 5120], dtype: .bfloat16)
        eval(x)
        let cache = base.snapshot()
        func run(_ skip: String) -> (mean: Double, best: Double) {
            func one() -> MLXArray {
                cache.restore(base)
                var h = x
                for i in 0 ..< 64 {
                    let p = "language_model.model.layers.\(i)."
                    let n1 = try! store.rmsNorm(p + "input_layernorm", h)
                    var mixed = MLXArray.zeros([1, S, 5120], dtype: .bfloat16)
                    if (i + 1) % 4 != 0 {
                        if skip != "gdn" {
                            mixed = try! GDN.forward(n1, store: store, layer: i, state: cache.gdnState(i))
                        }
                    } else {
                        if skip != "attn" {
                            mixed = try! Attention.forward(n1, store: store, layer: i,
                                                           cache: cache.attentionCache(i))
                        }
                    }
                    h = h + mixed
                    if skip != "mlp" {
                        let n2 = try! store.rmsNorm(p + "post_attention_layernorm", h)
                        h = h + (try! MLP.forward(n2, store: store, layer: i))
                    }
                }
                return h
            }
            eval(one())
            var total = 0.0, best = Double.infinity
            for _ in 0 ..< n {
                let t0 = Date()
                eval(one())
                let dt = Date().timeIntervalSince(t0) * 1000
                total += dt; best = min(best, dt)
            }
            return (total / Double(n), best)
        }
        let full = run("")
        let noG = run("gdn"), noA = run("attn"), noM = run("mlp")
        print(String(format: "S=%d  full %6.2f ms (min %6.2f)", S, full.mean, full.best))
        print(String(format: "  no gdn  %6.2f  -> gdn  %5.2f ms", noG.mean, full.mean - noG.mean))
        print(String(format: "  no attn %6.2f  -> attn %5.2f ms", noA.mean, full.mean - noA.mean))
        print(String(format: "  no mlp  %6.2f  -> mlp  %5.2f ms", noM.mean, full.mean - noM.mean))
    } catch {
        FileHandle.standardError.write(Data("benchsplitS failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchqmmS" {
    // Does MLX's quantizedMatmul fall off a fast path when M (tokens per pass) > 1?
    // "3xM1" is what three separate single-token calls would cost on the same weights.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 16 : 16
        let p = "language_model.model.layers.0.linear_attn."
        func row(_ name: String, _ prefix: String, _ nOut: Int, _ nIn: Int) {
            let w = try! store.tensor(prefix + ".weight")
            let s = try! store.tensor(prefix + ".scales")
            let b = try! store.tensor(prefix + ".biases")
            let mb = Double(nOut) * Double(nIn) * 0.5 / 1e6
            var out = String(format: "%-6@ %6.1f MB", name as NSString, mb)
            var m1 = 0.0
            for M in 1 ... 4 {
                let x = MLXArray.zeros([1, M, nIn], dtype: .bfloat16)
                eval(x)
                func body() -> [MLXArray] {
                    (0 ..< n).map { _ in
                        quantizedMatmul(x, w, scales: s, biases: b, transpose: true,
                                        groupSize: 64, bits: 4)
                    }
                }
                eval(body())
                var best = Double.infinity
                for _ in 0 ..< 3 {
                    let t0 = Date()
                    eval(body())
                    best = min(best, Date().timeIntervalSince(t0) * 1000 / Double(n))
                }
                if M == 1 { m1 = best }
                out += String(format: "  M%d %6.3f/%5.0fGBs", M, best, mb / best)
            }
            out += String(format: "   3xM1 %6.3f", 3 * m1)
            print(out)
        }
        row("qkv", p + "in_proj_qkv", 10240, 5120)
        row("z", p + "in_proj_z", 6144, 5120)
        row("gate", "language_model.model.layers.0.mlp.gate_proj", 17408, 5120)
        row("down", "language_model.model.layers.0.mlp.down_proj", 5120, 17408)
    } catch {
        FileHandle.standardError.write(Data("benchqmmS failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchqmmM" {
    // Large-M quantized matmul, 2D [M,K] vs 3D [1,M,K]: the prefill question is whether the
    // batch-of-one dimension is forcing MLX off its fast GEMM path.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let M = args.count >= 4 ? Int(args[3]) ?? 1024 : 1024
        func measure(_ label: String, _ w: MLXArray, _ s: MLXArray, _ b: MLXArray,
                     _ nOut: Int, _ nIn: Int) {
            let mb = Double(nOut) * Double(nIn) * 0.5 / 1e6
            let gf = 2.0 * Double(M) * Double(nOut) * Double(nIn) / 1e9
            func best(_ x: MLXArray) -> Double {
                let bits = WeightStore.quantBits(w, s)
                let f = { quantizedMatmul(x, w, scales: s, biases: b, transpose: true,
                                          groupSize: 64, bits: bits) }
                eval(f())
                var t = Double.infinity
                for _ in 0 ..< 3 {
                    let t0 = Date(); eval(f()); t = min(t, Date().timeIntervalSince(t0) * 1000)
                }
                return t
            }
            let x3 = MLXArray.zeros([1, M, nIn], dtype: .bfloat16)
            let x2 = MLXArray.zeros([M, nIn], dtype: .bfloat16)
            eval(x3, x2)
            let t3 = best(x3), t2 = best(x2)
            print(String(format: "%-12@ M=%d 3D %7.2f ms (%5.1f TF/s) | 2D %7.2f ms (%5.1f TF/s) | speedup %.2fx",
                         label, M, t3, gf / t3, t2, gf / t2, t3 / t2))
        }
        let p = "language_model.model.layers.0.linear_attn."
        func q(_ name: String) -> (MLXArray, MLXArray, MLXArray) {
            (try! store.tensor(name + ".weight"), try! store.tensor(name + ".scales"),
             try! store.tensor(name + ".biases"))
        }
        let (qw, qs, qb) = q(p + "in_proj_qkv")
        measure("qkv", qw, qs, qb, 10240, 5120)
        let f = try store.mlpFused(0)
        measure("gate+up", f.w, f.s, f.b, 34816, 5120)
        let (dw, ds, db) = q("language_model.model.layers.0.mlp.down_proj")
        measure("down", dw, ds, db, 5120, 17408)
    } catch {
        FileHandle.standardError.write(Data("benchqmmM failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchbuild" {
    // Splits a decode pass into "build the lazy graph" vs "run it on the GPU".
    // The build-only number is the hard ceiling on what any `compile` can save:
    // compile caches the traced graph, it does not make the kernels faster.
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 20 : 20
        let base = makePrimedCache(pos: 8)
        evalPrimedState(base)
        let cache = base.snapshot()
        _ = try QwenModel.forward(tokens: [198], store: store, cache: cache)

        var sink: MLXArray?
        let tb = Date()
        for _ in 0 ..< n {
            cache.restore(base)          // drop last graph, same tensors as before
            sink = try QwenModel.forward(tokens: [198], store: store, cache: cache).logits
        }
        let buildMs = Date().timeIntervalSince(tb) / Double(n) * 1000
        eval(sink!)

        let tf = Date()
        for _ in 0 ..< n {
            cache.restore(base)
            let r = try QwenModel.forward(tokens: [198], store: store, cache: cache)
            eval(r.logits, cache)
        }
        let fullMs = Date().timeIntervalSince(tf) / Double(n) * 1000
        print(String(format: "build-only %.2f ms   full %.2f ms   gpu %.2f ms   (%.0f%% build)",
                     buildMs, fullMs, fullMs - buildMs, buildMs / fullMs * 100))
    } catch {
        FileHandle.standardError.write(Data("benchbuild failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "qgemv" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let p = "language_model.model.layers.0.linear_attn."
        func check(_ name: String, _ prefix: String, _ nIn: Int) {
            let w = try! store.tensor(prefix + ".weight")
            let sc = try! store.tensor(prefix + ".scales")
            let bs = try! store.tensor(prefix + ".biases")
            let x = MLXRandom.normal([1, 1, nIn]).asType(.bfloat16)
            let ref = quantizedMatmul(x, w, scales: sc, biases: bs, transpose: true,
                                      groupSize: 64, bits: 4)
            let got = QGEMV.linear(x: x, w: w, scales: sc, biases: bs)
            eval(ref, got)
            let d = abs(ref - got)
            print(String(format: "%-6@ max %.5f mean %.6f", name as NSString,
                         d.max().item(Float.self), d.mean().item(Float.self)))
            // throughput
            var outs: [MLXArray] = []
            for _ in 0 ..< 20 { outs.append(QGEMV.linear(x: x, w: w, scales: sc, biases: bs)) }
            eval(outs)
            let t0 = Date()
            var outs2: [MLXArray] = []
            for _ in 0 ..< 50 { outs2.append(QGEMV.linear(x: x, w: w, scales: sc, biases: bs)) }
            eval(outs2)
            let ms = Date().timeIntervalSince(t0) / 50 * 1000
            let mb = Double(w.shape[0]) * Double(nIn) * 0.5 / 1e6
            print(String(format: "       %7.3f ms  %6.1f MB  %6.0f GB/s", ms, mb, mb / ms))
        }
        check("qkv", p + "in_proj_qkv", 5120)
        check("z", p + "in_proj_z", 5120)
        check("out", p + "out_proj", 6144)
        check("gate", "language_model.model.layers.0.mlp.gate_proj", 5120)
        check("down", "language_model.model.layers.0.mlp.down_proj", 17408)
    } catch {
        FileHandle.standardError.write(Data("qgemv failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchqmm" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let p = "language_model.model.layers.0.linear_attn."
        let x = MLXArray.zeros([1, 1, 5120], dtype: .bfloat16)
        func run(_ name: String, _ prefix: String, _ nOut: Int, _ xin: MLXArray, _ nIn: Int) {
            let w = try! store.tensor(prefix + ".weight")
            let s = try! store.tensor(prefix + ".scales")
            let b = try! store.tensor(prefix + ".biases")
            var outs: [MLXArray] = []
            outs.reserveCapacity(50)
            for _ in 0 ..< 50 {
                outs.append(quantizedMatmul(xin, w, scales: s, biases: b, transpose: true,
                                            groupSize: 64, bits: 4))
            }
            eval(outs)
            let t0 = Date()
            var outs2: [MLXArray] = []
            for _ in 0 ..< 50 {
                outs2.append(quantizedMatmul(xin, w, scales: s, biases: b, transpose: true,
                                             groupSize: 64, bits: 4))
            }
            eval(outs2)
            let ms = Date().timeIntervalSince(t0) / 50 * 1000
            let mb = Double(nOut) * Double(nIn) * 0.5 / 1e6
            print(String(format: "%-10@ %7.3f ms  %6.1f MB  %6.0f GB/s", name as NSString, ms, mb, mb / ms))
        }
        let x6 = MLXArray.zeros([1, 1, 6144], dtype: .bfloat16)
        let x17 = MLXArray.zeros([1, 1, 17408], dtype: .bfloat16)
        run("qkv", p + "in_proj_qkv", 10240, x, 5120)
        run("z", p + "in_proj_z", 6144, x, 5120)
        run("b", p + "in_proj_b", 48, x, 5120)
        run("out", p + "out_proj", 5120, x6, 6144)
        run("gate", "language_model.model.layers.0.mlp.gate_proj", 17408, x, 5120)
        run("down", "language_model.model.layers.0.mlp.down_proj", 5120, x17, 17408)
        run("lm_head", "language_model.lm_head", 151936, x, 5120)
    } catch {
        FileHandle.standardError.write(Data("benchqmm failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "benchsplit" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 10 : 10
        let S = args.count >= 5 ? Int(args[4]) ?? 1 : 1
        let x = MLXArray.zeros([1, S, 5120], dtype: .bfloat16)
        func run(_ skip: String) -> Double {
            let cache = ModelCache()
            var h = x
            func one() -> MLXArray {
                var h = x
                for i in 0 ..< 64 {
                    let p = "language_model.model.layers.\(i)."
                    let n1 = try! store.rmsNorm(p + "input_layernorm", h)
                    var mixed = MLXArray.zeros([1, S, 5120], dtype: .bfloat16)
                    if (i + 1) % 4 != 0 {
                        if skip != "gdn" { mixed = try! GDN.forward(n1, store: store, layer: i, state: cache.gdnState(i)) }
                    } else {
                        if skip != "attn" { mixed = try! Attention.forward(n1, store: store, layer: i, cache: cache.attentionCache(i)) }
                    }
                    h = h + mixed
                    if skip != "mlp" {
                        let n2 = try! store.rmsNorm(p + "post_attention_layernorm", h)
                        h = h + (try! MLP.forward(n2, store: store, layer: i))
                    }
                }
                return h
            }
            eval(one())
            let t0 = Date()
            for _ in 0 ..< n { eval(one()) }
            return Date().timeIntervalSince(t0) / Double(n) * 1000
        }
        print(String(format: "full      %7.2f ms", run("")))
        print(String(format: "no gdn    %7.2f ms", run("gdn")))
        print(String(format: "no attn   %7.2f ms", run("attn")))
        print(String(format: "no mlp    %7.2f ms", run("mlp")))
    } catch {
        FileHandle.standardError.write(Data("benchsplit failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 4, args[1] == "checktie" {
    do {
        let store = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let n = args.count >= 4 ? Int(args[3]) ?? 16 : 16
        let t0 = Date()
        let ids = try QwenModel.generate(prompt: [9707, 1234, 5678], maxTokens: n, store: store)
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "decode: %.1f ms/token (%.2f tok/s) ids=%d", dt / Double(n) * 1000,
                     Double(n) / dt, ids.count))
    } catch {
        FileHandle.standardError.write(Data("benchdecode failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 4, args[1] == "mtpacc" {
    do {
        let target = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let head = try WeightStore(dir: URL(fileURLWithPath: args[3]))
        let n = args.count >= 5 ? Int(args[4]) ?? 20 : 20
        let cache = ModelCache()
        let prompt: [Int32] = args.count >= 6
            ? args[5].split(separator: ",").map { Int32($0)! }
            : [9707, 1234, 5678]
        var (hidden, logits) = try QwenModel.forward(tokens: prompt, store: target, cache: cache)
        var matches = 0
        for step in 0 ..< n {
            let t1 = Int32(argMax(logits).item(Int32.self))
            let lastHidden = hidden[0..., hidden.shape[1] - 1 ..< hidden.shape[1], 0...]
            let draft = Int32(argMax(try MTP.forward(hidden: lastHidden, token: t1, target: target,
                                                     head: head, state: MTPState(),
                                                     position: prompt.count + step)).item(Int32.self))
            let next = try QwenModel.forward(tokens: [t1], store: target, cache: cache)
            hidden = next.hidden
            logits = next.logits
            let t2 = Int32(argMax(logits).item(Int32.self))
            if draft == t2 { matches += 1 }
            if step < 5 { print("step \(step): target \(t1) -> \(t2), draft \(draft)") }
        }
        print("acceptance: \(matches)/\(n) = \(String(format: "%.0f", 100.0 * Double(matches) / Double(n)))%")
    } catch {
        FileHandle.standardError.write(Data("mtpacc failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 4, args[1] == "mtp" {
    do {
        let target = try WeightStore(dir: URL(fileURLWithPath: args[2]))
        let head = try WeightStore(dir: URL(fileURLWithPath: args[3]))
        let prompt: [Int32] = args.count >= 6
            ? args[5].split(separator: ",").map { Int32($0)! }
            : [9707, 1234, 5678]
        let cache = ModelCache()
        let pre = try QwenModel.forward(tokens: prompt, store: target, cache: cache)
        let n1 = Int32(argMax(pre.logits).item(Int32.self))
        let lastHidden = pre.hidden[0..., (prompt.count - 1) ..< prompt.count, 0...]
        let step2 = try QwenModel.forward(tokens: [n1], store: target, cache: cache)
        let t2 = Int32(argMax(step2.logits).item(Int32.self))
        let m2logits = try MTP.forward(hidden: lastHidden, token: n1, target: target,
                                       head: head, state: MTPState())
        let m2 = Int32(argMax(m2logits).item(Int32.self))
        let mCurLogits = try MTP.forward(hidden: lastHidden, token: prompt.last!, target: target,
                                         head: head, state: MTPState())
        let mCur = Int32(argMax(mCurLogits).item(Int32.self))
        let top = m2logits.asArray(Float.self).enumerated().sorted { $0.element > $1.element }.prefix(3)
        print("target token 1:", n1, " target token 2:", t2)
        print("mtp token 2   :", m2, m2 == t2 ? "MATCH" : "MISS")
        print("mtp current-token variant:", mCur, mCur == n1 ? "MATCH n1" : "MISS n1")
        print("mtp top3:", top.map { "\($0.offset):\(String(format: "%.3f", $0.element))" })
    } catch {
        FileHandle.standardError.write(Data("mtp failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "gen" {
    do {
        let dir = URL(fileURLWithPath: args[2])
        let n = args.count >= 4 ? Int(args[3]) ?? 32 : 32
        let layers = args.count >= 5 ? Int(args[4]) ?? 64 : 64
        let store = try WeightStore(dir: dir)
        let t0 = Date()
        let prompt: [Int32] = args.count >= 5
            ? args[4].split(separator: ",").map { Int32($0)! }
            : [9707, 1234, 5678]
        let ids = try QwenModel.generate(prompt: prompt, maxTokens: n, store: store, layers: layers)
        print("ids:", ids)
        let dt = Date().timeIntervalSince(t0)
        print("elapsed:", String(format: "%.1f", dt), "s for", n, "tokens ->",
              String(format: "%.2f", Double(n) / dt), "tok/s")
    } catch {
        FileHandle.standardError.write(Data("gen failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 3, args[1] == "logits" {
    do {
        let dir = URL(fileURLWithPath: args[2])
        let tokens: [Int32] = [9707, 1234, 5678]
        let store = try WeightStore(dir: dir)
        let t0 = Date()
        let logits = try QwenModel.lastLogits(tokens: tokens, store: store)
        eval(logits)
        let values = logits.asArray(Float.self)
        let top = values.enumerated().sorted { $0.element > $1.element }.prefix(5)
        print("tokens: \(tokens)")
        print("elapsed: \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        print("argmax:", top.first!.offset)
        print("top5:", top.map { "\($0.offset):\(String(format: "%.3f", $0.element))" })
    } catch {
        FileHandle.standardError.write(Data("logits failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 4, args[1] == "layer3" {
    do {
        let dir = URL(fileURLWithPath: args[2]); let ref = args[3]
        func floats(_ path: String) throws -> [Float] {
            let d = try Data(contentsOf: URL(fileURLWithPath: path))
            return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let shape = [1, 3, 5120]
        let x = MLXArray(try floats(ref + "_l3in.bin"), shape).asType(.bfloat16)
        let refY = MLXArray(try floats(ref + "_l3out.bin"), shape)
        let store = try WeightStore(dir: dir)
        let y = try DecoderLayer.forward(x, store: store, layer: 3)
        eval(y)
        let diff = abs(y - refY)
        print("layer3 out:", y.shape, y.dtype)
        print("max abs diff:", String(format: "%.5f", diff.max().item(Float.self)))
        print("mean abs diff:", String(format: "%.5f", diff.mean().item(Float.self)))
    } catch {
        FileHandle.standardError.write(Data("layer3 failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 4, args[1] == "layer0" {
    do {
        let dir = URL(fileURLWithPath: args[2]); let ref = args[3]
        func floats(_ path: String) throws -> [Float] {
            let d = try Data(contentsOf: URL(fileURLWithPath: path))
            return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let shape = [1, 3, 5120]
        let x = MLXArray(try floats(ref + "_layerin.bin"), shape).asType(.bfloat16)
        let refY = MLXArray(try floats(ref + "_layerout.bin"), shape)
        let store = try WeightStore(dir: dir)
        let y = try DecoderLayer.forward(x, store: store, layer: 0)
        eval(y)
        let diff = abs(y - refY)
        print("layer0 out:", y.shape, y.dtype)
        print("max abs diff:", String(format: "%.5f", diff.max().item(Float.self)))
        print("mean abs diff:", String(format: "%.5f", diff.mean().item(Float.self)))
    } catch {
        FileHandle.standardError.write(Data("layer0 failed: \(error)\n".utf8)); exit(1)
    }
} else if args.count >= 4, args[1] == "gdn" {
    do {
        let dir = URL(fileURLWithPath: args[2])
        let ref = args[3]
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: ref + "_meta.json"))) as! [String: Any]
        let xShape = meta["x_shape"] as! [Int]
        let yShape = meta["y_shape"] as! [Int]
        func floats(_ path: String) throws -> [Float] {
            let d = try Data(contentsOf: URL(fileURLWithPath: path))
            return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let x = MLXArray(try floats(ref + "_x.bin"), xShape).asType(.bfloat16)
        let refY = MLXArray(try floats(ref + "_y.bin"), yShape)
        let store = try WeightStore(dir: dir)
        let y = try GDN.forward(x, store: store)
        eval(y)
        let diff = abs(y - refY)
        print("out shape:", y.shape, "dtype:", y.dtype)
        print("max abs diff:", String(format: "%.5f", diff.max().item(Float.self)))
        print("mean abs diff:", String(format: "%.5f", diff.mean().item(Float.self)))
        print("ref y[0,0,0:5]:", refY.asArray(Float.self).prefix(5).map { String(format: "%.4f", $0) })
        print("got y[0,0,0:5]:", y.asArray(Float.self).prefix(5).map { String(format: "%.4f", $0) })
    } catch {
        FileHandle.standardError.write(Data("gdn failed: \(error)\n".utf8))
        exit(1)
    }
} else if args.count >= 3, args[1] == "probe" {
    do {
        let dir = URL(fileURLWithPath: args[2])
        let token = Int32(args.count >= 4 ? Int(args[3])! : 9707)
        let store = try WeightStore(dir: dir)
        let emb = try store.embedding("language_model.model.embed_tokens", tokens: [token])
        let normed = try store.rmsNorm("language_model.model.layers.0.input_layernorm", emb)
        let qkv = try store.linear("language_model.model.layers.0.linear_attn.in_proj_qkv", normed)
        eval(qkv)
        let e = emb.asArray(Float.self)
        let n = normed.asArray(Float.self)
        let q = qkv.asArray(Float.self)
        print("token:", token)
        print("emb[0:6]:", e.prefix(6).map { String(format: "%.5f", $0) })
        print("norm[0:6]:", n.prefix(6).map { String(format: "%.5f", $0) })
        print("qkv[0:6]:", q.prefix(6).map { String(format: "%.5f", $0) })
        print("qkv.shape:", qkv.shape, "dtype:", qkv.dtype)
        print("qkv.sum:", String(format: "%.3f", q.reduce(0, +)))
        print("shards loaded:", store.loadedShards)
    } catch {
        FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
        exit(1)
    }
} else if args.count >= 3, args[1] == "inspect" {
    do {
        try inspect(args[2])
    } catch {
        FileHandle.standardError.write(Data("inspect failed: \(error)\n".utf8))
        exit(1)
    }
} else {
    if args.count > 1 {
        FileHandle.standardError.write(Data("strim: unknown or incomplete command \(args[1...].joined(separator: " "))\n\(cliHelpText())\n".utf8))
        exit(2)
    }
    print(cliHelpText())
}
