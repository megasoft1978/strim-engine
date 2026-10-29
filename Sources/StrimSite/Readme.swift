import Foundation

/// The README must stay a short front page; `strim site check` fails above this.
let README_MAX_LINES = 45

extension SiteBuilder {
    /// (id, label, unit, better) of every generated head-to-head cell, in summary order.
    func finalCells() -> [(id: String, label: String, unit: String, better: String)] {
        (D.raw["final"]?["cells"]?.arr ?? []).compactMap { c in
            guard let id = c["id"]?.str else { return nil }
            return (id, c["label"]?.pyStr ?? "", c["unit"]?.pyStr ?? "", c["better"]?.pyStr ?? "")
        }
    }

    /// Engine with the best median in a cell (ties: none), by the cell's direction.
    func bestEngine(_ id: String, _ better: String) -> String? {
        var best: (String, Double)?
        for e in ENGINES {
            guard let v = D.figs[fid(id, e)]?.value.number else { continue }
            if best == nil || (better == "lower" ? v < best!.1 : v > best!.1) { best = (e, v) }
        }
        return best?.0
    }

    func mdCellFig(_ i: String, bold: Bool = false) -> String {
        guard let f = D.figs[i] else { return "n/a" }
        let t = D.text(i) + (f.unit == "%" ? "%" : f.unit == "x" ? "x" : "")
        return bold ? "**\(t)**" : t
    }

    func readmeBlock(_ name: String) throws -> String {
        if name == "soak_line" {
            let ids = ["soak.tasks_passed", "soak.tasks_total", "soak.pass_claude", "soak.pass_codex", "soak.crashes"]
            if ids.allSatisfy({ D.pending($0) }) {
                return "Real-client soak (`claude -p` and `codex exec` against `strim serve`, 30 minutes): **soak: pending.**"
            }
            return "Real-client soak, earlier build (2026-10-27, 30 minutes, `claude -p` and `codex exec` against `strim serve`, toy tasks): tasks passed \(D.text("soak.tasks_passed")) of \(D.text("soak.tasks_total")), "
                + "Claude Code \(D.text("soak.pass_claude"))%, Codex \(D.text("soak.pass_codex"))%, server crashes \(D.text("soak.crashes")), HTTP 5xx \(D.text("soak.http5xx")). "
                + "A reliability check, not a quality benchmark; the Claude Code failures were a harness allow-list flaw, since fixed. Not repeated on the current build or the current sandboxed harness."
        }
        if name == "lossline" {
            return lossLine().replacingOccurrences(of: "All losses: benchmarks.", with: "All losses: [benchmarks](site/benchmarks.html).")
        }
        if name == "glance" { return glanceMarkdown() }
        if name == "proofs" {
            return proofPoints { D.text($0) }.map { "- **\($0.head)** \($0.body)" }.joined(separator: "\n")
        }
        if name == "notfaster" {
            let t = notFaster { D.text($0) }
            return "Not faster: " + t + "."
        }
        if name == "validity" { return validityMarkdown() }
        if name == "runlink" { return "[raw results](\(FINAL_REL)/results.json)" }
        if name == "runline" {
            let run = H["run"]
            return "Run [\(rawDirName)](\(FINAL_REL)/summary.md) ([results.json](\(FINAL_REL)/results.json)), \(run?["date"]?.pyStr ?? ""): Strim build \(D.text("final.claim.build")), \(RIVALS.map { rv in let v = D.figs["ver.h2h.\(rv)"] != nil ? D.text("ver.h2h.\(rv)") : (WIDE_NAMES[rv] ?? rv); return v + (mtpRivals().contains(rv) ? " (MTP on)" : " (no MTP)") }.joined(separator: ", ")), \(D.text("final.claim.passes")) passes of one rep, medians, 2% tie band."
        }
        if name == "app_figure" {
            return appLive("app-hero-live.png") ? "![The Strim menu-bar app with a running server, captured from a live session on a 64 GB M5 Max](\(Self.APP_DIR)app-hero-live.png)" : ""
        }
        if name == "why" { return readmeWhy() }
        if name == "mintable" { return readmeMiniTable() }
        if name == "hero_image" {
            return appLive("readme-hero.png") ? "<a href=\"\(SITE_URL)\"><img src=\"\(Self.APP_DIR)readme-hero.png\" alt=\"The Strim app: a status window with live decode speed beside a chat window running an agent against the local model\" width=\"1200\"></a>" : ""
        }
        if name == "table" { return readmeTable() }
        if name == "caption" { return readmeCaption() }
        if name == "live_caption" { return readmeLiveCaption() }
        if name == "hardware" { return readmeHardware() }
        if name == "decode_alt" { return readmeDecodeAlt() }
        if name == "scoreboard" { return scoreboardMarkdown() }
        if name == "banner_alt" { return bannerAlt() }
        if name == "ratio_alt" { return speedAlt() }
        if name == "features" { return featuresMarkdown() }
        throw SiteError("README template: unknown block @\(name)")
    }

    func buildReadme() throws -> String {
        guard let tpl = readText(readmeTpl) else { throw SiteError("cannot read site/README.template.md") }
        let s = Array(tpl.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            if s[i] == "{", i + 1 < s.count, s[i + 1] == "{" {
                var j = i + 2
                while j < s.count, s[j] != "}" { j += 1 }
                if j > i + 2, j + 1 < s.count, s[j + 1] == "}" {
                    var spec = String.UnicodeScalarView()
                    spec.append(contentsOf: s[(i + 2)..<j])
                    out.append(contentsOf: try readmeSub(pyStrip(String(spec))).unicodeScalars)
                    i = j + 2
                    continue
                }
            }
            out.append(s[i]); i += 1
        }
        return String(out).replacingOccurrences(of: "\n\n\n", with: "\n\n")   // an empty optional block leaves no extra blank line
    }

    private func readmeSub(_ spec: String) throws -> String {
        if spec.hasPrefix("@") { return try readmeBlock(String(spec.dropFirst())) }
        let (i, _, mode) = pyPartition(spec, "|")
        guard let f = D.figs[i] else { throw SiteError("README template: unknown figure \(i)") }
        if D.pending(i) { return "pending" }
        let t = D.text(i)
        if mode == "n" { return t }
        let u = f.unit
        if u == "x" { return t + "x" }
        if u == "%" { return t + "%" }
        return t + (u.isEmpty ? "" : " " + u)
    }
}

extension SiteBuilder {
    private func plain(_ html: String) -> String { html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }

    /// Four bullets, every number from the run data and only for claim-eligible wins.
    func readmeWhy() -> String {
        var out: [String] = []
        if let v = num("final.d4k.strim") {
            var s = "- **Fast decode.** \(fmtFixed(v, 1)) tok/s at 4K context"
            if let r = claimedRatio("d4k") { s += ", \(plain(r.num))x the closest rival (\(r.rival))" }
            out.append(s + ".")
        }
        if let r = claimedRatio("aw5") { out.append("- **Agents share work.** Four agents on one 16K prefix run \(plain(r.num))x faster than the closest rival (\(r.rival)), because the prefix is cached once.") }
        var local = "- **Local and lean.** The server binds `127.0.0.1` only; nothing leaves your Mac."
        if let m = peakMemoryRange() {
            local += " Peak memory \(fmtFixed(m.mine, 1)) GB, against \(fmtFixed(m.lo.v, 1)) GB for \(WIDE_NAMES[m.lo.rv] ?? m.lo.rv)."
        }
        out.append(local)
        out.append("- **Built for agents.** MTP speculative decoding, an exact prefix cache and a sandboxed tool harness, behind OpenAI, Anthropic and Responses APIs plus MCP.")
        return out.joined(separator: "\n")
    }

    /// Three rows: decode at 4K, shared-prefix agents, cold 32K first token (the honest loss). Ratios only where claimable.
    func readmeMiniTable() -> String {
        var rows = ["| Measurement | Strim | Closest rival | Strim vs rival |", "|---|---:|---:|:---:|"]
        for id in ["d4k", "aw5", "c32k_tt"] {
            guard let c = hCell(id), let b = bestRival(id), let unit = c["unit"]?.pyStr else { continue }
            let sv = D.text(fid(id, "strim")), rv = D.text(fid(id, b.rival))
            let verdict = c["verdict"]?[b.rival]?.str ?? "n/a"
            let res = b.claimable && ["WIN", "LOSS", "TIE"].contains(verdict) ? "\(ratioLabel(b.ratio)) \(verdict)" : "not claimable"
            rows.append("| \(HERO_TITLE[id] ?? id) (\(unit)\(c["better"]?.str == "lower" ? ", lower is better" : "")) | \(sv) | \(rv) (\(WIDE_NAMES[b.rival] ?? b.rival)) | \(res) |")
        }
        return rows.joined(separator: "\n")
    }
}
