import Foundation
import Testing
import StrimCore
import StrimEngine
@testable import StrimServer

@Suite struct MTPMetricsTests {
    @Test func metricsExposeBoundedCountsLifetimeAndUnsupportedBatchCoverage() async throws {
        let fake = FakeEngine()
        fake.reportedStats.mtp.recordRound(depth: 3, accepted: 1)
        fake.reportedStats.mtpUnsupportedBatchTokens = 8
        let server = StrimOpenAIServer(engine: fake, config: ServerConfig(modelId: "fake", bearerToken: "test"))
        let port = try await server.start(port: 0); defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/metrics")!)
        request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let engine = try #require(root["engine"] as? [String: Any])
        let mtp = try #require(engine["mtp"] as? [String: Any])
        #expect(mtp["proposed"] as? [Int] == [1, 1, 1, 0])
        #expect(mtp["reached"] as? [Int] == [1, 1, 0, 0])
        #expect(mtp["accepted_prefix"] as? [Int] == [1, 0, 0, 0])
        #expect(mtp["positions"] as? [Int] == [1, 2, 3, 4])
        #expect(mtp["rounds"] as? Int == 1 && mtp["emitted"] as? Int == 2)
        #expect(mtp["batch_supported"] as? Bool == false)
        #expect(mtp["unsupported_batch_tokens"] as? Int == 8)
        #expect(mtp["coverage"] as? String == "completed_specstream_rounds")
        #expect(mtp["resets"] as? String == "engine_creation")
        #expect(mtp["lifetime"] as? String == fake.reportedStats.mtpLifetime)
        #expect(mtp["started_at"] is String)
        #expect(mtp["overflow_proposed"] as? Int == 0)
        #expect(root["server"] is [String: Any])
    }
    @Test func defaultMetricsHaveZeroCoverage() {
        let stats = EngineStats()
        #expect(stats.mtp.rounds == 0 && stats.mtp.proposed == [0, 0, 0, 0])
        #expect(stats.mtpUnsupportedBatchTokens == 0)
    }
}
