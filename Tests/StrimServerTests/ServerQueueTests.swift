import Foundation
import Testing
import StrimAdmission
import StrimEngine
import StrimHTTP
import StrimTemplate
@testable import StrimServer

// Lines tagged NEW-API use the knobs added by the fix; the pre-fix regression run deletes them.

private func until(_ cond: () async -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await cond()
}

/// Status and headers of one request, or (-1, [:]) after `seconds` without an answer.
private func fetch(_ r: URLRequest, within seconds: Double, session: URLSession) async -> (Int, [String: String]) {
    await withTaskGroup(of: (Int, [String: String]).self) { g in
        g.addTask {
            guard let (_, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse else { return (-1, [:]) }
            var f: [String: String] = [:]
            for (k, v) in h.allHeaderFields { f[String(describing: k).lowercased()] = String(describing: v) }
            return (h.statusCode, f)
        }
        g.addTask { try? await Task.sleep(for: .seconds(seconds)); return (-1, [:]) }
        let first = await g.next() ?? (-1, [:])
        g.cancelAll()
        return first
    }
}

private struct Rig {
    let engine = FakeEngine()
    let gate = PriorityGate(maxInflight: 1, maxBackground: 1)
    let server: StrimOpenAIServer
    let port: UInt16

    init(queue: Int = 64, timeoutS: Int = 600, apiClass: Priority = .interactive) async throws {
        engine.script([.event(.tokens([1], "ok")), .event(.finished(.stop, makeUsage(prompt: 1, cached: 0, completion: 1)))])
        var cfg = ServerConfig(modelId: "m", admission: gate)
        cfg.maxQueuedRequests = queue            // NEW-API
        cfg.queueTimeoutSeconds = timeoutS       // NEW-API
        cfg.apiPriority = apiClass               // NEW-API
        server = StrimOpenAIServer(engine: engine, config: cfg)
        port = try await server.start(port: 0)
    }

    func request(priority: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        r.httpMethod = "POST"
        r.httpBody = Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        if let priority { r.setValue(priority, forHTTPHeaderField: "x-strim-priority") }
        return r
    }
}

@Suite("StrimServer queue limits", .serialized) struct ServerQueueTests {
    @Test func fullQueueAnswers429WithRetryAfter() async throws {
        let rig = try await Rig(queue: 1); defer { rig.server.stop() }
        let hold = try await rig.gate.lease(.interactive)
        let s = URLSession(configuration: .ephemeral); defer { s.invalidateAndCancel() }
        let first = Task { await fetch(rig.request(), within: 20, session: s) }
        #expect(await until { await rig.gate.stats().waitingInteractive == 1 })
        let (status, headers) = await fetch(rig.request(), within: 5, session: s)
        #expect(status == 429)
        #expect(Int(headers["retry-after"] ?? "") != nil)
        await hold.release()
        #expect(await first.value.0 == 200)
    }

    @Test func queuedRequestTimesOutWith503() async throws {
        let rig = try await Rig(timeoutS: 1); defer { rig.server.stop() }
        let hold = try await rig.gate.lease(.interactive)
        let s = URLSession(configuration: .ephemeral); defer { s.invalidateAndCancel() }
        let (status, headers) = await fetch(rig.request(), within: 6, session: s)
        #expect(status == 503)
        #expect(headers["retry-after"] != nil)
        #expect(await rig.gate.stats().waitingInteractive == 0)
        await hold.release()
    }

    @Test func clientCannotRaiseItselfAboveTheTokenClass() async throws {
        let rig = try await Rig(apiClass: .background); defer { rig.server.stop() }
        let hold = try await rig.gate.lease(.interactive)
        let s = URLSession(configuration: .ephemeral); defer { s.invalidateAndCancel() }
        let req = Task { await fetch(rig.request(priority: "interactive"), within: 20, session: s) }
        #expect(await until { await rig.gate.stats().waitingBackground == 1 })
        #expect(await rig.gate.stats().waitingInteractive == 0)
        await hold.release()
        #expect(await req.value.0 == 200)
    }

    @Test func responseStoreIsBoundedByBytes() {
        func convo(_ n: Int) -> [OrderedJSON] {
            [.ordered([("role", .string("user")), ("content", .string(String(repeating: "a", count: n)))])]
        }
        let store = ResponseStore(capacity: 256, maxBytes: 10_000)   // NEW-API-INIT
        for i in 0..<20 { store.put("r\(i)", convo(2_000)) }
        #expect(store.byteCount <= 10_000)   // NEW-API
        #expect(store.get("r19") != nil)
        #expect(store.get("r0") == nil)
        store.put("huge", convo(50_000))
        #expect(store.get("huge") == nil)
        store.put("r19", convo(100))
        #expect(store.byteCount <= 10_000)   // NEW-API
    }
}
