import Foundation
import MLX
import Testing
@testable import StrimCore

private let specs: [(Int, Int)] = [(4, 64), (8, 64), (4, 128), (8, 32), (2, 64), (3, 64), (6, 64)]

private func quantTensors(bits: Int, group: Int, n: Int = 16, k: Int = 256) -> (MLXArray, MLXArray, MLXArray) {
    MLXRandom.seed(7)
    let w = MLXRandom.normal([n, k]).asType(.bfloat16)
    let q = quantized(w, groupSize: group, bits: bits)
    eval(q.wq, q.scales, q.biases!)
    return (q.wq, q.scales, q.biases!)
}

@Test func specValidatesMatchingShapes() throws {
    for (b, g) in specs {
        let (w, s, _) = quantTensors(bits: b, group: g)
        try QuantSpec(bits: b, groupSize: g).validate(tensor: "t", w: w, s: s)
    }
}

@Test func specRejectsEveryWrongInterpretation() throws {
    for (b, g) in specs {
        let (w, s, _) = quantTensors(bits: b, group: g)
        let truth = QuantSpec(bits: b, groupSize: g)
        let consistent = QuantSpec.shapeCandidates(packed: w.shape.last!, groups: s.shape.last!)
        #expect(consistent.contains(truth))
        for (b2, g2) in specs where (b2, g2) != (b, g) {
            let wrong = QuantSpec(bits: b2, groupSize: g2)
            do {
                try wrong.validate(tensor: "layer.x", w: w, s: s)
                // only an interpretation with the same K on both sides may pass (e.g. 4-bit g128 vs 8-bit g64 at half width)
                #expect(consistent.contains(wrong), "\(wrong) accepted tensor that is \(truth)")
            } catch let QuantError.mismatch(name, cfg, _, _, _, _, cands) {
                #expect(name == "layer.x")
                #expect(cfg == wrong)
                #expect(!consistent.contains(wrong))
                #expect(cands.contains(truth))
            }
        }
    }
}

@Test func mismatchMessageNamesTensorAndBothInterpretations() throws {
    let (w, s, _) = quantTensors(bits: 4, group: 128)
    do {
        try QuantSpec(bits: 4, groupSize: 64).validate(tensor: "language_model.model.layers.3.mlp.down_proj", w: w, s: s)
        Issue.record("no throw")
    } catch {
        let m = "\(error)"
        #expect(m.contains("language_model.model.layers.3.mlp.down_proj"))
        #expect(m.contains("4-bit g64"))
        #expect(m.contains("4-bit g128"))
    }
}

@Test func nonAffineModeIsRejectedLoudly() throws {
    let (w, s, _) = quantTensors(bits: 4, group: 64)
    #expect(throws: QuantError.self) { try QuantSpec(bits: 4, groupSize: 32, mode: "mxfp4").validate(tensor: "t", w: w, s: s) }
}

@Test func qmmWithSpecMatchesDequantizedMatmul() throws {
    for (b, g) in specs {
        let (w, s, bi) = quantTensors(bits: b, group: g)
        let x = MLXRandom.normal([2, 256]).asType(.bfloat16)
        let y = quantizedMatmul(x, w, scales: s, biases: bi, transpose: true, groupSize: g, bits: b).asType(.float32)
        let ref = matmul(x.asType(.float32), dequantized(w, scales: s, biases: bi, groupSize: g, bits: b).asType(.float32).T)
        let err = abs(y - ref).max().item(Float.self)
        #expect(err < 0.5, "bits \(b) g\(g) err \(err)")
    }
}

@Test func parsesGlobalAndPerModuleOverrides() throws {
    let json = """
    {"quantization": {"group_size": 128, "bits": 3, "mode": "affine",
       "language_model.model.layers.0.mlp.gate_proj": {"bits": 8, "group_size": 64},
       "language_model.model.layers.0.mlp.up_proj": {"bits": 5},
       "language_model.lm_head": false,
       "language_model.model.layers.1.mlp.gate_proj": true}}
    """
    let cfg = try QuantConfig.parse(block: (try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])["quantization"] as! [String: Any])
    #expect(cfg.global == QuantSpec(bits: 3, groupSize: 128))
    #expect(cfg.spec(forPrefix: "language_model.model.layers.0.mlp.gate_proj") == QuantSpec(bits: 8, groupSize: 64))
    #expect(cfg.spec(forPrefix: "language_model.model.layers.0.mlp.up_proj") == QuantSpec(bits: 5, groupSize: 128))
    #expect(cfg.spec(forPrefix: "language_model.model.layers.1.mlp.gate_proj") == QuantSpec(bits: 3, groupSize: 128))
    #expect(cfg.spec(forPrefix: "language_model.lm_head") == nil)
    #expect(cfg.spec(forPrefix: "language_model.model.layers.2.mlp.down_proj") == QuantSpec(bits: 3, groupSize: 128))
    // head stored under language_model.mtp.: lookup with the store key prefix
    var c2 = cfg
    c2.overrides["language_model.mtp.fc"] = QuantSpec(bits: 8, groupSize: 32)
    #expect(c2.spec(forPrefix: "fc", keyPrefix: "language_model.mtp.") == QuantSpec(bits: 8, groupSize: 32))
}

@Test func rejectsUnsupportedBitsAndGroups() throws {
    #expect(throws: QuantError.self) { _ = try QuantConfig.parse(block: ["bits": 7, "group_size": 64]) }
    #expect(throws: QuantError.self) { _ = try QuantConfig.parse(block: ["bits": 4, "group_size": 48]) }
    #expect(throws: QuantError.self) { _ = try QuantConfig.parse(block: ["m": ["bits": 4]]) ; _ = try QuantConfig.parse(block: ["bits": 4, "x": ["bits": 4]]) }
}

@Test func fingerprintChangesWithAnySpec() throws {
    let a = try QuantConfig.parse(block: ["bits": 4, "group_size": 64, "m": ["bits": 8, "group_size": 64]])
    let b = try QuantConfig.parse(block: ["bits": 4, "group_size": 64, "m": ["bits": 8, "group_size": 32]])
    let c = try QuantConfig.parse(block: ["bits": 4, "group_size": 128, "m": ["bits": 8, "group_size": 64]])
    #expect(Set([a.fingerprint, b.fingerprint, c.fingerprint]).count == 3)
    #expect(a.fingerprint == (try QuantConfig.parse(block: ["m": ["bits": 8, "group_size": 64], "group_size": 64, "bits": 4])).fingerprint)
}

private func makeStore(config: String, bits: Int, group: Int) throws -> WeightStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let (w, s, b) = quantTensors(bits: bits, group: group)
    try save(arrays: ["m.weight": w, "m.scales": s, "m.biases": b], url: dir.appendingPathComponent("model.safetensors"))
    let idx = #"{"metadata":{"total_size":1},"weight_map":{"m.weight":"model.safetensors","m.scales":"model.safetensors","m.biases":"model.safetensors"}}"#
    try Data(idx.utf8).write(to: dir.appendingPathComponent("model.safetensors.index.json"))
    try Data(config.utf8).write(to: dir.appendingPathComponent("config.json"))
    return try WeightStore(dir: dir)
}

@Test func storeUsesConfigSpecAndThrowsOnMismatch() throws {
    let ok = try makeStore(config: #"{"quantization":{"bits":4,"group_size":128}}"#, bits: 4, group: 128)
    #expect(try ok.quantSpec("m") == QuantSpec(bits: 4, groupSize: 128))
    let y = try ok.linear("m", MLXArray.ones([1, 256]).asType(.bfloat16))
    #expect(y.shape == [1, 16])
    // old behaviour: 4-bit g128 read as g64 shape inference gave 8-bit garbage; now a hard error
    let bad = try makeStore(config: #"{"quantization":{"bits":4,"group_size":64}}"#, bits: 4, group: 128)
    #expect(throws: QuantError.self) { _ = try bad.linear("m", MLXArray.ones([1, 256]).asType(.bfloat16)) }
    let override = try makeStore(config: #"{"quantization":{"bits":8,"group_size":64,"m":{"bits":4,"group_size":128}}}"#, bits: 4, group: 128)
    #expect(try override.quantSpec("m") == QuantSpec(bits: 4, groupSize: 128))
    let none = try makeStore(config: #"{}"#, bits: 4, group: 64)
    #expect(throws: QuantError.self) { _ = try none.quantSpec("m") }
}
