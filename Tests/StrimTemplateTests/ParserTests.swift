import Foundation
import Testing
@testable import StrimTemplate

private let tools: [ToolSpec] = [
    ToolSpec(name: "read_file", description: "Read", parameters: .ordered([
        ("type", .string("object")),
        ("properties", .ordered([("path", .ordered([("type", .string("string"))])), ("limit", .ordered([("type", .string("integer"))]))])),
    ])),
    ToolSpec(name: "create", description: "Create", parameters: .ordered([
        ("type", .string("object")),
        ("properties", .ordered([
            ("title", .ordered([("type", .string("string"))])),
            ("labels", .ordered([("type", .string("array"))])),
            ("meta", .ordered([("type", .string("object"))])),
            ("ratio", .ordered([("type", .string("number"))])),
            ("dry", .ordered([("type", .string("boolean"))])),
            ("opt", .ordered([("type", .array([.string("integer"), .string("null")]))])),
            ("any", .ordered([("description", .string("untyped"))])),
        ])),
    ])),
]

private func parse(_ text: String, reasoning: Bool = false, tools t: [ToolSpec] = tools) -> [ParserEvent] {
    var p = ToolCallParser(tools: t, startsInReasoning: reasoning)
    return (p.feed(text) + p.finish()).coalesced()
}

private func call(_ name: String, _ args: [(String, OrderedJSON)]) -> [ParserEvent] {
    [.toolCallBegin(name: name)] + args.map { .toolCallArg(key: $0.0, value: $0.1) } + [.toolCallEnd]
}

private let readCall = "<tool_call>\n<function=read_file>\n<parameter=path>\nsrc/main.ts\n</parameter>\n<parameter=limit>\n20\n</parameter>\n</function>\n</tool_call>"

@Test func parsesReasoningTextAndToolCall() {
    let ev = parse("Plan the read.</think>\n\nLet me read it.\n\n" + readCall, reasoning: true)
    #expect(ev == [.reasoning("Plan the read."), .text("Let me read it.")] + call("read_file", [("path", .string("src/main.ts")), ("limit", .int(20))]))
}

@Test func explicitThinkTagAndContentMode() {
    #expect(parse("<think>\nhm\n</think>\n\nanswer") == [.reasoning("hm\n"), .text("answer")])
    #expect(parse("\n\nplain answer  \n") == [.text("plain answer  \n")])
    #expect(ToolCallParser.promptOpensReasoning("<|im_start|>assistant\n<think>\n"))
    #expect(!ToolCallParser.promptOpensReasoning("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
}

@Test func parallelCallsAndSchemaTyping() {
    let text = "<tool_call>\n<function=create>\n<parameter=title>\n42\n</parameter>\n<parameter=labels>\n[\"bug\", \"docs\"]\n</parameter>\n"
        + "<parameter=meta>\n{\"z\": 1, \"a\": {\"k\": null}}\n</parameter>\n<parameter=ratio>\n0.5\n</parameter>\n<parameter=dry>\ntrue\n</parameter>\n"
        + "<parameter=opt>\nnull\n</parameter>\n<parameter=any>\n{\"x\": [1, 2]}\n</parameter>\n<parameter=undeclared>\nhello world\n</parameter>\n</function>\n</tool_call>\n"
        + "<tool_call>\n<function=read_file>\n<parameter=path>\n/a b\n</parameter>\n<parameter=limit>\nnot a number\n</parameter>\n</function>\n</tool_call>"
    let ev = parse(text)
    let expected = call("create", [
        ("title", .string("42")), ("labels", .array([.string("bug"), .string("docs")])),
        ("meta", .ordered([("z", .int(1)), ("a", .ordered([("k", .null)]))])), ("ratio", .double(0.5)), ("dry", .bool(true)),
        ("opt", .null), ("any", .ordered([("x", .array([.int(1), .int(2)]))])), ("undeclared", .string("hello world")),
    ]) + call("read_file", [("path", .string("/a b")), ("limit", .string("not a number"))])
    #expect(ev == expected)
}

@Test func multilineValuesKeepInnerWhitespace() {
    let ev = parse("<tool_call>\n<function=read_file>\n<parameter=path>\n\n  a\n\nb  \n\n</parameter>\n</function>\n</tool_call>")
    #expect(ev == call("read_file", [("path", .string("\n  a\n\nb  \n"))]))
}

@Test func literalCloseTagInsideValueSurvives() {
    let v = "x</parameter> y\n</parameter>z"
    let ev = parse("<tool_call>\n<function=read_file>\n<parameter=path>\n\(v)\n</parameter>\n</function>\n</tool_call>")
    #expect(ev == call("read_file", [("path", .string(v))]))
}

private let incompleteError = ParserEvent.toolCallError("Malformed tool call: incomplete XML. Resend the complete <tool_call> block.")
private let readArgs: [(String, OrderedJSON)] = [("path", .string("src/main.ts")), ("limit", .int(20))]

private func splits(_ text: String, _ check: (_ events: [ParserEvent], _ count: Int) -> Void) {
    for split in 0...text.count {
        var p = ToolCallParser(tools: tools)
        let i = text.index(text.startIndex, offsetBy: split)
        let ev = (p.feed(String(text[..<i])) + p.feed(String(text[i...])) + p.finish()).coalesced()
        check(ev, p.toolCallCount)
    }
}

@Test func unparseableBlockPassesThroughAsText() {
    #expect(parse("x <tool_call>garbage</tool_call> y") == [.text("x <tool_call>garbage</tool_call> y")])
    #expect(parse("<tool_call>{\"name\": \"read_file\", \"arguments\": {}}</tool_call>") == [.text("<tool_call>{\"name\": \"read_file\", \"arguments\": {}}</tool_call>")])
    #expect(parse("a <tool_call>\n<function=>\n</function>") == [.text("a <tool_call>\n<function=>\n</function>")])
    #expect(parse("a <tool_cal") == [.text("a <tool_cal")])
    #expect(parse("a <tool_call>\n<func") == [.text("a <tool_call>\n<func")])
    // no tools declared: tool calls are plain text
    #expect(parse("a\n\n" + readCall, tools: []) == [.text("a\n\n" + readCall)])
}

@Test func proseMentioningToolCallThenRealCallExecutesAtEverySplit() {
    let text = "use <tool_call> tags. " + readCall
    splits(text) { ev, count in
        #expect(ev == [.text("use <tool_call> tags.")] + call("read_file", readArgs))
        #expect(count == 1)
    }
}

@Test func proseMentioningToolCallWithoutCloserIsTextOnly() {
    for prose in ["the <tool_call> tag is used for calls", "see <tool_call>\nnot a call", "ends with <tool_call>"] {
        splits(prose) { ev, count in
            #expect(ev == [.text(prose)])
            #expect(count == 0)
        }
    }
}

@Test func truncatedInsideParameterNeverExecutes() {
    let truncated = "<tool_call>\n<function=read_file>\n<parameter=path>\nsrc/a.ts\n</parameter>\n<parameter=limit>\n2"
    splits(truncated) { ev, count in
        #expect(!ev.contains(.toolCallEnd))
        #expect(ev.last == incompleteError)
        #expect(count == 0)
    }
    // truncated inside the function header
    splits("a <tool_call>\n<function=read_fi") { ev, count in
        #expect(ev == [.text("a"), incompleteError])
        #expect(count == 0)
    }
}

@Test func argEventsStreamPerParameterBeforeEnvelopeCloses() {
    var p = ToolCallParser(tools: tools)
    #expect(p.feed("<tool_call>\n<function=read_file>\n") == [.toolCallBegin(name: "read_file")])
    #expect(p.feed("<parameter=path>\nsrc/main.ts\n</parameter>\n").isEmpty)  // closer needs lookahead
    #expect(p.feed("<parameter=limit>\n") == [.toolCallArg(key: "path", value: .string("src/main.ts"))])
    #expect(p.feed("20\n</parameter>\n</function>") == [.toolCallArg(key: "limit", value: .int(20)), .toolCallEnd])
    #expect(p.toolCallCount == 1)
    #expect(p.feed("\n</tool_call>").isEmpty)
    #expect(p.finish().isEmpty)
}

@Test func missingEnvelopeCloseStillExecutes() {
    let noClose = "<tool_call>\n<function=read_file>\n<parameter=path>\na\n</parameter>\n</function>"
    splits(noClose) { ev, count in
        #expect(ev == call("read_file", [("path", .string("a"))]))
        #expect(count == 1)
    }
    #expect(parse(noClose + " trailing") == call("read_file", [("path", .string("a"))]) + [.text("trailing")])
}

@Test func toleratesMissingFunctionClose() {
    let ev = parse("<tool_call>\n<function=read_file>\n<parameter=path>\na\n</parameter>\n</tool_call> done")
    #expect(ev == call("read_file", [("path", .string("a"))]) + [.text("done")])  // leading whitespace of content is dropped while `lead` is set
}

// MARK: stray reasoning delimiters never reach content

private func render(_ ev: [ParserEvent]) -> (reasoning: String, text: String) {
    var r = "", t = ""
    for e in ev {
        if case let .reasoning(x) = e { r += x }
        if case let .text(x) = e { t += x }
    }
    return (r, t)
}

@Test func openerInjectedByPromptThenCloserOnly() {  // (a)
    let ev = parse("Plan.</think>\n\nThe answer.", reasoning: true, tools: [])
    #expect(ev == [.reasoning("Plan."), .text("The answer.")])
}

@Test func closerSplitAcrossChunks() {  // (b)
    var p = ToolCallParser(startsInReasoning: true)
    var ev = [ParserEvent]()
    for c in ["Plan.</thi", "nk", ">\n\nAns", "wer.</", "think", ">"] { ev += p.feed(c) }
    ev += p.finish()
    #expect(ev.coalesced() == [.reasoning("Plan."), .text("Answer.")])
}

@Test func thinkingOffPrefillEmitsNothingOfTheKind() {  // (c)
    #expect(parse("Just the answer.", reasoning: false, tools: []) == [.text("Just the answer.")])
    #expect(!ToolCallParser.promptOpensReasoning("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
}

@Test func trailingStrayCloserIsDropped() {  // (d) real transcript shape
    let t = "```diff\n-a\n+b\n```\n\nNo files were edited.\n</think>"
    for tl in [tools, []] {
        let r = render(parse(t, tools: tl))
        #expect(!r.text.contains("</think>"))
        #expect(r.text.hasPrefix("```diff\n-a\n+b\n```\n\nNo files were edited."))
    }
}

@Test func tagsInCodeStayLiteral() {  // (e)
    let r = render(parse("Use ```\n</think>\n``` and `<think>` then </think>done", tools: []))
    #expect(r.text == "Use ```\n</think>\n``` and `<think>` then done")
    #expect(r.reasoning.isEmpty)
    // tool-call argument JSON is never inspected
    let ev = parse("<tool_call>\n<function=create>\n<parameter=title>\nx </think> <think> y\n</parameter>\n</function>\n</tool_call>")
    #expect(ev == call("create", [("title", .string("x </think> <think> y"))]))
}

@Test func multipleThinkingBlocks() {  // (f)
    let r = render(parse("<think>one</think>\n\nA <think>two</think>\n\nB", tools: []))
    #expect(r.reasoning == "onetwo")
    #expect(r.text == "A B")
}

private let samples: [(String, Bool)] = [
    ("Plan the read.</think>\n\nLet me read it.\n\n" + readCall, true),
    ("<think>\nhm</think>\n\nsome  text \n\n" + readCall + "\n\n" + readCall + "\n", false),
    ("Think \u{1F600} e\u{0301}.</think>\n\ncaf\u{00e9} \u{4E2D}\u{6587} \u{1F600}\n\n<tool_call>\n<function=read_file>\n<parameter=path>\n\u{4E2D}\u{6587}\u{0301}\n</parameter>\n</function>\n</tool_call>\u{0301}tail", true),
    ("x</parameter>y <tool_call>\n<function=read_file>\n<parameter=path>\na</parameter>b\n</parameter>\n</function>\n</tool_call>", false),
    ("<tool_call>\n<function=create>\n<parameter=meta>\n{\"a\": [1, {\"b\": \"</tool_call>\"}]}\n</parameter>\n</function>\n</tool_call>", false),
    ("x <tool_call>garbage</tool_call> y <tool_call>\n<function=read_file>\n</function>\n</tool_call>", false),
    ("<tool_call>\n<function=read_file>\n<parameter=path>\ntrunc", false),
    ("no think close at all, reasoning only", true),
    ("a<tool_call>\n  \n<function=read_file>\ngarbage <parameter=path>\nq\n</parameter>  junk </function>\n  <function=create>\n</function></tool_call>", false),
    ("answer.\n</think>", false),
    ("a <think>b</think> c ```\n</think> <think>\n```\n</think>d `</think>` e", false),
    ("r1</think>\nA <think>r2</think>\nB\n</think>", true),
    ("</think></think> <think> <tool_call><tool_call>\n<function=read_file>\n</function>", true),
]

/// Property test: any chunking yields the same coalesced events as the unsplit text.
@Test func chunkingNeverChangesEvents() {
    var checks = 0
    var rng = SystemRandomNumberGeneratorSeeded(seed: 0x5eed)
    for (text, reasoning) in samples {
        let scalars = Array(text.unicodeScalars)
        func make(_ r: Range<Int>) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: scalars[r]); return String(v) }
        let expected = parse(text, reasoning: reasoning)
        // every single split point
        for cut in 0...scalars.count {
            var p = ToolCallParser(tools: tools, startsInReasoning: reasoning)
            let ev = (p.feed(make(0..<cut)) + p.feed(make(cut..<scalars.count)) + p.finish()).coalesced()
            #expect(ev == expected, "split at \(cut) of \(text.debugDescription)")
            checks += 1
        }
        // one scalar at a time
        var p1 = ToolCallParser(tools: tools, startsInReasoning: reasoning)
        var ev1 = [ParserEvent]()
        for i in 0..<scalars.count { ev1 += p1.feed(make(i..<i + 1)) }
        #expect((ev1 + p1.finish()).coalesced() == expected, "char-by-char \(text.debugDescription)")
        // random chunkings
        for _ in 0..<60 {
            var p = ToolCallParser(tools: tools, startsInReasoning: reasoning)
            var ev = [ParserEvent]()
            var i = 0
            while i < scalars.count {
                let n = min(scalars.count - i, 1 + Int(rng.next() % 12))
                ev += p.feed(make(i..<i + n))
                i += n
            }
            #expect((ev + p.finish()).coalesced() == expected, "random chunking of \(text.debugDescription)")
            checks += 1
        }
    }
    #expect(checks > 1000)
}

/// Template-rendered assistant tool calls parse back to the same typed arguments.
@Test func templateRoundTrip() throws {
    let args: [(String, OrderedJSON)] = [
        ("title", .string("Fix caf\u{00e9} </parameter> \u{1F600}")), ("labels", .array([.string("bug")])),
        ("meta", .ordered([("z", .int(1)), ("a", .ordered([("k", .null), ("f", .double(2.0))]))])), ("ratio", .double(0.25)),
        ("dry", .bool(false)), ("opt", .int(7)),
    ]
    let msgs: [Message] = [.user("go"), .assistant("Doing it.", toolCalls: [ToolCall(name: "create", arguments: args)])]
    let text = try ChatTemplate.render(messages: msgs, tools: tools, addGenerationPrompt: false, enableThinking: false)
    let start = text.range(of: "Doing it.", options: .backwards)!.lowerBound
    var body = String(text[start...])
    body.removeLast("<|im_end|>\n".count)
    let ev = parse(body)
    #expect(ev == [.text("Doing it.")] + call("create", args))
}

struct SystemRandomNumberGeneratorSeeded {
    var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return s >> 33
    }
}
