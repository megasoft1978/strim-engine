import Foundation
import XCTest
@testable import StrimPrompt
import StrimTemplate
import StrimTokenizer

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

private struct TextCase: Decodable { let name: String; let text: String?; let ids: [Int32] }
private struct TextFixture: Decodable { let encode: [TextCase] }

final class TokenizeToolTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("models/qwen38-4bit/tokenizer.json").path),
                          "needs models/qwen38-4bit (weights are not in the repository)")
    }

    static let tok: Tokenizer = try! Tokenizer.load(modelDir: repoRoot.appendingPathComponent("models/qwen38-4bit").path)

    /// `strim tokenize --text` path: every encode case of the committed tokenizer parity fixture.
    func testTextIdsMatchParityFixture() throws {
        let d = try Data(contentsOf: repoRoot.appendingPathComponent("bench/fixtures/tokenizer_parity.json"))
        let fx = try JSONDecoder().decode(TextFixture.self, from: d)
        XCTAssertFalse(fx.encode.isEmpty)
        var bad: [String] = []
        for c in fx.encode where TokenizeTool.textIds(c.text ?? "", tokenizer: Self.tok) != c.ids {
            bad.append(c.name)
        }
        XCTAssertTrue(bad.isEmpty, "mismatches: \(bad.prefix(20))")
    }

    /// `strim tokenize --chat` path: fresh prompts from the committed prompt parity fixture (no session, no
    /// reasoning or tool-choice overrides), compared against its ids.
    func testChatIdsMatchPromptParityFixture() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("bench/fixtures/prompt_parity.json"), encoding: .utf8)
        guard case let .array(cases) = try OrderedJSON.parse(text) else { return XCTFail("fixture is not an array") }
        var checked = 0
        var bad: [String] = []
        for c in cases {
            guard c["session"] == nil, c["enable_thinking"] == nil, c["policy"] == nil, c["tool_choice"] == nil,
                  c["reasoning_effort"] == nil, c["preserve_thinking"] == nil, c["add_generation_prompt"] != .bool(false),
                  case let .array(ms)? = c["messages"], case let .array(raw)? = c["ids"] else { continue }
            let want = raw.map { v -> Int32 in if case let .int(i) = v { return Int32(i) } else { return -1 } }
            let messages = try ms.map { try Message(json: $0) }
            var tools: [ToolSpec] = []
            if case let .array(t)? = c["tools"] { tools = t.map { ToolSpec(json: $0) } }
            let got = try TokenizeTool.chatIds(messages: messages, tools: tools, tokenizer: Self.tok)
            if got != want { bad.append(c["id"]?.stringValue ?? "?") }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertTrue(bad.isEmpty, "mismatches: \(bad.prefix(20))")
    }

    /// The object form `{"messages":[...],"tools":[...]}` and the bare array give the same prompt.
    func testChatInputForms() throws {
        let msgs = #"[{"role":"system","content":"sys"},{"role":"user","content":"hi"}]"#
        let arrayForm = try TokenizeTool.chatInput(json: msgs)
        let objectForm = try TokenizeTool.chatInput(json: #"{"messages":\#(msgs),"tools":[]}"#)
        XCTAssertEqual(arrayForm.messages, objectForm.messages)
        XCTAssertTrue(objectForm.tools.isEmpty)
        let a = try TokenizeTool.chatIds(messages: arrayForm.messages, tokenizer: Self.tok)
        let b = try TokenizeTool.chatIds(messages: objectForm.messages, tokenizer: Self.tok)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, Self.tok.encode(try ChatTemplate.render(messages: arrayForm.messages)))
    }

    func testChatInputRejectsBadShapes() {
        XCTAssertThrowsError(try TokenizeTool.chatInput(json: #"{"tools":[]}"#))
        XCTAssertThrowsError(try TokenizeTool.chatInput(json: #""hi""#))
        XCTAssertThrowsError(try TokenizeTool.chatInput(json: #"[{"role":"bogus","content":"x"}]"#))
    }
}
