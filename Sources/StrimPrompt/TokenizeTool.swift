import Foundation
import StrimTemplate
import StrimTokenizer

/// Backs `strim tokenize`. Chat input is tokenized as the engine builds a fresh prompt: `PromptBuilder.prepare`
/// over an empty ledger, so user text that contains control strings is tokenized as plain text.
public enum TokenizeTool {
    /// Plain text: specials that appear in the text are recognised (HF behaviour); no chat template.
    public static func textIds(_ text: String, tokenizer: Tokenizer) -> [Int32] {
        tokenizer.encode(text)
    }

    /// A JSON array of OpenAI-style messages, or an object with `messages` and optional `tools`.
    public static func chatInput(json text: String) throws -> (messages: [Message], tools: [ToolSpec]) {
        let root = try OrderedJSON.parse(text)
        var messageJSON: [OrderedJSON]
        var toolJSON: [OrderedJSON] = []
        switch root {
        case let .array(a):
            messageJSON = a
        case .object:
            guard case let .array(a)? = root["messages"] else {
                throw TemplateError("chat input object needs a \"messages\" array")
            }
            messageJSON = a
            if case let .array(t)? = root["tools"] { toolJSON = t }
        default:
            throw TemplateError("chat input must be an array of messages or an object with \"messages\"")
        }
        return (try messageJSON.map { try Message(json: $0) }, toolJSON.map { ToolSpec(json: $0) })
    }

    /// Ids of the rendered chat prompt, generation prompt included: the template applied as shipped (no request
    /// overrides, `templateDefault`) and tokenized as HF does (`hfCompat`), the reference the benches used.
    /// The engine's own default (`contentSpecialTokens: .disabled`) differs only for content with control strings.
    public static func chatIds(messages: [Message], tools: [ToolSpec] = [], tokenizer: Tokenizer) throws -> [Int32] {
        try PromptBuilder.prepare(ledger: Ledger(tokenizer: tokenizer), messages: messages, tools: tools,
                                  reasoningPolicy: .templateDefault, contentSpecialTokens: .hfCompat).newIds
    }
}
