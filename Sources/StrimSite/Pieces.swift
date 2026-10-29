import Foundation

extension SiteBuilder {
    func soakBlock() -> String {
        let ids = ["soak.tasks_total", "soak.tasks_passed", "soak.claude_tasks", "soak.claude_passed", "soak.pass_claude",
                   "soak.codex_tasks", "soak.codex_passed", "soak.pass_codex", "soak.failures", "soak.elapsed_min",
                   "soak.crashes", "soak.restarts", "soak.http5xx", "soak.requests_total", "soak.requests_failed",
                   "soak.rss_min", "soak.rss_max", "soak.rss_slope", "soak.ttft_q1", "soak.ttft_q4", "soak.ttft_p90"]
        let pend = ids.allSatisfy { D.pending($0) }
        let labels: [String: String] = [
            "soak.tasks_total": "Tasks run", "soak.tasks_passed": "Tasks passed",
            "soak.claude_tasks": "Claude Code + Strim tasks", "soak.claude_passed": "Claude Code + Strim passed",
            "soak.pass_claude": "Claude Code pass rate", "soak.codex_tasks": "Codex + Strim tasks",
            "soak.codex_passed": "Codex + Strim passed", "soak.pass_codex": "Codex pass rate",
            "soak.failures": "Failed tasks", "soak.elapsed_min": "Run length",
            "soak.crashes": "Server crashes", "soak.restarts": "Server restarts",
            "soak.http5xx": "HTTP 5xx events", "soak.requests_total": "Requests served", "soak.requests_failed": "Requests failed",
            "soak.rss_min": "RSS minimum", "soak.rss_max": "RSS maximum", "soak.rss_slope": "RSS slope",
            "soak.ttft_q1": "TTFT median, first quartile", "soak.ttft_q4": "TTFT median, last quartile",
            "soak.ttft_p90": "TTFT p90",
        ]
        let rows = ids.map { [esc(labels[$0]!), td($0, unit: true)] }
        let t = table("30-minute real-client soak", ["Measure", "Value"], rows, numcols: [1])
        if pend {
            return "<div class=\"pendbox\"><p><strong>Soak: pending.</strong> The 30-minute soak (<code>strim soak</code>) is still running "
                + "or has not been summarised. No interim numbers are shown: a run in progress is not a result. "
                + "When a complete run (duration of at least 30 minutes) exists under <code>bench/results/soak-20261027/</code> or <code>bench/soak/results/</code>, <code>strim site refresh-soak</code> fills this table from its <code>summary.txt</code>.</p></div>" + t
        }
        return t
    }

    func versionRows() -> String {
        var rows: [[String]] = []
        let items: [(String, String)] = [
            ("ver.hw", "Hardware"), ("ver.macos", "macOS"), ("ver.mlx_swift", "MLX Swift"),
            ("ver.strim_h2h", "Strim build in the head-to-head"),
        ] + RIVALS.filter { D.figs["ver.h2h.\($0)"] != nil }.map { ("ver.h2h.\($0)", WIDE_NAMES[$0] ?? $0) } + [
            ("ver.claude", "Claude Code (soak client)"), ("ver.codex", "Codex (soak client)"),
        ]
        for (i, label) in items {
            let f = fig(i)
            rows.append([esc(label), tdText("<span title=\"\(esc(i))\">\(esc(f.raw["value"]?.pyStr ?? "None"))</span>"), tdText(srcLink(f.sourcePath), "src")])
        }
        return table("Versions", ["Component", "Version", "Source"], rows)
    }

    func verdictCell(_ id: String) -> String {
        guard D.figs[id] != nil else { return tdText("n/a", "muted") }
        let v = D.text(id)
        let cls = v == "WIN" ? "ahead" : v == "LOSS" ? "behind" : v == "TIE" ? "tied" : ""
        return cls.isEmpty ? tdText(esc(v), "muted") : tdText("<span class=\"tag \(cls)\" title=\"\(esc(id))\">\(esc(v))</span>")
    }

    func bars(_ cell: String, strimLabel: String = "Strim") -> [Bar] {
        ENGINES.map { (e: String) -> Bar in
            (e == "strim" ? strimLabel : ENG_LABEL[e] ?? e, fid(cell, e), e == "strim" ? "strim" : "")
        }
    }

    func cellUnit(_ id: String) -> String { finalCells().first(where: { $0.id == id })?.unit ?? "" }

    /// Launch lines of the rivals for the Reproduce block: engine_meta flags when the run recorded them, the two legacy lines otherwise.
    func rivalLaunchLines() -> String {
        let exe = ["rapid-mlx": "rapid-mlx", "mlx-vlm": "mlx_vlm.server", "mlx-lm": "mlx_lm.server", "omlx": "omlx"]
        let withFlags = RIVALS.filter { engineMeta[$0]?["flags"] != nil }
        if withFlags.isEmpty {
            return esc("rapid-mlx --no-telemetry serve models/qwen38-4bit --port 8651 --max-num-seqs 4 --speculative-config '{\"method\":\"mtp\",\"model\":\"models/qwen38-mtp-4bit\"}'\nmlx_vlm.server --model models/qwen38-4bit --port 8651          # defaults: no MTP, no prefix cache")
        }
        return withFlags.map { esc((exe[$0] ?? $0) + " " + (engineMeta[$0]?["flags"] ?? "")) }.joined(separator: "\n")
    }

    func hasCells(_ ids: [String]) -> Bool { ids.allSatisfy { id in finalCells().contains { $0.id == id } } }

    /// Rivals that run with MTP, per engine_meta (rapid-mlx when the run predates engine_meta).
    func mtpRivals() -> [String] {
        RIVALS.filter { rv in engineMeta[rv]?["mtp"].map { $0.lowercased().hasPrefix("yes") } ?? (rv == "rapid-mlx") }
    }

    /// "rapid-mlx also uses MTP, so the gap to it is the engine, not the speculative head. mlx-vlm and mlx-lm have no MTP, so their gap includes it."
    func mtpNote() -> String {
        let with = mtpRivals().map { WIDE_NAMES[$0] ?? $0 }, without = RIVALS.filter { !mtpRivals().contains($0) }.map { WIDE_NAMES[$0] ?? $0 }
        var parts: [String] = []
        if !with.isEmpty { parts.append("\(esc(listWords(with))) also \(with.count == 1 ? "uses" : "use") MTP, so the gap to \(with.count == 1 ? "it is" : "them is") the engine, not the speculative head.") }
        if !without.isEmpty { parts.append("\(esc(listWords(without))) \(without.count == 1 ? "has" : "have") no MTP, so \(without.count == 1 ? "its" : "their") gap includes it.") }
        return parts.joined(separator: " ")
    }

    /// One sentence per rival about how it was launched: engine_meta flags, MTP and prefix cache when known, the legacy wording otherwise.
    func rivalConfigText() -> String {
        RIVALS.map { rv -> String in
            let name = esc(WIDE_NAMES[rv] ?? rv)
            if let m = engineMeta[rv], let flags = m["flags"] {
                return "\(name) ran as <code>\(esc(flags))</code> (MTP: \(esc(m["mtp"] ?? "n/a")); prefix cache: \(esc(m["prefix_cache"] ?? "n/a")))."
            }
            if rv == "rapid-mlx" { return "rapid-mlx runs with its MTP speculative head on and <code>--max-num-seqs 4</code> (so c=8 queues)." }
            if rv == "mlx-vlm" { return "mlx-vlm runs its server defaults, which means no MTP and no cross-request prefix cache." }
            return "\(name) ran with its server defaults."
        }.joined(separator: " ")
    }

    func finalSection() -> String {
        guard D.raw["final"]?.truthy ?? false else {
            return "<h3 id=\"r-final\">Final head-to-head</h3><div class=\"pendbox\"><p><strong>Missing.</strong> <code>\(FINAL_REL)/</code> was not found, so no final figures exist.</p></div>"
        }
        var o = "<h3 id=\"r-final\">Final head-to-head: Strim vs \(esc(listWords(RIVALS.map { WIDE_NAMES[$0] ?? $0 })))</h3>"
        o += "<p>Qwen3.8-27B 4-bit served alone over HTTP by each engine, one engine on the GPU at a time, thinking off, greedy decoding, on one Apple M5 Max with 64&nbsp;GB. "
            + "\(n("final.claim.passes")) passes (pass 1 in the order \(esc(ENGINES.map { WIDE_NAMES[$0] ?? $0 }.joined(separator: ", "))); pass 2 reversed), one rep per pass, so each value is the median of two runs, which is their mean. "
            + "The largest swap growth in any session was \(n("final.claim.swap"))&nbsp;MB. "
            + "Strim is build \(n("final.claim.build")); \(rivalConfigText()) "
            + "Verdict: WIN / LOSS when the ratio is outside a 2% band, otherwise TIE. Raw files, launch lines and the full per-rival tables: <a href=\"../\(FINAL_REL)/summary.md\">summary.md</a>.</p>"
        o += chart("Decode speed, tok/s (higher is better)", "Greedy, after a cold prompt of each size: 256 tokens at 4K and 16K, 128 tokens at 32K.", [
            ("4K context", bars("d4k")), ("16K context", bars("d16k")), ("32K context", bars("d32k")),
        ], "tok/s")
        let dv = decodeVs { n($0) }
        o += "<p>Strim decodes \(dv.head.replacingOccurrences(of: " decode", with: "")) \(dv.tail), at 4K to 32K context. \(mtpNote())</p>"
        o += chart("Cold prompt time to first token, s (lower is better)", "One distinct prompt at a time, no cache hit possible.", [
            ("4K prompt", bars("c4k_tt")), ("16K prompt", bars("c16k_tt")), ("32K prompt", bars("c32k_tt")),
        ], "s")
        o += "<p class=\"note\">Cold prefill (tok/s): within the 2% band of the best rival at \(n("final.claim.prefill_tie")), \(n("final.claim.prefill_gap")) behind it at \(n("final.claim.prefill_loss")). A tie is not a win.</p>"
        o += chart("Median first-token latency under concurrency, s (lower is better)", "c = number of simultaneous requests. 512-token, agent-style (about 2.8K tokens) and distinct 4K prompts.", [
            ("c=4, 512-token prompts", bars("p50_512c4")), ("c=8, 512-token prompts", bars("p50_512c8")),
            ("c=4, agent prompts", bars("p50_agc4")), ("c=8, agent prompts", bars("p50_agc8")),
            ("c=4, 4K prompts", bars("p50_4kc4")), ("c=8, 4K prompts", bars("p50_4kc8")),
        ], "s")
        o += "<p>Strim has the lowest median first-token latency at 4 to 8 concurrent requests, \(n("final.claim.ttft_p50_lower"))&nbsp;lower than each rival. "
            + "Caveat: rival p50 and p95 are nearly identical (their requests report first tokens batch-synchronously), so their p50 is a weaker number than Strim's per-request TTFT.</p>"
        o += chart("Aggregate decode throughput under concurrency, tok/s (higher is better)", "Total generated tokens per second across all simultaneous requests: the one fully comparable concurrency number.", [
            ("c=4, 512-token prompts", bars("a512c4")), ("c=8, 512-token prompts", bars("a512c8")),
            ("c=4, agent prompts", bars("aagc4")), ("c=8, agent prompts", bars("aagc8")),
            ("c=4, 4K prompts", bars("a4kc4")), ("c=8, 4K prompts", bars("a4kc8")),
        ], "tok/s")
        o += "<p class=\"note\">Strim is more than 2% behind the best rival in \(n("final.claim.agg_lower_n")) of these six cells, by \(n("final.claim.agg_lower")). "
            + "Batched decode narrows the gap but the remaining cost is the quantized matmul at 4 to 8 rows (<a href=\"#how-batch\">below</a>).</p>"
        o += chart("Tail first-token latency (p95), s (lower is better)", "With 4 or 8 requests per cell, p95 is the slowest request.", [
            ("c=4, 512-token prompts", bars("p95_512c4")), ("c=8, 512-token prompts", bars("p95_512c8")),
            ("c=4, agent prompts", bars("p95_agc4")), ("c=8, agent prompts", bars("p95_agc8")),
            ("c=4, 4K prompts", bars("p95_4kc4")), ("c=8, 4K prompts", bars("p95_4kc8")),
        ], "s")
        o += "<p class=\"note\">Strim's p95 is more than 2% worse than the best rival in \(n("final.claim.p95_worse_n")) of these six cells, by \(n("final.claim.p95_worse")). The same staggering that gives a low median pushes the last request out.</p>"
        o += chart("Four agents sharing a 16K prefix: median first-token latency, s (lower is better)", "Four clients send the same 16K prefix with different suffixes at once.", [
            (nil, bars("p50_w5")),
        ], "s")
        o += chart("Four agents sharing a 16K prefix: aggregate throughput, tok/s (higher is better)", "Neither rival shares the prefix across requests in this setup.", [
            (nil, bars("aw5")),
        ], "tok/s")
        o += "<p>With a shared 16K prefix Strim is \(n("final.claim.w5_speedup"))&nbsp;faster than each rival in aggregate throughput.</p>"
        if hasCells(["rp8", "rp6"]) {
            o += chart("Agent replay: summed prefill over 8 turns, s (lower is better)", "Synthetic session, prompts 4.1K to 40.8K tokens, each turn resends the history. Prefill sum is the sum of per-turn first-token latency.", [
                ("Turns 1 to 8", bars("rp8")), ("Turns 1 to 6", bars("rp6")),
            ], "s")
            o += "<p>8-turn replay, summed prefill: \(valuesAcross("rp8", { n($0) + "&nbsp;s" })). \(RIVALS.filter { engineHas("rp8", $0) }.map { "Verdict against \(esc(WIDE_NAMES[$0] ?? $0)): \(n(fverdict("rp8", $0)))" }.joined(separator: "; ")). "
                + "Engines with a cross-request prefix cache reuse part of the turn-8 prompt; the others re-prefill it. "
                + "Replay resends recorded assistant turns, so Strim's token ledger and hot-session reuse do not apply: a lower bound for Strim on a live agent.</p>"
        }
        // full table
        var rows: [[String]] = []
        for c in finalCells() {
            let best = bestEngine(c.id, c.better)
            var r = [esc(c.label), tdText(esc(c.unit), "muted")]
            for e in ENGINES { r.append(D.figs[fid(c.id, e)] != nil ? td(fid(c.id, e), e == best) : tdText("n/a", "num muted")) }
            for rv in RIVALS { r.append(D.figs[fratio(c.id, rv)] != nil ? td(fratio(c.id, rv), unit: true) : tdText("n/a", "num muted")) }
            for rv in RIVALS { r.append(verdictCell(fverdict(c.id, rv))) }
            rows.append(r)
        }
        o += table("All \(finalCells().count) cells: median of \(num("final.claim.passes").map { String(Int($0)) } ?? "?") passes; ratio = Strim / rival; bold = best of the \(ENGINES.count)",
                   ["Cell", "Unit"] + ENGINES.map { engLabel($0) } + RIVALS.map { "Strim / \(WIDE_NAMES[$0] ?? $0)" } + RIVALS.map { "vs \(WIDE_NAMES[$0] ?? $0)" }, rows, numcols: Set(2...(1 + ENGINES.count + RIVALS.count)),
                   foot: "Verdicts: WIN means Strim is better by more than 2%, LOSS worse by more than 2%, TIE within 2%. Lower-is-better cells (TTFT, time) win with a ratio below 1.")
        // A second per-engine detail table keeps median, spread, and validity adjacent and explicit.
        var detailRows: [[String]] = []
        for c in finalCells() {
            let raw = D.raw["final"]?["cells"]?.arr?.first(where: { $0["id"]?.str == c.id })
            var row = [esc(c.label), esc(c.unit)]
            for e in ENGINES {
                row.append(td(fid(c.id, e)))
                let passes = raw?["per_pass"]?[e]?.arr?.compactMap(\.number) ?? []
                if let lo = passes.min(), let hi = passes.max() {
                    row.append(tdText(fmtFixed(hi - lo, hi - lo >= 10 ? 1 : 2), "num"))
                } else { row.append(tdText("n/a", "num muted")) }
                let eligible: Bool
                if case .bool(let value)? = raw?["claim_eligible"]?[e] { eligible = value } else { eligible = engineHas(c.id, e) }
                row.append(tdText(engineHas(c.id, e) ? (eligible ? "yes" : "no") : "n/a", "muted"))
            }
            detailRows.append(row)
        }
        o += table("Per-engine detail: median, spread, valid", ["Cell", "Unit"] + ENGINES.flatMap { ["\(engLabel($0)) median", "range", "valid"] }, detailRows, numcols: Set(2...(1 + ENGINES.count * 3)),
                   foot: "Valid = results.json claim_eligible for that engine and cell. A measured but ineligible comparison is shown with its value and marked no; aborted oMLX cells show n/a.")
        let validity = D.raw["final"]?["validity"]?["sessions"]?.arr ?? []
        if !validity.isEmpty {
            var earliest: [String: Double] = [:]
            func sessionKey(_ s: PyJSON) -> String { "\(s["engine"]?.pyStr ?? "")|\(s["pass"]?.pyStr ?? "")|\((s["cells"]?.arr ?? []).map { $0.pyStr }.joined(separator: ","))" }
            for s in validity {
                let k = sessionKey(s), end = s["end"]?.number ?? .greatestFiniteMagnitude
                earliest[k] = min(earliest[k] ?? .greatestFiniteMagnitude, end)
            }
            let vrows = validity.sorted { ($0["end"]?.number ?? 0) < ($1["end"]?.number ?? 0) }.map { s -> [String] in
                let k = sessionKey(s), primary = (s["end"]?.number ?? .greatestFiniteMagnitude) == earliest[k]
                return [esc(WIDE_NAMES[s["engine"]?.pyStr ?? ""] ?? s["engine"]?.pyStr ?? ""), esc(s["pass"]?.pyStr ?? ""),
                        esc((s["cells"]?.arr ?? []).map { $0.pyStr }.joined(separator: ", ")), primary ? "primary" : "rerun",
                        esc(s["status"]?.pyStr ?? "UNKNOWN"), s["load_max"]?.number.map { fmtFixed($0, 2) } ?? "n/a"]
            }
            o += table("Session validity: \(validity.count) records including retained reruns", ["Engine", "Pass", "Cell groups", "Attempt", "Status", "Load max"], vrows, numcols: [1, 5])
        }
        let losses = finalCells().compactMap { c -> String? in
            guard let b = bestRival(c.id), b.claimable,
                  hCell(c.id)?["verdict"]?[b.rival]?.str == "LOSS" else { return nil }
            let gap = Int(((1 - b.ratio) * 100).rounded())
            return "<li><strong>\(esc(c.label))</strong>: \(gap)% behind \(esc(WIDE_NAMES[b.rival] ?? b.rival)) (ratio \(fmtFixed(b.ratio, 3))×).</li>"
        }
        o += "<h4 id=\"r-losses\">Honest losses</h4>" + (losses.isEmpty ? "<p>No claimable cell is more than 2% behind its best rival.</p>" : "<ul class=\"loss-list\">\(losses.joined())</ul>")
        // memory
        let mrows: [[String]] = [["Peak physical footprint, whole run"] + ENGINES.map { td("final.mem.\($0)") }]
        o += table("Peak memory over the whole run (engine process tree, includes Metal buffers), GB", ["Measure"] + ENGINES.map { WIDE_NAMES[$0] ?? $0 }, mrows, numcols: Set(1...ENGINES.count),
                   foot: "Whole-run maximum over passes and sessions, not steady state. oMLX measured 55.2 GB and exceeded the watchdog threshold; its abort note is retained in the session flags. Largest swap growth: \(n("final.claim.swap"))&nbsp;MB.")
        // agreement
        o += "<h4 id=\"r-agree\">Greedy agreement (sanity check only)</h4><p>8 fixed prompts, 64 greedy tokens. Strim against itself across the two passes: \(n("final.agree.self")) identical. \(RIVALS.filter { D.figs["final.agree.\($0)"] != nil }.map { "Strim against \(esc(WIDE_NAMES[$0] ?? $0)): \(n("final.agree.\($0)"))" }.joined(separator: "; ")). "
            + "The divergences are bf16 near-ties, where a single flipped token changes every later one; it is a sanity check, not a quality measurement.</p>"
        // honest list
        o += "<h4 id=\"r-caveats\">Caveats that change how to read the table</h4><ul>"
        for c in [
            "<strong>Validity.</strong> " + validityHTML(),
            "<strong>Two passes, one rep each.</strong> Pass-to-pass spread is listed in the raw summary; prefill gaps of a few percent sit near the edge of the 2% tie band, so a single flipped pass can change a verdict.",
            "<strong>Rival configuration.</strong> \(rivalConfigText()) Defaults were used otherwise; rival tuning was not explored.",
            "<strong>TTFT definitions differ in practice.</strong> Rivals report batch-synchronous first tokens, so aggregate throughput is the only fully comparable concurrency number.",
            "<strong>Later commits are not included.</strong> Only the build named above was measured.",
            "<strong>One model, one machine, thinking off,</strong> synthetic agent prompts and a synthetic 8-turn fixture.",
        ] { o += "<li>\(c)</li>" }
        o += "</ul>"
        return o
    }

    func tierTable() -> String {
        let rows: [[String]] = [
            ["8 GB", tdText("<span title=\"qt.t8\">unsupported</span>"), tdText("Does not fit: even a 2-bit 27B exceeds the GPU budget.", "wrapcell")],
            ["16 GB", tdText("<span title=\"qt.t16\">unsupported</span>"), tdText("Does not fit in practice with 4-bit weights plus MTP head and runtime.", "wrapcell")],
            ["24 GB", td("qt.t24"), tdText("Estimate for 4-bit: very short context only (bf16 KV / q8 KV, low and high GPU budget).", "wrapcell")],
            ["32 GB", td("qt.t32"), tdText("Estimate (bf16 KV / q8 KV).", "wrapcell")],
            ["36 GB", td("qt.t36"), tdText("Estimate (bf16 KV / q8 KV).", "wrapcell")],
            ["48 GB", td("qt.t48"), tdText("Estimate (bf16 KV).", "wrapcell")],
            ["64 GB", tdText("<span title=\"qt.t64\">full context</span> (measured machine)"), tdText("The only tier Strim has been run on.", "wrapcell")],
        ]
        return table("Memory tiers for the supported 4-bit checkpoint (computed, not measured, except 64 GB)", ["Mac memory", "Context (tokens)", "Status"], rows,
                     foot: "Computed from the model config with an assumed 5.5&nbsp;GiB for macOS and apps; weights are \(n("qt.w4"))&nbsp;GiB of text-only 4-bit and the fixed engine overhead is about \(n("qt.f4"))&nbsp;GiB. "
                         + "On the test machine the GPU working-set limit measured \(n("qt.mem_gib"))&nbsp;GiB. Source: <a href=\"../docs/RESEARCH-QUANT-TIERS-2026-10-27.md\">RESEARCH-QUANT-TIERS</a>. No smaller Mac has been tested.")
    }

    func figureIndex() -> String {
        var rows = ""
        for i in D.order {
            let f = D.figs[i]!
            for k in ["unit", "source_path", "method_note", "caveat"] where f.raw[k] == nil { fail("KeyError: '\(k)' (\(i))") }
            let v = D.text(i)
            let tag = D.pending(i) ? " <span class=\"tag\">pending</span>" : ""
            rows += "<tr id=\"fig-\(esc(i))\"><th scope=\"row\"><code>\(esc(i))</code></th><td class=\"num\">\(esc(v))\(tag)</td><td>\(esc(f.unit))</td>"
                + "<td class=\"src\">\(srcLink(f.sourcePath))</td><td class=\"wrapcell\">\(esc(f.raw["method_note"]?.pyStr ?? ""))</td><td class=\"wrapcell\">\(esc(f.raw["caveat"]?.pyStr ?? ""))</td></tr>"
        }
        let h = ["id", "value", "unit", "source", "method", "caveat"].map { "<th scope=\"col\">\($0)</th>" }.joined()
        return "<div class=\"tablewrap\" tabindex=\"0\" role=\"region\" aria-label=\"All figures\"><table><thead><tr>\(h)</tr></thead><tbody>\(rows)</tbody></table></div>"
    }

}
