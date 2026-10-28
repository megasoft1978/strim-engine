import Foundation
import Testing
import StrimAPI
import StrimEngine
import StrimHarness
import StrimHost
import StrimJobs
@testable import StrimControl

private struct Boom: Error, CustomStringConvertible { var description: String { "weights missing" } }

private let readRoutes = [("GET", "/v1/strim/status"), ("GET", "/v1/strim/events"), ("GET", "/v1/strim/jobs"), ("GET", "/v1/strim/jobs/j_abcdefgh23"),
                            ("GET", "/v1/strim/models"), ("GET", "/v1/strim/pack")]
private let writeRoutes = [("POST", "/v1/strim/load"), ("POST", "/v1/strim/unload"), ("POST", "/v1/strim/jobs/approve"),
                           ("POST", "/v1/strim/chat/open"), ("POST", "/v1/strim/chat/append"), ("POST", "/v1/strim/chat/cancel"),
                           ("POST", "/v1/strim/chat/close"),
                           ("POST", "/v1/strim/pause"), ("POST", "/v1/strim/resume"), ("POST", "/v1/strim/jobs/cancel"), ("DELETE", "/v1/strim/chat/j_abcdefgh23")]

@Suite("Control routes: auth and guards", .serialized)
struct ControlGuardTests {
    @Test("every route: 401 without the bearer token")
    func noToken() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        for (m, p) in readRoutes + writeRoutes {
            let x = await r.call(m, p, body: m == "POST" ? "{}" : nil, auth: false)
            #expect(x.status == 401, "\(m) \(p) -> \(x.status)")
        }
        let bad = await r.call("GET", "/v1/strim/status", auth: false, headers: ["Authorization": "Bearer nope"])
        #expect(bad.status == 401)
    }

    @Test("every route: 403 for a non-loopback Host, even with the token")
    func badHost() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        for (m, p) in readRoutes + writeRoutes {
            let x = await r.call(m, p, body: m == "POST" ? "{}" : nil, host: "evil.example.com")
            #expect(x.status == 403, "\(m) \(p) -> \(x.status)")
        }
    }

    @Test("foreign Origin and cross-site fetch metadata are refused, loopback Origin passes")
    func origin() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        #expect(await r.call("GET", "/v1/strim/status", headers: ["Origin": "https://evil.example.com"]).status == 403)
        #expect(await r.call("POST", "/v1/strim/unload", body: "", headers: ["Origin": "http://evil.test"]).status == 403)
        #expect(await r.call("GET", "/v1/strim/status", headers: ["Sec-Fetch-Site": "cross-site"]).status == 403)
        #expect(await r.call("GET", "/v1/strim/status", headers: ["Origin": "http://localhost:3000"]).status == 200)
    }

    @Test("write bodies must be JSON and small")
    func bodyChecks() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let ct = await r.call("POST", "/v1/strim/load", body: #"{"model":"m"}"#, headers: ["Content-Type": "text/plain"], json: false)
        #expect(ct.status == 400)
        let bad = await r.call("POST", "/v1/strim/load", body: "{nope")
        #expect(bad.status == 400 && bad.code == "bad_request")
        let big = await r.call("POST", "/v1/strim/load", body: #"{"model":""# + String(repeating: "a", count: 1_200_000) + #""}"#)
        #expect(big.status == 400)
    }

    @Test("errors use the envelope; unknown method is 405")
    func envelope() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let x = await r.call("GET", "/v1/strim/jobs/not-an-id")
        #expect(x.status == 400)
        #expect(try x.error().code == "bad_request")
        #expect(await r.call("PUT", "/v1/strim/status").status == 405)
    }
}

@Suite("Control routes: status, load, unload", .serialized)
struct ControlStatusTests {
    @Test("status JSON has exactly the keys of the contract sample and decodes as HostStatus")
    func statusGolden() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let x = await r.call("GET", "/v1/strim/status")
        #expect(x.status == 200 && x.headers["content-type"] == "application/json")
        let st = try x.decode(HostStatus.self)
        #expect(st.state == .ready && st.model == "Qwen-27B" && st.mtp == "head")
        let sample = try JSONSerialization.jsonObject(with: try ControlJSON.encode(FakeControlClient.sampleStatus)) as! [String: Any]
        #expect(try x.keys() == Set(sample.keys))
        let mem = try (JSONSerialization.jsonObject(with: x.data) as! [String: Any])["memory"] as! [String: Any]
        #expect(Set(mem.keys) == ["weights_gb", "prefix_trie_gb", "mlx_cache_gb", "headroom_gb"])
        #expect(abs(st.memory.weightsGB - 4) < 1e-9 && abs(st.memory.prefixTrieGB - 1) < 1e-9)
        #expect(abs(st.memory.mlxCacheGB - 0.5) < 1e-9 && abs(st.memory.headroomGB - 16) < 1e-9)
    }

    @Test("status reflects real counters after a generation")
    func counters() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        var u = Usage(); u.promptTokens = 100; u.cachedTokens = 50; u.prefillSeconds = 0.5; u.completionTokens = 40; u.decodeSeconds = 2
        u.mtpAccept = 0.6; u.mtpPasses = 20
        r.engine.script = [.finished(.stop, u)]
        let id = try await r.slot.client.openSession(SessionConfig())
        for try await _ in r.slot.client.generate(id, GenParams()) {}
        let st = try await r.call("GET", "/v1/strim/status").decode(HostStatus.self)
        #expect(abs(st.decodeTPS - 20) < 1e-9 && abs(st.prefillTPS - 100) < 1e-9)
        #expect(abs(st.mtpAcceptance - 0.6) < 1e-9 && abs(st.mtpDepth - 2) < 1e-9)
        #expect(abs(st.prefixHitRate - 0.5) < 1e-9 && st.savedPrefillSeconds > 0)
        #expect(st.localTokensGenerated == 40 && st.tokensToday == 40)
        #expect(st.activeJobs == 0 && st.queuedJobs == 0 && st.uptimeSeconds >= 0)
    }

    @Test("stopped slot: state stopped, no model, zero memory")
    func stopped() async throws {
        let r = try await Rig.make(load: false); defer { r.stop() }
        let st = try await r.call("GET", "/v1/strim/status").decode(HostStatus.self)
        #expect(st.state == .stopped && st.model == nil && st.memory.weightsGB == 0)
    }

    @Test("load: 202 loading, then ready; same call again is a no-op; another model while ready is 409")
    func load() async throws {
        let r = try await Rig.make(load: false); defer { r.stop() }
        let x = await r.call("POST", "/v1/strim/load", body: #"{"model":"/models/a","mtp":"/models/h"}"#)
        #expect(x.status == 202)
        let first = try x.decode(HostStatus.self)
        #expect(first.state == .loading || first.state == .ready)
        await r.slot.waitForLoad()
        #expect(try await r.call("GET", "/v1/strim/status").decode(HostStatus.self).state == .ready)
        #expect(await r.call("POST", "/v1/strim/load", body: #"{"model":"/models/a","mtp":"/models/h"}"#).status == 202)
        let other = await r.call("POST", "/v1/strim/load", body: #"{"model":"/models/b"}"#)
        #expect(other.status == 409 && other.code == "conflict")
    }

    @Test("load validation: empty model and missing body are 400")
    func loadValidation() async throws {
        let r = try await Rig.make(load: false); defer { r.stop() }
        #expect(await r.call("POST", "/v1/strim/load", body: #"{"model":""}"#).status == 400)
        #expect(await r.call("POST", "/v1/strim/load", body: "").status == 400)
        #expect(await r.call("POST", "/v1/strim/load", body: #"{"mtp":"x"}"#).status == 400)
    }

    @Test("failed load: status error with last_crash, retry works; load while loading is 409")
    func failedLoad() async throws {
        let gate = Locked<Int>(0)
        let r = try await Rig.make(load: false, factory: { _, _, _ in
            let n = gate.withLock { $0 += 1; return $0 }
            if n == 1 { try await Task.sleep(for: .milliseconds(300)); throw Boom() }
            return CtlFakeEngine()
        })
        defer { r.stop() }
        #expect(await r.call("POST", "/v1/strim/load", body: #"{"model":"/models/a"}"#).status == 202)
        let busy = await r.call("POST", "/v1/strim/load", body: #"{"model":"/models/a"}"#)
        #expect(busy.status == 409)
        let unl = await r.call("POST", "/v1/strim/unload", body: "")
        #expect(unl.status == 409)
        await r.slot.waitForLoad()
        let st = try await r.call("GET", "/v1/strim/status").decode(HostStatus.self)
        #expect(st.state == .error && st.lastCrash == "weights missing")
        #expect(await r.call("POST", "/v1/strim/load", body: #"{"model":"/models/a"}"#).status == 202)
        await r.slot.waitForLoad()
        #expect(try await r.call("GET", "/v1/strim/status").decode(HostStatus.self).state == .ready)
    }

    @Test("unload: 200 stopped and idempotent; engine reference is released")
    func unload() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let x = await r.call("POST", "/v1/strim/unload", body: "")
        #expect(x.status == 200 && x.state == .stopped)
        #expect(await r.call("POST", "/v1/strim/unload", body: "").status == 200)
        #expect(!r.slot.client.isLoaded)
    }

    @Test("unload with a running job or open chat session is 409 and leaves the model loaded")
    func unloadBusy() async throws {
        let hold = Locked<Bool>(true)
        let r = try await Rig.make(executor: { _, _, _ in
            while hold.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(20)) }
            return HarnessJobResult(status: .done, summary: "ok")
        })
        defer { hold.withLock { $0 = false }; r.stop() }
        let id = try await r.jobs.submit(HarnessJobSpec(task: "t", cwd: "/tmp"), priority: .normal)
        for _ in 0..<400 where (try await r.jobs.status(id, waitS: 0)).status != .running { try await Task.sleep(for: .milliseconds(20)) }
        await r.jobs.flush()
        let x = await r.call("POST", "/v1/strim/unload", body: "")
        #expect(x.status == 409 && x.code == "conflict")
        let st = try await r.call("GET", "/v1/strim/status").decode(HostStatus.self)
        #expect(st.state == .busy && st.activeJobs == 1)
        hold.withLock { $0 = false }
        _ = try await r.jobs.status(id, waitS: 5); await r.jobs.flush()
        #expect(await r.call("POST", "/v1/strim/unload", body: "").status == 200)
    }
}

@Suite("Control routes: jobs", .serialized)
struct ControlJobsTests {
    @Test("list is newest first; detail has summary, verify output, patch and digest")
    func listDetail() async throws {
        let patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\n one\n+two\n"
        let r = try await Rig.make(patch: patch); defer { r.stop() }
        let a = try await runJob(r, cwd: "/tmp")
        try await Task.sleep(for: .milliseconds(20))
        let b = try await runJob(r, cwd: "/tmp")
        let list = try await r.call("GET", "/v1/strim/jobs").decode([JobSummary].self)
        #expect(list.map(\.id) == [b, a])
        #expect(list[0].status == .done && list[0].source == .mcp && list[0].verify == .verified && list[0].title == "fix it")
        let d = await r.call("GET", "/v1/strim/jobs/\(a)")
        #expect(d.status == 200)
        let det = try d.decode(JobDetail.self)
        #expect(det.id == a && det.patch == patch && det.resultSummary == "patched" && det.verifyOutput == "3 passed")
        let obj = try JSONSerialization.jsonObject(with: d.data) as! [String: Any]
        #expect(obj["patch_sha256"] as? String == StrimControlPlane.sha256(Data(patch.utf8)))
    }

    @Test("detail: unknown id 404, malformed id 400, 'approve' is not a job id")
    func detailErrors() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let nf = await r.call("GET", "/v1/strim/jobs/j_abcdefgh23")
        #expect(nf.status == 404 && nf.code == "not_found")
        #expect(await r.call("GET", "/v1/strim/jobs/..%2F..%2Fetc").status == 400)
        #expect(await r.call("GET", "/v1/strim/jobs/approve").status == 400)
        #expect(await r.call("GET", "/v1/strim/jobs/").status == 400)
    }

    @Test("a patchPath outside the job directory is never read")
    func forgedPatchPath() async throws {
        let secret = tmpDir("sec").appendingPathComponent("secret.txt")
        try "TOP SECRET".write(to: secret, atomically: true, encoding: .utf8)
        let r = try await Rig.make(executor: { _, _, _ in
            HarnessJobResult(status: .done, summary: "x", patchPath: secret.path)
        })
        defer { r.stop() }
        let id = try await runJob(r, cwd: "/tmp")
        let d = await r.call("GET", "/v1/strim/jobs/\(id)")
        #expect(!d.body.contains("TOP SECRET") && d.detail?.patch == nil)
    }

    @Test("pre-run approval: apply runs the job, reject cancels it")
    func preRun() async throws {
        let r = try await Rig.make(requireApproval: true); defer { r.stop() }
        let a = try await r.jobs.submit(HarnessJobSpec(task: "a", cwd: "/tmp"), priority: .normal)
        let b = try await r.jobs.submit(HarnessJobSpec(task: "b", cwd: "/tmp"), priority: .normal)
        for _ in 0..<400 where (try await r.jobs.status(a, waitS: 0)).status != .awaitingApproval { try await Task.sleep(for: .milliseconds(20)) }
        let ok = await r.call("POST", "/v1/strim/jobs/approve", body: #"{"job_id":"\#(a)","action":"apply"}"#)
        #expect(ok.status == 200, "\(ok.body)")
        #expect((try await r.jobs.status(a, waitS: 5)).status == .done)
        for _ in 0..<400 where (try await r.jobs.status(b, waitS: 0)).status != .awaitingApproval { try await Task.sleep(for: .milliseconds(20)) }
        let rej = await r.call("POST", "/v1/strim/jobs/approve", body: #"{"job_id":"\#(b)","action":"reject"}"#)
        let bst = try await r.jobs.status(b, waitS: 0).status
        #expect(rej.status == 200, "\(rej.body) \(bst)")
        #expect((try await r.jobs.status(b, waitS: 5)).status == .cancelled)
        let again = await r.call("POST", "/v1/strim/jobs/approve", body: #"{"job_id":"\#(a)","action":"apply"}"#)
        #expect(again.status == 409 || again.status == 400)
    }
}
