import Foundation
import Testing
import StrimAdmission
import StrimEngine
import StrimTemplate
@testable import StrimHarness

private final class Hits: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func bump() -> Int { lock.withLock { n += 1; return n } }
    var value: Int { lock.withLock { n } }
}

/// Polls `cond` (no wall-clock assertions): true once it holds, false after ~10 s.
private func poll(_ cond: () async -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if await cond() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await cond()
}

private func call(_ name: String, _ args: [(String, OrderedJSON)] = []) -> [FakeEngine.Step] {
    var s: [FakeEngine.Step] = [.event(.toolCallBegin(name: name))]
    for (k, v) in args { s.append(.event(.toolCallArg(key: k, value: v))) }
    s.append(.event(.toolCallEnd))
    return s
}
private func turn(_ steps: [FakeEngine.Step]) -> [FakeEngine.Step] {
    steps + [.event(.finished(.stop, makeUsage(prompt: 100, completion: 10)))]
}
/// An unknown tool: the loop reports the error and continues, so the run takes another turn.
private func probeTurn(_ i: Int) -> [FakeEngine.Step] { turn(call("probe", [("i", .string("\(i)"))])) }
private func finishTurn() -> [FakeEngine.Step] {
    turn(call("finish", [("summary", .string("done")), ("status", .string("done"))]))
}

private let ws = Workspace(root: "/tmp/ws", base: "abc")
private func spec() -> HarnessJobSpec { HarnessJobSpec(task: "do it", cwd: "/tmp/p", context: "ctx", access: .write) }
private func agent(_ e: FakeEngine) -> AgentLoop { AgentLoop(engine: e, tools: [], systemPrompt: "SYS", date: "2026-10-26") }

@Suite struct AdmissionCheckpointTests {
    @Test func checkpointRunsBeforeEachTurnButTheFirst() async {
        let e = FakeEngine()
        e.script(probeTurn(1))
        e.script(probeTurn(2))
        e.script(finishTurn())
        let hits = Hits()
        let r = await AdmissionCheckpoint.$current.withValue({ _ = hits.bump() }) {
            await agent(e).run(spec: spec(), workspace: ws, onEvent: { _ in })
        }
        #expect(r.status == .done)
        #expect(e.snapshot { $0.generates.count } == 3)
        #expect(hits.value == 2)
    }

    @Test func singleTurnRunWaitsNever() async {
        let e = FakeEngine()
        e.script(finishTurn())
        let hits = Hits()
        let r = await AdmissionCheckpoint.$current.withValue({ _ = hits.bump() }) {
            await agent(e).run(spec: spec(), workspace: ws, onEvent: { _ in })
        }
        #expect(r.status == .done && hits.value == 0)
    }

    /// Delegated run holds the only slot; an interactive request queues; at the next turn boundary the run yields,
    /// the interactive request runs, and the delegated run resumes only after it releases.
    @Test func interactiveBurstPausesDelegatedRunBetweenTurns() async throws {
        let gate = PriorityGate(maxInflight: 1)
        let e = FakeEngine()
        e.script(probeTurn(1))
        e.script(finishTurn())
        let lease = try await gate.lease(.background)
        let interactive = Task { try await gate.lease(.interactive) }
        #expect(await poll { await gate.stats().waitingInteractive == 1 })

        let run = Task {
            await AdmissionCheckpoint.$current.withValue({ try await lease.checkpoint() }) {
                await agent(e).run(spec: spec(), workspace: ws, onEvent: { _ in })
            }
        }
        #expect(await poll {
            let s = await gate.stats()
            return s.activeInteractive == 1 && s.waitingBackground == 1
        })
        #expect(e.snapshot { $0.generates.count } == 1, "second turn must not start while interactive work runs")

        let held = try await interactive.value
        await held.release()
        let r = await run.value
        #expect(r.status == .done)
        #expect(e.snapshot { $0.generates.count } == 2)
        #expect(await gate.stats().backgroundYields == 1)
        await lease.release()
    }
}
