import Foundation

/// JSON value that preserves object key order (Python `dict` insertion order, as HF `tojson` sees it).
public enum OrderedJSON: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON
        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
        public static func == (a: Member, b: Member) -> Bool {
            a.key.unicodeScalars.elementsEqual(b.key.unicodeScalars) && a.value == b.value
        }
    }

    case null
    case bool(Bool)
    case int(Int)
    /// Integer literal outside `Int` range, kept as canonical decimal digits (Python ints are unbounded).
    case bigInt(String)
    case double(Double)
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    public static func ordered(_ pairs: [(String, OrderedJSON)]) -> OrderedJSON {
        .object(pairs.map { Member($0.0, $0.1) })
    }

    public static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.bigInt(x), .bigInt(y)): return x == y
        case let (.double(x), .double(y)): return x == y || (x.isNaN && y.isNaN)
        case let (.string(x), .string(y)): return x.unicodeScalars.elementsEqual(y.unicodeScalars)
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)): return x == y
        default: return false
        }
    }

    public subscript(key: String) -> OrderedJSON? {
        guard case let .object(members) = self else { return nil }
        for m in members where m.key.unicodeScalars.elementsEqual(key.unicodeScalars) { return m.value }
        return nil
    }

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var members: [Member]? {
        if case let .object(m) = self { return m }
        return nil
    }

    // MARK: serialization (Python `json.dumps(x, ensure_ascii=False)`, what HF `tojson` does)

    /// Matches HF/Jinja `tojson` in this template: separators ", " and ": ", insertion order, non-ASCII
    /// emitted raw (ensure_ascii=False), only `"` `\` and control characters < 0x20 escaped, no HTML escaping.
    public func serialized() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .int(i): out += String(i)
        case let .bigInt(s): out += s
        case let .double(d): out += OrderedJSON.pythonFloatRepr(d)
        case let .string(s): OrderedJSON.writeString(s, to: &out)
        case let .array(items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += ", " }
                item.write(to: &out)
            }
            out += "]"
        case let .object(members):
            out += "{"
            for (i, m) in members.enumerated() {
                if i > 0 { out += ", " }
                OrderedJSON.writeString(m.key, to: &out)
                out += ": "
                m.value.write(to: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, to out: inout String) {
        var buf = String.UnicodeScalarView()
        buf.append("\"")
        for u in s.unicodeScalars {
            switch u {
            case "\"": buf.append(contentsOf: "\\\"".unicodeScalars)
            case "\\": buf.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": buf.append(contentsOf: "\\n".unicodeScalars)
            case "\r": buf.append(contentsOf: "\\r".unicodeScalars)
            case "\t": buf.append(contentsOf: "\\t".unicodeScalars)
            case "\u{08}": buf.append(contentsOf: "\\b".unicodeScalars)
            case "\u{0C}": buf.append(contentsOf: "\\f".unicodeScalars)
            default:
                if u.value < 0x20 {
                    let hex = String(u.value, radix: 16)
                    buf.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - hex.count) + hex).unicodeScalars)
                } else {
                    buf.append(u)
                }
            }
        }
        buf.append("\"")
        out += String(buf)
    }

    /// CPython `repr(float)` / `json.dumps` float text (shortest round-trip digits, exponent when
    /// decpt <= -4 or > 16, at least two exponent digits).
    static func pythonFloatRepr(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let neg = d < 0
        let desc = "\(abs(d))"
        var mant = desc
        var exp = 0
        if let e = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mant = String(desc[desc.startIndex..<e])
            exp = Int(desc[desc.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        let parts = mant.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let frac = parts.count > 1 ? String(parts[1]) : ""
        var digits = Array(intPart + frac)
        var decpt = intPart.count + exp
        while digits.first == "0" {
            digits.removeFirst()
            decpt -= 1
        }
        while digits.last == "0" { digits.removeLast() }
        let ds = String(digits)
        var body: String
        if decpt <= -4 || decpt > 16 {
            let e = decpt - 1
            let es = String(abs(e))
            body = String(ds.prefix(1)) + (ds.count > 1 ? "." + ds.dropFirst() : "")
                + "e" + (e < 0 ? "-" : "+") + (es.count < 2 ? "0" + es : es)
        } else if decpt <= 0 {
            body = "0." + String(repeating: "0", count: -decpt) + ds
        } else if decpt >= ds.count {
            body = ds + String(repeating: "0", count: decpt - ds.count) + ".0"
        } else {
            body = String(ds.prefix(decpt)) + "." + ds.dropFirst(decpt)
        }
        return neg ? "-" + body : body
    }

    // MARK: parsing (Python `json.loads` semantics, key order preserved)

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ text: String) throws -> OrderedJSON {
        var p = JSONParser(Array(text.utf8))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        if p.i != p.b.count { throw ParseError(description: "extra data at \(p.i)") }
        return v
    }
}

private struct JSONParser {
    let b: [UInt8]
    var i = 0
    var depth = 0
    init(_ b: [UInt8]) { self.b = b }

    func err(_ m: String) -> OrderedJSON.ParseError { .init(description: "\(m) at \(i)") }

    mutating func skipWS() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    mutating func literal(_ s: String) -> Bool {
        let u = Array(s.utf8)
        if i + u.count <= b.count, Array(b[i..<i + u.count]) == u {
            i += u.count
            return true
        }
        return false
    }

    mutating func value() throws -> OrderedJSON {
        guard i < b.count else { throw err("unexpected end") }
        switch b[i] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): if literal("true") { return .bool(true) }
        case UInt8(ascii: "f"): if literal("false") { return .bool(false) }
        case UInt8(ascii: "n"): if literal("null") { return .null }
        case UInt8(ascii: "N"): if literal("NaN") { return .double(.nan) }
        case UInt8(ascii: "I"): if literal("Infinity") { return .double(.infinity) }
        default:
            if b[i] == UInt8(ascii: "-"), i + 1 < b.count, b[i + 1] == UInt8(ascii: "I") {
                i += 1
                if literal("Infinity") { return .double(-.infinity) }
                i -= 1
            }
            return try number()
        }
        throw err("unexpected token")
    }

    mutating func number() throws -> OrderedJSON {
        let start = i
        if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        guard i < b.count, isDigit(b[i]) else { i = start; throw err("bad number") }
        if b[i] == 0x30 { i += 1 } else { while i < b.count, isDigit(b[i]) { i += 1 } }
        var isFloat = false
        if i + 1 < b.count, b[i] == UInt8(ascii: "."), isDigit(b[i + 1]) {
            isFloat = true
            i += 1
            while i < b.count, isDigit(b[i]) { i += 1 }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            var j = i + 1
            if j < b.count, b[j] == UInt8(ascii: "+") || b[j] == UInt8(ascii: "-") { j += 1 }
            if j < b.count, isDigit(b[j]) {
                while j < b.count, isDigit(b[j]) { j += 1 }
                i = j
                isFloat = true
            }
        }
        let text = String(decoding: b[start..<i], as: UTF8.self)
        if isFloat { return .double(Double(text) ?? .nan) }
        if let n = Int(text) { return .int(n) }
        // canonical big integer: strip "-0" oddities and keep sign + digits
        return .bigInt(text)
    }

    mutating func string() throws -> String {
        i += 1  // opening quote
        var out = [UInt8]()
        while true {
            guard i < b.count else { throw err("unterminated string") }
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c < 0x20 { throw err("control character in string") }
            if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
            i += 1
            guard i < b.count else { throw err("bad escape") }
            let e = b[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var cp = try hex4()
                if cp >= 0xD800 && cp < 0xDC00, i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                    let save = i
                    i += 2
                    let lo = try hex4()
                    if lo >= 0xDC00 && lo < 0xE000 {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    } else {
                        i = save
                    }
                }
                let scalar = Unicode.Scalar(cp) ?? "\u{FFFD}"  // lone surrogate: not representable in Swift String
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: i -= 1; throw err("bad escape")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16),
              b[i..<i + 4].allSatisfy({ $0 != UInt8(ascii: "+") && $0 != UInt8(ascii: "-") })
        else { throw err("bad \\u escape") }
        i += 4
        return v
    }

    mutating func array() throws -> OrderedJSON {
        i += 1
        depth += 1
        defer { depth -= 1 }
        if depth > 512 { throw err("too deep") }
        var items = [OrderedJSON]()
        skipWS()
        if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipWS()
            items.append(try value())
            skipWS()
            guard i < b.count else { throw err("unterminated array") }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw err("expected , or ]")
        }
    }

    mutating func object() throws -> OrderedJSON {
        i += 1
        depth += 1
        defer { depth -= 1 }
        if depth > 512 { throw err("too deep") }
        var members = [OrderedJSON.Member]()
        skipWS()
        if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
        while true {
            skipWS()
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw err("expected key") }
            let k = try string()
            skipWS()
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw err("expected :") }
            i += 1
            skipWS()
            let v = try value()
            // Python dict: a duplicate key keeps its first position and takes the last value.
            if let idx = members.firstIndex(where: { $0.key.unicodeScalars.elementsEqual(k.unicodeScalars) }) {
                members[idx].value = v
            } else {
                members.append(.init(k, v))
            }
            skipWS()
            guard i < b.count else { throw err("unterminated object") }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            throw err("expected , or }")
        }
    }
}
