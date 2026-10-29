import Foundation

// README front page, Batch 3: lowercase wordmark lockup and the 4K decode bar chart as standalone SVGs for GitHub's dark and light themes.
// Outlined paths only (Mark.swift geometry, unchanged), system fonts, no filters, no green.

let README_ASSET_DIR = "site/assets/readme/"

/// Numbers in the README carry three significant figures (75.3, 9.77, 0.958, 1.02).
func sig3(_ v: Double) -> String {
    guard v != 0, v.isFinite else { return "0" }
    let e = Int(floor(log10(abs(v))))
    let q = pow(10, Double(e - 2))                       // one unit of the third significant digit
    let r = (v / q).rounded() * q
    let dp = max(0, 2 - Int(floor(log10(abs(r)))))
    return String(format: "%.\(dp)f", r)
}

struct ReadmeTheme {
    let name: String, card: String, edge: String, text: String, muted: String, strim: String, rival: String, track: String
    static let dark = ReadmeTheme(name: "dark", card: "#14151A", edge: "#2A2C34", text: BR_TEXT, muted: BR_MUTED, strim: BR_ACCENT, rival: "#686B76", track: "#1B1C22")
    static let light = ReadmeTheme(name: "light", card: "#FFFFFF", edge: "#E1E3E8", text: BR_TEXT_LIGHT, muted: "#595C68", strim: BR_ACCENT_LIGHT, rival: "#8E919C", track: "#F1F2F5")
}

extension SiteBuilder {
    /// Wordmark lockup (S mark + outlined "strim", proportions of the site header), viewBox 212 x 64.
    func readmeWordmarkSVG(_ t: ReadmeTheme) -> String {
        let k = 0.0575, x = 76.0 - 44.1 * k, y = 11.0 + 715.0 * k   // wordmark 42 units tall next to the 64-unit mark, as in the site header
        let d = WORDMARK_DOT
        let word = "<g transform=\"translate(\(fmtFixed(x, 2)) \(fmtFixed(y, 2))) scale(\(fmtFixed(k, 4)))\"><path d=\"\(WORDMARK_PATH)\" fill=\"\(t.text)\"/>"
            + "<rect x=\"\(fnum(d.x))\" y=\"\(fnum(d.y))\" width=\"\(fnum(d.w))\" height=\"\(fnum(d.h))\" rx=\"\(fnum(d.w / 2))\" fill=\"\(t.strim)\"/></g>"
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 212 64\" width=\"212\" height=\"64\" role=\"img\" aria-label=\"strim\"><title>strim</title>"
            + markStreams(stroke: t.strim) + word + "</svg>"
    }

    /// Strim and every rival with a 4K decode value, fastest first.
    func readmeDecodeBars() -> [(name: String, value: Double, strim: Bool)] {
        guard let c = hCell("d4k") else { return [] }
        return ENGINES.compactMap { e -> (String, Double, Bool)? in
            guard let v = c["values"]?[e]?.number, v > 0 else { return nil }
            return (WIDE_NAMES[e] ?? e, v, e == ENGINES.first)
        }.sorted { $0.1 > $1.1 }
    }

    func readmeDecodeAlt() -> String {
        "Decode tok/s at 4K: " + readmeDecodeBars().enumerated().map { ($0.offset == 0 ? "" : "then ") + "\($0.element.name) \(sig3($0.element.value))" }.joined(separator: ", ")
    }

    func readmeDecodeSVG(_ t: ReadmeTheme) -> String {
        let bars = readmeDecodeBars()
        let W = 720.0, x0 = 28.0, labelW = 104.0, barX = x0 + labelW, barW = W - barX - 72.0, top = 70.0, rowH = 38.0, bh = 20.0
        let H_ = top + Double(bars.count) * rowH + 34
        let mx = bars.map(\.value).max() ?? 1
        let font = "font-family=\"\(BR_SANS)\""
        var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(fnum(W)) \(fnum(H_))\" width=\"\(fnum(W))\" height=\"\(fnum(H_))\" role=\"img\" aria-labelledby=\"t d\">"
        s += "<title id=\"t\">Decode speed at 4K context</title><desc id=\"d\">\(esc(readmeDecodeAlt()))</desc>"
        s += "<rect x=\"0.5\" y=\"0.5\" width=\"\(fnum(W - 1))\" height=\"\(fnum(H_ - 1))\" rx=\"12\" fill=\"\(t.card)\" stroke=\"\(t.edge)\"/>"
        s += "<text x=\"\(fnum(x0))\" y=\"34\" \(font) font-size=\"17\" font-weight=\"700\" fill=\"\(t.text)\">Decode speed at 4K context</text>"
        s += "<text x=\"\(fnum(x0))\" y=\"54\" \(font) font-size=\"12.5\" fill=\"\(t.muted)\">Tokens per second, higher is better</text>"
        for (i, b) in bars.enumerated() {
            let y = top + Double(i) * rowH, w = max(2, b.value / mx * barW), col = b.strim ? t.strim : t.rival
            s += "<text x=\"\(fnum(x0))\" y=\"\(fnum(y + bh - 5))\" \(font) font-size=\"14\" font-weight=\"\(b.strim ? 700 : 400)\" fill=\"\(b.strim ? t.text : t.muted)\">\(esc(b.name))</text>"
            s += "<rect x=\"\(fnum(barX))\" y=\"\(fnum(y))\" width=\"\(fnum(barW))\" height=\"\(fnum(bh))\" rx=\"4\" fill=\"\(t.track)\"/>"
            s += "<rect x=\"\(fnum(barX))\" y=\"\(fnum(y))\" width=\"\(fnum(w))\" height=\"\(fnum(bh))\" rx=\"4\" fill=\"\(col)\"/>"
            s += "<text x=\"\(fnum(barX + barW + 10))\" y=\"\(fnum(y + bh - 5))\" \(font) font-size=\"14\" font-weight=\"\(b.strim ? 700 : 400)\" fill=\"\(t.text)\">\(sig3(b.value))</text>"
        }
        let run = H["run"], machine = (run?["machine"]?.pyStr ?? "").components(separatedBy: ", macOS").first ?? ""
        s += "<text x=\"\(fnum(x0))\" y=\"\(fnum(H_ - 14))\" \(font) font-size=\"11.5\" fill=\"\(t.muted)\">\(esc(machine)), \(esc(run?["date"]?.pyStr ?? "")), median of \(D.text("final.claim.passes")) passes, one engine at a time</text>"
        return s + "</svg>"
    }

    /// (path relative to the repo root, SVG)
    func readmeAssets() -> [(String, String)] {
        var out: [(String, String)] = []
        for t in [ReadmeTheme.dark, ReadmeTheme.light] {
            out.append((README_ASSET_DIR + "wordmark-\(t.name).svg", readmeWordmarkSVG(t)))
            out.append((README_ASSET_DIR + "decode-\(t.name).svg", readmeDecodeSVG(t)))
        }
        return out
    }

    // MARK: table

    /// "**1.50x**" for a win, "0.96x, slower" for a loss outside the 2% tie band, "1.01x, tie" inside it. Never colour, never caps.
    func readmeRatio(_ r: Double) -> String {
        if r >= 1.02 { return "**\(fmtFixed(r, 2))x**" }
        if r <= 0.98 { return "\(fmtFixed(r, 2))x, slower" }
        return "\(fmtFixed(r, 2))x, tie"
    }

    /// Rivals with a claimable value in every table row (a rival that aborted in one of them is left out of ranges).
    func readmeTableRivals() -> [String] {
        RIVALS.filter { rv in ["d4k", "aw5", "c32k_tt", "a512c4", "a512c8"].allSatisfy { !["NC", "n/a"].contains(hCell($0)?["verdict"]?[rv]?.str ?? "n/a") } }
    }

    func readmeRow(_ label: String, _ id: String) -> String? {
        guard let c = hCell(id), let s = c["values"]?["strim"]?.number, let b = bestRival(id), b.claimable, let rv = c["values"]?[b.rival]?.number else { return nil }
        return "| \(label) | \(sig3(s)) | \(sig3(rv)) (\(WIDE_NAMES[b.rival] ?? b.rival)) | \(readmeRatio(b.ratio)) |"
    }

    func readmeTable() -> String {
        var rows = ["| Workload | Strim | Best other engine | Ratio |", "|---|---:|---:|---:|"]
        if let r = readmeRow("Decode, 4K context (tok/s)", "d4k") { rows.append(r) }
        if let r = readmeRow("4 agents, shared 16K prefix (tok/s)", "aw5") { rows.append(r) }
        if let m = peakMemoryRange() {
            let lo = fmtFixed(m.lo.v, 1), hi = fmtFixed(m.hi.v, 1)
            rows.append("| Peak memory, whole run (GB, lower is better) | \(fmtFixed(m.mine, 1)) | \(lo == hi ? lo : "\(lo)-\(hi)") | \(readmeRatio(m.lo.v / m.mine)) |")
        }
        if let r = readmeRow("Cold 32K prompt, first token (s, lower is better)", "c32k_tt") { rows.append(r) }
        for (id, label) in [("a512c4", "4 concurrent requests, aggregate (tok/s)"), ("a512c8", "8 concurrent requests, aggregate (tok/s)")] {
            if let r = readmeRow(label, id) { rows.append(r) }
        }
        return rows.joined(separator: "\n")
    }

    func readmeCaption() -> String {
        let run = H["run"]
        let parts = (run?["machine"]?.pyStr ?? "").components(separatedBy: ", macOS ")
        let model = (run?["model"]?.pyStr ?? "").components(separatedBy: " + ").first ?? ""
        return "<sub>\(parts[0]), macOS \(parts.count > 1 ? parts[1] : ""), \(model), one engine at a time, median of \(D.text("final.claim.passes")) passes, \(run?["date"]?.pyStr ?? ""), build \(run?["strim_build"]?.pyStr ?? ""). Ratio above 1 means Strim is better. "
            + "Not a fit if you want many models or a model browser: use Ollama or LM Studio. [Every cell and method](\(SITE_URL)benchmarks.html) · [raw data](\(FINAL_REL)) · MIT · Not affiliated with Qwen, Alibaba or Apple.</sub>"
    }

    func readmeLiveCaption() -> String { liveCaptionText() }

    func readmeHardware() -> String { ((H["run"]?["machine"]?.pyStr ?? "").components(separatedBy: ", macOS").first) ?? "" }
}
