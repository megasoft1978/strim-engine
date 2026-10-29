import Foundation

/// Facts about the head-to-head run that the site shows, parsed from <run dir>/summary.md (never typed).
/// The run directory is the single constant FINAL_REL in Builder.swift: pointing it at a newer run and rebuilding replaces every number and caveat.
struct RunMeta {
    var id: String
    var date: String
    var build: String
    var versions: [String: String] = [:]   // engine -> version read from the summary title ("rapid-mlx 0.15.7")
    var rapid: String? { versions["rapid-mlx"] }
    var vlm: String? { versions["mlx-vlm"] }
    var sessions: Int?          // rows of the per-session load table
    var polluted: Int?          // rows marked POLLUTED
    var maxLoad: Double?        // highest 1-min load recorded at a cell start
    var maxSwapMB: Int?         // largest swap growth over the sessions
    var passes: Int
    var title: String
    var clean: Bool { (polluted ?? 0) == 0 }
}

func firstMatch(_ pattern: String, in text: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        guard let r = Range(m.range(at: i), in: text) else { return "" }
        return String(text[r])
    }
}

extension SiteBuilder {
    func parseRunMeta(summary text: String, passes: Int, engines: [String] = ["strim", "rapid-mlx", "mlx-vlm"]) -> RunMeta {
        let title = pySplitlines(text).first.map { pyStrip(String($0.drop(while: { $0 == "#" || $0 == " " }))) } ?? ""
        let id = FINAL_REL.split(separator: "/").last.map(String.init) ?? FINAL_REL
        let date = firstMatch(#"\((\d{4}-\d{2}-\d{2})\)"#, in: title)?[1] ?? firstMatch(#"(\d{4})(\d{2})(\d{2})$"#, in: id).map { "\($0[1])-\($0[2])-\($0[3])" } ?? ""
        let build = firstMatch(#"Strim ([0-9a-f]{7,40}) vs"#, in: title)?[1]
            ?? firstMatch(#"(?:exactly commit|built from commit) ([0-9a-f]{7,40})"#, in: text)?[1]
            ?? "unknown"
        var rows: [[String]] = []
        let secs = mdSections(text)
        if let k = secs.keys.first(where: { $0.hasPrefix("Completeness") }) {
            rows = (secs.lines[k] ?? []).filter { $0.hasPrefix("| ") && $0.contains(" pass ") }
                .map { l in pyStrip(pyStrip(l), chars: ["|"]).split(separator: "|", omittingEmptySubsequences: false).map { pyStrip(String($0)) } }
        }
        var maxLoad: Double?
        var polluted = 0
        for r in rows where r.count >= 4 {
            if r[3].hasPrefix("POLLUTED") { polluted += 1 }
            for tok in r[2].split(whereSeparator: { $0 == "/" || $0 == " " }) { if let v = Double(tok) { maxLoad = max(maxLoad ?? 0, v) } }
        }
        var versions: [String: String] = [:]
        for e in engines.dropFirst() {
            if let v = firstMatch("(?i)" + NSRegularExpression.escapedPattern(for: e) + #" (\d+\.\d+\.\d+(?:\.[A-Za-z0-9]+)?)"#, in: title)?[1] { versions[e] = v }
        }
        var swap: Int?
        for line in pySplitlines(text) {
            if let m = firstMatch(#"swap growth max (\d+) MB"#, in: line), let v = Int(m[1]) { swap = max(swap ?? 0, v) }
        }
        return RunMeta(id: id, date: date, build: build,
                       versions: versions,
                       sessions: rows.isEmpty ? nil : rows.count, polluted: rows.isEmpty ? nil : polluted, maxLoad: maxLoad, maxSwapMB: swap, passes: passes, title: title)
    }

    /// Validity sentence for the run, built from the parsed facts (figure ids final.val.*), plain text with figure markup supplied by `f`.
    func validityText(_ f: (String) -> String) -> String {
        if D.figs["final.val.sessions"] == nil {
            return "summary.md has no per-session load table, so the cleanliness of this run is not stated here; read the raw summary."
        }
        let total = f("final.val.sessions"), bad = f("final.val.polluted")
        if (num("final.val.polluted") ?? 0) > 0 {
            return "\(f("final.val.clean")) of \(total) primary sessions were clean; \(bad) were marked polluted. Reruns are retained in the data. Claims use only cells marked claim eligible (highest primary-session 1-minute load \(f("final.val.load_max")))."
        }
        return "All \(total) primary engine sessions ran clean (highest 1-minute load \(f("final.val.load_max")))."
    }
}

extension SiteBuilder {
    var validityPolluted: Bool { (num("final.val.polluted") ?? 0) > 0 }

    /// Validity sentence plus links to the methodology and full cell table.
    func validityHTML() -> String {
        validityText { n($0) } + " <a href=\"#method\">Method</a> and <a href=\"#r-final\">every cell</a>."
    }

    func validityMarkdown() -> String {
        validityText { D.text($0) } + " [Method](site/benchmarks.html#method) and [every cell](site/benchmarks.html#r-final)."
    }
}
