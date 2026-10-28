import Foundation

let README_ROWS = ["d4k", "d16k", "d32k", "c4k_tt", "c16k_tt", "c32k_tt", "a512c4", "p50_512c4", "p95_512c4", "a512c8", "p50_512c8", "p95_512c8",
                   "aagc4", "p50_agc4", "aw5", "p50_w5", "rp8", "rpc8"]

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
        if name == "h2h" {
            let cells = finalCells()
            var rows = ["| Measurement | Strim | rapid-mlx (MTP) | mlx-vlm (no MTP) | vs rapid-mlx | vs mlx-vlm |", "|---|---:|---:|---:|:---:|:---:|"]
            for id in README_ROWS {
                guard let c = cells.first(where: { $0.id == id }) else { throw SiteError("README: unknown cell \(id)") }
                let best = bestEngine(id, c.better)
                let u = c.unit == "%" ? "" : " (\(c.unit))"
                var r = "| \(c.label)\(u) |"
                for e in ENGINES { r += " " + mdCellFig(fid(id, e), bold: e == best) + " |" }
                for rv in RIVALS { r += " " + D.text(fverdict(id, rv)) + " |" }
                rows.append(r)
            }
            return rows.joined(separator: "\n")
        }
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
        return String(out)
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
