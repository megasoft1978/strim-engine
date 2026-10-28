import Foundation

public enum ParserEvent: Equatable, Sendable {
    case text(String)
    case reasoning(String)
    case toolCallBegin(name: String)
    /// Emitted when a `<parameter=KEY>` block closes; value typed per the tool schema.
    case toolCallArg(key: String, value: OrderedJSON)
    case toolCallEnd
}

extension Array where Element == ParserEvent {
    /// Merges adjacent text / adjacent reasoning events. Chunking may split text events at arbitrary
    /// points; the merged sequence is chunking-invariant.
    public func coalesced() -> [ParserEvent] {
        var out = [ParserEvent]()
        for e in self {
            switch (out.last, e) {
            case let (.text(a)?, .text(b)): out[out.count - 1] = .text(a + b)
            case let (.reasoning(a)?, .reasoning(b)): out[out.count - 1] = .reasoning(a + b)
            default: out.append(e)
            }
        }
        return out
    }
}

/// Streaming parser for Qwen3.8 output:
///
///     [<think>]reasoning</think>\n\ntext\n\n<tool_call>\n<function=NAME>\n<parameter=KEY>\nVALUE\n</parameter>\n</function>\n</tool_call>
///
/// - `feed` accepts arbitrary chunk splits; after `coalesced()` the events equal those of the unsplit text.
/// - Reasoning routing: starts in reasoning when the prompt ended `<think>\n` (`startsInReasoning`), or when the
///   output itself begins with `<think>`. Leading whitespace of reasoning/content is dropped, whitespace
///   right before a tool call is dropped, trailing content whitespace is held until more text or `finish()`.
/// - A `<tool_call>` not followed by `<function=NAME>` is passed through as text.
/// - Once `<function=NAME>` is seen, `toolCallBegin` is emitted and events stream; garbage between tags is
///   dropped, a missing `</function>` is tolerated, a parameter cut off by end of stream is dropped.
/// - A `</parameter>` only closes a value when followed (modulo whitespace) by `<parameter=`, `</function>` or
///   `</tool_call>`, so values may contain a literal `</parameter>`.
/// - Values: string-typed params stay raw strings (the template renders strings raw); other types are
///   JSON-decoded (null/int/number/boolean/object/array), undeclared or untyped params try JSON then fall back
///   to the raw string, as rapid-mlx's qwen3 parser does. Unlike rapid, a JSON-quoted string for a string param
///   is NOT unquoted (keeps template round-trips exact) and an invalid boolean stays a string.
public struct ToolCallParser {
    private enum State {
        case reasoning
        case content
        case toolHead(inEnvelope: Bool)  // after `<tool_call>` (false) or after `</function>` (true), expecting `<function=`
        case funcBody
        case paramValue(key: String)
    }

    private static let thinkOpen = Array("<think>".unicodeScalars)
    private static let thinkClose = Array("</think>".unicodeScalars)
    private static let toolOpen = Array("<tool_call>".unicodeScalars)
    private static let toolClose = Array("</tool_call>".unicodeScalars)
    private static let funcOpen = Array("<function=".unicodeScalars)
    private static let funcClose = Array("</function>".unicodeScalars)
    private static let paramOpen = Array("<parameter=".unicodeScalars)
    private static let paramClose = Array("</parameter>".unicodeScalars)

    private var schemas: [String: OrderedJSON] = [:]
    private let detectTools: Bool
    private var state: State
    private var buf: [Unicode.Scalar] = []
    private var pos = 0
    private var started = false
    private var lead = true
    private var pendingWS = ""
    private var toolLead = ""
    private var scanFrom = 0
    private var currentFunction = ""
    public private(set) var toolCallCount = 0

    /// - Parameter startsInReasoning: true when the rendered prompt ended with `<think>\n` (thinking on).
    public init(tools: [ToolSpec] = [], startsInReasoning: Bool = false) {
        for t in tools { if let n = t.name { schemas[n] = t.parameters ?? .null } }
        detectTools = !tools.isEmpty
        state = startsInReasoning ? .reasoning : .content
    }

    /// True when the prompt leaves the model inside an open `<think>` block.
    public static func promptOpensReasoning(_ prompt: String) -> Bool {
        prompt.unicodeScalars.reversed().starts(with: "<think>\n".unicodeScalars.reversed())
    }

    public mutating func feed(_ chunk: String) -> [ParserEvent] {
        buf.append(contentsOf: chunk.unicodeScalars)
        var out = [ParserEvent]()
        drain(&out, final: false)
        compact()
        return out
    }

    /// End of stream: flushes held text, closes an open tool call.
    public mutating func finish() -> [ParserEvent] {
        var out = [ParserEvent]()
        drain(&out, final: true)
        switch state {
        case .funcBody, .paramValue:
            out.append(.toolCallEnd)
            toolCallCount += 1
        default: break
        }
        state = .content
        if !pendingWS.isEmpty {
            out.append(.text(pendingWS))
            pendingWS = ""
        }
        buf.removeAll()
        pos = 0
        return out
    }

    // MARK: engine

    private mutating func compact() {
        if pos > 4096 && pos * 2 > buf.count {
            buf.removeFirst(pos)
            pos = 0
        }
    }

    private func rest(_ from: Int, _ to: Int) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: buf[from..<to])
        return String(v)
    }

    private func find(_ tag: [Unicode.Scalar], from: Int) -> Int? {
        let n = tag.count
        guard buf.count - n >= from else { return nil }
        var i = from
        let last = buf.count - n
        while i <= last {
            if buf[i] == tag[0] {
                var k = 1
                while k < n, buf[i + k] == tag[k] { k += 1 }
                if k == n { return i }
            }
            i += 1
        }
        return nil
    }

    private func hasTag(_ tag: [Unicode.Scalar], at i: Int) -> Bool {
        guard buf.count - i >= tag.count else { return false }
        for k in 0..<tag.count where buf[i + k] != tag[k] { return false }
        return true
    }

    /// buf[i...] is a (shorter) proper prefix of `tag`.
    private func isPartial(_ tag: [Unicode.Scalar], at i: Int) -> Bool {
        let n = buf.count - i
        guard n < tag.count else { return false }
        for k in 0..<n where buf[i + k] != tag[k] { return false }
        return true
    }

    /// Longest proper prefix of `tag` that the buffer ends with (from `pos`).
    private func partialSuffix(_ tag: [Unicode.Scalar]) -> Int {
        var k = min(tag.count - 1, buf.count - pos)
        while k > 0 {
            var ok = true
            for j in 0..<k where buf[buf.count - k + j] != tag[j] { ok = false; break }
            if ok { return k }
            k -= 1
        }
        return 0
    }

    private func skipWS(_ i: Int) -> Int {
        var j = i
        while j < buf.count, isPySpace(buf[j]) { j += 1 }
        return j
    }

    private mutating func drain(_ out: inout [ParserEvent], final: Bool) {
        if !started {
            let j = skipWS(pos)
            pos = j
            if j >= buf.count { return }
            if !final, isPartial(Self.thinkOpen, at: j) { return }
            started = true
            if hasTag(Self.thinkOpen, at: j) {
                state = .reasoning
                pos = j + Self.thinkOpen.count
            }
        }
        while true {
            switch state {
            case .reasoning:
                if let i = find(Self.thinkClose, from: pos) {
                    emitReasoning(rest(pos, i), &out)
                    pos = i + Self.thinkClose.count
                    state = .content
                    lead = true
                    continue
                }
                let cut = buf.count - (final ? 0 : partialSuffix(Self.thinkClose))
                emitReasoning(rest(pos, cut), &out)
                pos = cut
                return

            case .content:
                if !detectTools {
                    emitContent(rest(pos, buf.count), &out)
                    pos = buf.count
                    return
                }
                if let i = find(Self.toolOpen, from: pos) {
                    emitContent(rest(pos, i), &out)
                    toolLead = pendingWS
                    pendingWS = ""
                    pos = i + Self.toolOpen.count
                    state = .toolHead(inEnvelope: false)
                    continue
                }
                let cut = buf.count - (final ? 0 : partialSuffix(Self.toolOpen))
                emitContent(rest(pos, cut), &out)
                pos = cut
                return

            case let .toolHead(inEnvelope):
                let j = skipWS(pos)
                if inEnvelope, hasTag(Self.toolClose, at: j) {
                    pos = j + Self.toolClose.count
                    state = .content
                    continue
                }
                if hasTag(Self.funcOpen, at: j) {
                    // name up to '>'
                    var k = j + Self.funcOpen.count
                    var bad = false
                    while k < buf.count, buf[k] != ">" {
                        if buf[k] == "<" || buf[k] == "\n" || k - j > 300 { bad = true; break }
                        k += 1
                    }
                    if !bad, k < buf.count {
                        let name = pyTrim(rest(j + Self.funcOpen.count, k))
                        if !name.isEmpty {
                            pos = k + 1
                            toolLead = ""
                            currentFunction = name
                            out.append(.toolCallBegin(name: name))
                            state = .funcBody
                            continue
                        }
                        bad = true
                    }
                    if !bad && !final { return }  // name not complete yet
                    reject(inEnvelope, &out)
                    continue
                }
                if !final, j >= buf.count || isPartial(Self.funcOpen, at: j) || (inEnvelope && isPartial(Self.toolClose, at: j)) {
                    return
                }
                reject(inEnvelope, &out)
                continue

            case .funcBody:
                let j = skipWS(pos)
                if j >= buf.count {
                    pos = j
                    return
                }
                if hasTag(Self.paramOpen, at: j) {
                    var k = j + Self.paramOpen.count
                    var bad = false
                    while k < buf.count, buf[k] != ">" {
                        if buf[k] == "<" || buf[k] == "\n" || k - j > 300 { bad = true; break }
                        k += 1
                    }
                    if !bad, k < buf.count {
                        let key = rest(j + Self.paramOpen.count, k)
                        pos = k + 1
                        scanFrom = pos
                        state = .paramValue(key: key)
                        continue
                    }
                    if !bad && !final { pos = j; return }
                    pos = j + 1  // garbage '<'
                    continue
                }
                if hasTag(Self.funcClose, at: j) {
                    pos = j + Self.funcClose.count
                    out.append(.toolCallEnd)
                    toolCallCount += 1
                    state = .toolHead(inEnvelope: true)
                    continue
                }
                if hasTag(Self.toolClose, at: j) {
                    pos = j + Self.toolClose.count
                    out.append(.toolCallEnd)
                    toolCallCount += 1
                    state = .content
                    continue
                }
                if !final, isPartial(Self.paramOpen, at: j) || isPartial(Self.funcClose, at: j) || isPartial(Self.toolClose, at: j) {
                    pos = j
                    return
                }
                // garbage: drop up to the next '<'
                var k = j + 1
                while k < buf.count, buf[k] != "<" { k += 1 }
                pos = k
                continue

            case let .paramValue(key):
                var from = max(scanFrom, pos)
                var closed: (end: Int, next: Int)?
                var unresolved: Int?
                while let i = find(Self.paramClose, from: from) {
                    let after = skipWS(i + Self.paramClose.count)
                    if after >= buf.count {
                        if final { closed = (i, i + Self.paramClose.count) } else { unresolved = i }
                        break  // need lookahead
                    }
                    if hasTag(Self.paramOpen, at: after) || hasTag(Self.funcClose, at: after) || hasTag(Self.toolClose, at: after) {
                        closed = (i, i + Self.paramClose.count)
                        break
                    }
                    if !final, isPartial(Self.paramOpen, at: after) || isPartial(Self.funcClose, at: after) || isPartial(Self.toolClose, at: after) {
                        unresolved = i
                        break  // need lookahead
                    }
                    from = i + 1  // literal "</parameter>" inside the value
                }
                guard let c = closed else {
                    scanFrom = unresolved ?? max(pos, buf.count - Self.paramClose.count + 1)
                    return
                }
                var raw = rest(pos, c.end)
                if raw.unicodeScalars.first == "\n" { raw.unicodeScalars.removeFirst() }
                if raw.unicodeScalars.last == "\n" { raw.unicodeScalars.removeLast() }
                pos = c.next
                out.append(.toolCallArg(key: key, value: coerce(raw, function: currentFunction, key: key)))
                state = .funcBody
                continue
            }
        }
    }

    private mutating func reject(_ inEnvelope: Bool, _ out: inout [ParserEvent]) {
        if inEnvelope {
            state = .content  // stray text after a call: implicit end of the envelope
        } else {
            let text = toolLead + "<tool_call>"
            toolLead = ""
            emitContent(text, &out)
            state = .content
        }
    }

    // MARK: emission

    private mutating func emitReasoning(_ s: String, _ out: inout [ParserEvent]) {
        var text = s
        if lead {
            text = lstripPy(text)
            if !text.isEmpty { lead = false }
        }
        if !text.isEmpty { out.append(.reasoning(text)) }
    }

    private mutating func emitContent(_ s: String, _ out: inout [ParserEvent]) {
        var text = s
        if lead {
            text = lstripPy(text)
            if text.isEmpty { return }
            lead = false
        }
        if text.isEmpty { return }
        if !detectTools {
            out.append(.text(text))
            return
        }
        let scalars = Array(text.unicodeScalars)
        var end = scalars.count
        while end > 0, isPySpace(scalars[end - 1]) { end -= 1 }
        if end == 0 {
            pendingWS += text
            return
        }
        var body = String.UnicodeScalarView()
        body.append(contentsOf: scalars[0..<end])
        var tail = String.UnicodeScalarView()
        tail.append(contentsOf: scalars[end...])
        out.append(.text(pendingWS + String(body)))
        pendingWS = String(tail)
    }

    private func lstripPy(_ s: String) -> String {
        var v = Substring(s).unicodeScalars
        while let f = v.first, isPySpace(f) { v.removeFirst() }
        return String(v)
    }

    // MARK: argument typing

    private func coerce(_ raw: String, function: String, key: String) -> OrderedJSON {
        let prop = schemas[function]?["properties"]?[key]
        let type = Self.schemaType(prop)
        let keyword = pyTrim(raw)
        if let t = type, ["string", "str", "text", "varchar", "char", "enum"].contains(t) { return .string(raw) }
        if keyword.lowercased() == "null" { return .null }
        func decode(_ want: ((OrderedJSON) -> Bool)? = nil) -> OrderedJSON {
            guard let v = try? OrderedJSON.parse(keyword) else { return .string(raw) }
            if case let .double(d) = v, !d.isFinite { return .string(raw) }
            if let want, !want(v) { return .string(raw) }
            return v
        }
        guard let t = type else { return decode() }
        if ["integer", "int", "uint", "long", "short", "unsigned"].contains(where: { t.hasPrefix($0) }) {
            if let i = Int(keyword) { return .int(i) }
            return .string(raw)
        }
        if t.hasPrefix("num") || t.hasPrefix("float") || t.hasPrefix("double") {
            if t.hasPrefix("num"), let i = Int(keyword) { return .int(i) }
            if let d = Double(keyword), d.isFinite { return .double(d) }
            return .string(raw)
        }
        if ["boolean", "bool", "binary"].contains(t) {
            switch keyword.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return .string(raw)
            }
        }
        if t == "object" || t.hasPrefix("dict") { return decode { if case .object = $0 { return true } else { return false } } }
        if t == "array" || t == "arr" || t.hasPrefix("list") { return decode { if case .array = $0 { return true } else { return false } } }
        return decode()
    }

    /// JSON-schema `type` of a property: a string, the first non-null of a type list, or of anyOf/oneOf.
    static func schemaType(_ schema: OrderedJSON?) -> String? {
        guard let schema else { return nil }
        switch schema["type"] {
        case let .some(.string(s)): return s.lowercased()
        case let .some(.array(a)):
            for x in a { if case let .string(s) = x, s != "null" { return s.lowercased() } }
            return nil
        default: break
        }
        for k in ["anyOf", "oneOf"] {
            if case let .array(opts)? = schema[k] {
                for o in opts {
                    if let t = schemaType(o), t != "null" { return t }
                }
            }
        }
        return nil
    }
}
