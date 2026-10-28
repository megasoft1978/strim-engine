import CryptoKit
import Foundation
import MLX

public enum QuantError: Error, CustomStringConvertible {
    case badConfig(String)
    case unsupportedMode(tensor: String, mode: String)
    case noConfig(tensor: String)
    case unquantizedTensor(String)
    case mismatch(tensor: String, config: QuantSpec, wShape: [Int], sShape: [Int], configK: Int?, scaleK: Int,
                  shapeCandidates: [QuantSpec])

    public var description: String {
        switch self {
        case .badConfig(let m): return "config.json quantization: \(m)"
        case .unsupportedMode(let t, let m):
            return "tensor \(t): quantization mode '\(m)' is not supported by this engine (affine only)"
        case .noConfig(let t):
            return "tensor \(t) is quantized but config.json has no usable `quantization` block; refusing to guess bits/group size"
        case .unquantizedTensor(let t): return "tensor \(t): config marks it unquantized but scales are present"
        case .mismatch(let t, let c, let w, let s, let ck, let sk, let cands):
            let kc = ck.map(String.init) ?? "non-integer"
            let alt = cands.isEmpty ? "none" : cands.map(\.description).joined(separator: ", ")
            return "quantization mismatch for \(t): config says \(c) => weight columns imply K=\(kc) (weight \(w)) but scales imply K=\(sk) (scales \(s)); shapes alone are consistent with: \(alt)"
        }
    }
}

/// Bits / group size / mode of one quantized tensor.
public struct QuantSpec: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var bits: Int
    public var groupSize: Int
    public var mode: String
    public init(bits: Int, groupSize: Int, mode: String = "affine") {
        self.bits = bits; self.groupSize = groupSize; self.mode = mode
    }
    public var description: String { "\(mode) \(bits)-bit g\(groupSize)" }

    public static let validBits = [2, 3, 4, 5, 6, 8]
    public static let validGroupSizes = [32, 64, 128]

    /// Input width implied by the packed weight (uint32 words of 32 bits), or nil if it is not whole.
    public static func columns(packed: Int, bits: Int) -> Int? {
        (packed * 32) % bits == 0 ? packed * 32 / bits : nil
    }

    /// Every (bits, group) whose two K derivations agree for these shapes.
    public static func shapeCandidates(packed: Int, groups: Int) -> [QuantSpec] {
        var out: [QuantSpec] = []
        for b in validBits {
            guard let k = columns(packed: packed, bits: b) else { continue }
            for g in validGroupSizes where groups * g == k { out.append(QuantSpec(bits: b, groupSize: g)) }
        }
        return out
    }

    /// Throws unless K from the packed columns (config bits) equals K from the scales (config group size).
    public func validate(tensor: String, w: MLXArray, s: MLXArray) throws {
        guard mode == "affine" else { throw QuantError.unsupportedMode(tensor: tensor, mode: mode) }
        guard let packed = w.shape.last, let groups = s.shape.last else {
            throw QuantError.badConfig("tensor \(tensor) has no columns")
        }
        let wk = QuantSpec.columns(packed: packed, bits: bits)
        if wk != groups * groupSize || wk == nil {
            throw QuantError.mismatch(tensor: tensor, config: self, wShape: w.shape, sShape: s.shape,
                                      configK: wk, scaleK: groups * groupSize,
                                      shapeCandidates: QuantSpec.shapeCandidates(packed: packed, groups: groups))
        }
    }
}

/// `quantization` block of a config.json: a global spec plus per-module overrides as mlx_lm writes
/// them (`"model.layers.0.mlp.gate_proj": {"bits": 8, "group_size": 64}`; `false` = left unquantized).
public struct QuantConfig: Equatable, Sendable {
    public var global: QuantSpec?
    public var overrides: [String: QuantSpec] = [:]
    public var unquantized: Set<String> = []

    public init(global: QuantSpec?, overrides: [String: QuantSpec] = [:], unquantized: Set<String> = []) {
        self.global = global; self.overrides = overrides; self.unquantized = unquantized
    }

    static let reserved: Set<String> = ["bits", "group_size", "mode", "quant_method"]

    private static func spec(_ d: [String: Any], base: QuantSpec?, path: String) throws -> QuantSpec {
        func int(_ k: String) throws -> Int? {
            guard let v = d[k] else { return nil }
            guard let n = (v as? NSNumber), !(v is Bool), n.intValue == Int(exactly: n.doubleValue) else {
                throw QuantError.badConfig("\(path).\(k) is not an integer")
            }
            return n.intValue
        }
        guard let bits = try int("bits") ?? base?.bits else { throw QuantError.badConfig("\(path) has no bits") }
        guard let group = try int("group_size") ?? base?.groupSize else {
            throw QuantError.badConfig("\(path) has no group_size")
        }
        let mode = (d["mode"] as? String) ?? base?.mode ?? "affine"
        guard QuantSpec.validBits.contains(bits) else {
            throw QuantError.badConfig("\(path).bits=\(bits) (supported \(QuantSpec.validBits))")
        }
        guard QuantSpec.validGroupSizes.contains(group) else {
            throw QuantError.badConfig("\(path).group_size=\(group) (supported \(QuantSpec.validGroupSizes))")
        }
        return QuantSpec(bits: bits, groupSize: group, mode: mode)
    }

    /// Parses one quantization dictionary (global keys + overrides).
    public static func parse(block: [String: Any]) throws -> QuantConfig {
        var cfg = QuantConfig(global: nil)
        if block["bits"] != nil || block["group_size"] != nil {
            cfg.global = try spec(block, base: nil, path: "quantization")
        }
        for (k, v) in block where !reserved.contains(k) {
            if let d = v as? [String: Any] {
                cfg.overrides[k] = try spec(d, base: cfg.global, path: "quantization[\(k)]")
            } else if let b = v as? Bool {
                if b { if let g = cfg.global { cfg.overrides[k] = g } } else { cfg.unquantized.insert(k) }
            }
        }
        return cfg
    }

    /// Reads `<dir>/config.json` (`quantization`, else `quantization_config`; both present must agree).
    /// Returns nil when the file or both blocks are absent.
    public static func load(dir: URL) throws -> QuantConfig? {
        guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent("config.json").path) else {
            return nil
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuantError.badConfig("config.json is not an object")
        }
        let a = try (root["quantization"] as? [String: Any]).map(parse(block:))
        let b = try (root["quantization_config"] as? [String: Any]).map(parse(block:))
        if let a, let b, a.global != b.global {
            throw QuantError.badConfig("`quantization` (\(a.global.map(\.description) ?? "-")) and `quantization_config` (\(b.global.map(\.description) ?? "-")) disagree")
        }
        guard var cfg = a ?? b else { return nil }
        if let a, let b {   // union; `quantization` wins on conflict
            cfg.overrides = b.overrides.merging(a.overrides) { _, new in new }
            cfg.unquantized = a.unquantized.union(b.unquantized)
        }
        return cfg
    }

    /// Candidate config keys for a tensor prefix (store key prefix, with and without `language_model.`).
    static func keys(_ prefix: String, keyPrefix: String) -> [String] {
        var out = [keyPrefix + prefix, prefix]
        for p in out where p.hasPrefix("language_model.") { out.append(String(p.dropFirst("language_model.".count))) }
        return out
    }

    /// Spec for the module whose tensors are `<prefix>.weight/.scales/.biases`.
    public func spec(forPrefix prefix: String, keyPrefix: String = "") -> QuantSpec? {
        let ks = QuantConfig.keys(prefix, keyPrefix: keyPrefix)
        for k in ks { if let s = overrides[k] { return s } }
        for k in ks where unquantized.contains(k) { return nil }
        return global
    }

    /// Short stable hash of the global spec and every per-module override.
    public var fingerprint: String {
        var h = SHA256()
        func add(_ s: String) { h.update(data: Data(s.utf8)); h.update(data: Data([0])) }
        add("quantcfg-v1")
        add(global.map(\.description) ?? "-")
        for k in overrides.keys.sorted() { add("\(k)=\(overrides[k]!)") }
        for k in unquantized.sorted() { add("\(k)=none") }
        return Data(h.finalize()).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Combined fingerprint of a model dir and an optional MTP head dir ("none" when no quant block).
    public static func fingerprint(modelDir: String, headDir: String?) -> String {
        func one(_ d: String?) -> String {
            guard let d else { return "-" }
            return ((try? load(dir: URL(fileURLWithPath: d))) ?? nil)?.fingerprint ?? "none"
        }
        return "\(one(modelDir))/\(one(headDir))"
    }
}
