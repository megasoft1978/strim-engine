import Foundation
import Testing
import StrimAPI
import StrimHarness
import StrimHost
import StrimJobs
@testable import StrimControl

private func approveBody(_ id: String, sha: String) -> String { #"{"job_id":"\#(id)","action":"apply","patch_sha256":"\#(sha)"}"# }

@Suite("control hardening", .serialized)
struct ControlHardeningTests {
    // MARK: model paths

    @Test("load only accepts models under the allowed roots (canonical, no traversal, no symlink escape)")
    func modelRoots() async throws {
        let root = tmpDir("models").resolvingSymlinksInPath().path
        let outside = tmpDir("outside").resolvingSymlinksInPath().path
        try FileManager.default.createSymbolicLink(atPath: root + "/escape", withDestinationPath: outside)
        try FileManager.default.createDirectory(atPath: root + "/ok", withIntermediateDirectories: true)
        var o = StrimControlPlane.Options(); o.modelRoots = [root]
        let r = try await Rig.make(load: false, options: o); defer { r.stop() }
        func load(_ m: String, mtp: String? = nil) async -> HTTPReply {
            await r.call("POST", "/v1/strim/load", body: mtp.map { #"{"model":"\#(m)","mtp":"\#($0)"}"# } ?? #"{"model":"\#(m)"}"#)
        }
        #expect(await load("/etc/passwd").status == 403)
        #expect(await load(root + "/../etc").status == 403)
        #expect(await load(root + "-evil/x").status == 403)
        #expect(await load(root + "/escape/model").status == 403)
        #expect(await load("relative/model").status == 400)
        #expect(await load(root + "/ok", mtp: "/etc/head").status == 403)
        #expect(await load(root + "/ok", mtp: root + "/ok").status == 202)
        await r.slot.waitForLoad()
    }

    @Test("no model roots configured: API loading is refused")
    func noRoots() async throws {
        var o = StrimControlPlane.Options(); o.modelRoots = []
        let r = try await Rig.make(load: false, options: o); defer { r.stop() }
        let x = await r.call("POST", "/v1/strim/load", body: #"{"model":"/models/a"}"#)
        #expect(x.status == 403 && x.code == "forbidden")
    }

    // MARK: apply uses the job's own access

    @Test("a read-only host does not apply an older write job")
    func applyHonoursAccess() async throws {
        let (repo, patch) = try makeRepo()
        let r = try await Rig.make(patch: patch, policy: HostPolicy(maxAccess: .read, allowedRoots: [])); defer { r.stop() }
        let id = try await runJob(r, cwd: repo)   // recorded access: write
        let x = await r.call("POST", "/v1/strim/jobs/approve", body: approveBody(id, sha: StrimControlPlane.sha256(Data(patch.utf8))))
        #expect(x.status == 403 && x.code == "forbidden", "\(x.body)")
        #expect((try? String(contentsOfFile: repo + "/a.txt", encoding: .utf8)) == "one\n")
    }

    // MARK: SSE cap, shared poller, filters

    @Test("event streams are capped (429) and the cap frees up when one closes")
    func subscriberCap() async throws {
        var o = StrimControlPlane.Options(); o.maxEventSubscribers = 2; o.jobPollInterval = .milliseconds(30)
        let r = try await Rig.make(options: o); defer { r.stop() }
        var a: SSEClient? = SSEClient(port: r.port, path: "/v1/strim/events", token: r.control)
        let b = SSEClient(port: r.port, path: "/v1/strim/events", token: r.control)
        _ = await a!.read(timeout: 2) { $0.contains("event: status") }
        _ = await b!.read(timeout: 2) { $0.contains("event: status") }
        let third = await r.call("GET", "/v1/strim/events")
        #expect(third.status == 429 && third.code == "too_many_subscribers")
        a = nil
        for _ in 0..<100 where r.plane.hub.subscriberCount > 1 { try await Task.sleep(for: .milliseconds(50)) }
        // the freed slot is usable
        let c = try #require(SSEClient(port: r.port, path: "/v1/strim/events", token: r.control))
        let text = await c.read(timeout: 3) { $0.contains("event: status") }
        #expect(text.contains("event: status"))
        _ = b
    }

    @Test("one shared poller serves every subscriber and stops with the last one")
    func sharedPoller() async throws {
        var o = StrimControlPlane.Options(); o.jobPollInterval = .milliseconds(30); o.statusInterval = .milliseconds(60)
        let r = try await Rig.make(options: o); defer { r.stop() }
        var clients: [SSEClient?] = (0..<3).map { _ in SSEClient(port: r.port, path: "/v1/strim/events", token: r.control) }
        for c in clients { _ = await c!.read(timeout: 2) { $0.components(separatedBy: "event: status").count > 2 } }
        #expect(r.plane.pollerLock.withLock { $0 != nil })
        #expect(r.plane.hub.subscriberCount == 3)
        clients = []
        for _ in 0..<100 where r.plane.pollerLock.withLock({ $0 != nil }) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(r.plane.pollerLock.withLock { $0 == nil }, "poller must stop when nobody listens")
        // and it restarts for the next subscriber
        let again = try #require(SSEClient(port: r.port, path: "/v1/strim/events", token: r.control))
        _ = await again.read(timeout: 3) { $0.components(separatedBy: "event: status").count > 2 }
        #expect(r.plane.pollerLock.withLock { $0 != nil })
    }

    @Test("a session_id filter receives only that session's chat output; malformed filter is 400")
    func sessionFilter() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        func open() async throws -> String {
            try await r.call("POST", "/v1/strim/chat/open", body: #"{"cwd":"/tmp","profile":"interactive"}"#).decode(ChatSession.self).sessionID
        }
        let a = try await open(), b = try await open()
        #expect(await r.call("GET", "/v1/strim/events?session_id=nope").status == 400)
        let onlyA = try #require(SSEClient(port: r.port, path: "/v1/strim/events?session_id=\(a)", token: r.control))
        let all = try #require(SSEClient(port: r.port, path: "/v1/strim/events", token: r.control))
        _ = await onlyA.read(timeout: 2) { $0.contains("event: status") }
        _ = await all.read(timeout: 2) { $0.contains("event: status") }
        #expect(await r.call("POST", "/v1/strim/chat/append", body: #"{"session_id":"\#(b)","text":"hi"}"#).status == 202)
        let seenAll = await all.read(timeout: 5) { $0.contains(#""kind":"done""#) }
        #expect(seenAll.contains("chat_delta") && seenAll.contains(b))
        try await Task.sleep(for: .milliseconds(200))
        let seenA = await onlyA.read(timeout: 0.5) { _ in false }
        #expect(!seenA.contains("chat_delta") && !seenA.contains(b), "another session's output leaked into the filtered stream")
    }

    // MARK: live diff cache

    @Test("detail reads of an open chat reuse a cached live diff; approve always reads fresh")
    func patchCache() async throws {
        let calls = Locked<Int>(0)
        let patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\n one\n+two\n"
        let r = try await Rig.make(currentPatch: { _ in calls.withLock { $0 += 1 }; return patch }); defer { r.stop() }
        let id = try await r.call("POST", "/v1/strim/chat/open", body: #"{"cwd":"/tmp","profile":"interactive"}"#).decode(ChatSession.self).sessionID
        await r.jobs.flush()
        for _ in 0..<5 { _ = await r.call("GET", "/v1/strim/jobs/\(id)") }
        #expect(calls.withLock { $0 } == 1)
        _ = await r.call("POST", "/v1/strim/jobs/approve", body: approveBody(id, sha: StrimControlPlane.sha256(Data(patch.utf8))))
        #expect(calls.withLock { $0 } == 2, "approve must not use the cache")
    }
}
