import Foundation
import Testing
import StrimEngine
import StrimTemplate
@testable import StrimHarness

private struct QwenRead: HarnessTool {
    let name = "read_file"
    var spec: ToolSpec { ToolSpec(name: name, description: "read", parameters: .ordered([])) }
    func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult { ToolResult(output: "contents") }
}

@Suite struct QwenKnobsTests {
    private let ws = Workspace(root: "/tmp/qk1/ws", base: "base")
    private let spec = HarnessJobSpec(task: "fix", cwd: "/tmp/qk1/ws", access: .write)

    private func loop(_ e: FakeEngine, _ k: HarnessKnobs) -> AgentLoop {
        AgentLoop(engine: e, tools: [QwenRead()], systemPrompt: "SYS", knobs: k)
    }
    private func read(prompt: Int, reasoning: String = "plan") -> [FakeEngine.Step] {
        [.event(.reasoning(reasoning)), .event(.toolCallBegin(name: "read_file")),
         .event(.toolCallArg(key: "path", value: .string("a.swift"))), .event(.toolCallEnd),
         .event(.finished(.stop, makeUsage(prompt: prompt, completion: 10)))]
    }
    private var finish: [FakeEngine.Step] {
        [.event(.toolCallBegin(name: "finish")), .event(.toolCallArg(key: "summary", value: .string("ok"))),
         .event(.toolCallEnd), .event(.finished(.stop, makeUsage(prompt: 100, completion: 10)))]
    }

    @Test func roundTripDefaultsAndValidation() throws {
        let legacy = try HarnessKnobs.decode(Data("{}".utf8))
        #expect(legacy == HarnessKnobs())
        let encoded = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        #expect(!encoded.contains("context") && !encoded.contains("sampling") && !encoded.contains("preserve_thinking"))
        for context in [HarnessKnobs.Context.standard, .long, .xlong] {
            for sampling in [HarnessKnobs.Sampling.greedy, .qwen] {
                for preserve in [HarnessKnobs.PreserveThinking.off, .on] {
                    let k = HarnessKnobs(context: context, sampling: sampling, preserve_thinking: preserve)
                    #expect(try HarnessKnobs.decode(JSONEncoder().encode(k)) == k)
                }
            }
        }
        for bad in [#"{"context":"huge"}"#, #"{"sampling":"hot"}"#, #"{"preserve_thinking":true}"#] {
            #expect(throws: (any Error).self) { try HarnessKnobs.decode(Data(bad.utf8)) }
        }
    }

    @Test func contextThresholdsAndSafeClamping() {
        for context in [HarnessKnobs.Context.standard, .long, .xlong] {
            let k = HarnessKnobs(context: context)
            #expect(k.compactionTokens == (context == .standard ? 28_000 : 56_000))
            #expect(loop(FakeEngine(), k).compactionThreshold == k.compactionTokens)
            #expect(HarnessKnobs(compactionThreshold: 99, context: context).compactionTokens == Int(Double(context.tokens) * 0.9))
            #expect(HarnessKnobs(compactionThreshold: -1, context: context).compactionTokens == Int(Double(context.tokens) * 0.4))
        }
        #expect(HarnessKnobs.Context.xlong.requestedTokens == 131_072)
        #expect(HarnessKnobs.Context.xlong.tokens == 65_536)
        let k = HarnessKnobs(context: .long)
        #expect(k.outputCap(thinking: false, promptTokens: 100, turnCap: 4096, background: true, environment: [:]) == 8192)
        #expect(k.outputCap(thinking: true, promptTokens: 100, turnCap: 4096, background: true, environment: [:]) == 16_384)
        #expect(k.outputCap(thinking: true, promptTokens: 60_000, turnCap: 4096, background: true, environment: [:]) == 5536)
        #expect(k.outputCap(thinking: true, promptTokens: 100, turnCap: 4096, background: true,
                            environment: ["STRIM_MAX_OUTPUT_TOKENS": "7000", "STRIM_BACKGROUND_MAX_TOKENS": "3000"]) == 3000)
        #expect(k.outputCap(thinking: true, promptTokens: 100, turnCap: 4096, background: false,
                            environment: ["STRIM_MAX_OUTPUT_TOKENS": "7000", "STRIM_BACKGROUND_MAX_TOKENS": "3000"]) == 7000)
    }

    @Test func compactionActuallyUsesEachContextThreshold() async {
        for context in [HarnessKnobs.Context.standard, .long, .xlong] {
            for prompt in [30_000, 57_000] {
                let e = FakeEngine(); e.script(read(prompt: prompt)); e.script(finish)
                let r = await loop(e, HarnessKnobs(context: context)).run(spec: spec, workspace: ws, onEvent: { _ in })
                #expect(r.status == .done)
                #expect(e.snapshot { $0.opened.count } == (prompt > context.compactionTokens ? 2 : 1))
            }
        }
    }

    @Test func qwenSamplingChangesWithTheTurnAndHonoursSeed() async {
        let e = FakeEngine(); e.script(read(prompt: 100)); e.script(finish)
        let k = HarnessKnobs(thinking: .firstPlanningTurn, seed: 42, context: .long, sampling: .qwen)
        _ = await loop(e, k).run(spec: spec, workspace: ws, onEvent: { _ in })
        let p = e.snapshot { $0.generates.map(\.params) }
        #expect(p.count == 2)
        #expect(p[0].temperature == 1 && p[0].topP == 0.95 && p[0].topK == 20 && p[0].seed == 43 && p[0].maxTokens == 16_384)
        #expect(p[1].temperature == 0.7 && p[1].topP == 0.8 && p[1].topK == 20 && p[1].seed == 44 && p[1].maxTokens == 8192)
        let greedy = HarnessKnobs(temperature: 0.6, sampling: .greedy)
        #expect(greedy.samplingValues(thinking: true).temperature == 0 && greedy.seed(forGeneration: 1) == nil)
        #expect(HarnessKnobs(temperature: 0.6).samplingValues(thinking: false).temperature == 0.6)
        #expect(HarnessKnobs(seed: UInt64.max, sampling: .qwen).seed(forGeneration: 2) == 1)
    }

    @Test func preservedReasoningSurvivesReplayAndRendersAcrossUserTurns() async throws {
        let e = FakeEngine(); e.script(read(prompt: 100, reasoning: "retained-plan")); e.script(finish)
        let k = HarnessKnobs(thinking: .firstPlanningTurn, preserve_thinking: .on)
        _ = await loop(e, k).run(spec: spec, workspace: ws, onEvent: { _ in })
        #expect(e.snapshot { $0.opened.allSatisfy { $0.1.preserveThinking == true } })
        let history = try #require(e.snapshot { f in f.appends.compactMap { (_, input) -> [Message]? in if case let .history(m) = input { return m }; return nil }.first })
        #expect(history.first { $0.role == .assistant }?.reasoningContent == "retained-plan")
        let messages = history + [.user("continue")]
        let rendered = try ChatTemplate.renderSegments(messages: messages, tools: [QwenRead().spec],
                                                       enableThinking: true, reasoningEffort: "xhigh", preserveThinking: true).map(\.text).joined()
        #expect(rendered.contains("<think>\nretained-plan\n</think>"))
        let dropped = try ChatTemplate.renderSegments(messages: messages, preserveThinking: false).map(\.text).joined()
        #expect(!dropped.contains("retained-plan"))
    }

    @Test func preservedReasoningSurvivesAnActualNextUserTurn() async throws {
        let e = FakeEngine()
        e.script([.event(.reasoning("prior-user-plan")), .event(.tokens([1], "answer one")),
                  .event(.finished(.stop, makeUsage(prompt: 100, completion: 10)))])
        e.script([.event(.tokens([2], "answer two")), .event(.finished(.stop, makeUsage(prompt: 200, completion: 10)))])
        let l = loop(e, HarnessKnobs(thinking: .firstPlanningTurn, preserve_thinking: .on))
        let conversation = l.openConversation(spec: spec, workspace: ws)
        _ = await l.runUserTurn(conversation, text: "first", onEvent: { _ in })
        _ = await l.runUserTurn(conversation, text: "next", onEvent: { _ in })
        let history = try #require(e.snapshot { f in f.appends.compactMap { (_, input) -> [Message]? in
            if case let .history(m) = input { return m }; return nil
        }.first })
        #expect(history.map(\.role) == [.system, .user, .assistant, .user])
        let rendered = try ChatTemplate.renderSegments(messages: history, preserveThinking: true).map(\.text).joined()
        #expect(rendered.contains("prior-user-plan") && rendered.contains("answer one"))
        await l.closeConversation(conversation)
    }

    @Test func reasoningCountsTowardCompactionWithoutUsage() async {
        let e = FakeEngine()
        e.script(Array(read(prompt: 0, reasoning: String(repeating: "r", count: 230_000)).dropLast()))
        e.script(finish)
        _ = await loop(e, HarnessKnobs(thinking: .allTurns, context: .long, preserve_thinking: .on))
            .run(spec: spec, workspace: ws, onEvent: { _ in })
        #expect(e.snapshot { $0.opened.count } == 2)
    }

    @Test func largerTurnCapStillRespectsJobTokenBudget() async {
        var limits = HarnessLimits(); limits.maxGeneratedTokens = 500
        let job = HarnessJobSpec(task: "fix", cwd: ws.root, access: .write, limits: limits)
        let e = FakeEngine(); e.script(finish)
        _ = await loop(e, HarnessKnobs(thinking: .allTurns, context: .long)).run(spec: job, workspace: ws, onEvent: { _ in })
        #expect(e.snapshot { $0.generates.first?.params.maxTokens } == 500)
    }

    @Test func compactionDropsReasoningBeforeRebuildingProgress() async {
        let e = FakeEngine(); e.script(read(prompt: 57_000, reasoning: String(repeating: "old reasoning ", count: 1000))); e.script(finish)
        let k = HarnessKnobs(thinking: .allTurns, context: .long, preserve_thinking: .on)
        _ = await loop(e, k).run(spec: spec, workspace: ws, onEvent: { _ in })
        let messages = e.snapshot { f in f.appends.flatMap { (_, input) -> [Message] in if case let .messages(m) = input { return m }; return [] } }
        #expect(e.snapshot { $0.opened.count } == 2)
        #expect(messages.allSatisfy { $0.reasoningContent == nil })
        #expect(messages.contains { if case let .text(t) = $0.content { t.contains("Progress so far") && !t.contains("old reasoning") } else { false } })
    }
}
