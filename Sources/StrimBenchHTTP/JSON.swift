import Foundation

public enum StrimBenchHTTPModule { public static let name = "StrimBenchHTTP" }

/// JSON value that keeps object key order and the int/float distinction, so files written here
/// match what Python's `json.dumps` writes (`ensure_ascii`, `", "` / `": "` separators, float repr).
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public static func obj(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var o = JSONObject()
        for (k, v) in pairs { o[k] = v }
        return .object(o)
    }

    public init(_ d: Double?) { self = d.map { .double($0) } ?? .null }
    public init(_ i: Int?) { self = i.map { .int($0) } ?? .null }
    public init(_ s: String?) { self = s.map { .string($0) } ?? .null }

    public subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d == d.rounded() && abs(d) < 9e15 ? Int(d) : nil
        default: return nil
        }
    }
    /// Numbers only (bool excluded, like Python's `isinstance(x, (int, float))` plus a bool guard).
    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// Python truthiness: None/False/0/0.0/""/[]/{} are falsy.
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.members.isEmpty
        }
    }
}

public struct JSONObject: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: JSONValue
    }
    public private(set) var members: [Member] = []
    public init() {}

    public subscript(key: String) -> JSONValue? {
        get { members.first { $0.key == key }?.value }
        set {
            if let i = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[i].value = newValue } else { members.remove(at: i) }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
        }
    }
    public var keys: [String] { members.map(\.key) }
}

public struct JSONError: Error, CustomStringConvertible {
    public let description: String
}

// MARK: - Parser

public enum JSON {
    public static func parse(_ text: String) throws -> JSONValue { try parse(Array(text.utf8)) }

    public static func parse(_ data: Data) throws -> JSONValue { try parse(Array(data)) }

    public static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        var p = Parser(b: bytes)
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        if p.i != bytes.count { throw JSONError(description: "Extra data at \(p.i)") }
        return v
    }

    /// Lines of a JSONL file; blank or unparsable lines are skipped (Python `jl` helper).
    public static func lines(_ path: String) -> [JSONValue] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [JSONValue] = []
        for ln in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let v = try? parse(String(ln)) { out.append(v) }
        }
        return out
    }

    struct Parser {
        let b: [UInt8]
        var i = 0
        init(b: [UInt8]) { self.b = b }

        mutating func skipWS() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        }

        func err(_ m: String) -> JSONError { JSONError(description: "\(m) at char \(i)") }

        mutating func value() throws -> JSONValue {
            guard i < b.count else { throw err("Expecting value") }
            switch b[i] {
            case UInt8(ascii: "{"):
                i += 1
                var o = JSONObject()
                skipWS()
                if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                while true {
                    skipWS()
                    guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw err("Expecting property name") }
                    let k = try str()
                    skipWS()
                    guard i < b.count, b[i] == UInt8(ascii: ":") else { throw err("Expecting ':' delimiter") }
                    i += 1
                    skipWS()
                    o[k] = try value()
                    skipWS()
                    guard i < b.count else { throw err("Expecting ',' delimiter") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                    throw err("Expecting ',' delimiter")
                }
            case UInt8(ascii: "["):
                i += 1
                var a: [JSONValue] = []
                skipWS()
                if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                while true {
                    skipWS()
                    a.append(try value())
                    skipWS()
                    guard i < b.count else { throw err("Expecting ',' delimiter") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                    throw err("Expecting ',' delimiter")
                }
            case UInt8(ascii: "\""):
                return .string(try str())
            case UInt8(ascii: "t"): try lit("true"); return .bool(true)
            case UInt8(ascii: "f"): try lit("false"); return .bool(false)
            case UInt8(ascii: "n"): try lit("null"); return .null
            case UInt8(ascii: "N"): try lit("NaN"); return .double(.nan)
            case UInt8(ascii: "I"): try lit("Infinity"); return .double(.infinity)
            default: return try number()
            }
        }

        mutating func lit(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= b.count, Array(b[i ..< i + u.count]) == u else { throw err("Expecting value") }
            i += u.count
        }

        mutating func number() throws -> JSONValue {
            let start = i
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            if i < b.count, b[i] == UInt8(ascii: "I") { try lit("Infinity"); return .double(-.infinity) }
            let ds = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            guard i > ds else { i = start; throw err("Expecting value") }
            var isFloat = false
            if i < b.count, b[i] == UInt8(ascii: "."), i + 1 < b.count, b[i + 1] >= 0x30, b[i + 1] <= 0x39 {
                isFloat = true
                i += 1
                while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            }
            if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                var j = i + 1
                if j < b.count, b[j] == UInt8(ascii: "+") || b[j] == UInt8(ascii: "-") { j += 1 }
                if j < b.count, b[j] >= 0x30, b[j] <= 0x39 {
                    isFloat = true
                    while j < b.count, b[j] >= 0x30, b[j] <= 0x39 { j += 1 }
                    i = j
                }
            }
            let s = String(decoding: b[start ..< i], as: UTF8.self)
            if !isFloat, let v = Int(s) { return .int(v) }
            guard let d = Double(s) else { throw err("Expecting value") }
            return .double(d)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i ..< i + 4], as: UTF8.self), radix: 16) else {
                throw err("Invalid \\uXXXX escape")
            }
            i += 4
            return v
        }

        mutating func str() throws -> String {
            i += 1
            var out: [UInt8] = []
            while true {
                guard i < b.count else { throw err("Unterminated string") }
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < b.count else { throw err("Unterminated string") }
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
                        if cp >= 0xD800, cp < 0xDC00, i + 6 <= b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                            let save = i
                            i += 2
                            let lo = try hex4()
                            if lo >= 0xDC00, lo < 0xE000 {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                            } else {
                                i = save
                            }
                        }
                        let scalar = Unicode.Scalar(cp) ?? "\u{FFFD}"
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: throw err("Invalid \\escape")
                    }
                } else {
                    if c < 0x20 { throw err("Invalid control character") }
                    out.append(c)
                    i += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    // MARK: - Writer (Python json.dumps compatible)

    /// `indent == nil` gives `json.dumps` defaults (`", "`, `": "`); `indent = n` gives `indent=n` (`","`, `": "`).
    public static func dumps(_ v: JSONValue, indent: Int? = nil, ensureASCII: Bool = true) -> String {
        var s = ""
        write(v, indent: indent, level: 0, ascii: ensureASCII, into: &s)
        return s
    }

    static func write(_ v: JSONValue, indent: Int?, level: Int, ascii: Bool, into s: inout String) {
        switch v {
        case .null: s += "null"
        case .bool(let b): s += b ? "true" : "false"
        case .int(let i): s += String(i)
        case .double(let d): s += pyFloatJSON(d)
        case .string(let t): writeString(t, ascii: ascii, into: &s)
        case .array(let a):
            if a.isEmpty { s += "[]"; return }
            s += "["
            for (n, x) in a.enumerated() {
                if n > 0 { s += indent == nil ? ", " : "," }
                if let ind = indent { s += "\n" + String(repeating: " ", count: ind * (level + 1)) }
                write(x, indent: indent, level: level + 1, ascii: ascii, into: &s)
            }
            if let ind = indent { s += "\n" + String(repeating: " ", count: ind * level) }
            s += "]"
        case .object(let o):
            if o.members.isEmpty { s += "{}"; return }
            s += "{"
            for (n, m) in o.members.enumerated() {
                if n > 0 { s += indent == nil ? ", " : "," }
                if let ind = indent { s += "\n" + String(repeating: " ", count: ind * (level + 1)) }
                writeString(m.key, ascii: ascii, into: &s)
                s += ": "
                write(m.value, indent: indent, level: level + 1, ascii: ascii, into: &s)
            }
            if let ind = indent { s += "\n" + String(repeating: " ", count: ind * level) }
            s += "}"
        }
    }

    static func writeString(_ t: String, ascii: Bool, into s: inout String) {
        s += "\""
        for u in t.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            case "\u{08}": s += "\\b"
            case "\u{0C}": s += "\\f"
            default:
                if u.value < 0x20 {
                    s += String(format: "\\u%04x", u.value)
                } else if ascii, u.value > 0x7E {
                    if u.value > 0xFFFF {
                        let v = u.value - 0x10000
                        s += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    } else {
                        s += String(format: "\\u%04x", u.value)
                    }
                } else {
                    s.unicodeScalars.append(u)
                }
            }
        }
        s += "\""
    }
}

/// Python `repr(float)`: shortest round-trip digits; exponent form when exp10 < -4 or >= 16.
public func pyFloatRepr(_ d: Double) -> String {
    if d.isNaN { return "nan" }
    if d.isInfinite { return d < 0 ? "-inf" : "inf" }
    if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
    var desc = "\(abs(d))"
    var exp10 = 0
    if let eIdx = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        exp10 = Int(desc[desc.index(after: eIdx)...].replacingOccurrences(of: "+", with: "")) ?? 0
        desc = String(desc[..<eIdx])
    }
    var intPart = desc
    var frac = ""
    if let dot = desc.firstIndex(of: ".") {
        intPart = String(desc[..<dot])
        frac = String(desc[desc.index(after: dot)...])
    }
    var digits = intPart + frac
    var decpt = intPart.count + exp10
    while digits.hasPrefix("0") && digits.count > 1 { digits.removeFirst(); decpt -= 1 }
    while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
    let sign = d < 0 ? "-" : ""
    let e = decpt - 1
    if e < -4 || e >= 16 {
        var m = String(digits.first!)
        if digits.count > 1 { m += "." + digits.dropFirst() }
        let es = String(format: "%02d", abs(e))
        return "\(sign)\(m)e\(e < 0 ? "-" : "+")\(es)"
    }
    if decpt <= 0 { return sign + "0." + String(repeating: "0", count: -decpt) + digits }
    if decpt >= digits.count { return sign + digits + String(repeating: "0", count: decpt - digits.count) + ".0" }
    let idx = digits.index(digits.startIndex, offsetBy: decpt)
    return sign + digits[..<idx] + "." + digits[idx...]
}

func pyFloatJSON(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    return pyFloatRepr(d)
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}
