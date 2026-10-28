import Foundation

/// html.escape(str(s), quote=True)
public func esc(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.utf8.count + 16)
    for u in s.unicodeScalars {
        switch u {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#x27;"
        default: out.unicodeScalars.append(u)
        }
    }
    return out
}

/// Python str.splitlines() (without keepends).
public func pySplitlines(_ text: String) -> [String] {
    var lines: [String] = []
    var cur = String.UnicodeScalarView()
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
        let u = scalars[i]
        switch u.value {
        case 0x0a, 0x0b, 0x0c, 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
            lines.append(String(cur)); cur = String.UnicodeScalarView()
        case 0x0d:
            lines.append(String(cur)); cur = String.UnicodeScalarView()
            if i + 1 < scalars.count, scalars[i + 1].value == 0x0a { i += 1 }
        default:
            cur.append(u)
        }
        i += 1
    }
    if !cur.isEmpty { lines.append(String(cur)) }
    return lines
}

/// Python str.strip() (Unicode whitespace).
public func pyStrip(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

/// Python s.strip("|") style: strip any of `chars` from both ends.
public func pyStrip(_ s: String, chars: Set<Character>) -> String {
    var a = Substring(s)
    while let f = a.first, chars.contains(f) { a.removeFirst() }
    while let l = a.last, chars.contains(l) { a.removeLast() }
    return String(a)
}

/// Python text.rpartition(sep) -> (head, sep, tail)
public func pyRpartition(_ s: String, _ sep: Character) -> (String, String, String) {
    guard let i = s.lastIndex(of: sep) else { return ("", "", s) }
    return (String(s[..<i]), String(sep), String(s[s.index(after: i)...]))
}

/// Python text.partition(sep)
public func pyPartition(_ s: String, _ sep: Character) -> (String, String, String) {
    guard let i = s.firstIndex(of: sep) else { return (s, "", "") }
    return (String(s[..<i]), String(sep), String(s[s.index(after: i)...]))
}

public func readText(_ path: String) -> String? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return String(decoding: d, as: UTF8.self)
}

public func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

public func isFile(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
}

public func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

/// A tiny backtracking matcher for the fixed patterns used on soak summaries (no regex engine).
struct Pat {
    enum Tok {
        case lit(String)          // literal text
        case digits               // \d+
        case numDot               // [\d.]+
        case optMinus             // -?
        case ws                   // \s+
        case notNL                // [^\n]*
        case cap(Bool)            // capture start (true) / end (false)
    }
    let toks: [Tok]
    init(_ toks: [Tok]) { self.toks = toks }

    /// re.search(...).group(1) or nil
    func search(_ text: String) -> String? {
        let s = Array(text.unicodeScalars)
        for start in 0...s.count {
            var cs = -1, ce = -1
            if run(0, start, s, &cs, &ce), cs >= 0, ce >= cs {
                var v = String.UnicodeScalarView()
                v.append(contentsOf: s[cs..<ce])
                return String(v)
            }
        }
        return nil
    }

    private func isDigit(_ u: Unicode.Scalar) -> Bool { u.value >= 0x30 && u.value <= 0x39 }
    private func isWS(_ u: Unicode.Scalar) -> Bool {
        switch u.value { case 0x20, 0x09, 0x0a, 0x0b, 0x0c, 0x0d: return true; default: return false }
    }

    private func run(_ t: Int, _ pos: Int, _ s: [Unicode.Scalar], _ cs: inout Int, _ ce: inout Int) -> Bool {
        if t == toks.count { return true }
        switch toks[t] {
        case .lit(let l):
            let ls = Array(l.unicodeScalars)
            guard pos + ls.count <= s.count, Array(s[pos..<pos + ls.count]) == ls else { return false }
            return run(t + 1, pos + ls.count, s, &cs, &ce)
        case .cap(let start):
            let (oc, oe) = (cs, ce)
            if start { cs = pos } else { ce = pos }
            if run(t + 1, pos, s, &cs, &ce) { return true }
            cs = oc; ce = oe
            return false
        case .optMinus:
            if pos < s.count, s[pos] == "-", run(t + 1, pos + 1, s, &cs, &ce) { return true }
            return run(t + 1, pos, s, &cs, &ce)
        case .digits, .numDot, .ws, .notNL:
            var n = pos
            switch toks[t] {
            case .digits: while n < s.count, isDigit(s[n]) { n += 1 }
            case .numDot: while n < s.count, isDigit(s[n]) || s[n] == "." { n += 1 }
            case .ws: while n < s.count, isWS(s[n]) { n += 1 }
            default: while n < s.count, s[n] != "\n" { n += 1 }
            }
            let minLen: Int
            if case .notNL = toks[t] { minLen = 0 } else { minLen = 1 }
            var e = n
            while e - pos >= minLen {
                if run(t + 1, e, s, &cs, &ce) { return true }
                e -= 1
            }
            return false
        }
    }
}

/// Python `needle in hay` (code point / byte exact, no Unicode normalisation).
public func pyContains(_ hay: String, _ needle: String) -> Bool {
    let n = Array(needle.utf8)
    if n.isEmpty { return true }
    let h = Array(hay.utf8)
    if n.count > h.count { return false }
    let first = n[0]
    var i = 0
    let last = h.count - n.count
    while i <= last {
        if h[i] == first {
            var k = 1
            while k < n.count, h[i + k] == n[k] { k += 1 }
            if k == n.count { return true }
        }
        i += 1
    }
    return false
}
