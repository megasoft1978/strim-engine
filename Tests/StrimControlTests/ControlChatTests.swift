import Foundation
import Testing
import StrimAPI
import StrimEngine
import StrimHarness
import StrimHost
import StrimJobs
@testable import StrimControl

private func open(_ r: Rig, cwd: String = "/tmp", profile: String = "interactive") async -> HTTPReply {
    await r.call("POST", "/v1/strim/chat/open", body: #"{"cwd":"\#(cwd)","profile":"\#(profile)"}"#)
}
private func append(_ id: String, _ text: String = "hi") -> String { #"{"session_id":"\#(id)","text":"\#(text)"}"# }
private func sid(_ x: HTTPReply) throws -> String { try x.decode(ChatSession.self).sessionID }

@Suite("chat routes", .serialized)
struct ControlChatTests {
    @Test("open returns a session whose id is the job id; unknown profile 400; relative cwd 400")
    func openSession() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let x = await open(r)
        #expect(x.status == 200)
        let s = try x.decode(ChatSession.self)
        #expect(s.sessionID == s.jobID && s.cwd == "/tmp" && s.profile == "interactive")
        #expect(r.chat.opened.count == 1 && r.chat.opened[0].0 == s.sessionID && r.chat.opened[0].2 == .interactive)
        let job = try await r.call("GET", "/v1/strim/jobs/\(s.jobID)").decode(JobDetail.self)
        #expect(job.summary.source == .chat && job.summary.status == .running)
        let bad = await open(r, profile: "turbo")
        #expect(bad.status == 400 && bad.code == "bad_request")
        #expect(await open(r, cwd: "relative/dir").status == 400)
    }

    @Test("max sessions is 409 conflict")
    func maxSessions() async throws {
        let r = try await Rig.make(maxChat: 1); defer { r.stop() }
        #expect(await open(r).status == 200)
        let x = await open(r)
        #expect(x.status == 409 && x.code == "conflict" && x.error_message.contains("max_sessions"))
    }

    @Test("append default mode: 202, then chat_delta and harness_event frames arrive on /events")
    func appendViaEvents() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let id = try sid(await open(r))
        let sse = try #require(SSEClient(port: r.port, path: "/v1/strim/events", token: r.control))
        _ = await sse.read(timeout: 2) { $0.contains("event: status") }
        let a = await r.call("POST", "/v1/strim/chat/append", body: append(id))
        #expect(a.status == 202)
        let text = await sse.read(timeout: 5) { $0.contains(#""kind":"done""#) }
        let fr = sse.frames(text).filter { $0.event == "chat_delta" || $0.event == "harness_event" }
        let evs = try fr.map { try JSONDecoder().decode(StrimEvent.self, from: Data($0.data.utf8)) }
        let deltas = evs.compactMap { e -> ChatDelta? in if case .chatDelta(let d) = e { return d } else { return nil } }
        #expect(deltas.map(\.kind) == [.text, .toolCall, .toolResult, .text, .done])
        #expect(deltas.map(\.text) == ["hello ", "read_file a.txt", "read_file: ok", "world", "all done"])
        #expect(deltas.allSatisfy { $0.sessionID == id })
        let harness = evs.compactMap { e -> StrimAPI.HarnessEvent? in if case .harnessEvent(let h) = e { return h } else { return nil } }
        #expect(harness.map(\.kind) == ["turn", "usage"] && harness[1].text == "10/4/2" && harness[0].jobID == id)
    }

    @Test("append with Accept: text/event-stream streams the turn in the response")
    func appendDirect() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let id = try sid(await open(r))
        let sse = try #require(SSEClient(port: r.port, method: "POST", path: "/v1/strim/chat/append", token: r.control, body: append(id)))
        let text = await sse.read(timeout: 5) { $0.contains(#""kind":"done""#) }
        #expect(sse.head.contains("200") && sse.head.lowercased().contains("text/event-stream"))
        #expect(sse.frames(text).filter { $0.event == "chat_delta" }.count == 5)
    }

    @Test("a client that drops the direct stream cancels the turn")
    func disconnectCancels() async throws {
        let r = try await Rig.make(); r.chat.hang = true; defer { r.stop() }
        let id = try sid(await open(r))
        var sse: SSEClient? = try #require(SSEClient(port: r.port, method: "POST", path: "/v1/strim/chat/append", token: r.control, body: append(id)))
        _ = await sse!.read(timeout: 5) { $0.contains("world") }
        sse = nil   // closes the socket
        for _ in 0..<200 where r.chat.terminatedCount == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(r.chat.terminatedCount >= 1, "turn was not cancelled after the client left")
    }

    @Test("a 202 turn nobody listens to is cancelled after the grace period")
    func orphanTurn() async throws {
        let r = try await Rig.make(); r.chat.hang = true; defer { r.stop() }
        let id = try sid(await open(r))
        #expect(await r.call("POST", "/v1/strim/chat/append", body: append(id)).status == 202)
        for _ in 0..<200 where r.chat.cancelCount == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(r.chat.cancelCount == 1, "orphan turn was not cancelled")
    }

    @Test("a 202 turn with a listener connected is not cancelled by the watchdog")
    func listenedTurnSurvives() async throws {
        let r = try await Rig.make(); r.chat.hang = true; defer { r.stop() }
        let id = try sid(await open(r))
        let sse = try #require(SSEClient(port: r.port, path: "/v1/strim/events", token: r.control))
        _ = await sse.read(timeout: 2) { $0.contains("event: status") }
        #expect(await r.call("POST", "/v1/strim/chat/append", body: append(id)).status == 202)
        try await Task.sleep(for: .milliseconds(900))   // 3x the grace
        #expect(r.chat.cancelCount == 0)
    }

    @Test("append errors: no model 503, unknown session 404, empty text 400, turn in progress 409")
    func appendErrors() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let id = try sid(await open(r))
        let nf = await r.call("POST", "/v1/strim/chat/append", body: append("j_abcdefgh23"))
        #expect(nf.status == 404 && nf.code == "not_found")
        r.chat.hang = true
        let sse = try #require(SSEClient(port: r.port, path: "/v1/strim/events", token: r.control))
        _ = await sse.read(timeout: 2) { $0.contains("event: status") }
        #expect(await r.call("POST", "/v1/strim/chat/append", body: append(id)).status == 202)
        let busy = await r.call("POST", "/v1/strim/chat/append", body: append(id, "again"))
        #expect(busy.status == 409 && busy.error_message.contains("turn_in_progress"))
        // cancel the turn, the session stays open
        let c = await r.call("POST", "/v1/strim/chat/cancel", body: #"{"session_id":"\#(id)"}"#)
        #expect(c.status == 200 && r.chat.cancelCount == 1)
        try await r.slot.unload(force: true)
        let down = await r.call("POST", "/v1/strim/chat/append", body: append(id))
        #expect(down.status == 503 && down.code == "unavailable")
        _ = sse
    }

    @Test("close (DELETE and POST) ends the session; afterwards append is 409 session_closed")
    func closeSession() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let a = try sid(await open(r)), b = try sid(await open(r))
        let d = await r.call("DELETE", "/v1/strim/chat/\(a)")
        #expect(d.status == 200 && d.detail?.summary.status == .done)
        let p = await r.call("POST", "/v1/strim/chat/close", body: #"{"session_id":"\#(b)"}"#)
        #expect(p.status == 200 && r.chat.closed.sorted() == [a, b].sorted())
        let x = await r.call("POST", "/v1/strim/chat/append", body: append(a))
        #expect(x.status == 409 && x.error_message.contains("session_closed"))
        #expect(await r.call("DELETE", "/v1/strim/chat/j_abcdefgh23").status == 404)
        #expect(await r.call("DELETE", "/v1/strim/chat/bad").status == 400)
    }

    @Test("ChatEvent -> wire table")
    func mapping() {
        let id = "j_x"
        func one(_ e: ChatEvent) -> StrimEvent { ControlMapping.events(e, sessionID: id)[0] }
        #expect(one(.reasoningDelta("r")) == .chatDelta(ChatDelta(sessionID: id, kind: .reasoning, text: "r")))
        #expect(one(.toolCallFinished(name: "bash", summary: "boom", isError: true)) == .chatDelta(ChatDelta(sessionID: id, kind: .toolResult, text: "bash ERROR: boom")))
        #expect(one(.compaction("c")) == .harnessEvent(StrimAPI.HarnessEvent(jobID: id, kind: "compaction", text: "c")))
        #expect(one(.limit("steps")) == .harnessEvent(StrimAPI.HarnessEvent(jobID: id, kind: "limit", text: "steps")))
        let p = ChatPatch(userTurn: 1, patch: nil, patchPath: nil, filesChanged: [FileChange(path: "a", added: 1, removed: 0), FileChange(path: "b/c", added: 1, removed: 0)])
        #expect(one(.patchReady(p)) == .harnessEvent(StrimAPI.HarnessEvent(jobID: id, kind: "patch", text: "a,b/c")))
        #expect(ControlMapping.error(.turnInProgress).status == 409 && ControlMapping.error(.sessionNotFound("x")).status == 404)
        #expect(ControlMapping.error(.emptyText).status == 400 && ControlMapping.error(.openFailed("invalid cwd: x")).status == 400)
        #expect(ControlMapping.error(.openFailed("disk")).status == 500)
    }
}

extension HTTPReply { var error_message: String { (try? error().message) ?? "" } }

@Suite("chat open obeys the host policy", .serialized)
struct ControlChatPolicyTests {
    @Test("cwd outside allowedRoots is 403 and no session reaches the backend")
    func outsideRoots() async throws {
        let root = tmpDir("root").resolvingSymlinksInPath().path
        let r = try await Rig.make(policy: HostPolicy(maxAccess: .write, allowedRoots: [root])); defer { r.stop() }
        let x = await open(r, cwd: "/tmp")
        #expect(x.status == 403 && x.code == "forbidden")
        #expect(r.chat.opened.isEmpty)
        #expect(await open(r, cwd: root).status == 200)
        #expect(await open(r, cwd: root + "/../other").status == 403)
        #expect(r.chat.opened.count == 1)
    }

    @Test("read-only host opens chat read-only; the backend wrapper refuses write on it")
    func maxAccess() async throws {
        let r = try await Rig.make(policy: HostPolicy(maxAccess: .read, allowedRoots: [])); defer { r.stop() }
        #expect(await open(r).status == 200)
        #expect(r.chat.opened.count == 1)
        let wrapped = PolicyCheckedChatBackend(inner: r.chat, policy: HostPolicy(maxAccess: .read, allowedRoots: []))
        await #expect(throws: ChatForbidden.self) {
            try await wrapped.openSession(spec: HarnessJobSpec(task: "", cwd: "/tmp", access: .write), sessionID: "j_abcdefgh23", profile: .interactive)
        }
        #expect(r.chat.opened.count == 1)
    }
}
