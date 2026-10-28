import Foundation
import StrimTemplate
import StrimTokenizer

public struct PreparedPrompt: Sendable {
    public var ledger: Ledger
    /// Ids not covered by the previous ledger prefix (suffix to prefill), including the generation prompt.
    public var newIds: [Int32]
    /// Length of the ledger prefix reused verbatim.
    public var reusedPrefixIds: Int
    public var reusedSegments: Int
    public var totalSegments: Int
    /// First message index where a previously recorded segment no longer matched (client edited/compacted history).
    public var fallbackAtMessage: Int?
    public var reuseRatio: Double { ledger.ids.isEmpty ? 0 : Double(reusedPrefixIds) / Double(ledger.ids.count) }
}

public enum PromptBuilder {
    /// Reconciles a full client message list against `ledger`. The text is always rendered (cheap); only
    /// segments after the longest matching ledger prefix are tokenized. Rendered-origin records match on the
    /// rendered text; generated-origin assistant records match on role + trimmed content + tool_calls
    /// (canonical, key-sorted JSON), with reasoning optional (see `reasoningMatches`).
    ///
    /// `contentSpecialTokens`: `.disabled` (default) tokenizes user-provided text with control strings as plain
    /// text, so content cannot forge turns or tool results; `.hfCompat` reproduces HF's ids for such content.
    public static func prepare(
        ledger: Ledger,
        messages: [Message],
        tools: [ToolSpec] = [],
        reasoningPolicy: ReasoningPolicy = .disableWhenTools,
        enableThinking: Bool? = nil,
        addGenerationPrompt: Bool = true,
        toolChoice: String? = nil,
        reasoningEffort: String? = nil,
        preserveThinking: Bool? = nil,
        contentSpecialTokens: ContentSpecialTokens = .disabled
    ) throws -> PreparedPrompt {
        // Render over placeholders for every user-provided string; `restore` yields each segment's text as regions.
        let sentinel = try ContentSentinels.encode(messages: messages, tools: tools)
        let segs = try ChatTemplate.renderSegments(
            messages: sentinel.messages, tools: sentinel.tools, addGenerationPrompt: addGenerationPrompt,
            enableThinking: enableThinking, reasoningPolicy: reasoningPolicy, toolChoice: toolChoice,
            reasoningEffort: reasoningEffort, preserveThinking: preserveThinking)
        // Group segments so each group starts at <|im_start|>; a segment that does not (a tool block as the very
        // first message) is fused with its predecessor, because splitting there would not equal joint tokenization.
        struct Group { var role: String; var text: String; var regions: [Region]; var messages: Range<Int> }
        var groups = [Group]()
        for s in segs {
            let regions = try sentinel.sentinels.restore(s.text)
            let text = regions.map(\.text).joined()
            if s.role != "generation_prompt", !text.hasPrefix(ChatTemplate.imStart), var last = groups.popLast() {
                last.text += text
                last.regions += regions
                last.messages = min(last.messages.lowerBound, s.messages.lowerBound)..<max(last.messages.upperBound, s.messages.upperBound)
                groups.append(last)
            } else {
                groups.append(Group(role: s.role, text: text, regions: regions, messages: s.messages))
            }
        }
        let gen = groups.last?.role == "generation_prompt" ? groups.removeLast() : nil

        var work = ledger
        if work.endsWithGenerationPrompt { work.truncateRecords(to: work.records.count - 1) }
        var matched = 0
        var fallback: Int?
        while matched < groups.count, matched < work.records.count {
            if recordMatches(work.records[matched], groups[matched].role, groups[matched].text, groups[matched].messages, messages) {
                matched += 1
            } else {
                fallback = work.records[matched].messages.lowerBound
                break
            }
        }
        if fallback == nil, work.records.count > matched, matched == groups.count {
            fallback = groups.last?.messages.upperBound  // ledger held more turns than the client resent
        }
        work.truncateRecords(to: matched)
        let reused = work.ids.count
        for g in groups[matched...] {
            work.append(regions: g.regions, role: g.role, messages: g.messages, mode: contentSpecialTokens)
        }
        if let gen { work.append(regions: gen.regions, role: gen.role, messages: gen.messages, mode: contentSpecialTokens) }
        return PreparedPrompt(
            ledger: work, newIds: Array(work.ids[reused...]), reusedPrefixIds: reused, reusedSegments: matched,
            totalSegments: groups.count + (gen == nil ? 0 : 1), fallbackAtMessage: fallback)
    }

    static func recordMatches(_ r: Ledger.Record, _ role: String, _ text: String, _ range: Range<Int>, _ messages: [Message]) -> Bool {
        guard r.complete, r.role == role, r.messages == range else { return false }
        switch r.origin {
        case .rendered:
            return r.hash == fnv64(text)
        case .generated:
            guard role == "assistant", range.count == 1, range.lowerBound < messages.count else { return false }
            let m = messages[range.lowerBound]
            return r.hash == messageKey(m) && reasoningMatches(stored: r.reasoning, client: normalizedReasoning(m))
        }
    }

    /// Reasoning match rule: a client that drops reasoning_content (nil or blank) still matches; a client that
    /// sends reasoning must send what was generated (trimmed).
    static func reasoningMatches(stored: String?, client: String?) -> Bool {
        guard let c = client, !c.isEmpty else { return true }
        return c == (stored ?? "")
    }

    // MARK: message normalisation

    /// Hash of role + template-normalised content + canonical tool calls. Reasoning is deliberately excluded.
    public static func messageKey(_ m: Message) -> UInt64 {
        var s = m.role.rawValue + "\u{1}" + normalizedContent(m.content)
        for c in m.toolCalls {
            s += "\u{2}" + c.name + "\u{3}"
            s += canonical(.object(c.arguments ?? []))
        }
        return fnv64(s)
    }

    public static func normalizedReasoning(_ m: Message) -> String? { m.reasoningContent.map(pyTrim) }

    static func normalizedContent(_ c: MessageContent) -> String {
        switch c {
        case .none: return ""
        case let .text(s): return pyTrim(s)
        case let .parts(items):
            var out = ""
            for item in items {
                let type = item["type"]?.stringValue
                if item["image"] != nil || item["image_url"] != nil || type == "image" { out += "\u{0}img" }
                else if item["video"] != nil || type == "video" { out += "\u{0}vid" }
                else if case let .string(t)? = item["text"] { out += t }
            }
            return pyTrim(out)
        }
    }

    /// Key-sorted compact JSON so a client that reorders argument keys still matches.
    static func canonical(_ j: OrderedJSON) -> String {
        switch j {
        case let .object(ms):
            return "{" + ms.sorted { $0.key < $1.key }.map { fnvEscape($0.key) + ":" + canonical($0.value) }.joined(separator: ",") + "}"
        case let .array(a):
            return "[" + a.map(canonical).joined(separator: ",") + "]"
        default:
            return j.serialized()
        }
    }

    private static func fnvEscape(_ s: String) -> String { OrderedJSON.string(s).serialized() }

    private static func pyTrim(_ s: String) -> String {
        let u = s.unicodeScalars
        guard let a = u.firstIndex(where: { !pySpace($0) }), let b = u.lastIndex(where: { !pySpace($0) }) else { return "" }
        return String(u[a...b])
    }
}
