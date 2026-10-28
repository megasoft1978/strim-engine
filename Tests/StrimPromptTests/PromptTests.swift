import Foundation
import Testing
@testable import StrimPrompt
import StrimTemplate
import StrimTokenizer

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Weights are not committed: the model-backed tests skip in a clean clone.
private let qwenModelPresent = FileManager.default.fileExists(atPath: root.appendingPathComponent("models/qwen38-4bit/tokenizer.json").path)

private let tokenizer: Tokenizer = try! Tokenizer.load(modelDir: root.appendingPathComponent("models/qwen38-4bit").path)

private struct Case {
    var id: String
    var session: String?
    var step: Int
    var messages: [Message]
    var tools: [ToolSpec]
    var gen: Bool
    var enableThinking: Bool?
    var policy: ReasoningPolicy
    var toolChoice: String?
    var effort: String?
    var preserve: Bool?
    var ids: [Int32]

    init(_ c: OrderedJSON) throws {
        id = c["id"]?.stringValue ?? "?"
        session = c["session"]?.stringValue
        if case let .int(s)? = c["step"] { step = s } else { step = 0 }
        guard case let .array(ms)? = c["messages"] else { throw TemplateError("no messages") }
        messages = try ms.map { try Message(json: $0) }
        if case let .array(ts)? = c["tools"] { tools = ts.map { ToolSpec(json: $0) } } else { tools = [] }
        if case let .bool(g)? = c["add_generation_prompt"] { gen = g } else { gen = true }
        if case let .bool(b)? = c["enable_thinking"] { enableThinking = b }
        policy = ReasoningPolicy(rawValue: c["policy"]?.stringValue ?? "") ?? .templateDefault
        toolChoice = c["tool_choice"]?.stringValue
        effort = c["reasoning_effort"]?.stringValue
        if case let .bool(b)? = c["preserve_thinking"] { preserve = b }
        guard case let .array(raw)? = c["ids"] else { throw TemplateError("no ids") }
        ids = raw.map { if case let .int(i) = $0 { return Int32(i) } else { return -1 } }
    }

    func prepare(_ ledger: Ledger, _ msgs: [Message]? = nil, mode: ContentSpecialTokens = .disabled) throws -> PreparedPrompt {
        try PromptBuilder.prepare(
            ledger: ledger, messages: msgs ?? messages, tools: tools, reasoningPolicy: policy, enableThinking: enableThinking,
            addGenerationPrompt: gen, toolChoice: toolChoice, reasoningEffort: effort, preserveThinking: preserve,
            contentSpecialTokens: mode)
    }

    func segments(_ msgs: [Message]? = nil) throws -> [Segment] {
        try ChatTemplate.renderSegments(
            messages: msgs ?? messages, tools: tools, addGenerationPrompt: gen, enableThinking: enableThinking,
            reasoningPolicy: policy, toolChoice: toolChoice, reasoningEffort: effort, preserveThinking: preserve)
    }
}

private let cases: [Case] = {
    let text = try! String(contentsOf: root.appendingPathComponent("bench/fixtures/prompt_parity.json"), encoding: .utf8)
    guard case let .array(a) = try! OrderedJSON.parse(text) else { fatalError("fixture") }
    return a.map { try! Case($0) }
}()

private var sessions: [(String, [Case])] {
    var by = [String: [Case]]()
    for c in cases { if let s = c.session { by[s, default: []].append(c) } }
    return by.keys.sorted().map { ($0, by[$0]!.sorted { $0.step < $1.step }) }
}

private func firstDiff(_ a: [Int32], _ b: [Int32]) -> Int {
    var i = 0
    while i < min(a.count, b.count), a[i] == b[i] { i += 1 }
    return i
}

@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func fixtureSize() {
    #expect(cases.count >= 120)
    print("prompt fixture: \(cases.count) conversations, \(sessions.count) sessions")
}

@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func newlineIdIsLookedUp() {
    let l = Ledger(tokenizer: tokenizer)
    #expect(l.newlineId == tokenizer.encode("\n")[0])
    #expect(l.imEndId == tokenizer.specialIds["<|im_end|>"])
}

/// Boundary tokenization: tokenizing template segments separately and concatenating == HF ids of the full render.
@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func rawSegmentBoundaryTokenization() throws {
    var bad = [String](), ok = 0
    for c in cases {
        let segs = try c.segments()
        let ids = segs.flatMap { tokenizer.encode($0.text) }
        if ids == c.ids { ok += 1 } else { bad.append("\(c.id)@\(firstDiff(ids, c.ids)) roles=\(segs.map(\.role))") }
    }
    print("raw segment boundary: \(ok)/\(cases.count) equal; breaking: \(bad.prefix(8))")
    // Known breaking shape: a tool block as the very first message has no <|im_start|> (PromptBuilder fuses it).
    for b in bad { #expect(b.contains("\"tool\""), Comment(rawValue: b)) }
}

/// Oracle comparison in `.hfCompat` (HF's ids, control strings in content included). Default-mode parity for the
/// control-free cases is in ContentSpecialTokensTests.swift.
@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func coldBuildMatchesOracle() throws {
    var bad = [String]()
    for c in cases {
        let p = try c.prepare(Ledger(tokenizer: tokenizer), mode: .hfCompat)
        if p.ledger.ids != c.ids { bad.append("\(c.id)@\(firstDiff(p.ledger.ids, c.ids))") }
        if p.reusedPrefixIds != 0 || p.newIds != p.ledger.ids { bad.append("\(c.id) cold reuse") }
    }
    print("cold build: \(cases.count - bad.count)/\(cases.count) exact")
    #expect(bad.isEmpty, Comment(rawValue: bad.prefix(10).joined(separator: "\n")))
}

private enum Variant { case exact, extraSpace }

/// Replays one session turn by turn. Returns (turns, reused ids, total ids, simulated generations, skipped generations).
private func simulate(_ session: [Case], _ variant: Variant) throws -> (reused: Int, total: Int, gens: Int, skipped: Int, diverged: Int, problems: [String]) {
    var ledger = Ledger(tokenizer: tokenizer)
    var divergedSteps = 0
    var priorLen = 0, reused = 0, total = 0, gens = 0, skipped = 0
    var problems = [String]()
    var modified = false
    var diverged = false
    for (i, c) in session.enumerated() {
        let p = try c.prepare(ledger)
        if i > 0 {
            if p.reusedPrefixIds != priorLen { problems.append("\(c.id): reused \(p.reusedPrefixIds) != prior \(priorLen) (fallback \(String(describing: p.fallbackAtMessage)))") }
            reused += p.reusedPrefixIds
        }
        total += p.ledger.ids.count
        switch variant {
        case .exact:
            if diverged {
                if p.newIds != Array(c.ids.suffix(p.newIds.count)) { problems.append("\(c.id): suffix != oracle suffix") }
            } else if p.ledger.ids != c.ids { problems.append("\(c.id): ids != oracle @\(firstDiff(p.ledger.ids, c.ids))") }
        case .extraSpace:
            if p.newIds != Array(c.ids.suffix(p.newIds.count)) { problems.append("\(c.id): suffix != oracle suffix") }
            if !modified, p.ledger.ids != c.ids { problems.append("\(c.id): differs before any modification") }
            if modified && p.ledger.ids == c.ids { problems.append("\(c.id): expected divergence") }
        }
        guard i + 1 < session.count else { break }
        // simulate the model generating the next assistant turn
        let next = session[i + 1]
        let n = c.messages.count
        let segs = try next.segments()
        guard let seg = segs.first(where: { $0.role == "assistant" && $0.messages == n..<n + 1 }) else { problems.append("\(c.id): no assistant seg"); break }
        var text = seg.text
        var msg = next.messages[n]
        if variant == .extraSpace {
            text = String(text.dropLast(ChatTemplate.imEnd.count + 1)) + "  " + ChatTemplate.imEnd + "\n"
            if case let .text(s) = msg.content { msg.content = .text(s + "  ") } else { msg.content = .text("  ") }
        }
        let gpText = try c.segments().last!.text
        guard c.gen, text.hasPrefix(gpText) else {
            skipped += 1  // template re-render has content the generation prompt cannot have produced (e.g. reasoning with thinking off)
            break
        }
        // the model generates the text after the generation prompt, tokenized on its own
        var generated = tokenizer.encode(String(text.dropFirst(gpText.count)))
        generated.removeLast()                 // model generates <|im_end|> but not the trailing "\n"
        let gpIds = Array(p.ledger.ids[p.ledger.records.last!.ids])
        if variant == .exact, gpIds + generated + [ledger.newlineId] != tokenizer.encode(text) { divergedSteps += 1; diverged = true }
        ledger = p.ledger
        try ledger.appendGenerated(ids: generated, finishedWithImEnd: true, message: msg)
        if variant == .extraSpace { modified = true }
        priorLen = ledger.ids.count
        gens += 1
    }
    return (reused, total, gens, skipped, divergedSteps, problems)
}

@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func multiTurnReuseExact() throws {
    var reused = 0, total = 0, gens = 0, skipped = 0, div = 0, bad = [String]()
    var fullSessions = 0
    for (name, s) in sessions {
        let r = try simulate(s, .exact)
        reused += r.reused; total += r.total; gens += r.gens; skipped += r.skipped; div += r.diverged
        bad += r.problems.map { "\(name): \($0)" }
        if r.skipped == 0 { fullSessions += 1 }
    }
    print("multi-turn exact: \(sessions.count) sessions, fully simulated \(fullSessions), generations \(gens), skipped sessions \(skipped), generations differing from cold render (empty-think boundary) \(div), reuse (ids reused / ids in turns>0) \(reused)/\(total)")
    #expect(bad.isEmpty, Comment(rawValue: bad.prefix(10).joined(separator: "\n")))
    #expect(gens >= 60)
}

@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func multiTurnReuseWithDivergentGeneration() throws {
    var reused = 0, total = 0, gens = 0, bad = [String]()
    for (name, s) in sessions {
        let r = try simulate(s, .extraSpace)
        reused += r.reused; total += r.total; gens += r.gens
        bad += r.problems.map { "\(name): \($0)" }
    }
    print("multi-turn divergent generation: generations \(gens), reuse \(reused)/\(total)")
    #expect(bad.isEmpty, Comment(rawValue: bad.prefix(10).joined(separator: "\n")))
    #expect(gens >= 60)
}

private func longestAgentSession() throws -> (Case, Ledger) {
    let s = sessions.first { $0.0 == "agent5_tools" }!.1
    var ledger = Ledger(tokenizer: tokenizer)
    var last = s[0]
    for (i, c) in s.enumerated() {
        let p = try c.prepare(ledger)
        ledger = p.ledger
        last = c
        guard i + 1 < s.count else { break }
        let n = c.messages.count
        let seg = try s[i + 1].segments().first { $0.role == "assistant" && $0.messages == n..<n + 1 }!
        var ids = tokenizer.encode(seg.text)
        ids.removeLast()
        try ledger.appendGenerated(ids: Array(ids.dropFirst(ledger.ids[ledger.records.last!.ids].count)), finishedWithImEnd: true, message: s[i + 1].messages[n])
    }
    return (last, ledger)
}

@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func editedHistoryFallsBackAndStaysCorrect() throws {
    let (last, ledger) = try longestAgentSession()
    // client resends the final prompt unchanged: everything but the generation prompt is reused
    let same = try last.prepare(ledger)
    #expect(same.fallbackAtMessage == nil && same.reusedPrefixIds == ledger.records.last!.ids.lowerBound)
    // edit a middle user/tool message
    var edited = last.messages
    let k = edited.indices.first { edited[$0].role == .tool && $0 > 4 }!
    edited[k].content = .text("EDITED " + String(describing: k))
    let p = try last.prepare(ledger, edited)
    let cold = try last.prepare(Ledger(tokenizer: tokenizer), edited)
    #expect(p.ledger.ids == cold.ledger.ids)
    #expect(p.fallbackAtMessage == k)
    #expect(p.reusedPrefixIds == ledger.records.first { $0.messages.contains(k) }!.ids.lowerBound)
    // compaction: drop two middle messages
    var compact = last.messages
    compact.removeSubrange(3..<5)
    let q = try last.prepare(ledger, compact)
    #expect(q.ledger.ids == (try last.prepare(Ledger(tokenizer: tokenizer), compact)).ledger.ids)
    print("history edit at message \(k): reused \(p.reusedPrefixIds)/\(p.ledger.ids.count) ids; compaction reused \(q.reusedPrefixIds)/\(q.ledger.ids.count)")
    // truncate + fork
    var f = ledger.fork()
    f.truncate(to: 2)
    #expect(f.messageCount <= 2 && ledger.messageCount > 2 && f.ids.count < ledger.ids.count)
}

@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func reasoningIsOptionalWhenMatching() throws {
    let user = Message.user("hi")
    var l = Ledger(tokenizer: tokenizer)
    let a = Message.assistant("Hello there", reasoning: "thinking it over")
    func run(_ client: Message) throws -> PreparedPrompt {
        let first = try PromptBuilder.prepare(ledger: l, messages: [user])
        var led = first.ledger
        let gen = tokenizer.encode("thinking it over\n</think>\n\nHello there<|im_end|>")
        try led.appendGenerated(ids: gen, finishedWithImEnd: true, message: a)
        l = led
        return try PromptBuilder.prepare(ledger: led, messages: [user, client, .user("next")])
    }
    let dropped = try run(.assistant("Hello there"))
    #expect(dropped.fallbackAtMessage == nil && dropped.reusedPrefixIds == l.ids.count)
    l = Ledger(tokenizer: tokenizer)
    let same = try run(.assistant("  Hello there \n", reasoning: " thinking it over "))
    #expect(same.fallbackAtMessage == nil && same.reusedPrefixIds == l.ids.count)
    l = Ledger(tokenizer: tokenizer)
    let other = try run(.assistant("Hello there", reasoning: "something else"))
    #expect(other.fallbackAtMessage == 1 && other.reusedPrefixIds < l.ids.count)
    l = Ledger(tokenizer: tokenizer)
    let changed = try run(.assistant("Hello there!"))
    #expect(changed.fallbackAtMessage == 1)
    // tool-call argument key order does not matter
    let call = Message.assistant("", toolCalls: [ToolCall(name: "f", arguments: [("a", .int(1)), ("b", .string("x"))])])
    let swapped = Message.assistant("", toolCalls: [ToolCall(name: "f", arguments: [("b", .string("x")), ("a", .int(1))])])
    #expect(PromptBuilder.messageKey(call) == PromptBuilder.messageKey(swapped))
}

@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func incompleteGenerationIsNotReused() throws {
    let user = Message.user("hi")
    var led = try PromptBuilder.prepare(ledger: Ledger(tokenizer: tokenizer), messages: [user]).ledger
    let a = Message.assistant("partial")
    try led.appendGenerated(ids: tokenizer.encode("partial"), finishedWithImEnd: false, message: a)
    #expect(led.ids.last == tokenizer.encode("partial").last)  // no <|im_end|>/"\n" added
    let p = try PromptBuilder.prepare(ledger: led, messages: [user, a, .user("go on")])
    #expect(p.fallbackAtMessage == 1)
    #expect(p.ledger.ids == (try PromptBuilder.prepare(ledger: Ledger(tokenizer: tokenizer), messages: [user, a, .user("go on")])).ledger.ids)
}

@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func toolOptionChangeInvalidatesHeader() throws {
    let tool = ToolSpec(name: "t", description: "d", parameters: .ordered([]))
    let msgs = [Message.system("sys"), .user("q")]
    let a = try PromptBuilder.prepare(ledger: Ledger(tokenizer: tokenizer), messages: msgs, tools: [tool])
    let b = try PromptBuilder.prepare(ledger: a.ledger, messages: msgs, tools: [])
    #expect(b.reusedPrefixIds == 0 && b.fallbackAtMessage == 0)
    let c = try PromptBuilder.prepare(ledger: a.ledger, messages: msgs + [.assistant("x"), .user("y")], tools: [tool])
    #expect(c.reusedPrefixIds > 0 && c.fallbackAtMessage == nil)
}
