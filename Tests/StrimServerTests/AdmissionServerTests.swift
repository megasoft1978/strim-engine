import Foundation
import Testing
import StrimAdmission
import StrimEngine
@testable import StrimServer

/// HTTP-layer admission. Real sockets are involved, so the wait helper polls with a short sleep (the gate itself
/// is exercised deterministically in StrimAdmissionTests).
private func until(_ cond: () async -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await cond()
}

private let okScript: [FakeEngine.Step] = [.event(.tokens([1], "ok")), .event(.finished(.stop, makeUsage(prompt: 1, cached: 0, completion: 1)))]

private struct Rig {
    let engine: FakeEngine
    let gate: PriorityGate
    let server: StrimOpenAIServer
    let port: UInt16

    init(maxInflight: Int = 1, script: [FakeEngine.Step] = okScript) async throws {
        engine = FakeEngine()
        engine.script(script)
        gate = PriorityGate(maxInflight: maxInflight, maxBackground: 1)
        server = StrimOpenAIServer(engine: engine, config: ServerConfig(modelId: "m", admission: gate))
        port = try await server.start(port: 0)
    }

    func post(_ path: String = "/v1/chat/completions", body: String? = nil, priority: String? = nil,
              session: URLSession) -> Task<Int, Never> {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        r.httpMethod = "POST"
        r.httpBody = Data((body ?? #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#).utf8)
        if let priority { r.setValue(priority, forHTTPHeaderField: "x-strim-priority") }
        return Task { ((try? await session.data(for: r))?.1 as? HTTPURLResponse)?.statusCode ?? -1 }
    }
}

@Suite("StrimServer admission", .serialized) struct AdmissionServerTests {
    // Port of bench/test_priority_ordering.py: the slot is taken BEFORE the engine is touched.
    @Test func slotTakenBeforeEngineCall() async throws {
        let rig = try await Rig(); defer { rig.server.stop() }
        let hold = try await rig.gate.lease(.interactive)
        let s = URLSession(configuration: .ephemeral); defer { s.invalidateAndCancel() }
        let req = rig.post(priority: "background", session: s)
        #expect(await until { await rig.gate.stats().waitingBackground == 1 })
        #expect(rig.engine.snapshot { $0.opened.count + $0.appends.count + $0.generates.count } == 0)
        await hold.release()
        #expect(await req.value == 200)
        #expect(rig.engine.snapshot { $0.generates.count } == 1)
        #expect(await until { await rig.gate.stats().activeBackground == 0 })
        #expect(await rig.gate.stats().admittedBackground == 1)
    }

    @Test func interactiveRequestOutranksQueuedBackground() async throws {
        let rig = try await Rig(); defer { rig.server.stop() }
        let hold = try await rig.gate.lease(.interactive)
        let s = URLSession(configuration: .ephemeral); defer { s.invalidateAndCancel() }
        let bg = rig.post(priority: "background", session: s)
        #expect(await until { await rig.gate.stats().waitingBackground == 1 })
        let fg = rig.post(session: s)                             // default priority: interactive
        #expect(await until { await rig.gate.stats().waitingInteractive == 1 })
        await hold.release()
        let (a, b) = (await fg.value, await bg.value)
        #expect(a == 200 && b == 200)
        let st = await rig.gate.stats()
        #expect(st.admittedInteractive == 2 && st.admittedBackground == 1)   // hold + fg, then bg
    }

    @Test func disconnectWhileQueuedDropsWaiter() async throws {
        let rig = try await Rig(); defer { rig.server.stop() }
        let hold = try await rig.gate.lease(.interactive)
        let s = URLSession(configuration: .ephemeral)
        let req = rig.post(session: s)
        #expect(await until { await rig.gate.stats().waitingInteractive == 1 })
        s.invalidateAndCancel()
        _ = await req.value
        #expect(await until { await rig.gate.stats().waitingInteractive == 0 })
        #expect(rig.engine.snapshot { $0.generates.count } == 0)
        await hold.release()
    }

    @Test func slotReleasedAfterEngineError() async throws {
        let rig = try await Rig(script: [.fail(.mlx("boom"))]); defer { rig.server.stop() }
        let s = URLSession(configuration: .ephemeral); defer { s.invalidateAndCancel() }
        _ = await rig.post(session: s).value
        #expect(await until { await rig.gate.stats().activeInteractive == 0 })
    }

    @Test func anthropicAdapterAlsoAdmits() async throws {
        let rig = try await Rig(); defer { rig.server.stop() }
        let hold = try await rig.gate.lease(.interactive)
        let s = URLSession(configuration: .ephemeral); defer { s.invalidateAndCancel() }
        let req = rig.post("/v1/messages", body: #"{"model":"m","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}"#,
                           priority: "background", session: s)
        #expect(await until { await rig.gate.stats().waitingBackground == 1 })
        #expect(rig.engine.snapshot { $0.opened.count } == 0)
        await hold.release()
        #expect(await req.value == 200)
    }

    @Test func noAdmissionConfiguredBehavesAsBefore() async throws {
        let engine = FakeEngine()
        engine.script(okScript)
        let server = StrimOpenAIServer(engine: engine, config: ServerConfig(modelId: "m"))
        let port = try await server.start(port: 0); defer { server.stop() }
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        r.httpMethod = "POST"
        r.httpBody = Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let (_, resp) = try await URLSession(configuration: .ephemeral).data(for: r)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    }
}
