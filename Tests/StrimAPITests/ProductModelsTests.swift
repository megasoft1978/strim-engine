import Foundation
import Testing
@testable import StrimAPI

private func enc<T: Encodable>(_ v: T) throws -> String {
    let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try e.encode(v), as: UTF8.self)
}
private func rt<T: Codable & Equatable>(_ v: T, _ golden: String) throws {
    #expect(try enc(v) == golden)
    #expect(try JSONDecoder().decode(T.self, from: Data(golden.utf8)) == v)
}

@Suite struct ProductModelsTests {
    @Test func pauseAndCancel() throws {
        try rt(PauseRequest(cancelRunning: true), #"{"cancel_running":true}"#)
        #expect(try JSONDecoder().decode(PauseRequest.self, from: Data("{}".utf8)).cancelRunning == false)
        try rt(JobsPauseState(paused: true, queued: 2, running: 1, cancelled: 1), #"{"cancelled":1,"paused":true,"queued":2,"running":1}"#)
        try rt(JobCancelRequest(jobID: "j_abc"), #"{"job_id":"j_abc"}"#)
        try rt(JobCancelResult(jobID: "j_abc", status: .cancelled, cancelled: true), #"{"cancelled":true,"job_id":"j_abc","status":"cancelled"}"#)
    }
    @Test func modelsAndPack() throws {
        try rt(ModelList(models: [LocalModel(name: "Q", path: "/m/Q", sizeGB: 1.5, kind: "model")]),
               #"{"models":[{"kind":"model","name":"Q","path":"/m/Q","size_gb":1.5}]}"#)
        try rt(PackInfo(activeFingerprint: "aaaaaaaaaaaaaaaa", packCount: 1,
                        lastEvolve: EvolveSummary(fingerprint: "aaaaaaaaaaaaaaaa", round: 1, valGainPP: 2, createdAt: "t")),
               #"{"active_fingerprint":"aaaaaaaaaaaaaaaa","last_evolve":{"created_at":"t","dry_run":false,"fingerprint":"aaaaaaaaaaaaaaaa","round":1,"val_gain_pp":2},"pack_count":1}"#)
        try rt(PackInfo(), #"{"pack_count":0}"#)
    }
    @Test func thinkingFieldIsOptionalOnTheWire() throws {
        try rt(ChatOpenRequest(cwd: "/p"), #"{"cwd":"\/p","profile":"interactive"}"#.replacingOccurrences(of: "\\/", with: "/"))
        try rt(ChatOpenRequest(cwd: "/p", enableThinking: false), #"{"cwd":"/p","enable_thinking":false,"profile":"interactive"}"#)
        try rt(ChatAppendRequest(sessionID: "s", text: "hi"), #"{"session_id":"s","text":"hi"}"#)
        try rt(ChatAppendRequest(sessionID: "s", text: "hi", enableThinking: true), #"{"enable_thinking":true,"session_id":"s","text":"hi"}"#)
    }
    @Test func statusPausedFlagOmittedWhenUnknown() throws {
        let m = MemoryStats(weightsGB: 0, prefixTrieGB: 0, mlxCacheGB: 0, headroomGB: 0)
        #expect(try !enc(HostStatus(state: .ready, memory: m)).contains("jobs_paused"))
        #expect(try enc(HostStatus(state: .ready, memory: m, jobsPaused: true)).contains(#""jobs_paused":true"#))
    }
    @Test func routesAreDistinct() {
        let r = [StrimRoutes.pause, StrimRoutes.resume, StrimRoutes.jobCancel, StrimRoutes.models, StrimRoutes.pack]
        #expect(Set(r).count == r.count && r.allSatisfy { $0.hasPrefix("/v1/strim/") })
    }
}
