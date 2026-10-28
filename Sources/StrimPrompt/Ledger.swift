import Foundation
import StrimTemplate
import StrimTokenizer

public func fnv64(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

public enum LedgerError: Error, CustomStringConvertible {
    case noGenerationPrompt
    case unexpectedTokenization(String)
    public var description: String {
        switch self {
        case .noGenerationPrompt: return "appendGenerated needs a trailing generation_prompt segment (call PromptBuilder.prepare first)"
        case let .unexpectedTokenization(s): return s
        }
    }
}

/// Per-conversation record of the exact token ids the engine has seen, split into segments that mirror
/// `ChatTemplate.renderSegments`. Generated assistant turns keep the ids the model produced (not a re-render).
public struct Ledger: Sendable {
    public enum Origin: Sendable { case rendered, generated }

    public struct Record: Sendable {
        public var role: String
        /// Message indices this segment covers (empty for a synthesised header / generation prompt).
        public var messages: Range<Int>
        /// rendered: fnv64 of the segment text. generated: `PromptBuilder.messageKey` of the assistant message.
        public var hash: UInt64
        public var ids: Range<Int>
        public var origin: Origin
        /// generated only: trimmed reasoning the model produced (match rule: client may drop it).
        public var reasoning: String?
        /// false for a generation cut off before <|im_end|>; such a record is never reused.
        public var complete: Bool
    }

    public private(set) var ids: [Int32] = []
    public private(set) var records: [Record] = []
    public let tokenizer: Tokenizer
    public let imEndId: Int32
    /// id of the "\n" that the template emits after <|im_end|> (looked up, not hardcoded).
    public let newlineId: Int32
    let structuralTable: [SpecialToken]

    public init(tokenizer: Tokenizer) {
        self.tokenizer = tokenizer
        let t = tokenizer.encode(ChatTemplate.imEnd + "\n")
        precondition(t.count == 2, "<|im_end|>\\n must encode to exactly two ids")
        imEndId = t[0]
        newlineId = t[1]
        structuralTable = structuralSpecialTable(tokenizer)
    }

    /// Tokenizes `text` with specials parsed everywhere (HF behaviour) and stores it as one rendered segment.
    /// Segment text must start at a special-token boundary (<|im_start|>) for the split to equal a joint tokenization.
    public mutating func append(segmentRenderedText text: String, role: String, messages: Range<Int>) {
        append(regions: [Region(text: text, isContent: false)], role: role, messages: messages, mode: .hfCompat)
    }

    /// Stores one rendered segment given as regions (see `ContentSentinels.restore`). `mode` picks how content
    /// regions are tokenized; the record hash is always fnv64 of the full rendered text.
    mutating func append(regions: [Region], role: String, messages: Range<Int>, mode: ContentSpecialTokens) {
        let text = regions.map(\.text).joined()
        let new = mode == .hfCompat ? tokenizer.encode(text) : encodeRegions(regions, tokenizer: tokenizer, table: structuralTable)
        let start = ids.count
        ids += new
        records.append(Record(role: role, messages: messages, hash: fnv64(text), ids: start..<ids.count,
                              origin: .rendered, reasoning: nil, complete: true))
    }

    /// Message count covered by the ledger (generation prompt excluded).
    public var messageCount: Int { records.last(where: { $0.role != "generation_prompt" })?.messages.upperBound ?? 0 }

    public var endsWithGenerationPrompt: Bool { records.last?.role == "generation_prompt" }

    /// Stores the model's output verbatim after the trailing generation prompt, as one assistant segment.
    /// `message` is the assistant message the server derived from it (used to match the client's resend).
    /// If `finishedWithImEnd`, <|im_end|> is appended when `ids` lacks it, then the template's "\n" id, so the
    /// ledger equals a render structurally. Otherwise the record is incomplete and is not reused later.
    public mutating func appendGenerated(ids generated: [Int32], finishedWithImEnd: Bool, message: Message) throws {
        guard let gp = records.last, gp.role == "generation_prompt" else { throw LedgerError.noGenerationPrompt }
        var g = generated
        if finishedWithImEnd {
            if g.last != imEndId { g.append(imEndId) }
            g.append(newlineId)
        }
        records.removeLast()
        let n = gp.messages.lowerBound
        ids += g
        records.append(Record(role: "assistant", messages: n..<n + 1, hash: PromptBuilder.messageKey(message),
                              ids: gp.ids.lowerBound..<ids.count, origin: .generated,
                              reasoning: PromptBuilder.normalizedReasoning(message), complete: finishedWithImEnd))
    }

    /// Keeps only segments fully inside the first `messageCount` messages (drops the generation prompt).
    public mutating func truncate(to messageCount: Int) {
        var keep = records.count
        while keep > 0 {
            let r = records[keep - 1]
            if r.role == "generation_prompt" || r.messages.upperBound > messageCount { keep -= 1 } else { break }
        }
        truncateRecords(to: keep)
    }

    mutating func truncateRecords(to n: Int) {
        guard n < records.count else { return }
        let end = n == 0 ? 0 : records[n - 1].ids.upperBound
        records.removeLast(records.count - n)
        ids.removeLast(ids.count - end)
    }

    /// Independent copy (value semantics): branch a conversation without disturbing the original.
    public func fork() -> Ledger { self }
}
