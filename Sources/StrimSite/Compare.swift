import Foundation

extension SiteBuilder {
    private func hvFigure(_ caption: String, _ sub: String, _ label: String, _ svg: String) -> String {
        "<figure class=\"hvfig\"><figcaption>\(esc(caption))<span>\(esc(sub))</span></figcaption>"
            + "<div class=\"hvwrap\" tabindex=\"0\" role=\"region\" aria-label=\"\(esc(label))\">\(svg)</div></figure>"
    }

    /// Verdict counts over cells whose id starts with `prefix` (latency cells), per rival.
    private func countVerdict(_ prefix: String, _ rv: String, _ v: String) -> (Int, Int) {
        let ids = (REGIMES.first(where: { $0.id == "latency" })?.cells ?? []).filter { $0.hasPrefix(prefix) }
        let n = ids.filter { hCell($0)?["verdict"]?[rv]?.str == v }.count
        return (n, ids.count)
    }

    func compareSection() -> String {
        let run = H["run"]
        let mem = H["memory"]
        let wr = mem?["whole_run"]
        let mv = mem?["whole_run_verdict"]
        var o = "<section id=\"compare\" aria-labelledby=\"h-compare\"><h2 id=\"h-compare\">Strim vs rapid-mlx vs mlx-vlm at a glance</h2>"
        o += "<p>Head-to-head of \(esc(run?["date"]?.pyStr ?? "")) (\(esc(run?["id"]?.pyStr ?? ""))): Strim build \(esc(run?["strim_build"]?.pyStr ?? "")), \(esc(run?["rapid_mlx"]?.pyStr ?? "")) with MTP on, \(esc(run?["mlx_vlm"]?.pyStr ?? "")) with server defaults, "
            + "\(esc(run?["model"]?.pyStr ?? "")) on \(esc(run?["machine"]?.pyStr ?? "")), \(run?["passes"]?.pyStr ?? "") passes of one rep. "
            + "Wins and losses are drawn the same way. A verdict is WIN or LOSS only outside a \(run?["tie_band_pct"]?.pyStr ?? "2")% band. "
            + "Only numbers measured on that build are shown; work done since is not re-benchmarked and not included.</p>"
        o += scoreboardHTML()
        let losing = (H["scoreboard"]?["regimes"]?.arr ?? []).filter { r in RIVALS.contains { scoreCounts(r, $0).2 > 0 } }.map { $0["label"]?.pyStr ?? "" }
        o += "<p class=\"note\">Regimes with at least one LOSS against a rival: \(esc(losing.joined(separator: ", "))). Cells are counted once (cold prefill by tok/s, not again by first-token time). Every cell is in the <a href=\"#r-final\">full table</a>.</p>"
        o += hvFigure("Speed-up of Strim over each rival, per measurement", "Right of 1\u{00d7} Strim is faster, left it is slower. Higher is always better: for seconds the ratio is inverted.", "Speed-up chart, scrolls sideways on narrow screens", heroSVG(standalone: false))
        o += "<h3 id=\"c-memory\">Memory</h3>"
        let lowest = mem?["strim_lowest_cells"]?.pyStr ?? "0", total = mem?["cells_total"]?.pyStr ?? "0"
        o += "<p>Peak physical footprint over the whole run: Strim \(fnum(wr?["strim"]?.number ?? 0))&nbsp;GB, rapid-mlx \(fnum(wr?["rapid-mlx"]?.number ?? 0))&nbsp;GB, mlx-vlm \(fnum(wr?["mlx-vlm"]?.number ?? 0))&nbsp;GB "
            + "(\(esc(mv?["rapid-mlx"]?.pyStr ?? "")) against rapid-mlx, \(esc(mv?["mlx-vlm"]?.pyStr ?? "")) against mlx-vlm). "
            + (lowest == total ? "Strim has the lowest peak in every workload cell.</p>" : "Per workload cell the picture is mixed: Strim has the lowest peak in \(lowest) of \(total) cells; the whole-run figure is each engine's largest cell.</p>")
        o += hvFigure("Peak memory footprint by workload (GB)", "Engine process tree, includes Metal buffers; maximum over passes and sessions. Nobody swapped.", "Memory chart, scrolls sideways on narrow screens", memorySVG(standalone: false))
        o += "<h3 id=\"c-latency\">Latency</h3>"
        func cnt(_ prefix: String, _ rv: String, _ v: String) -> String { let (n, t) = countVerdict(prefix, rv, v); return "\(n) of \(t)" }
        o += "<p>Median first token (p50): Strim WINs \(cnt("p50", "rapid-mlx", "WIN")) cells against rapid-mlx and \(cnt("p50", "mlx-vlm", "WIN")) against mlx-vlm. "
            + "Tail (p95): WIN \(cnt("p95", "rapid-mlx", "WIN")) and LOSS \(cnt("p95", "rapid-mlx", "LOSS")) against rapid-mlx; WIN \(cnt("p95", "mlx-vlm", "WIN")) and LOSS \(cnt("p95", "mlx-vlm", "LOSS")) against mlx-vlm. "
            + "With four or eight requests per cell p95 is the slowest request, and the rivals deliver first tokens batch-synchronously, so their p50 is a weaker number than Strim's.</p>"
        o += hvFigure("First-token latency (TTFT) at c=4 and c=8, seconds", "Median (p50) and 95th percentile (p95). Lower is better; bars start at zero, each prompt class has its own scale.", "Latency chart, scrolls sideways on narrow screens", latencySVG(standalone: false))
        o += "</section>\n\n"
        o += featuresSection()
        return o
    }

    func featuresSection() -> String {
        let rows = F["rows"]?.arr ?? []
        let behind = rows.filter { r in
            let s = r["strim"]?["s"]?.str ?? ""
            return (s == "no" || s == "partial") && RIVALS.contains { r[$0]?["s"]?.str == "yes" }
        }.map { $0["label"]?.pyStr ?? "" }
        var o = "<section id=\"features\" aria-labelledby=\"h-features\"><h2 id=\"h-features\">Functionality</h2>"
        o += "<p>Strim is a one-model engine, so it does not try to match the rivals on breadth. Rows are checked against the installed packages, their <code>--help</code>, their README or this repository; "
            + "see <a href=\"../\(esc(F["source"]?.pyStr ?? ""))\">the comparison notes</a> for the evidence behind every cell. Rows with a Yes: \(esc(featureCounts())).</p>"
        o += featuresHTML()
        o += "<p class=\"note\"><strong>Not found</strong> means no evidence was found in what was checked, not proof of absence. <strong>Unknown</strong> means not verified. Where a rival is ahead of Strim (Strim has No or Partial, a rival has Yes): \(esc(behind.joined(separator: "; "))).</p>"
        o += "</section>\n\n"
        return o
    }
}
