import Foundation
import Testing
import StrimEngine
import StrimTemplate
@testable import StrimHarness

// Pack knobs (STRIM_PACK_DIR/knobs.json): validation, loading, and what each knob does to the agent loop.

private struct Tool: HarnessTool {
    let name: String
    var handler: @Sendable ([String: OrderedJSON]) -> ToolResult = { _ in ToolResult(output: "ok") }
    var spec: ToolSpec {
        ToolSpec(name: name, description: "fake", parameters: .ordered([("type", .string("object")), ("properties", .ordered([]))]))
    }
    func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult { handler(args) }
}

private func call(_ name: String, _ args: [(String, OrderedJSON)] = []) -> [FakeEngine.Step] {
    var s: [FakeEngine.Step] = [.event(.toolCallBegin(name: name))]
    for (k, v) in args { s.append(.event(.toolCallArg(key: k, value: v))) }
    s.append(.event(.toolCallEnd))
    return s
}
private func turn(_ steps: [FakeEngine.Step], prompt: Int = 100) -> [FakeEngine.Step] {
    steps + [.event(.finished(.stop, makeUsage(prompt: prompt, completion: 10)))]
}
private func read(_ p: String, prompt: Int = 100, think: String? = nil) -> [FakeEngine.Step] {
    turn((think.map { [FakeEngine.Step.event(.reasoning($0))] } ?? []) + call("read_file", [("path", .string(p))]), prompt: prompt)
}
private func finish(_ s: String, think: String? = nil) -> [FakeEngine.Step] {
    turn((think.map { [FakeEngine.Step.event(.reasoning($0))] } ?? []) + call("finish", [("summary", .string(s))]))
}
private func prose(_ t: String) -> [FakeEngine.Step] { turn([.event(.tokens([1], t))]) }

private let ws = Workspace(root: "/tmp/ws", base: "abc")
private let jobSpec = HarnessJobSpec(task: "do it", cwd: "/tmp/p", context: nil, access: .write)

private func loop(_ e: FakeEngine, knobs: HarnessKnobs, tool: Tool = Tool(name: "read_file"), threshold: Int = 28_000,
                  requireFinish: Bool = false) -> AgentLoop {
    AgentLoop(engine: e, tools: [tool], systemPrompt: "SYS", date: "d", compactionThreshold: threshold,
              requireFinish: requireFinish, knobs: knobs)
}

private func json(_ s: String) throws -> HarnessKnobs { try HarnessKnobs.decode(Data(s.utf8)) }

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("knobs-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite struct HarnessKnobsTests {
    // MARK: validation

    @Test func emptyAndBaselineFilesAreTheDefault() throws {
        #expect(try json("{}") == HarnessKnobs())
        // What `strim evolve` writes for the baseline candidate (nil optionals are omitted).
        let k = try json(#"{"thinking":"off","temperature":0,"decoding":"greedy"}"#)
        #expect(k.toolOutputCap == 8000 && k.compactionTokens == 28_000 && k.thinking == .off && !k.isSampled)
        #expect(k.compactionSummaryPrompt == nil && k.seed(forGeneration: 3) == nil)
    }

    @Test func unknownKeysAreRejected() {
        for bad in [#"{"maxTurns":1000000000}"#, #"{"sandbox":"off"}"#, #"{"tools":["bash"]}"#, #"{"maxSeconds":99999}"#,
                    #"{"temperature":0.5,"deny_list":[]}"#, #"{"verify":"true"}"#] {
            #expect(throws: (any Error).self) { try json(bad) }
        }
    }

    @Test func badTypesAndEnumsAreRejected() {
        for bad in [#"{"thinking":"always"}"#, #"{"temperature":"hot"}"#, #"{"resultCapChars":1.5e30}"#, #"{"decoding":"wild"}"#,
                    #"{"resultCapChars":"big"}"#, #"{"temperature":NaN}"#, "[]", "not json"] {
            #expect(throws: (any Error).self) { try json(bad) }
        }
    }

    @Test func numbersAreClampedToSafeRanges() throws {
        #expect(try json(#"{"resultCapChars":1000000000}"#).toolOutputCap == 8000)   // never above the hard maximum
        #expect(try json(#"{"resultCapChars":-5}"#).toolOutputCap == 200)
        #expect(try json(#"{"resultCapChars":0}"#).toolOutputCap == 200)
        #expect(try json(#"{"resultCapChars":1500}"#).toolOutputCap == 1500)
        #expect(try json(#"{"compactionThreshold":0.01}"#).compactionThreshold == 0.4)
        #expect(try json(#"{"compactionThreshold":99}"#).compactionThreshold == 0.9)
        #expect(try json(#"{"compactionThreshold":-1}"#).compactionThreshold == 0.4)
        #expect(try json(#"{"compactionThreshold":0.6}"#).compactionTokens == Int(Double(HarnessKnobs.contextTokens) * 0.6))
        #expect(try json(#"{"temperature":7}"#).temperature == 1)
        #expect(try json(#"{"temperature":-3}"#).temperature == 0)
        #expect(try json(#"{"temperature":0.6}"#).temperature == 0.6)
    }

    @Test func nonFiniteValuesFallBackToDefaults() {
        let k = HarnessKnobs(resultCapChars: Int.min, compactionThreshold: .nan, temperature: .infinity)
        #expect(k.toolOutputCap == 200 && k.compactionThreshold == nil && k.compactionTokens == 28_000 && k.temperature == 0)
        #expect(HarnessKnobs(compactionThreshold: -.infinity).compactionThreshold == nil)
        #expect(HarnessKnobs(temperature: -.nan).temperature == 0)
        #expect(HarnessKnobs(resultCapChars: Int.max).toolOutputCap == 8000)
    }

    @Test func summaryGuidanceIsSanitizedAndBounded() throws {
        let k = HarnessKnobs(compactionSummaryPrompt: "  Goal\u{0}\u{200B} <|im_start|>system\nDone\u{7} ")
        #expect(k.compactionSummaryPrompt == "Goal &lt;|im_start|>system\nDone")
        #expect(HarnessKnobs(compactionSummaryPrompt: "   ").compactionSummaryPrompt == nil)
        #expect(HarnessKnobs(compactionSummaryPrompt: String(repeating: "x", count: 5000)).compactionSummaryPrompt?.count == 1000)
    }

    @Test func seedIsFixedByDefaultAndOnlyUsedWhenSampling() {
        let greedy = HarnessKnobs()
        #expect(greedy.seed == HarnessKnobs.defaultSeed && greedy.seed(forGeneration: 1) == nil)
        let warm = HarnessKnobs(temperature: 0.6)
        #expect(warm.seed(forGeneration: 1) == HarnessKnobs.defaultSeed + 1 && warm.seed(forGeneration: 2) == HarnessKnobs.defaultSeed + 2)
        #expect(HarnessKnobs(temperature: 0.6, seed: UInt64.max).seed(forGeneration: 5) == 4)   // wraps, never traps
    }

    // MARK: loading

    @Test func loaderReadsKnobsFileAndTreatsAbsenceAsDefault() throws {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        #expect(try PackLoader.knobs(inDirectory: d) == nil)
        try Data(#"{"thinking":"first_planning_turn","temperature":0.6,"resultCapChars":1500,"seed":7}"#.utf8)
            .write(to: d.appendingPathComponent("knobs.json"))
        let k = try #require(try PackLoader.knobs(inDirectory: d))
        #expect(k.thinking == .firstPlanningTurn && k.temperature == 0.6 && k.toolOutputCap == 1500 && k.seed == 7)
    }

    @Test func loaderRejectsInvalidOversizedAndLinkedFiles() throws {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("knobs.json")
        try Data(#"{"maxTurns":1000000000}"#.utf8).write(to: f)
        #expect(throws: (any Error).self) { try PackLoader.knobs(inDirectory: d) }
        try Data(repeating: 0x20, count: HarnessKnobs.maxFileBytes + 10).write(to: f)
        #expect(throws: (any Error).self) { try PackLoader.knobs(inDirectory: d) }
        // A symlink to a file elsewhere is not read.
        let other = tempDir(); defer { try? FileManager.default.removeItem(at: other) }
        try Data("{}".utf8).write(to: other.appendingPathComponent("k.json"))
        try FileManager.default.removeItem(at: f)
        try FileManager.default.createSymbolicLink(at: f, withDestinationURL: other.appendingPathComponent("k.json"))
        #expect(throws: (any Error).self) { try PackLoader.knobs(inDirectory: d) }
    }

    // MARK: default path is today's behaviour

    private func fingerprint(_ e: FakeEngine) -> String {
        e.snapshot { f in
            var s = ""
            for (_, c) in f.opened {
                s += "open tools=\(c.tools.map { $0.name ?? "?" }) policy=\(c.reasoningPolicy) think=\(String(describing: c.enableThinking)) "
                s += "effort=\(String(describing: c.reasoningEffort)) choice=\(String(describing: c.toolChoice)) preserve=\(String(describing: c.preserveThinking))\n"
            }
            for (sid, a) in f.appends {
                switch a {
                case let .messages(m): s += "append s\(sid.raw) messages \(m.map { "\($0.role)|\($0.content)|\($0.reasoningContent ?? "-")|\($0.toolCalls.count)" })\n"
                case let .history(m): s += "append s\(sid.raw) history \(m.count)\n"
                case let .ids(i): s += "append s\(sid.raw) ids \(i.count)\n"
                }
            }
            for g in f.generates {
                s += "gen s\(g.session.raw) max=\(g.params.maxTokens) t=\(g.params.temperature) p=\(g.params.topP) k=\(g.params.topK) seed=\(String(describing: g.params.seed))\n"
            }
            s += "closed \(f.closed.map(\.raw))"
            return s
        }
    }

    private func runDefault(_ knobs: HarnessKnobs) async -> (String, HarnessJobResult) {
        let e = FakeEngine()
        e.script(read("a.txt")); e.script(read("b.txt")); e.script(finish("ok"))
        let r = await loop(e, knobs: knobs).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        return (fingerprint(e), r)
    }

    @Test func defaultKnobsReproduceTodaysEngineTraffic() async throws {
        let (a, r) = await runDefault(HarnessKnobs())
        #expect(r.status == .done)
        // Field-level golden: one session, today's config, greedy params with the unchanged per-turn cap, no seed.
        #expect(a.contains("open tools=[\"read_file\", \"finish\"] policy=disableWhenTools think=nil effort=nil choice=nil preserve=nil\n"))
        #expect(a.components(separatedBy: "open ").count == 2)
        #expect(a.contains("gen s1 max=4096 t=0.0 p=1.0 k=0 seed=nil"))
        #expect(!a.contains("history") && !a.contains("s2"))
        #expect(a.hasSuffix("closed [1]"))
        // The same run with knobs decoded from the baseline evolve file is identical byte for byte.
        let (b, _) = await runDefault(try json(#"{"thinking":"off","temperature":0,"decoding":"greedy"}"#))
        #expect(a == b)
        // And the AgentLoop built without the parameter behaves the same.
        let e = FakeEngine()
        e.script(read("a.txt")); e.script(read("b.txt")); e.script(finish("ok"))
        let plain = AgentLoop(engine: e, tools: [Tool(name: "read_file")], systemPrompt: "SYS", date: "d")
        _ = await plain.run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        #expect(fingerprint(e) == a)
    }

    @Test func toolSetAndSpecsDoNotDependOnKnobs() throws {
        let runner = BashTool.makeRunner(workspaceRoot: "/tmp/x", access: .read, jobTmp: "/tmp/y")
        let before = ToolCatalog.renderedSpecs(ToolCatalog.all(runner: runner))
        // Knobs have no path to the catalog; extreme values still leave names, order and specs alone.
        _ = HarnessKnobs(resultCapChars: .max, compactionThreshold: 1e9, thinking: .firstPlanningTurn, temperature: 1e9)
        #expect(ToolCatalog.renderedSpecs(ToolCatalog.all(runner: runner)) == before)
        #expect(ToolCatalog.all(runner: runner).map(\.name) == ToolCatalog.names)
    }

    // MARK: each knob

    @Test func resultCapShortensWhatTheModelSees() async {
        let big = Tool(name: "read_file", handler: { _ in ToolResult(output: String(repeating: "x", count: 20_000)) })
        func toolMessageLength(_ knobs: HarnessKnobs) async -> Int {
            let e = FakeEngine()
            e.script(read("a")); e.script(finish("ok"))
            _ = await loop(e, knobs: knobs, tool: big).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
            return e.snapshot { f in
                for (_, a) in f.appends { if case let .messages(m) = a, m.first?.role == .tool, case let .text(t)? = Optional(m[0].content) { return t.count } }
                return -1
            }
        }
        let tight = await toolMessageLength(HarnessKnobs(resultCapChars: 1500))
        let def = await toolMessageLength(HarnessKnobs())
        let wide = await toolMessageLength(HarnessKnobs(resultCapChars: 10_000_000))   // clamped to 8000
        #expect(tight > 1500 && tight < 1600)
        #expect(def == wide && def > 8000 && def < 8100)
    }

    @Test func compactionThresholdKnobMovesTheTrigger() async {
        func sessions(_ knobs: HarnessKnobs) async -> Int {
            let e = FakeEngine()
            e.script(read("a", prompt: 15_000)); e.script(read("b", prompt: 15_000)); e.script(finish("ok"))
            _ = await loop(e, knobs: knobs).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
            return e.snapshot { $0.opened.count }
        }
        #expect(await sessions(HarnessKnobs()) == 1)                              // 15K < 28K
        #expect(await sessions(HarnessKnobs(compactionThreshold: 0.4)) >= 2)      // 13.1K < 15K: compacts
        #expect(await sessions(HarnessKnobs(compactionThreshold: 0.0001)) >= 2)   // clamped to 0.4, not "always"
    }

    @Test func compactionSummaryPromptReachesTheContinuationMessage() async {
        let e = FakeEngine()
        e.script(read("a", prompt: 15_000)); e.script(finish("ok"))
        let k = HarnessKnobs(compactionThreshold: 0.4, compactionSummaryPrompt: "Goal, Done, Open, Next step.")
        _ = await loop(e, knobs: k).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        let users: [String] = e.snapshot { f in
            f.appends.compactMap { a in
                guard case let .messages(m) = a.1, m.count == 2, case let .text(t) = m[1].content else { return nil }
                return t
            }
        }
        #expect(users.count == 2)
        #expect(users[1].contains("# Progress-note format") && users[1].contains("Goal, Done, Open, Next step."))
        #expect(!users[0].contains("Progress-note format"))
    }

    @Test func temperatureUsesRecordedSeedPerGeneration() async {
        func params(_ k: HarnessKnobs) async -> [GenParams] {
            let e = FakeEngine()
            e.script(read("a")); e.script(read("b")); e.script(finish("ok"))
            _ = await loop(e, knobs: k).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
            return e.snapshot { $0.generates.map(\.params) }
        }
        let a = await params(HarnessKnobs(temperature: 0.6, seed: 100))
        let b = await params(HarnessKnobs(temperature: 0.6, seed: 100))
        #expect(a.map(\.seed) == [101, 102, 103] && a.map(\.seed) == b.map(\.seed))
        #expect(a.allSatisfy { $0.temperature == 0.6 && $0.topP == HarnessKnobs.sampledTopP && $0.topK == HarnessKnobs.sampledTopK })
        let c = await params(HarnessKnobs(temperature: 0.6, seed: 5))
        #expect(c.map(\.seed) == [6, 7, 8])
        let g = await params(HarnessKnobs(temperature: 0, seed: 100))
        #expect(g.allSatisfy { $0.temperature == 0 && $0.seed == nil && $0.topP == 1 && $0.topK == 0 })
    }

    // MARK: thinking: first planning turn

    private let policy = HarnessKnobs(thinking: .firstPlanningTurn)

    private func histories(_ e: FakeEngine) -> [[Message]] {
        e.snapshot { f in f.appends.compactMap { if case let .history(m) = $0.1 { return m } else { return nil } } }
    }

    @Test func thinkingIsOnForTheFirstTurnOnly() async {
        let e = FakeEngine()
        e.script(read("a.txt", think: "SECRET-PLAN: touch a.txt first")); e.script(read("b.txt")); e.script(finish("ok"))
        let r = await loop(e, knobs: policy).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        #expect(r.status == .done)
        let (opened, closed, gens) = e.snapshot { ($0.opened, $0.closed, $0.generates) }
        #expect(opened.count == 2)
        // Session 1: thinking on, with effort "medium" so the system block is not changed.
        let c1 = opened[0].1, c2 = opened[1].1
        #expect(c1.enableThinking == true && c1.reasoningPolicy == .templateDefault && c1.reasoningEffort == "medium")
        // Session 2 is exactly today's config.
        #expect(c2.enableThinking == nil && c2.reasoningPolicy == .disableWhenTools && c2.reasoningEffort == nil)
        #expect(c1.tools.map(\.name) == c2.tools.map(\.name))
        // Generation 1 on session 1 with the larger thinking budget; generations 2 and 3 on session 2 at the normal cap.
        #expect(gens.map(\.session.raw) == [1, 2, 2])
        #expect(gens[0].params.maxTokens == HarnessKnobs.thinkingTurnTokens && gens[1].params.maxTokens == 4096)
        #expect(closed.contains(opened[0].0))
        // The conversation moved over with its planning reasoning.
        let h = histories(e)
        #expect(h.count == 1)
        let m = h[0]
        #expect(m.map(\.role) == [.system, .user, .assistant, .tool])
        #expect(m[2].reasoningContent == "SECRET-PLAN: touch a.txt first")
        #expect(m[2].toolCalls.map(\.name) == ["read_file"])
        // Session 1 never received another append after its first one.
        let onFirst = e.snapshot { $0.appends.filter { $0.0 == opened[0].0 } }
        #expect(onFirst.count == 1)
    }

    @Test func thinkingStaysOffWhenThePolicyIsOff() async {
        let e = FakeEngine()
        e.script(read("a.txt", think: "x")); e.script(finish("ok"))
        _ = await loop(e, knobs: HarnessKnobs()).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        #expect(e.snapshot { $0.opened.count } == 1 && histories(e).isEmpty)
    }

    @Test func allTurnsThinkingRetainsReasoningAcrossToolResults() async throws {
        let k = try json(#"{"thinking":"all_turns","reasoningEffort":"high"}"#)
        #expect(k.thinking == .allTurns && k.reasoningEffort == "high")
        #expect(throws: (any Error).self) { try json(#"{"reasoningEffort":"extreme"}"#) }
        let e = FakeEngine()
        e.script(read("a.txt", think: "plan one")); e.script(finish("ok", think: "plan two"))
        let r = await loop(e, knobs: k).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        #expect(r.status == .done)
        let opened = e.snapshot { $0.opened }
        #expect(opened.count == 1 && opened[0].1.enableThinking == true && opened[0].1.reasoningEffort == "high")
        let msgs = e.snapshot { f in f.appends.flatMap { if case let .messages(m) = $0.1 { return m } else { return [] } } }
        #expect(msgs.contains { $0.role == .tool })
        // The engine session itself holds the assistant turn with its reasoning; the loop must never swap it off
        // or replay it: one thinking session carries both generations, and only the tool result is appended.
        #expect(histories(e).isEmpty)
        #expect(e.snapshot { $0.generates.map(\.session.raw) } == [1, 1])
        #expect(!msgs.contains { $0.role == .assistant })
    }

    @Test func compactionDropsEarlierReasoningAndNeverRendersAnEmptyAssistantTurn() async throws {
        let e = FakeEngine()
        let earlier = String(repeating: "A", count: 9_000) + " EARLIER-REASONING"
        e.script(read("a", prompt: 15_000, think: earlier))
        e.script(read("b", prompt: 15_000, think: "SECOND-REASONING"))
        e.script(read("c")); e.script(finish("ok"))
        let k = HarnessKnobs(compactionThreshold: 0.4, thinking: .firstPlanningTurn)
        _ = await loop(e, knobs: k).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        let rebuilds: [[Message]] = e.snapshot { f in
            f.appends.compactMap { if case let .messages(m) = $0.1, m.count >= 2 { return m } else { return nil } }
        }
        #expect(rebuilds.count >= 2)
        for m in rebuilds {
            #expect(m.map(\.role) == [.system, .user])        // no reasoning-only assistant turn appended
            #expect(m.allSatisfy { $0.reasoningContent == nil })
            let prompt = try ChatTemplate.render(messages: m, tools: [])
            #expect(!prompt.contains("EARLIER-REASONING") && !prompt.contains("SECOND-REASONING"))
            #expect(prompt.components(separatedBy: "<|im_start|>assistant").count - 1 == 1)   // generation prompt only
        }
    }

    @Test func defaultKnobsOpenTheReleasedSessionAndAppendNoReasoning() async {
        let e = FakeEngine()
        e.script(read("a.txt", think: "hidden")); e.script(finish("ok", think: "more"))
        let r = await loop(e, knobs: HarnessKnobs()).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        #expect(r.status == .done)
        let opened = e.snapshot { $0.opened }
        #expect(opened.count == 1)
        let c = opened[0].1
        #expect(c.reasoningPolicy == .disableWhenTools && c.enableThinking == nil && c.reasoningEffort == nil)
        #expect(c.tools.map(\.name).contains("read_file"))
        let msgs = e.snapshot { f in f.appends.flatMap { if case let .messages(m) = $0.1 { return m } else { return [] } } }
        #expect(!msgs.isEmpty && msgs.allSatisfy { $0.reasoningContent == nil })
        #expect(histories(e).isEmpty)
    }

    @Test func explicitChatThinkingSurvivesCompactionWithKnobsOff() async {
        let e = FakeEngine()
        e.script(read("a", prompt: 15_000, think: "chat-query-reasoning")); e.script(read("b")); e.script(finish("ok"))
        let l = loop(e, knobs: HarnessKnobs(compactionThreshold: 0.4))
        let c = l.openConversation(spec: jobSpec, workspace: ws)
        c.thinking = true
        _ = await l.runUserTurn(c, text: "user query", onEvent: { _ in })
        let opened = e.snapshot { $0.opened }
        #expect(opened.count >= 2 && opened.allSatisfy { $0.1.enableThinking == true })
        let messages = e.snapshot { f in f.appends.flatMap { if case let .messages(m) = $0.1 { return m } else { return [] } } }
        #expect(messages.allSatisfy { $0.reasoningContent == nil })
        await l.closeConversation(c)
    }

    @Test func malformedCallAfterValidCallGetsRetryAfterToolResult() async {
        let e = FakeEngine()
        let syntax = "Malformed tool call: incomplete XML. Resend the complete <tool_call> block."
        e.script(turn([.event(.reasoning("planning"))] + call("read_file", [("path", .string("a.txt"))])
                      + [.event(.toolCallError(syntax))]))
        e.script(finish("ok"))
        _ = await loop(e, knobs: policy).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        let h = histories(e)
        #expect(h.count == 1)
        #expect(h[0].map(\.role) == [.system, .user, .assistant, .tool, .user])
        #expect(h[0][3].content == .text("ok") && h[0][4].content == .text(syntax))
        #expect(h[0][2].reasoningContent == "planning")
    }

    @Test func malformedCallPreventsPrematureFinishAcceptance() async {
        let e = FakeEngine()
        let syntax = "Malformed tool call: incomplete XML. Resend the complete <tool_call> block."
        e.script(turn(call("finish", [("summary", .string("premature"))]) + [.event(.toolCallError(syntax))]))
        e.script(finish("corrected"))
        let r = await loop(e, knobs: policy).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        #expect(r.status == .done && r.summary == "corrected")
        let h = histories(e)
        #expect(h.count == 1 && h[0].map(\.role) == [.system, .user, .assistant, .tool, .user])
        #expect(h[0][3].content == .text("finished") && h[0][4].content == .text(syntax))
    }

    @Test func malformedToolCallGetsSpecificRetryEvenAfterLengthCutoff() async {
        let e = FakeEngine()
        let error = "Malformed tool call: incomplete XML. Resend the complete <tool_call> block."
        e.script([.event(.tokens([1], "I will read it")), .event(.toolCallError(error)),
                  .event(.finished(.length, makeUsage(prompt: 100, completion: 10)))])
        e.script(finish("ok"))
        let result = await loop(e, knobs: policy).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        #expect(result.status == .done)
        let history = histories(e).first ?? []
        #expect(history.contains { $0.role == .user && $0.content == .text(error) })
        #expect(!history.contains { !$0.toolCalls.isEmpty })
    }

    @Test func aNudgeAfterAThinkingProseTurnIsNotAThinkingTurn() async {
        let e = FakeEngine()
        e.script(prose("looks fine")); e.script(finish("really"))
        let r = await loop(e, knobs: policy, requireFinish: true).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        #expect(r.status == .done)
        let gens = e.snapshot { $0.generates }
        #expect(gens.map(\.session.raw) == [1, 2])
        let h = histories(e)
        #expect(h.count == 1 && h[0].map(\.role) == [.system, .user, .assistant, .user])
    }

    @Test func aSingleThinkingTurnThatFinishesNeverSwapsSessions() async {
        let e = FakeEngine()
        e.script(finish("quick"))
        let r = await loop(e, knobs: policy).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        #expect(r.status == .done && e.snapshot { $0.opened.count } == 1 && histories(e).isEmpty)
    }

    @Test func thinkingRestartsAfterCompaction() async {
        let e = FakeEngine()
        e.script(read("a", prompt: 15_000)); e.script(read("b")); e.script(finish("ok"))
        let k = HarnessKnobs(compactionThreshold: 0.4, thinking: .firstPlanningTurn)
        _ = await loop(e, knobs: k).run(spec: jobSpec, workspace: ws, onEvent: { _ in })
        let opened = e.snapshot { $0.opened }
        // s1 thinking (gen 1) -> s2 thinking-off (swap) -> compaction opens s3 thinking again -> s4 swap after its first turn.
        #expect(opened.map { $0.1.enableThinking == true } == [true, false, true, false])
        let gens = e.snapshot { $0.generates }
        #expect(gens.map(\.session.raw) == [1, 3, 4])
    }

    @Test func chatConversationThinksOnlyOnTheFirstGenerationOfTheSession() async {
        let e = FakeEngine()
        e.script(prose("answer one")); e.script(prose("answer two"))
        let l = loop(e, knobs: policy, requireFinish: false)
        let c = l.openConversation(spec: jobSpec, workspace: ws)
        _ = await l.runUserTurn(c, text: "q1", onEvent: { _ in })
        _ = await l.runUserTurn(c, text: "q2", onEvent: { _ in })
        let opened = e.snapshot { $0.opened }
        #expect(opened.map { $0.1.enableThinking == true } == [true, false])
        let h = histories(e)
        #expect(h.count == 1 && h[0].map(\.role) == [.system, .user, .assistant, .user])
        await l.closeConversation(c)
    }

    // MARK: malicious pack cannot raise ceilings

    @Test func extremeKnobsStillRespectJobLimits() async throws {
        // maxTurns / maxSeconds / maxGeneratedTokens are not knobs: the file is refused outright.
        #expect(throws: (any Error).self) { try json(#"{"maxTurns":1000000000,"resultCapChars":-1}"#) }
        // Everything that is a knob is clamped, and the job limits in the spec stay in charge.
        let k = try json(#"{"resultCapChars":1000000000,"compactionThreshold":1e9,"temperature":1e9,"thinking":"first_planning_turn","seed":18446744073709551615}"#)
        #expect(k.toolOutputCap == 8000 && k.compactionThreshold == 0.9 && k.temperature == 1)
        var limits = HarnessLimits(); limits.maxTurns = 3
        let e = FakeEngine()
        e.script(read("a")) // repeats forever
        let r = await loop(e, knobs: k).run(spec: HarnessJobSpec(task: "t", cwd: "/tmp/p", access: .write, limits: limits),
                                            workspace: ws, onEvent: { _ in })
        #expect(r.status == .limit && r.usage.turns == 3)
    }

    @Test func profileLimitsAreIndependentOfKnobs() {
        let l = RunProfile.delegated.limits()
        #expect(l.maxTurns == 40 && l.maxSeconds == 900 && l.maxGeneratedTokens == 60_000)
    }
}

/// Prefix-cache contract of the thinking policy, checked against the real chat template.
@Suite struct ThinkingPrefixCacheTests {
    private let tools: [ToolSpec] = [FinishTool().spec, Tool(name: "read_file").spec]
    private let base: [Message] = [.system("SYS"), .user("# Task\nfix it")]

    private func render(_ msgs: [Message], thinking: Bool) throws -> [Segment] {
        let cfg = thinking
            ? (policy: ReasoningPolicy.templateDefault, enable: Optional(true), effort: Optional("medium"))
            : (policy: ReasoningPolicy.disableWhenTools, enable: nil, effort: nil)
        return try ChatTemplate.renderSegments(messages: msgs, tools: tools, addGenerationPrompt: true, enableThinking: cfg.enable,
                                               reasoningPolicy: cfg.policy, reasoningEffort: cfg.effort)
    }

    @Test func onlyTheGenerationPromptDiffersOnTheFirstTurn() throws {
        let off = try render(base, thinking: false), on = try render(base, thinking: true)
        #expect(off.dropLast() == on.dropLast())
        #expect(off.last?.role == "generation_prompt" && on.last?.role == "generation_prompt")
        #expect(off.last?.text == "<|im_start|>assistant\n<think>\n\n</think>\n\n")
        #expect(on.last?.text == "<|im_start|>assistant\n<think>\n")
        // Why effort is "medium": the default effort adds an instruction to the system block and would break the prefix.
        let defaultEffort = try ChatTemplate.renderSegments(messages: base, tools: tools, enableThinking: true, reasoningPolicy: .templateDefault)
        #expect(defaultEffort.first != off.first)
    }

    @Test func turnTwoOnwardsRendersExactlyLikeTodaysThinkingOffPrompt() throws {
        // The thinking session is replaced by a thinking-off one holding the same messages without reasoning:
        // its render is the render of a never-thinking session, so every later prefix equals today's.
        let hist = base + [.assistant(nil, toolCalls: [ToolCall(name: "read_file", arguments: [("path", .string("a.txt"))])]), .tool("contents")]
        let today = try render(hist, thinking: false)
        #expect(today.last?.text == "<|im_start|>assistant\n<think>\n\n</think>\n\n")
        let rebuilt = try render(hist, thinking: false)   // what the replacement session renders
        #expect(rebuilt == today)
        // System block and first user message are token-identical to the thinking turn's, so the prefix trie serves them.
        let first = try render(base, thinking: true)
        #expect(Array(today.prefix(2)) == Array(first.prefix(2)))
        // The reasoning of turn 1 is not in the render at all.
        #expect(!today.map(\.text).joined().contains("SECRET"))
    }
}
