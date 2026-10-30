import Foundation
import CryptoKit
import MLX
import StrimCore
import StrimTokenizer

private func s4emit(_ value: [String: Any]) {
    var value = value; value["mlx_peak_bytes"] = Memory.peakMemory
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}
private func s4hash(_ ids: [Int32]) -> String {
    ids.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
}
private func s4prefill(_ ids: [Int32], _ store: WeightStore) throws -> (ModelCache, MLXArray) {
    let cache = ModelCache()
    var logits: MLXArray!
    for start in stride(from: 0, to: ids.count, by: 1024) {
        let end = min(start + 1024, ids.count)
        logits = try QwenModel.forwardAll(tokens: Array(ids[start..<end]), store: store, cache: cache, lastTokenOnly: true).logits
        eval(logits)
    }
    return (cache, logits)
}
func runS4(_ args: [String]) throws {
    let mode = args[0], path = args[1]
    let store = try WeightStore(dir: URL(fileURLWithPath: path))
    let tokenizer = try Tokenizer.load(modelDir: path)
    let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/tmp/s4/src/bench/ab_prompts.json"))) as! [String: String]
    let keys = corpus.keys.sorted()
    func prompt(_ key: String) -> [Int32] {
        tokenizer.encode("<|im_start|>user\n" + corpus[key]! + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
    }
    s4emit(["kind": "meta", "mode": mode, "fuse": ProcessInfo.processInfo.environment["STRIM_S4_FUSE"] ?? "0", "date": ISO8601DateFormatter().string(from: Date())])
    if mode == "decode" {
        let count = Int(args[2])!, reps = Int(args[3])!, steps = Int(args[4])!
        var caches: [ModelCache] = [], seeds: [Int32] = []
        for i in 0..<count {
            let (cache, logits) = try s4prefill(prompt(keys[i]), store)
            caches.append(cache); seeds.append(argMax(logits).item(Int32.self))
        }
        for rep in -1..<reps {
            var tokens = seeds
            var outputs = [[Int32]](repeating: [], count: count)
            let cache = count == 1 ? caches[0].snapshot() : nil
            let bc = count > 1 ? BatchModel.from(caches.map { $0.snapshot() }) : nil
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<steps {
                let logits = count == 1
                    ? try QwenModel.forward(tokens: [tokens[0]], store: store, cache: cache!).logits.reshaped([1, 1, -1])
                    : try BatchModel.forward(tokens: tokens.map { [$0] }, store: store, cache: bc!)
                tokens = argMax(logits, axis: -1).asArray(Int32.self)
                for b in 0..<count { outputs[b].append(tokens[b]) }
            }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            s4emit(["kind": "decode", "c": count, "rep": rep, "steps": steps, "seconds": seconds,
                    "aggregate_tps": Double(count * steps) / seconds, "request_tps": Double(steps) / seconds,
                    "hashes": outputs.map(s4hash)])
        }
    } else if mode == "verify" {
        let reps = Int(args[2])!, steps = Int(args[3])!
        let (cache, _) = try s4prefill(prompt("code"), store)
        for width in [3, 5, 8] {
            let ids = Array(prompt("code").suffix(width))
            // Fixed primed real state, no accumulated context drift, record the same rollback state as MTP verify.
            for rep in -1..<reps {
                var last: MLXArray!
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<steps {
                    let c = cache.snapshot(); c.beginVerify()
                    last = try QwenModel.forwardAll(tokens: ids, store: store, cache: c).logits
                    eval(last)
                }
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                s4emit(["kind": "verify", "width": width, "rep": rep, "steps": steps, "ms": seconds * 1000 / Double(steps), "hash": s4hash(argMax(last!, axis: -1).asArray(Int32.self))])
            }
        }
    } else if mode == "prefill" {
        let size = Int(args[2])!, reps = Int(args[3])!
        let pattern = keys.flatMap { prompt($0) }
        let ids = Array((0..<size).map { pattern[$0 % pattern.count] })
        _ = try s4prefill(Array(ids.prefix(1024)), store)
        for rep in -1..<reps {
            let start = DispatchTime.now().uptimeNanoseconds
            let (_, logits) = try s4prefill(ids, store)
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            s4emit(["kind": "prefill", "n": size, "rep": rep, "seconds": seconds, "tps": Double(size) / seconds, "next": argMax(logits).item(Int32.self), "logit_hash": logits.asType(.float32).asArray(Float.self).withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }])
        }
    } else if mode == "qualitybatch" || mode == "qualityverify" {
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        let reference = args.count > 3 ? URL(fileURLWithPath: args[3], isDirectory: true) : nil
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sizes = mode == "qualitybatch" ? [1, 4, 6, 7, 8] : [3, 5, 8]
        for size in sizes {
            let label = "\(mode)-\(size)"
            let refs = try reference.map { try loadArrays(url: $0.appendingPathComponent(label + ".safetensors")) }
            var saved: [String: MLXArray] = [:]
            var maxDiff: Float = 0, differentBits = 0, agreement = 0, comparedValues = 0
            func compare(_ name: String, _ value: MLXArray) {
                let row = value.asType(.float32)
                saved[name] = row
                if let ref = refs?[name] {
                    maxDiff = max(maxDiff, abs(row - ref).max().item(Float.self))
                    let a = row.asArray(Float.self), b = ref.asArray(Float.self)
                    comparedValues += a.count
                    differentBits += zip(a,b).filter { $0.bitPattern != $1.bitPattern }.count
                }
            }
            var outputs: [[Int32]]
            if mode == "qualityverify" {
                let (cache, _) = try s4prefill(prompt("code"), store)
                cache.beginVerify()
                let logits = try QwenModel.forwardAll(tokens: Array(prompt("code").suffix(size)), store: store, cache: cache).logits
                compare("logits", logits)
                outputs = [argMax(logits, axis: -1).asArray(Int32.self)]
                let expected = refs?["tokens"]?.asArray(Int32.self) ?? outputs[0]
                agreement = zip(outputs[0],expected).filter(==).count
                saved["tokens"] = MLXArray(outputs[0])
            } else {
                var caches: [ModelCache] = [], tokens: [Int32] = []
                for i in 0..<size {
                    let (cache, logits) = try s4prefill(prompt(keys[i]), store)
                    caches.append(cache); tokens.append(argMax(logits).item(Int32.self))
                }
                let bc = size > 1 ? BatchModel.from(caches) : nil
                outputs = [[Int32]](repeating: [], count: size)
                let refTokens = refs?["tokens"]?.asArray(Int32.self)
                for step in 0..<64 {
                    let logits = size == 1
                        ? try QwenModel.forward(tokens: [tokens[0]], store: store, cache: caches[0]).logits.reshaped([1, 1, -1])
                        : try BatchModel.forward(tokens: tokens.map { [$0] }, store: store, cache: bc!)
                    if step < 8 { compare("logits_\(step)", logits) }
                    let next = argMax(logits, axis: -1).asArray(Int32.self)
                    for b in 0..<size {
                        outputs[b].append(next[b])
                        let expected = refTokens?[step * size + b] ?? next[b]
                        if next[b] == expected { agreement += 1 }
                        tokens[b] = expected
                    }
                }
                saved["tokens"] = MLXArray((0..<64).flatMap { step in outputs.map { $0[step] } })
            }
            try save(arrays: saved, url: output.appendingPathComponent(label + ".safetensors"))
            s4emit(["kind": mode, "size": size, "hashes": outputs.map(s4hash), "max_abs_diff": maxDiff,
                    "different_float_bits": differentBits, "compared_values": comparedValues,
                    "teacher_forced_agreement": agreement, "tokens": outputs.reduce(0) { $0 + $1.count },
                    "has_reference": reference != nil])
            if reference != nil && (differentBits != 0 || agreement != outputs.reduce(0, { $0 + $1.count })) {
                throw WeightError.missingTensor("BLOCKED: \(label) differs from unpatched reference")
            }
        }
    } else if mode == "quality" {
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        let reference = args.count > 3 ? URL(fileURLWithPath: args[3], isDirectory: true) : nil
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for key in keys {
            let ids = prompt(key)
            let (cache, initial) = try s4prefill(ids, store)
            var logits = initial, generated: [Int32] = [], saved: [String: MLXArray] = [:]
            let refs = try reference.map { try loadArrays(url: $0.appendingPathComponent(key + ".safetensors")) }
            let refTokens = refs?["tokens"]?.asArray(Int32.self)
            var maxDiff: Float = 0, differentBits = 0, agreement = 0
            for step in 0..<64 {
                let row = logits.reshaped([-1]).asType(.float32)
                let token = argMax(row).item(Int32.self)
                generated.append(token)
                if step < 8 {
                    saved["logits_\(step)"] = row
                    if let ref = refs?["logits_\(step)"] {
                        maxDiff = max(maxDiff, abs(row - ref).max().item(Float.self))
                        let a = row.asArray(Float.self), b = ref.asArray(Float.self)
                        differentBits += zip(a,b).filter { $0.bitPattern != $1.bitPattern }.count
                    }
                }
                if let refTokens, token == refTokens[step] { agreement += 1 }
                // Teacher force the reference path to make all logit comparisons meaningful.
                let next = refTokens?[step] ?? token
                logits = try QwenModel.forward(tokens: [next], store: store, cache: cache).logits
            }
            saved["tokens"] = MLXArray(generated)
            try save(arrays: saved, url: output.appendingPathComponent(key + ".safetensors"))
            // Independent generation as well as teacher-forced argmax agreement.
            let free = try QwenModel.generate(prompt: ids, maxTokens: 64, store: store)
            let tail = Array(free.suffix(64))
            try JSONSerialization.data(withJSONObject: tail).write(to: output.appendingPathComponent(key + ".tokens.json"))
            var freeMatch = true
            if let reference {
                let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: reference.appendingPathComponent(key + ".tokens.json"))) as! [Int]
                freeMatch = tail.map(Int.init) == expected
            }
            s4emit(["kind": "quality", "prompt": key, "prompt_tokens": ids.count, "logit_rows": 8, "max_abs_diff": maxDiff,
                    "different_float_bits": differentBits, "teacher_forced_agreement": reference == nil ? 64 : agreement,
                    "steps": 64, "hash": s4hash(tail), "free_greedy_identical": freeMatch])
        }
    } else { throw WeightError.missingTensor("unknown S4 mode") }
}

if CommandLine.arguments.dropFirst().first == "enginebench" { runEngineBench(CommandLine.arguments) } else { try runS4(Array(CommandLine.arguments.dropFirst())) }
