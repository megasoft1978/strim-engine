import Foundation

/// Replaces secrets in tool output / results with `[REDACTED]`.
/// Callers must redact before applying any length cap, so a secret cut by the cap cannot leak a prefix.
public enum Redactor {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var secrets: Set<String> = []
        private var cached: SecretMatcher?
        func add(_ s: String) { lock.lock(); secrets.insert(s); cached = nil; lock.unlock() }
        /// Matcher over every registered secret and its encoded forms; rebuilt only when the set changes.
        func matcher() -> SecretMatcher {
            lock.lock(); defer { lock.unlock() }
            if let m = cached { return m }
            let m = SecretMatcher(patterns: secrets.flatMap(Redactor.variants(of:)))
            cached = m
            return m
        }
    }
    private static let store = Store()

    private static let marker = "[REDACTED]"

    private static let patterns: [NSRegularExpression] = [
        // PEM block to its END line, or to the end of the text when END is missing. A single lazy pattern
        // ends at the first match or at \z, so many BEGINs without an END stay linear.
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)"#,
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        #"\b(?:gh[posur]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#,
        #"\bglpat-[A-Za-z0-9_\-]{20,}"#,
        #"\bnpm_[A-Za-z0-9]{36}\b"#,
        #"\bAIza[0-9A-Za-z_\-]{35}"#,
        #"\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,}"#,
        #"\bsk-(?:ant-)?[A-Za-z0-9_\-]{20,}"#,
        #"\bxox[bpas]-[A-Za-z0-9\-]{10,}"#,
        // Lookbehind: a match may only start at the beginning of a token run, so runs are scanned once (linear).
        #"(?<![A-Za-z0-9_\-])eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Patterns whose capture group 2 is the secret; group 1 (key name, scheme) is kept as-is.
    private static let keepingPrefix: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(\bBearer\s+)([A-Za-z0-9._~+/=\-]{16,})"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"(aws_secret_access_key\s*[=:]\s*['"]?)([A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=])"#,
                                 options: [.caseInsensitive]),
        // scheme://user:pass@host -> scheme://[REDACTED]@host
        try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9+.\-])([A-Za-z][A-Za-z0-9+.\-]{0,31}://)([^\s/@:]+:[^\s/@]+)@"#),
    ]

    /// Generic `password|secret|token|api_key = value` (keys match anywhere, so `DB_PASSWORD=` works). The value
    /// is 12-4096 token-like characters with optional trailing `=` padding, must end at a quote, space, comma,
    /// semicolon or end of text, and must contain a digit (plain identifiers such as `token = tokens[i]` or
    /// `token = nextTokenValue` are left alone). Every quantifier is bounded, so each key costs O(4096).
    private static let assignment = try! NSRegularExpression(
        pattern: #"((?:password|passwd|secret|api[_-]?key|token)['"]?[ \t]{0,8}[=:][ \t]{0,8}['"]?)([A-Za-z0-9+/_\-]{12,4096}={0,2})(?=['"\s,;]|\z)"#,
        options: [.caseInsensitive])

    /// Register a runtime secret (e.g. the Strim token). Thread-safe; empty strings are ignored.
    public static func register(secret: String) {
        guard !secret.isEmpty else { return }
        store.add(secret)
    }

    /// Registers the token stored at `url` (e.g. `~/.strim/token`), trimmed. Returns false when the file is
    /// missing, is not a regular file, or is empty. Only regular files are read, so a FIFO cannot block startup.
    @discardableResult
    public static func registerStrimToken(from url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        register(secret: token)
        return true
    }

    /// Redacts registered secrets (plain, base64 and percent-encoded forms) and known secret patterns.
    /// Every detector runs on the original text and reports the UTF-16 ranges it covers; the ranges are then
    /// merged (overlapping or touching ranges become one), so every covered byte is redacted and each merged
    /// range becomes one marker. Idempotent. Apply before truncating.
    public static func redact(_ text: String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var spans = store.matcher().matchRanges(in: text)
        for re in patterns {
            for m in re.matches(in: text, range: full) { spans.append(m.range) }
        }
        for re in keepingPrefix {
            for m in re.matches(in: text, range: full) { spans.append(m.range(at: 2)) }
        }
        for m in assignment.matches(in: text, range: full) {
            let value = ns.substring(with: m.range(at: 2))
            // A value without a digit is an ordinary identifier, not a credential.
            if value.contains(where: \.isNumber) { spans.append(m.range(at: 2)) }
        }
        return replacing(spans.filter { $0.length > 0 }, in: ns)
    }

    /// Replaces the union of `spans` with the marker. Spans are sorted once; a span that starts before the
    /// current merged range ends extends it, so no covered character survives.
    private static func replacing(_ spans: [NSRange], in ns: NSString) -> String {
        let sorted = spans.sorted { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }
        var out = ""
        var pos = 0
        var open: (start: Int, end: Int)?
        func flush() {
            guard let o = open else { return }
            out += ns.substring(with: NSRange(location: pos, length: o.start - pos)) + marker
            pos = o.end
        }
        for r in sorted {
            let start = r.location, end = r.location + r.length
            if let o = open, start <= o.end {
                open = (o.start, max(o.end, end))
            } else {
                flush()
                open = (start, end)
            }
        }
        flush()
        out += ns.substring(from: pos)
        return out
    }

    /// Plain, base64 (padded and unpadded) and percent-encoded forms of one registered secret.
    fileprivate static func variants(of secret: String) -> [String] {
        var out = [secret]
        let b64 = Data(secret.utf8).base64EncodedString()
        out.append(b64)
        out.append(b64.trimmingCharacters(in: CharacterSet(charactersIn: "=")))
        if let p = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { out.append(p) }
        if let p = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { out.append(p) }
        return out.filter { !$0.isEmpty }
    }

}

/// Aho-Corasick over UTF-8 bytes: finds every occurrence of every pattern in one pass, so redaction cost is
/// linear in the input and does not grow with the number of registered secrets. Replacement is leftmost,
/// longest-first and non-overlapping. Patterns are valid UTF-8, so matches always fall on character boundaries.
fileprivate struct SecretMatcher: Sendable {
    private struct Node {
        var next: [UInt8: Int] = [:]
        var fail = 0
        /// Length of the longest pattern that ends at this node (through suffix links), 0 if none.
        var longest = 0
    }
    private var nodes: [Node] = [Node()]

    init(patterns: [String]) {
        for p in patterns where !p.isEmpty {
            let bytes = Array(p.utf8)
            var cur = 0
            for b in bytes {
                if let n = nodes[cur].next[b] { cur = n } else {
                    nodes.append(Node())
                    nodes[cur].next[b] = nodes.count - 1
                    cur = nodes.count - 1
                }
            }
            nodes[cur].longest = max(nodes[cur].longest, bytes.count)
        }
        // Breadth-first failure links; propagate the longest match through suffix links.
        var queue = Array(nodes[0].next.values)
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            for (b, v) in nodes[u].next {
                var f = nodes[u].fail
                while f != 0 && nodes[f].next[b] == nil { f = nodes[f].fail }
                let target = nodes[f].next[b] ?? 0
                nodes[v].fail = target == v ? 0 : target
                nodes[v].longest = max(nodes[v].longest, nodes[nodes[v].fail].longest)
                queue.append(v)
            }
        }
    }

    /// UTF-16 ranges of every occurrence of every pattern (overlapping occurrences included).
    func matchRanges(in text: String) -> [NSRange] {
        let input = Array(text.utf8)
        var byteRanges: [(start: Int, end: Int)] = []
        var state = 0
        for (i, b) in input.enumerated() {
            while state != 0 && nodes[state].next[b] == nil { state = nodes[state].fail }
            state = nodes[state].next[b] ?? 0
            let len = nodes[state].longest
            if len > 0 { byteRanges.append((i + 1 - len, i + 1)) }
        }
        guard !byteRanges.isEmpty else { return [] }
        // Map UTF-8 offsets to UTF-16 offsets in one walk. Match edges fall on character boundaries.
        var boundaries = Set<Int>()
        for r in byteRanges { boundaries.insert(r.start); boundaries.insert(r.end) }
        var utf16At: [Int: Int] = [:]
        utf16At.reserveCapacity(boundaries.count)
        var units = 0
        for (i, b) in input.enumerated() {
            if boundaries.contains(i) { utf16At[i] = units }
            if b & 0xC0 == 0x80 { continue }          // continuation byte: no new UTF-16 unit
            units += b >= 0xF0 ? 2 : 1                 // 4-byte sequences are a surrogate pair
        }
        utf16At[input.count] = units
        return byteRanges.map { r in
            let a = utf16At[r.start] ?? 0, z = utf16At[r.end] ?? 0
            return NSRange(location: a, length: z - a)
        }
    }
}
