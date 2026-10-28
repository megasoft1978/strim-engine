import Foundation
import MLX
import Testing
@testable import StrimEngine

private final class BundleMarker {}
private let metalReady: Void = {
    let b = Bundle(for: BundleMarker.self)
    _ = b.load()
    _ = Bundle.allBundles
}()

@Suite struct SamplerTests {
    init() { _ = metalReady }

    @Test func firstTokenReproducibleForSeed() {
        let logits = MLXArray((0 ..< 200).map { Float(($0 * 37) % 11) })
        func first(_ seed: UInt64) -> Int32 {
            Sampler(params: GenParams(temperature: 1, topP: 0.95, topK: 20, seed: seed)).sampleFirst(logits)
        }
        #expect(first(5) == first(5))
        #expect(Set((0 ..< 30).map { first(UInt64($0)) }).count > 2)
        let a = Sampler(params: GenParams(temperature: 1, seed: 5)), b = Sampler(params: GenParams(temperature: 1, seed: 5))
        #expect(a.config == b.config && a.config.seed == 5)
    }
}
