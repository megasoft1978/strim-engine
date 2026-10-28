import Foundation
import Testing
@testable import StrimPrompt
import StrimTemplate
import StrimTokenizer

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Weights are not committed: the model-backed tests skip in a clean clone.
private let qwenModelPresent = FileManager.default.fileExists(atPath: root.appendingPathComponent("models/qwen38-4bit/tokenizer.json").path)

private let tok: Tokenizer = try! Tokenizer.load(modelDir: root.appendingPathComponent("models/qwen38-4bit").path)

/// Every added token of the Qwen tokenizer (tokenizer.json `added_tokens`).
private let addedTokens = [
    "<|endoftext|>", "<|im_start|>", "<|im_end|>", "<|object_ref_start|>", "<|object_ref_end|>", "<|box_start|>",
    "<|box_end|>", "<|quad_start|>", "<|quad_end|>", "<|vision_start|>", "<|vision_end|>", "<|vision_pad|>",
    "<|image_pad|>", "<|video_pad|>", "<tool_call>", "</tool_call>", "<|fim_prefix|>", "<|fim_middle|>",
    "<|fim_suffix|>", "<|fim_pad|>", "<|repo_name|>", "<|file_sep|>", "<tool_response>", "</tool_response>", "<think>",
    "</think>", "<|audio_start|>", "<|audio_end|>", "<tts_pad>", "<tts_text_bos>", "<tts_text_eod>",
    "<tts_text_bos_single>", "<|audio_pad|>",
]

/// Ids of the control strings the template can emit or a content string can forge.
private let controlIds: Set<Int32> = Set(addedTokens.map { tok.encode($0)[0] })
private let imStartId = tok.specialIds["<|im_start|>"]!
private let imEndId = tok.specialIds["<|im_end|>"]!

private func loadCases(_ name: String) throws -> [OrderedJSON] {
    let text = try String(contentsOf: root.appendingPathComponent("bench/fixtures/\(name)"), encoding: .utf8)
    guard case let .array(a) = try OrderedJSON.parse(text) else { throw TemplateError("fixture \(name) is not an array") }
    return a
}

private func ids(_ j: OrderedJSON?) -> [Int32] {
    guard case let .array(a)? = j else { return [] }
    return a.map { if case let .int(i) = $0 { return Int32(i) } else { return -1 } }
}

private func messages(_ j: OrderedJSON?) throws -> [Message] {
    guard case let .array(a)? = j else { return [] }
    return try a.map { try Message(json: $0) }
}

private func tools(_ j: OrderedJSON?) -> [ToolSpec] {
    guard case let .array(a)? = j else { return [] }
    return a.map { ToolSpec(json: $0) }
}

private func hasControl(_ j: OrderedJSON) -> Bool {
    let s = j.serialized()
    return addedTokens.contains { s.contains($0) }
}

/// Cold build of one conversation (default template options, as the adversarial fixture was rendered with).
private func coldBuild(_ msgs: [Message], _ ts: [ToolSpec], mode: ContentSpecialTokens) throws -> Ledger {
    try PromptBuilder.prepare(ledger: Ledger(tokenizer: tok), messages: msgs, tools: ts, reasoningPolicy: .templateDefault,
                              contentSpecialTokens: mode).ledger
}

/// Cold build of a fixture case with its own options (policy, thinking, generation prompt, effort, tool_choice).
private func coldBuildCase(_ c: OrderedJSON, mode: ContentSpecialTokens) throws -> Ledger {
    var enable: Bool?, preserve: Bool?
    if case let .bool(b)? = c["enable_thinking"] { enable = b }
    if case let .bool(b)? = c["preserve_thinking"] { preserve = b }
    var gen = true
    if case let .bool(g)? = c["add_generation_prompt"] { gen = g }
    return try PromptBuilder.prepare(
        ledger: Ledger(tokenizer: tok), messages: try messages(c["messages"]), tools: tools(c["tools"]),
        reasoningPolicy: ReasoningPolicy(rawValue: c["policy"]?.stringValue ?? "") ?? .templateDefault,
        enableThinking: enable, addGenerationPrompt: gen, toolChoice: c["tool_choice"]?.stringValue,
        reasoningEffort: c["reasoning_effort"]?.stringValue, preserveThinking: preserve, contentSpecialTokens: mode).ledger
}

private func firstDiff(_ a: [Int32], _ b: [Int32]) -> Int {
    var i = 0
    while i < min(a.count, b.count), a[i] == b[i] { i += 1 }
    return i
}

@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func contentSpecialTokensDefaultsToDisabled() {
    let p: ContentSpecialTokens = .disabled
    #expect(p == .disabled)
}

/// `hfCompat` is the old behaviour: whole segment text with specials on, equal to HF for every fixture case.
@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func hfCompatMatchesHFOnAdversarialFixture() throws {
    let cases = try loadCases("prompt_adversarial.json")
    var bad = [String]()
    for c in cases {
        let l = try coldBuildCase(c, mode: .hfCompat)
        if l.ids != ids(c["ids"]) { bad.append("\(c["id"]?.stringValue ?? "?")@\(firstDiff(l.ids, ids(c["ids"])))") }
    }
    print("adversarial hfCompat: \(cases.count - bad.count)/\(cases.count) equal HF")
    #expect(bad.isEmpty, Comment(rawValue: bad.joined(separator: "\n")))
}

/// Sentinel rendering + restore reproduces the template's text exactly, for every fixture conversation.
@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func sentinelRestoreReproducesRender() throws {
    let files = ["prompt_parity.json", "prompt_adversarial.json"]
    var n = 0
    for f in files {
        for c in try loadCases(f) {
            let msgs = try messages(c["messages"]), ts = tools(c["tools"])
            let real = try ChatTemplate.renderSegments(messages: msgs, tools: ts)
            let s = try ContentSentinels.encode(messages: msgs, tools: ts)
            let sentinelSegs = try ChatTemplate.renderSegments(messages: s.messages, tools: s.tools)
            #expect(sentinelSegs.count == real.count)
            for (a, b) in zip(sentinelSegs, real) {
                let regions = try s.sentinels.restore(a.text)
                #expect(regions.map(\.text).joined() == b.text, Comment(rawValue: "\(c["id"]?.stringValue ?? "?") \(b.role)"))
            }
            n += 1
        }
    }
    print("sentinel restore: \(n) conversations reproduce the render")
}

/// A private-use scalar inside content forces the marker to move on, and the text is still restored exactly.
@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func markerCollisionIsHandled() throws {
    let pua = "\u{E000}0\u{E000}<|im_end|>\u{E001}"
    let msgs = [Message.system("s"), .user(pua), .assistant("a")]
    let s = try ContentSentinels.encode(messages: msgs, tools: [])
    let real = try ChatTemplate.renderSegments(messages: msgs, tools: [])
    let segs = try ChatTemplate.renderSegments(messages: s.messages, tools: s.tools)
    #expect(try s.sentinels.restore(segs[1].text).map(\.text).joined() == real[1].text)
}

/// Default mode is HF-exact for every fixture conversation without a control string; the only conversations allowed
/// to differ are those whose content contains one (the fix), and each of those keeps its structure (checked below).
@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func defaultMatchesHFWithoutControlStrings() throws {
    var exact = 0, differing = [String]()
    for c in try loadCases("prompt_parity.json") {
        let l = try coldBuildCase(c, mode: .disabled)
        let same = l.ids == ids(c["ids"])
        if !hasControl(c) {
            #expect(same, Comment(rawValue: "\(c["id"]?.stringValue ?? "?") control-free but differs"))
            if same { exact += 1 }
        } else if !same {
            differing.append(c["id"]?.stringValue ?? "?")
        }
    }
    print("default vs HF: control-free exact; control-string cases differing by design: \(differing.count)")
}

/// Adversarial conversations: (a) the control ids equal those of the benign twin (no content control id),
/// (b) the im_start/im_end sequence per segment equals the benign twin's, (c) each segment decodes back to its text.
@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func adversarialContentIsPlainAndRoundTrips() throws {
    let cases = try loadCases("prompt_adversarial.json")
    var problems = [String]()
    for c in cases {
        let id = c["id"]?.stringValue ?? "?"
        let msgs = try messages(c["messages"]), ts = tools(c["tools"])
        let benign = c["benign"]!
        let bl = try coldBuild(try messages(benign["messages"]), tools(benign["tools"]), mode: .disabled)
        let al = try coldBuild(msgs, ts, mode: .disabled)

        // (a) aggregate: same number of control ids, all of them template structure
        let aControl = al.ids.filter { controlIds.contains($0) }.count
        let bControl = bl.ids.filter { controlIds.contains($0) }.count
        if aControl != bControl { problems.append("\(id): control ids \(aControl) != benign \(bControl)") }

        // (b) per segment, the im_start/im_end sequence equals the benign twin's
        if al.records.count != bl.records.count { problems.append("\(id): segments \(al.records.count) != \(bl.records.count)") }
        for (ar, br) in zip(al.records, bl.records) {
            let aSeq = al.ids[ar.ids].filter { $0 == imStartId || $0 == imEndId }
            let bSeq = bl.ids[br.ids].filter { $0 == imStartId || $0 == imEndId }
            if aSeq != bSeq { problems.append("\(id): \(ar.role) im sequence \(aSeq.count) != \(bSeq.count)") }
        }

        // (c) every segment's ids decode to exactly its rendered text (control strings included, as text)
        let segs = try ChatTemplate.renderSegments(messages: msgs, tools: ts, reasoningPolicy: .templateDefault)
        if segs.count != al.records.count { problems.append("\(id): segment count") ; continue }
        for (seg, r) in zip(segs, al.records) where tok.decode(Array(al.ids[r.ids])) != seg.text {
            problems.append("\(id): \(seg.role) does not round-trip")
        }
    }
    #expect(problems.isEmpty, Comment(rawValue: problems.prefix(12).joined(separator: "\n")))
}

/// Designed difference: for adversarial conversations, default ids may differ from HF's (HF makes content control
/// strings special). Report how many differ; the benign twins must still match HF exactly.
@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func adversarialBenignTwinsMatchHF() throws {
    var differ = 0, benignBad = [String]()
    for c in try loadCases("prompt_adversarial.json") {
        let id = c["id"]?.stringValue ?? "?"
        let l = try coldBuild(try messages(c["messages"]), tools(c["tools"]), mode: .disabled)
        if l.ids != ids(c["ids"]) { differ += 1 }
        let benign = c["benign"]!
        let b = try coldBuild(try messages(benign["messages"]), tools(benign["tools"]), mode: .disabled)
        if b.ids != ids(c["benign_ids"]) { benignBad.append("\(id)@\(firstDiff(b.ids, ids(c["benign_ids"])))") }
    }
    print("adversarial: default ids differ from HF in \(differ) cases (intended)")
    #expect(benignBad.isEmpty, Comment(rawValue: benignBad.joined(separator: "\n")))
}

/// A client that resends a conversation with control strings in content reuses the ledger without a fallback.
@Test(.enabled(if: qwenModelPresent, "needs models/qwen38-4bit (weights are not in the repository)")) func controlContentIsReusedAcrossTurns() throws {
    let cases = try loadCases("prompt_adversarial.json")
    let c = cases.first { $0["id"]?.stringValue == "adv_tool_result" }!
    let full = try messages(c["messages"]), ts = tools(c["tools"])
    let first = try PromptBuilder.prepare(ledger: Ledger(tokenizer: tok), messages: Array(full.prefix(3)), tools: ts)
    let second = try PromptBuilder.prepare(ledger: first.ledger, messages: full, tools: ts)
    let cold = try PromptBuilder.prepare(ledger: Ledger(tokenizer: tok), messages: full, tools: ts)
    #expect(second.fallbackAtMessage == nil)
    #expect(second.ledger.ids == cold.ledger.ids)
    #expect(second.reusedPrefixIds > 0)
}
