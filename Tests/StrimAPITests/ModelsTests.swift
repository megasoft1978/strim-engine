import Foundation
import Testing
@testable import StrimAPI

private func enc() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
private func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try enc().encode(v), as: UTF8.self) }
private func roundTrip<T: Codable & Equatable>(_ v: T, golden: String) throws {
    #expect(try json(v) == golden)
    #expect(try JSONDecoder().decode(T.self, from: Data(golden.utf8)) == v)
}

private let mem = MemoryStats(weightsGB: 15.5, prefixTrieGB: 2, mlxCacheGB: 1, headroomGB: 20)
private let memJSON = #"{"headroom_gb":20,"mlx_cache_gb":1,"prefix_trie_gb":2,"weights_gb":15.5}"#
private let status = HostStatus(state: .busy, model: "m", mtp: "h", loadProgress: 0.5, memory: mem, decodeTPS: 40, prefillTPS: 900,
    mtpAcceptance: 0.7, mtpDepth: 2, prefixHitRate: 0.9, savedPrefillSeconds: 12, activeJobs: 1, queuedJobs: 2,
    tokensToday: 100, localTokensGenerated: 50, uptimeSeconds: 60, lastCrash: "oom", parentTokensSavedEstimate: 7)
private let statusJSON = #"{"active_jobs":1,"decode_tps":40,"last_crash":"oom","load_progress":0.5,"local_tokens_generated":50,"memory":"# + memJSON + #","model":"m","mtp":"h","mtp_acceptance":0.7,"mtp_depth":2,"parent_tokens_saved_estimate":7,"prefill_tps":900,"prefix_hit_rate":0.9,"queued_jobs":2,"saved_prefill_seconds":12,"state":"busy","tokens_today":100,"uptime_seconds":60}"#
private let sum = JobSummary(id: "j1", source: .mcp, status: .awaitingApproval, verify: .verified, started: 1000, finished: 1010, title: "t", cwd: "/r")
private let sumJSON = #"{"cwd":"/r","finished":1010,"id":"j1","source":"mcp","started":1000,"status":"awaiting_approval","title":"t","verify":"verified"}"#

@Suite struct ModelsTests {
    @Test func hostState() throws {
        for s in HostState.allCases { #expect(try json(s) == "\"\(s.rawValue)\"") }
        #expect(HostState.allCases.map(\.rawValue) == ["stopped", "loading", "ready", "busy", "error"])
    }
    @Test func memoryGolden() throws { try roundTrip(mem, golden: memJSON) }
    @Test func statusGolden() throws { try roundTrip(status, golden: statusJSON) }
    @Test func statusMinimalOmitsOptionals() throws {
        let s = HostStatus(state: .stopped, memory: mem)
        let j = try json(s)
        #expect(!j.contains("last_crash") && !j.contains("model") && !j.contains("parent_tokens"))
        #expect(try JSONDecoder().decode(HostStatus.self, from: Data(j.utf8)) == s)
    }
    @Test func loadRequest() throws {
        try roundTrip(LoadRequest(model: "m", mtp: "h"), golden: #"{"model":"m","mtp":"h"}"#)
    }
    @Test func jobSummary() throws { try roundTrip(sum, golden: sumJSON) }
    @Test func jobDetail() throws {
        let d = JobDetail(summary: sum, resultSummary: "ok", patch: "diff", turns: 3, localTokens: 99, verifyOutput: "pass")
        try roundTrip(d, golden: #"{"local_tokens":99,"patch":"diff","result_summary":"ok","summary":"# + sumJSON + #","turns":3,"verify_output":"pass"}"#)
    }
    @Test func approval() throws {
        try roundTrip(PatchApproval(jobID: "j1", action: .apply), golden: #"{"action":"apply","job_id":"j1"}"#)
        try roundTrip(PatchApproval(jobID: "j1", action: .reject), golden: #"{"action":"reject","job_id":"j1"}"#)
    }
    @Test func patchDigestIsAdditiveAndRoundTrips() throws {
        let sha = String(repeating: "ab", count: 32)
        try roundTrip(PatchApproval(jobID: "j1", action: .apply, patchSHA256: sha),
                      golden: #"{"action":"apply","job_id":"j1","patch_sha256":"\#(sha)"}"#)
        // old clients omit the field: still decodes, digest nil
        let old = try JSONDecoder().decode(PatchApproval.self, from: Data(#"{"action":"apply","job_id":"j1"}"#.utf8))
        #expect(old.patchSHA256 == nil)
        let d = JobDetail(summary: sum, patch: "diff", patchSHA256: sha)
        try roundTrip(d, golden: #"{"local_tokens":0,"patch":"diff","patch_sha256":"\#(sha)","summary":"# + sumJSON + #","turns":0}"#)
    }
    @Test func chat() throws {
        try roundTrip(ChatOpenRequest(cwd: "/r", profile: "interactive"), golden: #"{"cwd":"/r","profile":"interactive"}"#)
        try roundTrip(ChatAppendRequest(sessionID: "s", text: "hi"), golden: #"{"session_id":"s","text":"hi"}"#)
        try roundTrip(ChatCancelRequest(sessionID: "s"), golden: #"{"session_id":"s"}"#)
        try roundTrip(ChatSession(sessionID: "s", jobID: "j", cwd: "/r", profile: "p"), golden: #"{"cwd":"/r","job_id":"j","profile":"p","session_id":"s"}"#)
    }
    @Test func errors() throws {
        try roundTrip(APIErrorEnvelope(error: APIError(code: "c", message: "m")), golden: #"{"error":{"code":"c","message":"m"}}"#)
    }
    @Test func events() throws {
        try roundTrip(StrimEvent.status(HostStatus(state: .stopped, memory: mem)),
                      golden: #"{"data":{"active_jobs":0,"decode_tps":0,"local_tokens_generated":0,"memory":"# + memJSON + #","mtp_acceptance":0,"mtp_depth":0,"prefill_tps":0,"prefix_hit_rate":0,"queued_jobs":0,"saved_prefill_seconds":0,"state":"stopped","tokens_today":0,"uptime_seconds":0},"type":"status"}"#)
        try roundTrip(StrimEvent.jobEvent(JobEvent(jobID: "j", status: .done, verify: .failed)),
                      golden: #"{"data":{"job_id":"j","status":"done","verify":"failed"},"type":"job_event"}"#)
        try roundTrip(StrimEvent.harnessEvent(HarnessEvent(jobID: "j", kind: "tool", text: "ls")),
                      golden: #"{"data":{"job_id":"j","kind":"tool","text":"ls"},"type":"harness_event"}"#)
        try roundTrip(StrimEvent.chatDelta(ChatDelta(sessionID: "s", kind: .toolCall, text: "x")),
                      golden: #"{"data":{"kind":"tool_call","session_id":"s","text":"x"},"type":"chat_delta"}"#)
        try roundTrip(StrimEvent.error(APIError(code: "c", message: "m")),
                      golden: #"{"data":{"code":"c","message":"m"},"type":"error"}"#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(StrimEvent.self, from: Data(#"{"type":"zzz","data":{}}"#.utf8)) }
    }
    @Test func routes() {
        #expect(StrimRoutes.status == "/v1/strim/status")
        #expect(StrimRoutes.events == "/v1/strim/events")
        #expect(StrimRoutes.job("a") == "/v1/strim/jobs/a")
    }
}

@Suite struct FakeClientTests {
    @Test func scripted() async throws {
        let f = FakeControlClient()
        #expect(try await f.status().state == .ready)
        await f.setJobs([sum])
        #expect(try await f.job(id: "j1").summary == sum)
        try await f.unload()
        #expect(try await f.status().state == .stopped)
        try await f.approve(PatchApproval(jobID: "j1", action: .apply))
        #expect(await f.calls == ["unload", "approve:j1:apply"])
        await f.setFailNext(APIError(code: "x", message: "y"))
        await #expect(throws: APIError.self) { try await f.jobs() }
    }
    @Test func eventStream() async throws {
        let f = FakeControlClient()
        await f.emit(.jobEvent(JobEvent(jobID: "j", status: .running)))
        await f.emit(.error(APIError(code: "c", message: "m")))
        await f.finishEvents()
        var got: [StrimEvent] = []
        let s = f.events()
        Task { try? await Task.sleep(nanoseconds: 50_000_000); await f.finishEvents() }
        for try await e in s { got.append(e) }
        #expect(got.count == 2)
    }
}
