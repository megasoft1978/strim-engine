import Foundation
import Testing
import StrimAPI
import StrimHarness
import StrimHost
import StrimJobs
@testable import StrimControl

private func opts(models: [String] = ["/models"], packs: URL? = nil) -> StrimControlPlane.Options {
    var o = StrimControlPlane.Options()
    o.statusInterval = .milliseconds(100); o.jobPollInterval = .milliseconds(30); o.pingInterval = .milliseconds(150)
    o.orphanTurnGrace = .milliseconds(300)
    o.modelRoots = models; o.packsRoot = packs
    return o
}

private func blockingExecutor() -> JobExecutor {
    { _, _, _ in
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        return HarnessJobResult(status: .cancelled, summary: "stopped")
    }
}

private func submitBody(_ r: Rig, _ task: String) async throws -> String {
    try await r.jobs.submit(HarnessJobSpec(task: task, cwd: "/tmp/p"))
}

@Suite("Control: pause, cancel, models, pack", .serialized)
struct ControlProductTests {
    @Test("pause and resume flip jobs_paused in status; queued jobs wait while paused")
    func pauseResume() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        var st = try #require(await r.call("GET", "/v1/strim/status").decode(HostStatus.self) as HostStatus?)
        #expect(st.jobsPaused == false)
        let p = await r.call("POST", "/v1/strim/pause", body: "{}")
        #expect(p.status == 200)
        #expect(try p.decode(JobsPauseState.self).paused)
        let id = try await submitBody(r, "work")
        try await Task.sleep(for: .milliseconds(80))
        #expect(try await r.jobs.status(id, waitS: 0).status == .queued)
        st = try await r.call("GET", "/v1/strim/status").decode(HostStatus.self)
        #expect(st.jobsPaused == true && st.queuedJobs == 1)
        let q = await r.call("POST", "/v1/strim/resume", body: "{}")
        #expect(try q.decode(JobsPauseState.self).paused == false)
        #expect(try await r.jobs.status(id, waitS: 5).status == .done)
        // Idempotent, and an empty body is fine for pause.
        #expect(await r.call("POST", "/v1/strim/resume", body: "{}").status == 200)
        #expect(await r.call("POST", "/v1/strim/pause", body: "").status == 200)
    }

    @Test("pause with cancel_running cancels admitted jobs and reports the count")
    func pauseCancelRunning() async throws {
        let r = try await Rig.make(executor: blockingExecutor()); defer { r.stop() }
        let id = try await submitBody(r, "long")
        for _ in 0..<200 where try await r.jobs.status(id, waitS: 0).status != .running { try await Task.sleep(for: .milliseconds(5)) }
        let p = await r.call("POST", "/v1/strim/pause", body: #"{"cancel_running":true}"#)
        let s = try p.decode(JobsPauseState.self)
        #expect(s.paused && s.cancelled == 1)
        #expect(try await r.jobs.status(id, waitS: 2).status == .cancelled)
    }

    @Test("jobs/cancel: running, repeat, unknown, malformed")
    func cancelRoute() async throws {
        let r = try await Rig.make(executor: blockingExecutor()); defer { r.stop() }
        let id = try await submitBody(r, "long")
        let c = await r.call("POST", "/v1/strim/jobs/cancel", body: #"{"job_id":"\#(id)"}"#)
        #expect(c.status == 200)
        let res = try c.decode(JobCancelResult.self)
        #expect(res.status == .cancelled && res.cancelled && res.jobID == id)
        let again = try await r.call("POST", "/v1/strim/jobs/cancel", body: #"{"job_id":"\#(id)"}"#).decode(JobCancelResult.self)
        #expect(again.status == .cancelled && !again.cancelled)
        let none = await r.call("POST", "/v1/strim/jobs/cancel", body: #"{"job_id":"j_abcdefgh23"}"#)
        #expect(none.status == 404 && none.code == "not_found")
        let bad = await r.call("POST", "/v1/strim/jobs/cancel", body: #"{"job_id":"../x"}"#)
        #expect(bad.status == 400)
        #expect(await r.call("POST", "/v1/strim/jobs/cancel", body: "{}").status == 400)
    }

    @Test("jobs/cancel of a finished job is a no-op")
    func cancelFinished() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let id = try await submitBody(r, "quick")
        _ = try await r.jobs.status(id, waitS: 5)
        let res = try await r.call("POST", "/v1/strim/jobs/cancel", body: #"{"job_id":"\#(id)"}"#).decode(JobCancelResult.self)
        #expect(res.status == .done && !res.cancelled)
    }

    @Test("the API token cannot pause, cancel or list models")
    func apiTokenRefused() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        for (m, p, b) in [("POST", "/v1/strim/pause", "{}"), ("POST", "/v1/strim/resume", "{}"),
                          ("POST", "/v1/strim/jobs/cancel", #"{"job_id":"j_abcdefgh23"}"#),
                          ("GET", "/v1/strim/models", ""), ("GET", "/v1/strim/pack", "")] {
            let x = await r.call(m, p, body: m == "POST" ? b : nil, bearer: "tok")
            #expect(x.status == 403, "\(m) \(p) -> \(x.status)")
        }
    }

    @Test("models: lists config.json directories under the roots, nothing outside")
    func models() async throws {
        let root = tmpDir("models")
        let fm = FileManager.default
        for n in ["Qwen-27B", "mtp-head", "empty"] { try fm.createDirectory(at: root.appendingPathComponent(n), withIntermediateDirectories: true) }
        try fm.createDirectory(at: root.appendingPathComponent("org/Deep-8B"), withIntermediateDirectories: true)
        for n in ["Qwen-27B", "mtp-head", "org/Deep-8B"] { try Data("{}".utf8).write(to: root.appendingPathComponent(n + "/config.json")) }
        try Data(count: 2048).write(to: root.appendingPathComponent("Qwen-27B/model.safetensors"))
        let r = try await Rig.make(options: opts(models: [root.path])); defer { r.stop() }
        let list = try await r.call("GET", "/v1/strim/models").decode(ModelList.self)
        #expect(list.models.map(\.name) == ["Deep-8B", "mtp-head", "Qwen-27B"])
        #expect(list.models.first { $0.name == "mtp-head" }?.kind == "mtp")
        #expect(list.models.first { $0.name == "Qwen-27B" }?.sizeGB != nil)
        #expect(list.models.allSatisfy { $0.path.hasSuffix("/" + root.lastPathComponent + "/" + ($0.name == "Deep-8B" ? "org/" : "") + $0.name) })
        let none = try await Rig.make(options: opts(models: [])); defer { none.stop() }
        #expect(try await none.call("GET", "/v1/strim/models").decode(ModelList.self).models.isEmpty)
    }

    @Test("pack: active fingerprint and the newest evolve record")
    func pack() async throws {
        let root = tmpDir("packs")
        let fm = FileManager.default
        let a = "aaaaaaaaaaaaaaaa", b = "bbbbbbbbbbbbbbbb"
        for fp in [a, b] { try fm.createDirectory(at: root.appendingPathComponent(fp), withIntermediateDirectories: true) }
        try Data(a.utf8).write(to: root.appendingPathComponent("ACTIVE"))
        try Data(#"{"fingerprint":"\#(a)","createdAt":"2026-10-20T10:00:00Z","dryRun":false,"round":1,"valGainPP":1.5}"#.utf8 + Data("\n".utf8))
            .write(to: root.appendingPathComponent(a + "/provenance.jsonl"))
        try Data(("{\"fingerprint\":\"\(b)\",\"createdAt\":\"2026-10-21T10:00:00Z\",\"dryRun\":true}\n"
                  + "{\"fingerprint\":\"\(b)\",\"parent\":\"\(a)\",\"createdAt\":\"2026-10-22T10:00:00Z\",\"dryRun\":false,\"round\":3,\"valGainPP\":2.25,\"source\":\"strim evolve v0\"}\n").utf8)
            .write(to: root.appendingPathComponent(b + "/provenance.jsonl"))
        let r = try await Rig.make(options: opts(packs: root)); defer { r.stop() }
        let info = try await r.call("GET", "/v1/strim/pack").decode(PackInfo.self)
        #expect(info.activeFingerprint == a && info.packCount == 2)
        #expect(info.lastEvolve?.fingerprint == b && info.lastEvolve?.round == 3 && info.lastEvolve?.valGainPP == 2.25)
        #expect(info.lastEvolve?.parent == a && info.lastEvolve?.dryRun == false)
        // Empty or missing store: no crash, nothing claimed.
        let e = try await Rig.make(options: opts(packs: tmpDir("nopacks").appendingPathComponent("missing"))); defer { e.stop() }
        let none = try await e.call("GET", "/v1/strim/pack").decode(PackInfo.self)
        #expect(none.activeFingerprint == nil && none.packCount == 0 && none.lastEvolve == nil)
    }

    @Test("pack: an ACTIVE file that is not a known fingerprint is ignored")
    func packBadActive() async throws {
        let root = tmpDir("packs2")
        try Data("../../etc".utf8).write(to: root.appendingPathComponent("ACTIVE"))
        let r = try await Rig.make(options: opts(packs: root)); defer { r.stop() }
        #expect(try await r.call("GET", "/v1/strim/pack").decode(PackInfo.self).activeFingerprint == nil)
    }

    @Test("enable_thinking reaches the chat backend on open and append")
    func thinkingPassThrough() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let cwd = tmpDir("proj").path
        let o = await r.call("POST", "/v1/strim/chat/open", body: #"{"cwd":"\#(cwd)","profile":"interactive","enable_thinking":false}"#)
        #expect(o.status == 200)
        let sid = try o.decode(ChatSession.self).sessionID
        #expect(r.chat.thinking == [false])
        let a = await r.call("POST", "/v1/strim/chat/append", body: #"{"session_id":"\#(sid)","text":"hi","enable_thinking":true}"#)
        #expect(a.status == 202)
        #expect(r.chat.thinking == [false, true])
        // Omitted: not forwarded.
        _ = try await Task.sleep(for: .milliseconds(100))
        _ = await r.call("POST", "/v1/strim/chat/cancel", body: #"{"session_id":"\#(sid)"}"#)
    }
}
