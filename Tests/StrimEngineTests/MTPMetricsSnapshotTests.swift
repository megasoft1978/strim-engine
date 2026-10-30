import Foundation
import Testing
import StrimCore
@testable import StrimEngine

@Suite struct MTPMetricsSnapshotTests {
    @Test func publishedValueSnapshotsStayIndependent() {
        var live = EngineStats()
        live.mtpLifetime = "engine-1"
        live.mtpStartedAt = Date(timeIntervalSince1970: 1234)
        live.mtp.recordRound(depth: 3, accepted: 2)
        let published = live
        live.mtp.recordRound(depth: 4, accepted: 0)
        live.mtpUnsupportedBatchTokens += 8
        #expect(published.mtp.rounds == 1 && published.mtp.proposed == [1, 1, 1, 0])
        #expect(live.mtp.rounds == 2 && live.mtp.proposed == [2, 2, 2, 1])
        #expect(published.mtpUnsupportedBatchTokens == 0)
        #expect(live.mtpLifetime == published.mtpLifetime && live.mtpStartedAt == published.mtpStartedAt)
    }
    @Test func workerSnapshotsUseExistingLockWithoutModelPreparation() async {
        // Initial snapshots are available even before model preparation. Concurrent
        // readers only access EngineStats values, never SpecStream or MLX objects.
        let worker = EngineCore(config: EngineConfig(modelDir: "/unused"))
        let lifetime = worker.currentStats().mtpLifetime
        #expect(!lifetime.isEmpty)
        #expect(EngineCore(config: EngineConfig(modelDir: "/unused")).currentStats().mtpLifetime != lifetime)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { let stats = worker.currentStats(); return stats.mtp.rounds == 0 && stats.mtpLifetime == lifetime } }
            for await value in group { #expect(value) }
        }
    }
}
