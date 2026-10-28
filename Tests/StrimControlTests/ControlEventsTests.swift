import Foundation
import Testing
import StrimAPI
import StrimHarness
import StrimHost
import StrimJobs
@testable import StrimControl

@Suite("events (SSE)", .serialized)
struct ControlEventsTests {
    @Test("401 without token; framing is event/data/blank line with the {type,data} envelope")
    func framing() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        #expect(await r.call("GET", "/v1/strim/events", auth: false).status == 401)
        let sse = try #require(SSEClient(port: r.port, path: "/v1/strim/events", token: r.control))
        let text = await sse.read(timeout: 3) { $0.contains("\n\n") }
        #expect(sse.head.contains("200") && sse.head.lowercased().contains("content-type: text/event-stream"))
        let f = try #require(sse.frames(text).first)
        #expect(f.event == "status")
        #expect(text.hasPrefix("event: status\ndata: {") && text.contains("\n\n"))
        let ev = try JSONDecoder().decode(StrimEvent.self, from: Data(f.data.utf8))
        guard case .status(let st) = ev else { Issue.record("not a status"); return }
        #expect(st.state == .ready)
        let obj = try JSONSerialization.jsonObject(with: Data(f.data.utf8)) as! [String: Any]
        #expect(Set(obj.keys) == ["type", "data"] && obj["type"] as? String == "status")
    }

    @Test("status ticks repeat while connected, ping comments keep the stream alive")
    func ticks() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let sse = try #require(SSEClient(port: r.port, path: "/v1/strim/events", token: r.control))
        let text = await sse.read(timeout: 4) { $0.components(separatedBy: "event: status").count > 3 && $0.contains(": ping") }
        #expect(text.components(separatedBy: "event: status").count > 3)
        #expect(text.contains(": ping\n\n"))
    }

    @Test("job lifecycle shows up as job_event frames")
    func jobEvents() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        let sse = try #require(SSEClient(port: r.port, path: "/v1/strim/events", token: r.control))
        _ = await sse.read(timeout: 3) { $0.components(separatedBy: "event: status").count > 2 }   // poller has its baseline
        let id = try await r.jobs.submit(HarnessJobSpec(task: "t", cwd: "/tmp"), priority: .normal)
        let text = await sse.read(timeout: 5) { $0.contains(#""status":"done""#) && $0.contains("job_event") }
        let evs = try sse.frames(text).filter { $0.event == "job_event" }.map { try JSONDecoder().decode(StrimEvent.self, from: Data($0.data.utf8)) }
        let statuses = evs.compactMap { e -> JobStatusDTO? in if case .jobEvent(let j) = e, j.jobID == id { return j.status } else { return nil } }
        #expect(statuses.last == .done)
        #expect(statuses == statuses.enumerated().filter { $0.offset == 0 || statuses[$0.offset - 1] != $0.element }.map(\.element), "no duplicate consecutive statuses")
    }

    @Test("closing the connection drops the subscription")
    func unsubscribes() async throws {
        let r = try await Rig.make(); defer { r.stop() }
        var sse: SSEClient? = try #require(SSEClient(port: r.port, path: "/v1/strim/events", token: r.control))
        _ = await sse!.read(timeout: 2) { $0.contains("event: status") }
        #expect(r.plane.hub.subscriberCount == 1)
        sse = nil
        for _ in 0..<100 where r.plane.hub.subscriberCount > 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(r.plane.hub.subscriberCount == 0)
    }
}
