import Foundation
import StrimTemplate
import StrimTokenizer

/// How the ids of user-provided text are produced (see `PromptBuilder.prepare`).
public enum ContentSpecialTokens: Sendable {
    /// Default. Content (message text, reasoning, tool results, tool-call names and argument values, tool schemas)
    /// is tokenized with added-token matching off, so a control string inside content is plain text. Template
    /// markers stay special. Ids equal HF's unless content completes a control string with adjacent template text.
    case disabled
    /// HF behaviour: each segment's whole text is tokenized with specials on. Content control strings become
    /// control ids (forgeable turns and tool results). Kept for oracle comparisons.
    case hfCompat
}

/// A run of rendered text: template structure (control strings are matched) or user-provided content (never matched).
struct Region: Equatable {
    var text: String
    var isContent: Bool
}

/// Control strings the template emits as structure. All are Qwen added tokens (tokenizer.json).
let structuralSpecials = [
    "<|im_start|>", "<|im_end|>", "<think>", "</think>", "<tool_call>", "</tool_call>",
    "<tool_response>", "</tool_response>", "<|vision_start|>", "<|vision_end|>", "<|image_pad|>", "<|video_pad|>",
]

struct SpecialToken: Sendable {
    let bytes: [UInt8]
    let id: Int32
}

/// Ids of `structuralSpecials`, longest first (the tokenizer's matching order).
func structuralSpecialTable(_ tokenizer: Tokenizer) -> [SpecialToken] {
    structuralSpecials.map { s in
        let ids = tokenizer.encode(s)
        precondition(ids.count == 1, "\(s) must be a single added token")
        return SpecialToken(bytes: Array(s.utf8), id: ids[0])
    }.sorted { $0.bytes.count > $1.bytes.count }
}

/// Ids for rendered regions. Structural bytes are scanned for control strings; content bytes never are. Everything
/// between two structural controls is one plain stretch encoded in one call, so pre-tokenisation and BPE see the
/// same text as HF's joint encoding (merges across a region edge such as `=` + `get` are preserved).
func encodeRegions(_ regions: [Region], tokenizer: Tokenizer, table: [SpecialToken]) -> [Int32] {
    var out = [Int32]()
    var plain = [UInt8]()
    func flush() {
        if !plain.isEmpty {
            out += tokenizer.encode(String(decoding: plain, as: UTF8.self), allowSpecial: false)
            plain.removeAll(keepingCapacity: true)
        }
    }
    for r in regions {
        if r.isContent {
            plain += r.text.utf8
            continue
        }
        let b = Array(r.text.utf8)
        var i = 0
        scan: while i < b.count {
            for sp in table where i + sp.bytes.count <= b.count && b[i] == sp.bytes[0]
                && b[i..<i + sp.bytes.count].elementsEqual(sp.bytes) {
                flush()
                out.append(sp.id)
                i += sp.bytes.count
                continue scan
            }
            plain.append(b[i])
            i += 1
        }
    }
    flush()
    return out
}

/// Python `str.isspace()` for a scalar (what `str.strip()` and the template's `trim` remove).
func pySpace(_ u: Unicode.Scalar) -> Bool {
    switch u.value {
    case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
    default: return false
    }
}

/// Replaces every user-provided string of a conversation with a placeholder `M k M` (M: a private-use scalar that no
/// input contains, k: span index), so `ChatTemplate.renderSegments` renders the same structure over placeholders.
/// `restore` maps each placeholder back to its text, tagged as content.
///
/// The template's decisions that read content are kept: empty content stays empty (so `isEmpty` branches agree), and
/// the user-turn test for a lone `<tool_response>` wrapper is answered by carrying the wrapper literally in the
/// placeholder, which `restore` strips again. Template text itself is never placeholdered.
struct ContentSentinels {
    enum Piece: Equatable {
        case content(String)
        case structure(String)
    }

    struct Span {
        var pieces: [Piece]
        var prefix: String
        var suffix: String
    }

    private let marker: Unicode.Scalar
    private var markerString: String { String(Character(marker)) }
    private(set) var spans = [Span]()
    /// Set when an input string already contains `marker`; `encode` then retries with the next private-use scalar.
    private(set) var collision = false

    private init(marker: Unicode.Scalar) { self.marker = marker }

    /// Sentinel form of a conversation and its tools. Throws what the template would throw for the same input.
    static func encode(messages: [Message], tools: [ToolSpec]) throws -> (messages: [Message], tools: [ToolSpec], sentinels: ContentSentinels) {
        var scalar: UInt32 = 0xE000
        while true {
            var s = ContentSentinels(marker: Unicode.Scalar(scalar)!)
            let ms = try s.sentinelMessages(messages)
            var ts = [ToolSpec]()
            for t in tools { ts.append(ToolSpec(json: s.sentinelJSON(t.json))) }
            if !s.collision { return (ms, ts, s) }
            scalar += 1
            guard scalar <= 0xF8FF else { throw TemplateError("content uses every private-use code point") }
        }
    }

    /// Regions of one rendered segment: placeholders become content regions, everything else structure.
    func restore(_ rendered: String) throws -> [Region] {
        let u = Array(rendered.unicodeScalars)
        var out = [Region]()
        var buf = String.UnicodeScalarView()
        func flush() {
            if !buf.isEmpty {
                out.append(Region(text: String(buf), isContent: false))
                buf = String.UnicodeScalarView()
            }
        }
        var i = 0
        while i < u.count {
            guard u[i] == marker else {
                buf.append(u[i])
                i += 1
                continue
            }
            var j = i + 1
            var digits = String.UnicodeScalarView()
            while j < u.count, u[j] != marker {
                digits.append(u[j])
                j += 1
            }
            guard j < u.count, let k = Int(String(digits)), spans.indices.contains(k) else {
                throw TemplateError("prompt placeholder corrupted")
            }
            let span = spans[k]
            if !span.prefix.isEmpty {
                let p = span.prefix.unicodeScalars
                guard buf.count >= p.count, buf.suffix(p.count).elementsEqual(p) else { throw TemplateError("prompt placeholder corrupted") }
                buf.removeLast(p.count)
            }
            flush()
            for piece in span.pieces {
                switch piece {
                case let .content(s): if !s.isEmpty { out.append(Region(text: s, isContent: true)) }
                case let .structure(s): if !s.isEmpty { out.append(Region(text: s, isContent: false)) }
                }
            }
            i = j + 1
            if !span.suffix.isEmpty {
                let q = span.suffix.unicodeScalars
                guard u.count - i >= q.count, u[i..<i + q.count].elementsEqual(q) else { throw TemplateError("prompt placeholder corrupted") }
                i += q.count
            }
        }
        flush()
        return out
    }

    // MARK: sentinel construction

    /// Placeholder for `pieces`; empty content yields "" (the template then sees an empty string, as before).
    private mutating func placeholder(_ pieces: [Piece], prefix: String = "", suffix: String = "", always: Bool = false) -> String {
        var empty = true
        for p in pieces {
            switch p {
            case let .content(s), let .structure(s):
                if s.unicodeScalars.contains(marker) { collision = true }
                if !s.isEmpty { empty = false }
            }
        }
        if empty && !always { return "" }
        spans.append(Span(pieces: pieces, prefix: prefix, suffix: suffix))
        return prefix + markerString + String(spans.count - 1) + markerString + suffix
    }

    /// The template's `render_content` as pieces, with its validation (same errors, same order).
    static func contentPieces(_ c: MessageContent, isSystem: Bool) throws -> [Piece] {
        switch c {
        case .none: return []
        case let .text(s): return [.content(s)]
        case let .parts(items):
            var out = [Piece]()
            for item in items {
                guard case .object = item else { throw TemplateError("Unexpected item type in content.") }
                let type = item["type"]?.stringValue
                if item["image"] != nil || item["image_url"] != nil || type == "image" {
                    if isSystem { throw TemplateError("System message cannot contain images.") }
                    out.append(.structure("<|vision_start|><|image_pad|><|vision_end|>"))
                } else if item["video"] != nil || type == "video" {
                    if isSystem { throw TemplateError("System message cannot contain videos.") }
                    out.append(.structure("<|vision_start|><|video_pad|><|vision_end|>"))
                } else if let text = item["text"] {
                    guard case let .string(s) = text else { throw TemplateError("non-string text part") }
                    out.append(.content(s))
                } else {
                    throw TemplateError("Unexpected item type in content.")
                }
            }
            return out
        }
    }

    /// Python `strip()` over pieces: leading and trailing whitespace of the joined text.
    static func trimmed(_ pieces: [Piece]) -> [Piece] {
        var out = pieces
        while let first = out.first, case let .content(s) = first {
            let u = s.unicodeScalars
            let a = u.firstIndex(where: { !pySpace($0) }) ?? u.endIndex
            if a == u.endIndex { out.removeFirst() } else { out[0] = .content(String(u[a...])); break }
        }
        while let last = out.last, case let .content(s) = last {
            let u = s.unicodeScalars
            if let b = u.lastIndex(where: { !pySpace($0) }) {
                out[out.count - 1] = .content(String(u[...b]))
                break
            }
            out.removeLast()
        }
        return out
    }

    static func joined(_ pieces: [Piece]) -> String {
        var s = ""
        for p in pieces {
            switch p {
            case let .content(x), let .structure(x): s += x
            }
        }
        return s
    }

    private mutating func sentinelMessages(_ messages: [Message]) throws -> [Message] {
        guard !messages.isEmpty else { return messages }  // the template throws "No messages provided."
        var pieces = [[Piece]]()
        for m in messages { pieces.append(try Self.contentPieces(m.content, isSystem: false)) }
        if messages[0].role == .system { _ = try Self.contentPieces(messages[0].content, isSystem: true) }
        var out = [Message]()
        for (i, m) in messages.enumerated() {
            var x = m
            let body = Self.trimmed(pieces[i])
            let real = Self.joined(body).unicodeScalars
            let wrap = m.role == .user && real.starts(with: "<tool_response>".unicodeScalars)
                && real.reversed().starts(with: "</tool_response>".unicodeScalars.reversed())
            x.content = .text(placeholder(body, prefix: wrap ? "<tool_response>" : "", suffix: wrap ? "</tool_response>" : ""))
            if let r = m.reasoningContent {
                x.reasoningContent = placeholder(Self.trimmed([.content(r)]))
            }
            var calls = [ToolCall]()
            for call in m.toolCalls {
                var c = call
                c.name = placeholder([.content(call.name)])
                if let args = call.arguments {
                    var newArgs = [OrderedJSON.Member]()
                    for arg in args {
                        let value: OrderedJSON
                        if case let .string(v) = arg.value {
                            value = .string(placeholder([.content(v)]))
                        } else {
                            value = .string(placeholder([.content(arg.value.serialized())]))
                        }
                        newArgs.append(OrderedJSON.Member(placeholder([.content(arg.key)]), value))
                    }
                    c.arguments = newArgs
                }
                calls.append(c)
            }
            x.toolCalls = calls
            out.append(x)
        }
        return out
    }

    /// Inside a JSON document, every string (values and keys) becomes a placeholder; the serializer supplies the
    /// quotes, and `restore` supplies the JSON-escaped text.
    private mutating func sentinelJSON(_ j: OrderedJSON) -> OrderedJSON {
        switch j {
        case let .string(s): return .string(placeholder([.content(Self.jsonInner(s))], always: true))
        case let .bigInt(s): return .bigInt(placeholder([.content(s)], always: true))
        case let .object(ms):
            var out = [OrderedJSON.Member]()
            for m in ms {
                out.append(OrderedJSON.Member(placeholder([.content(Self.jsonInner(m.key))], always: true), sentinelJSON(m.value)))
            }
            return .object(out)
        case let .array(items):
            var out = [OrderedJSON]()
            for x in items { out.append(sentinelJSON(x)) }
            return .array(out)
        default: return j
        }
    }

    /// The text `OrderedJSON` writes between the quotes of a string (escapes applied).
    static func jsonInner(_ s: String) -> String {
        String(OrderedJSON.string(s).serialized().dropFirst().dropLast())
    }
}
