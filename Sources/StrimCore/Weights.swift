import CryptoKit
import Foundation
import MLX

public enum WeightError: Error, CustomStringConvertible {
    case missingTensor(String)
    case missingShard(String)
    public var description: String {
        switch self {
        case .missingTensor(let n): "tensor not found: \(n)"
        case .missingShard(let s): "shard not found: \(s)"
        }
    }
}

/// Rows of the target lm_head kept for MTP drafting: `idx` maps a truncated-vocab index
/// back to a token id; `w`, `s`, `b` are the quantized lm_head rows `idx` (ascending).
public struct DraftVocab {
    public let idx: MLXArray
    public let w: MLXArray
    public let s: MLXArray
    public let b: MLXArray
    /// Quantization of the lm_head rows kept here.
    public let spec: QuantSpec
}

private struct DraftVocabFile: Decodable {
    let k: Int
    let ids: [Int]
    let tokenizerSha256: String?

    enum CodingKeys: String, CodingKey {
        case k, ids
        case tokenizerSha256 = "tokenizer_sha256"
    }
}

private func stderrLine(_ line: String) {
    FileHandle.standardError.write("\(line)\n".data(using: .utf8)!)
}

private let draftVocabNoticeLock = NSLock()
nonisolated(unsafe) private var draftVocabNoticePrinted = false

/// Prints the draft-vocab source line once per process.
private func draftVocabNotice(_ line: String) {
    draftVocabNoticeLock.lock()
    defer { draftVocabNoticeLock.unlock() }
    guard !draftVocabNoticePrinted else { return }
    draftVocabNoticePrinted = true
    stderrLine(line)
}

/// Lazy, per-shard tensor store. One shard is materialised at a time as MLX arrays.
public final class WeightStore {
    public let dir: URL
    public let index: ModelIndex
    private var shards: [String: [String: MLXArray]] = [:]
    private var gdnCompiled: [Int: ([MLXArray]) -> [MLXArray]] = [:]
    public private(set) var loadedShards: [String] = []
    /// Set for checkpoints that store the MTP head under `language_model.mtp.` in the
    /// main shards (oQ4e) instead of a separate prefixless head file.
    public var keyPrefix = ""
    /// config.json `quantization` block of this directory (nil when absent).
    public let quantConfig: QuantConfig?
    private var specCache: [String: QuantSpec] = [:]
    /// Activation rotation declared by `<dir>/hadamard.json` (Prism Bonsai); nil for ordinary checkpoints.
    public let rotation: ActivationRotation?

    public init(dir: URL) throws {
        WiredLimit.applyFromEnvOnce()
        self.dir = dir
        self.quantConfig = try QuantConfig.load(dir: dir)
        self.rotation = try ActivationRotation.load(dir: dir)
        self.index = try ModelIndex(url: dir.appendingPathComponent("model.safetensors.index.json"))
    }

    /// If this store is used as the MTP head and the checkpoint keeps the head under
    /// `language_model.mtp.` in the main shards, switch every MTP lookup to that prefix.
    public func useIntegratedMTPPrefixIfNeeded() {
        if index.weightMap["pre_fc_norm_embedding.weight"] == nil,
           index.weightMap["language_model.mtp.pre_fc_norm_embedding.weight"] != nil {
            keyPrefix = "language_model.mtp."
        }
    }

    public func tensor(_ name: String) throws -> MLXArray {
        let name = keyPrefix + name
        guard let shard = index.weightMap[name] else { throw WeightError.missingTensor(name) }
        if shards[shard] == nil {
            let url = dir.appendingPathComponent(shard)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw WeightError.missingShard(shard)
            }
            shards[shard] = try loadArrays(url: url)
            if rotation != nil { for k in shards[shard]!.keys where k.hasPrefix("vision_tower") { shards[shard]![k] = nil } }   // text-only; the tower is never used
            if let rotation { for (k, v) in shards[shard]! where [.float32, .float16, .bfloat16].contains(v.dtype) && v.dtype != rotation.actDType && !k.hasSuffix(".signs") { shards[shard]![k] = v.asType(rotation.actDType); eval(shards[shard]![k]!) } }
            loadedShards.append(shard)
        }
        guard let t = shards[shard]?[name] else { throw WeightError.missingTensor(name) }
        return t
    }

    /// Shape-only bit-depth guess (benches and cross-checks; model paths use `quantSpec`).
    /// MLX packs quantized weights into uint32, so bits = 32 * packedColumns / (groups * groupSize).
    public static func quantBits(_ w: MLXArray, _ s: MLXArray, groupSize: Int = 64) -> Int {
        guard let packed = w.shape.last, let groups = s.shape.last, groups > 0 else { return 4 }
        let k = groups * groupSize
        guard k > 0 else { return 4 }
        let bits = (32 * packed) / k
        return (2 ... 8).contains(bits) ? bits : 4
    }

    /// Quantization of the module `prefix` (tensors `<prefix>.weight/.scales/.biases`) from
    /// config.json, cross-checked against the shapes. Throws on any disagreement; never guesses.
    public func quantSpec(_ prefix: String, w: MLXArray, s: MLXArray) throws -> QuantSpec {
        if let c = specCache[prefix] { return c }
        guard let cfg = quantConfig else { throw QuantError.noConfig(tensor: keyPrefix + prefix) }
        guard let spec = cfg.spec(forPrefix: prefix, keyPrefix: keyPrefix) else {
            if cfg.global == nil { throw QuantError.noConfig(tensor: keyPrefix + prefix) }
            throw QuantError.unquantizedTensor(keyPrefix + prefix)
        }
        try spec.validate(tensor: keyPrefix + prefix, w: w, s: s)
        specCache[prefix] = spec
        return spec
    }

    /// Spec for a module by name (loads its weight and scales).
    public func quantSpec(_ prefix: String) throws -> QuantSpec {
        if let c = specCache[prefix] { return c }
        return try quantSpec(prefix, w: try tensor(prefix + ".weight"), s: try tensor(prefix + ".scales"))
    }

    /// Hash of every quantization spec this store was configured with.
    public var quantFingerprint: String { quantConfig?.fingerprint ?? "none" }

    private var draftVocabLoaded = false
    private var draftVocabStore: DraftVocab?

    /// Truncated lm_head for MTP drafting, or nil (full vocab). First existing file of:
    /// env `STRIM_DRAFT_VOCAB=<path>`, `<modelDir>/draft_vocab.json`,
    /// `bench/draft_vocab_48k.json` under cwd. `STRIM_DRAFT_VOCAB=off`, no file, a
    /// `tokenizer_sha256` mismatch against `<modelDir>/tokenizer.json`, or an
    /// unquantized lm_head give nil.
    /// Verify never reads this: it always uses the full `language_model.lm_head`.
    public var draftVocab: DraftVocab? {
        if !draftVocabLoaded {
            draftVocabLoaded = true
            draftVocabStore = loadDraftVocab()
        }
        return draftVocabStore
    }

    private func loadDraftVocab() -> DraftVocab? {
        if rotation != nil { return nil }   // truncated lm_head rows would need the rotated hidden
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment["STRIM_DRAFT_VOCAB"].flatMap { $0.isEmpty ? nil : $0 }
        if env == "off" {
            draftVocabNotice("draft vocab: off (STRIM_DRAFT_VOCAB=off); using full vocab")
            return nil
        }
        let candidates = [env, dir.appendingPathComponent("draft_vocab.json").path,
                          "bench/draft_vocab_48k.json"].compactMap { $0 }
        guard let path = candidates.first(where: { fm.fileExists(atPath: $0) }),
              let data = fm.contents(atPath: path) else {
            draftVocabNotice("draft vocab: none found; using full vocab")
            return nil
        }
        let file: DraftVocabFile
        do {
            file = try JSONDecoder().decode(DraftVocabFile.self, from: data)
        } catch {
            stderrLine("draft vocab \(path): \(error)")
            return nil
        }
        guard let want = file.tokenizerSha256 else {
            stderrLine("draft vocab \(path): no tokenizer_sha256; using full vocab")
            return nil
        }
        if let tok = fm.contents(atPath: dir.appendingPathComponent("tokenizer.json").path) {
            let got = SHA256.hash(data: tok).map { String(format: "%02x", $0) }.joined()
            guard got == want.lowercased() else {
                stderrLine("draft vocab hash mismatch; using full vocab")
                return nil
            }
        }
        let ps = "language_model.lm_head"
        guard index.weightMap[ps + ".scales"] != nil,
              let w = try? tensor(ps + ".weight"), let s = try? tensor(ps + ".scales"),
              let b = try? tensor(ps + ".biases") else { return nil }
        let spec: QuantSpec
        do { spec = try quantSpec(ps, w: w, s: s) } catch {
            stderrLine("draft vocab \(path): \(error); using full vocab")
            return nil
        }
        let rows = w.shape[0]
        let ids = file.ids
        guard ids.count == file.k, ids.count > 0, ids.last! < rows,
              zip(ids, ids.dropFirst()).allSatisfy({ $0 < $1 }) else {
            stderrLine("draft vocab \(path): need k ascending ids < \(rows); ignored")
            return nil
        }
        let idx = MLXArray(ids.map { UInt32($0) })
        let rw = w.take(idx, axis: 0)
        let rs = s.take(idx, axis: 0)
        let rb = b.take(idx, axis: 0)
        eval(idx, rw, rs, rb)
        draftVocabNotice("draft vocab: loaded \(path)")
        return DraftVocab(idx: idx, w: rw, s: rs, b: rb, spec: spec)
    }

    /// dequantized embedding row(s)
    public func embedding(_ prefix: String, tokens: [Int32]) throws -> MLXArray {
        try embedding(prefix, indices: MLXArray(tokens))
    }

    /// dequantized embedding row(s) from an index tensor, so the lookup can run off a
    /// GPU-resident token id (e.g. a lazy `argMax`) with no host round-trip.
    public func embedding(_ prefix: String, indices: MLXArray) throws -> MLXArray {
        let w = try tensor(prefix + ".weight")
        let s = try tensor(prefix + ".scales")
        let b = try tensor(prefix + ".biases")
        let spec = try quantSpec(prefix, w: w, s: s)
        let rows = dequantized(w.take(indices, axis: 0), scales: s.take(indices, axis: 0),
                           biases: b.take(indices, axis: 0), groupSize: spec.groupSize, bits: spec.bits)
        if let rotation, rotation.inverseWeightNames.contains(keyPrefix + prefix + ".weight") {
            return rotation.invert(rows).asType(rotation.actDType)
        }
        return rows
    }

    /// Quantized matmul with explicit (config-derived) quantization.
    public func qmm(_ x: MLXArray, _ w: MLXArray, _ s: MLXArray, _ b: MLXArray, spec: QuantSpec) -> MLXArray {
        quantizedMatmul(rotation?.apply(x) ?? x, w, scales: s, biases: b, transpose: true,
                        groupSize: spec.groupSize, bits: spec.bits)
    }

    /// y = x @ W^T with W stored as packed uint32 + scales + biases
    public func linear(_ prefix: String, _ x: MLXArray) throws -> MLXArray {
        // oQ4e keeps the MTP fc projection unquantized (bf16) while the rest of the
        // head is quantized; fall back to a dense matmul when scales are absent.
        if index.weightMap[keyPrefix + prefix + ".scales"] == nil {
            let w = try tensor(prefix + ".weight")
            return matmul(x, w.transposed(-1, -2))
        }
        let w = try tensor(prefix + ".weight")
        let s = try tensor(prefix + ".scales")
        let b = try tensor(prefix + ".biases")
        return qmm(x, w, s, b, spec: try quantSpec(prefix, w: w, s: s))
    }

    /// Compiled single-token GDN step (weights captured as constants).
    public func gdnStep(layer: Int) -> ([MLXArray]) -> [MLXArray] {
        if let f = gdnCompiled[layer] { return f }
        let store = self
        let f = compile { (inputs: [MLXArray]) -> [MLXArray] in
            let r = try! GDN.step1(inputs[0], conv: inputs[1], ssm: inputs[2],
                                   store: store, layer: layer)
            return [r.y, r.conv, r.ssm]
        }
        gdnCompiled[layer] = f
        return f
    }

    public func rmsNorm(_ prefix: String, _ x: MLXArray, eps: Float = 1e-6) throws -> MLXArray {
        let w = try tensor(prefix + ".weight")
        return MLXFast.rmsNorm(x, weight: w, eps: eps)
    }

    /// Drop one tensor from its resident shard. Used when a fused copy replaces the
    /// originals, so fusion costs no extra resident memory.
    public func drop(_ name: String) {
        guard let shard = index.weightMap[name], var t = shards[shard] else { return }
        t[name] = nil
        shards[shard] = t
    }

    private var mlpFusedCache: [Int: (w: MLXArray, s: MLXArray, b: MLXArray)] = [:]

    /// True when gate_proj and up_proj share one quantization spec, so they can be fused into one matmul.
    public func mlpFusable(_ layer: Int) throws -> Bool {
        if mlpFusedCache[layer] != nil { return true }
        let p = "language_model.model.layers.\(layer).mlp."
        return try quantSpec(p + "gate_proj") == quantSpec(p + "up_proj")
    }

    /// gate_proj and up_proj as one [2*intermediate, K] matrix: one qmv instead of two,
    /// with double the rows so it lands in MLX's wide-GEMV regime. Rows are independent,
    /// so the result is bit-identical; the originals are dropped to keep memory net-zero.
    /// Requires `mlpFusable(layer)` (equal bits and group size); the shared spec stays in `quantSpec(<gate_proj>)`.
    public func mlpFused(_ layer: Int) throws -> (w: MLXArray, s: MLXArray, b: MLXArray) {
        if let f = mlpFusedCache[layer] { return f }
        let p = "language_model.model.layers.\(layer).mlp."
        let spec = try quantSpec(p + "gate_proj")
        guard try quantSpec(p + "up_proj") == spec else {
            throw QuantError.badConfig("\(p)gate_proj and up_proj differ in quantization; cannot fuse")
        }
        let w = concatenated([try tensor(p + "gate_proj.weight"), try tensor(p + "up_proj.weight")], axis: 0)
        let s = concatenated([try tensor(p + "gate_proj.scales"), try tensor(p + "up_proj.scales")], axis: 0)
        let b = concatenated([try tensor(p + "gate_proj.biases"), try tensor(p + "up_proj.biases")], axis: 0)
        eval(w, s, b)          // materialise once; a lazy concat would re-copy 89 MB per token
        for n in ["gate_proj.weight", "gate_proj.scales", "gate_proj.biases",
                  "up_proj.weight", "up_proj.scales", "up_proj.biases"] {
            drop(p + n)
        }
        let f = (w: w, s: s, b: b)
        mlpFusedCache[layer] = f
        return f
    }
}
