import Foundation

/// Error carrying the exact message the Python builder would have printed via SystemExit / a crash.
public struct SiteError: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

/// Insertion-ordered JSON object (Python dict semantics).
public struct JObject: Equatable {
    public private(set) var keys: [String] = []
    private var dict: [String: PyJSON] = [:]
    public init() {}
    public subscript(_ k: String) -> PyJSON? {
        get { dict[k] }
        set {
            if let v = newValue {
                if dict[k] == nil { keys.append(k) }
                dict[k] = v
            } else if dict[k] != nil {
                dict[k] = nil
                keys.removeAll { $0 == k }
            }
        }
    }
    public var items: [(String, PyJSON)] { keys.map { ($0, dict[$0]!) } }
}

/// JSON value that keeps the int/float distinction and key order, so output matches Python json.dumps byte for byte.
public indirect enum PyJSON: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([PyJSON])
    case object(JObject)

    public var str: String? { if case .string(let s) = self { return s }; return nil }
    public var obj: JObject? { if case .object(let o) = self { return o }; return nil }
    public var arr: [PyJSON]? { if case .array(let a) = self { return a }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
    /// Numeric value as Double (int or float, not bool).
    public var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    public var isNumber: Bool { number != nil }
    /// Python truthiness.
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.keys.isEmpty
        }
    }
    public subscript(_ k: String) -> PyJSON? { obj?[k] }

    /// Checked path lookup (Python `d[a][b]` raising KeyError).
    public func get(_ path: String...) throws -> PyJSON {
        var cur = self
        for p in path {
            guard let o = cur.obj, let n = o[p] else { throw SiteError("KeyError: \(p)") }
            cur = n
        }
        return cur
    }

    /// Python str(x).
    public var pyStr: String {
        switch self {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return pyRepr(d)
        case .string(let s): return s
        case .array, .object: return pyReprValue(self)
        }
    }
}

// MARK: Python float repr / formatting

/// Python repr(float): shortest round-trip digits, fixed notation for 1e-4 <= |x| < 1e16, else d.ddde+XX.
public func pyRepr(_ d: Double) -> String {
    if d.isNaN { return "nan" }
    if d.isInfinite { return d < 0 ? "-inf" : "inf" }
    if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
    // Swift's description yields the shortest round-trip digits too; re-layout them Python style.
    var s = "\(abs(d))"
    var exp = 0
    if let eIdx = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        exp = Int(s[s.index(after: eIdx)...]) ?? 0
        s = String(s[..<eIdx])
    }
    var intPart = s
    var frac = ""
    if let dot = s.firstIndex(of: ".") {
        intPart = String(s[..<dot])
        frac = String(s[s.index(after: dot)...])
    }
    var digits = intPart + frac
    var decpt = intPart.count + exp
    // strip leading zeros
    while digits.hasPrefix("0") && digits.count > 1 { digits.removeFirst(); decpt -= 1 }
    while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
    let neg = d < 0 ? "-" : ""
    if decpt > 16 || decpt < -3 {
        let first = String(digits.first!)
        let rest = String(digits.dropFirst())
        let e = decpt - 1
        let es = (e < 0 ? "-" : "+") + (abs(e) < 10 ? "0\(abs(e))" : "\(abs(e))")
        return neg + first + (rest.isEmpty ? "" : "." + rest) + "e" + es
    }
    if decpt <= 0 { return neg + "0." + String(repeating: "0", count: -decpt) + digits }
    if decpt >= digits.count { return neg + digits + String(repeating: "0", count: decpt - digits.count) + ".0" }
    let i = digits.index(digits.startIndex, offsetBy: decpt)
    return neg + digits[..<i] + "." + digits[i...]
}

/// f"{v:.{dp}f}"
public func fmtFixed(_ v: Double, _ dp: Int) -> String { String(format: "%.\(dp)f", v) }

/// round(v, dp) for a float (correctly rounded, half-even on the exact binary value).
public func pyRound(_ v: Double, _ dp: Int) -> Double { Double(String(format: "%.\(dp)f", v)) ?? v }

/// f"{n:,}"
public func fmtCommas(_ n: Int) -> String {
    let neg = n < 0
    var digits = String(neg ? String(n).dropFirst() : Substring(String(n)))
    var out = ""
    while digits.count > 3 {
        out = "," + digits.suffix(3) + out
        digits.removeLast(3)
    }
    return (neg ? "-" : "") + digits + out
}

/// Python repr(str).
public func pyReprString(_ s: String) -> String {
    let useDouble = s.contains("'") && !s.contains("\"")
    let q: Character = useDouble ? "\"" : "'"
    var out = String(q)
    for u in s.unicodeScalars {
        switch u {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if Character(u) == q { out += "\\" + String(q) }
            else if u.value < 0x20 || u.value == 0x7f { out += String(format: "\\x%02x", u.value) }
            else { out.unicodeScalars.append(u) }
        }
    }
    out.append(q)
    return out
}

public func pyReprValue(_ v: PyJSON) -> String {
    switch v {
    case .null: return "None"
    case .bool(let b): return b ? "True" : "False"
    case .int(let i): return String(i)
    case .double(let d): return pyRepr(d)
    case .string(let s): return pyReprString(s)
    case .array(let a): return "[" + a.map(pyReprValue).joined(separator: ", ") + "]"
    case .object(let o): return "{" + o.items.map { pyReprString($0.0) + ": " + pyReprValue($0.1) }.joined(separator: ", ") + "}"
    }
}

// MARK: parse

public enum PyJSONParser {
    public static func parse(_ text: String) throws -> PyJSON {
        var p = P(b: Array(text.utf8))
        p.ws()
        let v = try p.value()
        p.ws()
        if p.i != p.b.count { throw SiteError("JSON: extra data at \(p.i)") }
        return v
    }

    struct P {
        var b: [UInt8]
        var i = 0
        init(b: [UInt8]) { self.b = b }
        mutating func ws() { while i < b.count, b[i] == 0x20 || b[i] == 0x0a || b[i] == 0x0d || b[i] == 0x09 { i += 1 } }
        func err(_ m: String) -> SiteError { SiteError("JSON: \(m) at \(i)") }
        mutating func value() throws -> PyJSON {
            guard i < b.count else { throw err("unexpected end") }
            switch b[i] {
            case UInt8(ascii: "{"):
                i += 1
                var o = JObject()
                ws()
                if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                while true {
                    ws()
                    guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw err("expected key") }
                    let k = try string()
                    ws()
                    guard i < b.count, b[i] == UInt8(ascii: ":") else { throw err("expected ':'") }
                    i += 1; ws()
                    o[k] = try value()
                    ws()
                    guard i < b.count else { throw err("unterminated object") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                    throw err("expected ',' or '}'")
                }
            case UInt8(ascii: "["):
                i += 1
                var a: [PyJSON] = []
                ws()
                if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                while true {
                    ws()
                    a.append(try value())
                    ws()
                    guard i < b.count else { throw err("unterminated array") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                    throw err("expected ',' or ']'")
                }
            case UInt8(ascii: "\""): return .string(try string())
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
            guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { throw err("bad literal") }
            i += u.count
        }
        mutating func number() throws -> PyJSON {
            let st = i
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            var isFloat = false
            let digitsStart = i
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            if i == digitsStart { throw err("bad number") }
            if i < b.count, b[i] == UInt8(ascii: ".") {
                isFloat = true; i += 1
                while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            }
            if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                isFloat = true; i += 1
                if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
                while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
            }
            let s = String(decoding: b[st..<i], as: UTF8.self)
            if !isFloat, let n = Int(s) { return .int(n) }
            guard let d = Double(s) else { throw err("bad number \(s)") }
            return .double(d)
        }
        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else { throw err("bad \\u escape") }
            i += 4
            return v
        }
        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < b.count else { throw err("unterminated string") }
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < b.count else { throw err("bad escape") }
                    let e = b[i]; i += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5c)
                    case UInt8(ascii: "/"): out.append(0x2f)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0c)
                    case UInt8(ascii: "n"): out.append(0x0a)
                    case UInt8(ascii: "r"): out.append(0x0d)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var cp = try hex4()
                        if cp >= 0xD800 && cp < 0xDC00, i + 1 < b.count, b[i] == 0x5c, b[i + 1] == UInt8(ascii: "u") {
                            let save = i
                            i += 2
                            let lo = try hex4()
                            if lo >= 0xDC00 && lo < 0xE000 { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00) } else { i = save }
                        }
                        let sc = Unicode.Scalar(cp) ?? "\u{FFFD}"
                        out.append(contentsOf: Array(String(Character(sc)).utf8))
                    default: throw err("bad escape")
                    }
                } else {
                    out.append(c); i += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}

// MARK: dump (json.dumps(obj, indent=1, ensure_ascii=False))

public enum PyJSONWriter {
    public static func dumps(_ v: PyJSON, indent: Int = 1) -> String {
        var out = ""
        write(v, level: 0, indent: indent, into: &out)
        return out
    }

    static func write(_ v: PyJSON, level: Int, indent: Int, into out: inout String) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if d.isNaN { out += "NaN" } else if d.isInfinite { out += d < 0 ? "-Infinity" : "Infinity" } else { out += pyRepr(d) }
        case .string(let s): writeString(s, into: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[\n"
            let pad = String(repeating: " ", count: indent * (level + 1))
            for (k, e) in a.enumerated() {
                out += pad
                write(e, level: level + 1, indent: indent, into: &out)
                out += k == a.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent * level) + "]"
        case .object(let o):
            if o.keys.isEmpty { out += "{}"; return }
            out += "{\n"
            let pad = String(repeating: " ", count: indent * (level + 1))
            let items = o.items
            for (k, kv) in items.enumerated() {
                out += pad
                writeString(kv.0, into: &out)
                out += ": "
                write(kv.1, level: level + 1, indent: indent, into: &out)
                out += k == items.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent * level) + "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }
}
