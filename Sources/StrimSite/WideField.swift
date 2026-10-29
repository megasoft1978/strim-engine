import Foundation

/// Earlier field run used only for llama.cpp and Ollama, which are absent from the final head-to-head.
let WIDE_REL = "bench/results/final-20261026"
/// Scoreboard row shown in the hero chart.
let WIDE_ROW = "W1 greedy-256 decode tok/s"
let WIDE_NAMES: [String: String] = ["strim": "Strim", "rapid-mlx": "rapid-mlx", "mlx-lm": "mlx-lm", "tensorfold": "tensorfold", "omlx": "oMLX", "mlx-vlm": "mlx-vlm", "llama.cpp": "llama.cpp", "ollama": "Ollama"]

struct WideCell: Equatable {
    var raw: String          // the cell text as printed, e.g. "**61.9 (4)**" or "n/a"
    var value: Double?       // the median, nil for n/a
    var best: Bool           // bold in the table
}

struct WideTable {
    var engines: [String]
    var rows: [(metric: String, cells: [WideCell])]
}

/// Parses the first markdown table whose header starts with "metric". Columns not in WIDE_NAMES (the supplemental tensorfold-ctx64k launch) are dropped.
func parseWideScoreboard(_ md: String) -> WideTable? {
    var engines: [String] = []
    var keep: [Int] = []
    var rows: [(String, [WideCell])] = []
    var inTable = false
    for line in md.split(separator: "\n", omittingEmptySubsequences: true) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { if inTable { break }; continue }
        let cells = t.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
        if !inTable {
            guard cells.first == "metric" else { continue }
            inTable = true
            for (k, c) in cells.enumerated().dropFirst() where WIDE_NAMES[c] != nil || (c == "llama.cpp") { engines.append(c); keep.append(k) }
            continue
        }
        if cells.first?.hasPrefix("---") == true { continue }
        guard cells.count == (engines.count + 1) || cells.count > (keep.last ?? 0) else { continue }
        var out: [WideCell] = []
        for k in keep {
            let raw = cells[k]
            let bold = raw.hasPrefix("**")
            let num = raw.replacingOccurrences(of: "*", with: "").split(separator: " ").first.flatMap { Double($0) }
            out.append(WideCell(raw: raw, value: num, best: bold))
        }
        rows.append((cells[0], out))
    }
    return engines.isEmpty ? nil : WideTable(engines: engines, rows: rows)
}

extension SiteBuilder {
    func loadWide() -> WideTable? {
        guard let md = readText(root + "/" + WIDE_REL + "/summary.md"), let t = parseWideScoreboard(md) else { fail("cannot read the scoreboard of \(WIDE_REL)/summary.md"); return nil }
        return t
    }

    /// True when the hero row comes from the current multi-engine head-to-head (its decode row) instead of the archived all-engine run.
    var wideFromRun: Bool { !wideForceArchive && engineList.count >= 5 && hCell("d4k") != nil }

    /// "2026-10-26" from final-20261026 (or the date of the current head-to-head).
    var wideDate: String {
        if wideFromRun { return H["run"]?["date"]?.pyStr ?? "" }
        return wideArchiveDate
    }

    var wideArchiveDate: String {
        let d = WIDE_REL.split(separator: "-").last.map(String.init) ?? ""
        return d.count == 8 ? "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))" : d
    }

    /// Short git hash of the Strim build in the earlier field run.
    var wideBuild: String {
        if wideFromRun { return H["run"]?["strim_build"]?.pyStr ?? "" }
        guard let t = readText(root + "/" + WIDE_REL + "/notes.json"), let j = try? PyJSONParser.parse(t),
              let s = j["versions"]?["strim"]?.pyStr, let m = firstMatch(#"git ([0-9a-f]{7,})"#, in: s) else { return "" }
        return m[1]
    }

    /// Engines with a value in the hero row, fastest first.
    func wideBars() -> [(name: String, value: Double, strim: Bool, earlier: Bool)] {
        if wideFromRun {
            let current = ENGINES.compactMap { e in hCell("d4k")?["values"]?[e]?.number.map { (WIDE_NAMES[e] ?? e, $0, e == "strim", false) } }
            let archived = archivedWideBars()
            return (current + archived).sorted { $0.value > $1.value }
        }
        guard let t = loadWide(), let row = t.rows.first(where: { $0.metric == WIDE_ROW }) else { return [] }
        return zip(t.engines, row.cells).compactMap { e, c in c.value.map { (WIDE_NAMES[e] ?? e, $0, e == "strim", false) } }.sorted { $0.value > $1.value }
    }

    private func archivedWideBars() -> [(name: String, value: Double, strim: Bool, earlier: Bool)] {
        guard let t = loadWide(), let row = t.rows.first(where: { $0.metric == WIDE_ROW }) else { return [] }
        return zip(t.engines, row.cells).compactMap { e, c in
            guard ["llama.cpp", "ollama"].contains(e), let v = c.value else { return nil }
            return (WIDE_NAMES[e] ?? e, v, false, true)
        }
    }

    func wideAlt() -> String {
        if wideFromRun { return "Decode speed in tokens per second at 4K context on Qwen3.8-27B, Apple M5 Max (head-to-head of \(wideDate)): " + wideBars().map { "\($0.name) \(fmtFixed($0.value, 1))\($0.earlier ? " (earlier run)" : "")" }.joined(separator: ", ") + ". Dashed hollow beads are llama.cpp and Ollama from the \(wideArchiveDate) run." }
        return "Decode speed in tokens per second, W1 greedy-256 on Qwen3.8-27B, Apple M5 Max (run of \(wideDate)): " + wideBars().map { "\($0.name) \(fmtFixed($0.value, 1))" }.joined(separator: ", ") + "."
    }

    /// Current decode field with archived llama.cpp and Ollama points clearly marked as earlier measurements.
    func wideSectionHTML() -> String {
        var o = "<section id=\"wide\" aria-labelledby=\"h-wide\"><h2 id=\"h-wide\">Wider field: five engines, with two earlier-run points</h2>"
        o += "<ul class=\"legend earlier-legend\"><li><svg class=\"earlier-run\" viewBox=\"0 0 18 18\" aria-hidden=\"true\"><circle cx=\"9\" cy=\"9\" r=\"5\"/></svg>Dashed hollow beads are llama.cpp and Ollama from the \(esc(wideArchiveDate)) run.</li></ul>"
        o += "<figure class=\"hvfig wide\"><div class=\"glass\"><div class=\"hvwrap\">\(numberLineSVG(narrow: false, standalone: false))\(numberLineSVG(narrow: true, standalone: false))</div></div><figcaption class=\"cap\">\(esc(wideCaption()))</figcaption></figure>"
        o += "<p>The five filled points are medians from the same \(esc(wideDate)) head-to-head, built from Strim \(esc(wideBuild)); llama.cpp and Ollama are hollow dashed beads from the earlier run. They are visual context only. <a href=\"../\(esc(FINAL_REL))/summary.md\">Current run source</a>; <a href=\"../\(esc(WIDE_REL))/summary.md\">earlier run source</a>.</p></section>\n\n"
        return o
    }
}
