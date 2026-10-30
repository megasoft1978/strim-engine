import Foundation
import MLX
import Testing
@testable import StrimCore

private final class MacroBundleMarker {}

@Suite struct MacroPrefillTests {
    @Test func defaultPolicyIsUnchangedWithoutOptIn() {
        if ProcessInfo.processInfo.environment["STRIM_PREFILL_MACRO_BF16"] == nil {
            #expect(!MacroPrefill.enabled)
            #expect(PrefixPrefill.chunk == 1024)        }
    }

    // A change to future tokens must not leak backwards through either recurrence
    // or cached SDPA, including when all four subgraphs are evaluated lazily together.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STRIM_LIVE"] == "1"
                   && ProcessInfo.processInfo.environment["STRIM_PREFILL_MACRO_BF16"] == "1"))
    func macroMixersCannotSeeFutureRanges() throws {
        let b = Bundle(for: MacroBundleMarker.self); _ = b.load(); _ = Bundle.allBundles
        let model = try #require(ProcessInfo.processInfo.environment["STRIM_LIVE_MODEL"])
        let store = try WeightStore(dir: URL(fileURLWithPath: model))
        MLXRandom.seed(707)
        let x = (MLXRandom.normal([1, 4096, 5120]) * 0.1).asType(.bfloat16)
        let changed = concatenated([x[0..., 0..<1024, 0...], x[0..., 1024..<4096, 0...] + 1], axis: 1)
        for layer in [0, 3] {
            func run(_ input: MLXArray) throws -> MLXArray {
                if layer == 0 { return try GDN.forward(input, store: store, layer: layer, state: GDNState()) }
                return try Attention.forward(input, store: store, layer: layer, cache: AttentionCache())
            }
            let original = try run(x), futureChanged = try run(changed)
            #expect(arrayEqual(original[0..., 0..<1024, 0...], futureChanged[0..., 0..<1024, 0...]).item(Bool.self),
                    "future tokens leaked backwards in layer \(layer)")
        }
    }
}
