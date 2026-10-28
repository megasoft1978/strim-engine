import Foundation
import MLX
import Testing
import StrimEngine
@testable import StrimHost

/// Real model. Skipped unless `STRIM_LIVE=1` (and `STRIM_LIVE_MODEL=<dir>`, optional `STRIM_LIVE_HEAD=<dir>`).
/// Never runs in CI or while another process holds the GPU.
@Suite("EngineSlot live", .serialized)
struct EngineSlotLiveTests {
    static let live = ProcessInfo.processInfo.environment["STRIM_LIVE"] == "1"

    @Test("unload drops MLX active memory", .enabled(if: EngineSlotLiveTests.live))
    func unloadDropsMemory() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = try #require(env["STRIM_LIVE_MODEL"], "set STRIM_LIVE_MODEL")
        let slot = EngineSlot(
            factory: { m, h, _ in try await LocalEngineClient.start(EngineConfig.fromEnvironment(modelDir: m, headDir: h)) },
            release: { e in await (e as? LocalEngineClient)?.shutdown() })
        let before = Memory.activeMemory
        try await slot.load(model: model, mtp: env["STRIM_LIVE_HEAD"])
        let loaded = Memory.activeMemory
        #expect(loaded > before + (1 << 30), "model weights should be resident")
        try await slot.unload()
        Memory.clearCache()
        let after = Memory.activeMemory
        #expect(after < loaded / 4, "active memory \(after >> 20) MB after unload, \(loaded >> 20) MB loaded")
    }
}
