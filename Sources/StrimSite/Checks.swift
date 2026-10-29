import Foundation

/// Minimal tag scanner mirroring the LinkParser of the retired Python generator (balanced tags, duplicate ids, links, anchors).
struct LinkScan {
    static let void: Set<String> = ["meta", "link", "br", "hr", "img", "input", "rect", "path", "source", "wbr"]
    var stack: [String] = []
    var hrefs: [String] = []
    var ids: Set<String> = []
    var errors: [String] = []

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    mutating func feed(_ text: String) {
        let s = Array(text.unicodeScalars)
        var i = 0
        func isLetter(_ u: Unicode.Scalar) -> Bool { (u.value >= 0x41 && u.value <= 0x5a) || (u.value >= 0x61 && u.value <= 0x7a) }
        func isSpace(_ u: Unicode.Scalar) -> Bool { u == " " || u == "\n" || u == "\t" || u == "\r" || u == "\u{0c}" }
        while i < s.count {
            guard s[i] == "<" else { i += 1; continue }
            if i + 3 < s.count, s[i + 1] == "!", s[i + 2] == "-", s[i + 3] == "-" {
                // comment
                var j = i + 4
                while j + 2 < s.count, !(s[j] == "-" && s[j + 1] == "-" && s[j + 2] == ">") { j += 1 }
                i = min(j + 3, s.count); continue
            }
            if i + 1 < s.count, s[i + 1] == "!" || s[i + 1] == "?" {
                var j = i + 2
                while j < s.count, s[j] != ">" { j += 1 }
                i = j + 1; continue
            }
            let isEnd = i + 1 < s.count && s[i + 1] == "/"
            let nameStart = isEnd ? i + 2 : i + 1
            guard nameStart < s.count, isLetter(s[nameStart]) else { i += 1; continue }
            var j = nameStart
            var name = String.UnicodeScalarView()
            while j < s.count, !isSpace(s[j]), s[j] != "/", s[j] != ">" { name.append(s[j]); j += 1 }
            let tag = String(name).lowercased()
            if isEnd {
                while j < s.count, s[j] != ">" { j += 1 }
                i = j + 1
                endTag(tag)
                continue
            }
            var attrs: [(String, String?)] = []
            var selfClose = false
            while j < s.count {
                while j < s.count, isSpace(s[j]) { j += 1 }
                if j >= s.count { break }
                if s[j] == ">" { j += 1; break }
                if s[j] == "/" {
                    if j + 1 < s.count, s[j + 1] == ">" { selfClose = true; j += 2; break }
                    j += 1; continue
                }
                var an = String.UnicodeScalarView()
                while j < s.count, !isSpace(s[j]), s[j] != "=", s[j] != ">", s[j] != "/" { an.append(s[j]); j += 1 }
                while j < s.count, isSpace(s[j]) { j += 1 }
                var val: String?
                if j < s.count, s[j] == "=" {
                    j += 1
                    while j < s.count, isSpace(s[j]) { j += 1 }
                    var v = String.UnicodeScalarView()
                    if j < s.count, s[j] == "\"" || s[j] == "'" {
                        let q = s[j]; j += 1
                        while j < s.count, s[j] != q { v.append(s[j]); j += 1 }
                        j += 1
                    } else {
                        while j < s.count, !isSpace(s[j]), s[j] != ">" { v.append(s[j]); j += 1 }
                    }
                    val = LinkScan.unescape(String(v))
                }
                attrs.append((String(an).lowercased(), val))
            }
            i = j
            if selfClose { startEnd(attrs) } else { start(tag, attrs) }
        }
    }

    private func attr(_ attrs: [(String, String?)], _ k: String) -> String? {
        var r: String??
        for (n, v) in attrs where n == k { r = .some(v) }   // dict(attrs): last wins
        return r ?? nil
    }

    private mutating func start(_ tag: String, _ attrs: [(String, String?)]) {
        if let id = attr(attrs, "id") {
            if ids.contains(id) { errors.append("duplicate id \(id)") }
            ids.insert(id)
        }
        if tag == "a", let h = attr(attrs, "href") { hrefs.append(h) }
        if tag == "link", let h = attr(attrs, "href") { hrefs.append(h) }
        if !LinkScan.void.contains(tag) { stack.append(tag) }
    }

    private mutating func startEnd(_ attrs: [(String, String?)]) {
        if let id = attr(attrs, "id") { ids.insert(id) }
    }

    private mutating func endTag(_ tag: String) {
        if LinkScan.void.contains(tag) { return }
        if stack.last != tag {
            errors.append("unbalanced </\(tag)> (stack top \(stack.last.map { "\($0)" } ?? "None"))")
            if stack.contains(tag) {
                while let t = stack.popLast(), t != tag {}
            }
            return
        }
        stack.removeLast()
    }
}

extension SiteBuilder {
    func checkHTML(_ text: String) -> ([String], Int) {
        var p = LinkScan()
        p.feed(text)
        var errs = p.errors
        if !p.stack.isEmpty { errs.append("unclosed tags: [" + p.stack.map { pyReprString($0) }.joined(separator: ", ") + "]") }
        for h in p.hrefs {
            if h.hasPrefix("#") {
                if !p.ids.contains(String(h.dropFirst())) { errs.append("missing anchor \(h)") }
            } else if isExternal(h) {
                if !(h == SITE_URL || h.hasPrefix(SITE_URL + "benchmarks.html") || h.hasPrefix(REPO_URL)) { errs.append("external link (offline rule): \(h)") }
            } else {
                let tgt = site + "/" + (h.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                if !fileExists(tgt) { errs.append("broken link \(h)") }
            }
        }
        return (errs, p.hrefs.count)
    }

    /// Links between the two pages must land on an existing id (checkHTML only resolves same-page anchors).
    func checkCrossAnchors(landing: String, benchmarks: String) -> [String] {
        var a = LinkScan(), b = LinkScan()
        a.feed(landing); b.feed(benchmarks)
        var errs: [String] = []
        for h in a.hrefs where h.hasPrefix("benchmarks.html#") && !b.ids.contains(String(h.dropFirst("benchmarks.html#".count))) { errs.append("index.html: missing anchor \(h)") }
        for h in b.hrefs where h.hasPrefix("index.html#") && !a.ids.contains(String(h.dropFirst("index.html#".count))) { errs.append("benchmarks.html: missing anchor \(h)") }
        return errs
    }

    /// README invariants (Batch 3): short, themed wordmark/hero/chart, install order, DMG note, agent quickstart, why-not line, explicit loss rows, 3 significant figures.
    func checkReadmeShape(_ readme: String) -> [String] {
        var errs: [String] = []
        let lines = readme.split(separator: "\n", omittingEmptySubsequences: false).count
        if lines > README_MAX_LINES { errs.append("README has \(lines) lines, limit is \(README_MAX_LINES)") }
        for t in ["dark", "light"] where !readme.contains("site/assets/app/readme-hero-\(t).png") { errs.append("README must embed the hero screenshot site/assets/app/readme-hero-\(t).png") }
        if !readme.contains("megasoft1978.github.io/strim-engine/") { errs.append("README must link the Pages site") }
        guard let brew = readme.range(of: "brew install megasoft1978/strim/strim"), let pull = readme.range(of: "strim pull"), let serve = readme.range(of: "strim serve ~/.strim/models") else {
            return errs + ["README install block lacks brew, strim pull or strim serve"]
        }
        if !(brew.lowerBound < pull.lowerBound && pull.lowerBound < serve.lowerBound) { errs.append("README install order must be brew, strim pull, strim serve") }
        if !readme.contains("notarized") || readme.contains("not notarized") { errs.append("README must say the DMG is notarized") }
        if !readme.contains("ANTHROPIC_BASE_URL=http://127.0.0.1:8203") || !readme.contains("OPENAI_BASE_URL=http://127.0.0.1:8203/v1") { errs.append("README lacks the Claude Code / Codex quickstart on port 8203") }
        if !readme.contains("Not a fit if you want many models") { errs.append("README lacks the \"why not Strim\" line") }
        for t in ["wordmark", "decode"] { for th in ["dark", "light"] where !readme.contains("\(README_ASSET_DIR)\(t)-\(th).svg") { errs.append("README must reference \(README_ASSET_DIR)\(t)-\(th).svg") } }
        if let r = bestRival("c32k_tt"), r.claimable, r.ratio <= 0.98, !readme.contains("x, slower") { errs.append("README table must show the cold 32K loss as \"slower\"") }
        for bad in ["WIN", "LOSS"] where readme.contains(bad) { errs.append("README uses the capitalised verdict word \(bad)") }
        for line in readme.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("|") {
            for tok in line.split(whereSeparator: { !"0123456789.".contains($0) }) where tok.contains(".") || tok.count > 3 {
                var digits = Array(tok.filter(\.isNumber).drop(while: { $0 == "0" }))
                if !tok.contains(".") { while digits.last == "0" { digits.removeLast() } }   // 1960 and 15300 are three significant figures
                if digits.count > 3 { errs.append("README table number \(tok) has more than 3 significant figures") }
            }
        }
        if readme.range(of: "\\{[a-z_0-9@.|]+\\}", options: .regularExpression) != nil { errs.append("README has an unfilled {placeholder}") }
        return errs
    }

    /// re.match(r"^[a-z]+://", h) or h.startswith("//")
    private func isExternal(_ h: String) -> Bool {
        if h.hasPrefix("//") { return true }
        var n = 0
        for u in h.unicodeScalars {
            if u.value >= 0x61 && u.value <= 0x7a { n += 1 } else { break }
        }
        return n > 0 && h.unicodeScalars.dropFirst(n).starts(with: "://".unicodeScalars)
    }

    func checkMarkdownLinks(_ text: String, base: String) -> [String] {
        var errs: [String] = []
        let s = Array(text.unicodeScalars)
        var i = 0
        while i + 1 < s.count {
            if s[i] == "]", s[i + 1] == "(" {
                var j = i + 2
                var h = String.UnicodeScalarView()
                while j < s.count, s[j] != ")", !(s[j] == " " || s[j] == "\n" || s[j] == "\t" || s[j] == "\r" || s[j] == "\u{0b}" || s[j] == "\u{0c}") { h.append(s[j]); j += 1 }
                if !h.isEmpty, j < s.count, s[j] == ")" {
                    let href = String(h)
                    let skip = ["http://", "https://", "#", "mailto:"].contains { href.hasPrefix($0) }
                    if !skip {
                        let path = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                        if !fileExists(base + "/" + path) { errs.append("README broken link \(href)") }
                    }
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return errs
    }

    func checkFigures() throws -> [String] {
        var errs: [String] = []
        for i in D.order {
            let f = D.figs[i]!
            var missing = false
            for k in ["id", "value", "unit", "source_path", "method_note", "caveat"] where f.raw[k] == nil {
                errs.append("\(i): missing field \(k)"); missing = true
            }
            _ = missing
            let rawValue = f.raw["value"] ?? .null
            if rawValue.isNull && !f.isDerived { continue }
            if f.isDerived || (f.raw["computed"]?.truthy ?? false) { continue }
            let src = f.sourcePath
            if !(src.hasPrefix("bench/results/") || src.hasPrefix("bench/soak/") || src.hasPrefix("docs/")) {
                errs.append("\(i): source_path outside bench/results, bench/soak, docs: \(src)"); continue
            }
            let sp = root + "/" + src
            if !isFile(sp) { errs.append("\(i): source file missing: \(src)"); continue }
            var text = readText(sp) ?? ""
            if f.raw["verify_md"]?.truthy ?? false {
                if let e = try mdCheck(f) { errs.append(e) }
                continue
            }
            if f.raw["verify_section"]?.truthy ?? false {
                let secs = mdSections(text)
                let prefix = f.raw["verify_section"]!.pyStr
                let key = secs.keys.first(where: { $0.hasPrefix(prefix) }) ?? ""
                text = (secs.lines[key] ?? []).joined(separator: "\n")
            }
            if let vc = f.raw["verify_count"], vc.truthy {
                let secLines: [String]
                if let sec = vc["section"], sec.truthy { secLines = try mdSec(mdSections(text), sec.pyStr) } else { secLines = pySplitlines(text) }
                var prefixes = (vc["line_prefix"]?.arr ?? []).compactMap { $0.str }
                if prefixes.isEmpty { prefixes = [""] }
                let contains = vc["contains"]?.pyStr ?? ""
                let got = secLines.filter { pyContains($0, contains) && prefixes.contains(where: $0.hasPrefix) }.count
                if rawValue.number != Double(got) {
                    errs.append("\(i): counted \(got) lines with \(pyReprString(contains)) in \(src), figure says \(rawValue.pyStr)")
                }
                continue
            }
            var needles: [String]
            if let ver = f.raw["verify"], ver.truthy {
                needles = [ver.pyStr]
            } else if case .string(let s) = rawValue {
                needles = [s]
            } else if case .int(let n) = rawValue {
                needles = [String(n), fmtCommas(n)]
            } else {
                needles = [rawValue.pyStr, rawValue.pyStr]
            }
            if !needles.contains(where: { pyContains(text, $0) }) {
                let shown = "[" + needles.map { pyReprString($0) }.joined(separator: ", ") + "]"
                errs.append("\(i): value \(pyReprValue(rawValue)) not found in \(src) (looked for \(shown))")
            }
        }
        return errs
    }
}
