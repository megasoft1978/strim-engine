import Foundation

/// Cells shown in the README table, the landing table and the hero chart, in order. Wins and losses are both in here on purpose.
let GLANCE: [String] = ["d4k", "d32k", "aw5", "p50_agc8", "c32k_tt", "aagc8"]
/// Rows of the landing comparison matrix (ids of site/data/features.json), at most 6.
let COMPARE_ROWS: [String] = ["runtime", "breadth", "mtp", "prefix", "messages", "harness"]
/// Rows of the README results table (a win, a win under load, and the losses).
let README_GLANCE: [String] = ["d4k", "aw5", "c32k_tt", "aagc8"]

extension SiteBuilder {
    var rawDirName: String { FINAL_REL.split(separator: "/").last.map(String.init) ?? FINAL_REL }

    func cellLabel(_ id: String) -> String { SHORT[id] ?? finalCells().first(where: { $0.id == id })?.label ?? id }

    // MARK: sentences built from claim figures (f renders a figure id: HTML span for the site, plain text for the README)

    /// "Not faster" facts, from final.claim.* (no hand-typed numbers).
    func notFaster(_ f: (String) -> String) -> String {
        var parts: [String] = []
        let loss = D.text("final.claim.prefill_loss"), tie = D.text("final.claim.prefill_tie")
        if loss == "none" {
            parts.append("cold prefill is at or within 2% of the best rival at every size tested")
        } else {
            let head = tie == "none" ? "" : "at or within 2% of the best rival at \(f("final.claim.prefill_tie")), "
            parts.append("cold prefill is " + head + "\(f("final.claim.prefill_gap")) behind it at \(f("final.claim.prefill_loss"))")
        }
        if (num("final.claim.agg_lower_n") ?? 0) == 0 {
            parts.append("aggregate throughput never trails the best rival by more than 2%")
        } else {
            parts.append("aggregate throughput at 4 to 8 concurrent requests trails the best rival by more than 2% in \(f("final.claim.agg_lower_n")) of 6 cells (\(f("final.claim.agg_lower")))")
        }
        if (num("final.claim.p95_worse_n") ?? 0) == 0 {
            parts.append("p95 first-token latency is never more than 2% worse")
        } else {
            parts.append("p95 first-token latency is more than 2% worse in \(f("final.claim.p95_worse_n")) of 6 cells (\(f("final.claim.p95_worse")))")
        }
        return parts.joined(separator: "; ")
    }

    func notFasterSentence() -> String { notFaster { n($0) } + "." }

    /// Three proof points as (headline, detail).
    func proofPoints(_ f: (String) -> String) -> [(head: String, body: String)] {
        func v(_ cell: String, _ e: String) -> String { f(fid(cell, e)) }
        return [
            ("\(f("final.claim.decode_vs_rapid")) faster decode",
             "than rapid-mlx, and \(f("final.claim.decode_vs_vlm")) the speed of mlx-vlm. At 4K: \(v("d4k", "strim")) vs \(v("d4k", "rapid-mlx")) vs \(v("d4k", "mlx-vlm")) tok/s."),
            ("\(f("final.claim.w5_speedup")) faster for agents sharing a prefix",
             "with four clients on one 16K prefix. Median first token \(v("p50_w5", "strim")) s vs \(v("p50_w5", "rapid-mlx")) s and \(v("p50_w5", "mlx-vlm")) s."),
            ("\(f("final.claim.ttft_p50_lower")) lower median first token",
             "at 4 to 8 concurrent requests, against each rival."),
        ]
    }

    // MARK: run facts

    func runBannerHTML() -> String {
        let run = H["run"]
        let raw = "../" + esc(FINAL_REL)
        var o = "<dl class=\"facts runfacts\">"
        o += "<div><dt>Run</dt><dd><a href=\"\(raw)/summary.md\">\(esc(rawDirName))</a> (<a href=\"\(raw)/results.json\">results.json</a>), \(esc(run?["date"]?.pyStr ?? ""))</dd></div>"
        o += "<div><dt>Strim build</dt><dd>\(n("final.claim.build")), \(n("final.claim.passes")) passes of one rep, medians, \(esc(run?["tie_band_pct"]?.pyStr ?? "2"))% tie band</dd></div>"
        o += "<div><dt>Rivals</dt><dd>\(esc(run?["rapid_mlx"]?.pyStr ?? "")) (MTP on, <code>--max-num-seqs 4</code>), \(esc(run?["mlx_vlm"]?.pyStr ?? "")) (server defaults, no MTP)</dd></div>"
        o += "<div><dt>Machine</dt><dd>\(esc(D.meta["machine"]?.pyStr ?? "")); model \(esc(run?["model"]?.pyStr ?? ""))</dd></div>"
        o += "</dl>"
        o += "<div class=\"callout\" role=\"note\"><p><strong>Validity.</strong> \(validityHTML())</p></div>"
        return o
    }

    /// Claims block of the benchmarks page (data-driven cards, then the not-faster list).
    func claimsSection() -> String {
        func F(_ cell: String, _ e: String) -> String { n(fid(cell, e)) }
        var o = "<section id=\"claims\" aria-labelledby=\"h-claims\"><h2 id=\"h-claims\">What the data supports, and what it does not</h2>"
        o += "<p>Strim against rapid-mlx (MTP on) and mlx-vlm on Qwen3.8-27B 4-bit, one machine. Every claim below is computed from the cells in <a href=\"#r-final\">Results</a>; losses are listed next to the wins.</p>"
        o += "<ul class=\"claims\">"
        o += "<li class=\"claim\"><h3>Decode</h3><p class=\"big\">\(n("final.claim.decode_vs_rapid")) <span class=\"vs\">faster than rapid-mlx</span></p><p>and \(n("final.claim.decode_vs_vlm")) the speed of mlx-vlm, at 4K to 32K context. At 4K: \(F("d4k", "strim")) vs \(F("d4k", "rapid-mlx")) vs \(F("d4k", "mlx-vlm"))&nbsp;tok/s.</p><p class=\"cav\">rapid-mlx also uses MTP; mlx-vlm does not. <a href=\"#r-final\">Details</a></p></li>"
        o += "<li class=\"claim\"><h3>Four agents, one 16K prefix</h3><p class=\"big\">\(n("final.claim.w5_speedup")) <span class=\"vs\">faster aggregate</span></p><p>Four clients on one 16K prefix, aggregate tok/s. Median first token \(F("p50_w5", "strim"))&nbsp;s vs \(F("p50_w5", "rapid-mlx"))&nbsp;s (rapid-mlx) and \(F("p50_w5", "mlx-vlm"))&nbsp;s (mlx-vlm).</p><p class=\"cav\">Neither rival shared the prefix in this setup. <a href=\"#r-final\">Details</a></p></li>"
        o += "<li class=\"claim\"><h3>Median first token under concurrency</h3><p class=\"big\">\(n("final.claim.ttft_p50_lower")) <span class=\"vs\">lower, 4 to 8 concurrent</span></p><p>Against each rival, over 512-token, agent-style and 4K prompts.</p><p class=\"cav\">Rivals report first tokens batch-synchronously, so their median is a weaker number. <a href=\"#r-final\">Details</a></p></li>"
        o += "<li class=\"claim\"><h3>Agent replay</h3><p class=\"big\">\(F("rp8", "strim"))&nbsp;s <span class=\"vs\">vs \(F("rp8", "rapid-mlx"))&nbsp;s (rapid-mlx)</span></p><p>8-turn replay, summed prefill; verdict against rapid-mlx: \(n(fverdict("rp8", "rapid-mlx"))), against mlx-vlm (\(F("rp8", "mlx-vlm"))&nbsp;s): \(n(fverdict("rp8", "mlx-vlm"))).</p><p class=\"cav\">mlx-vlm has no cross-request prefix cache. <a href=\"#r-final\">Details</a></p></li>"
        o += "</ul>"
        o += "<div class=\"notahead\" role=\"note\" aria-labelledby=\"h-notahead\"><h3 id=\"h-notahead\">Where Strim is not faster</h3><ul>"
        o += "<li>\(notFasterSentence())</li>"
        o += "<li><strong>No \"fastest overall\".</strong> Two rivals, one model, one machine, thinking off. No head-to-head against llama.cpp, Ollama or LM Studio exists, so none is claimed.</li>"
        o += "</ul></div></section>\n\n"
        return o
    }

    // MARK: tables

    /// Rows for the glance tables: (cell id, label, unit, direction).
    func glanceRows(_ ids: [String] = GLANCE) -> [(id: String, label: String, unit: String, better: String)] {
        ids.compactMap { id in finalCells().first(where: { $0.id == id }).map { (id, SHORT[id] ?? $0.label, $0.unit, $0.better) } }
    }

    func glanceMarkdown() -> String {
        var rows = ["| Measurement | Strim | rapid-mlx | mlx-vlm | vs rapid-mlx | vs mlx-vlm |", "|---|---:|---:|---:|:---:|:---:|"]
        for r in glanceRows(README_GLANCE) {
            let best = bestEngine(r.id, r.better)
            var line = "| \(HERO_TITLE[r.id] ?? r.label) (\(r.unit)\(r.better == "lower" ? ", lower is better" : "")) |"
            for e in ENGINES { line += " " + mdCellFig(fid(r.id, e), bold: e == best) + " |" }
            for rv in RIVALS { line += " " + D.text(fverdict(r.id, rv)) + " |" }
            rows.append(line)
        }
        return rows.joined(separator: "\n")
    }

    /// Landing table: the glance cells plus the 8-turn replay and whole-run memory (8 rows).
    func glanceTableHTML() -> String {
        var rows: [[String]] = []
        func cellRow(_ id: String, _ label: String, _ unit: String, _ better: String) -> [String] {
            let best = bestEngine(id, better)
            var r = [esc(label) + "<span class=\"sub\">\(esc(unit))\(better == "lower" ? ", lower is better" : "")</span>"]
            for e in ENGINES { r.append(td(fid(id, e), e == best)) }
            for rv in RIVALS { r.append(verdictCell(fverdict(id, rv))) }
            return r
        }
        for g in glanceRows() { rows.append(cellRow(g.id, g.label, g.unit, g.better)) }
        if let c = finalCells().first(where: { $0.id == "rp8" }) { rows.append(cellRow("rp8", "8-turn agent replay, summed prefill", c.unit, c.better)) }
        let mem = H["memory"]?["whole_run_verdict"]
        let memBest = ENGINES.min(by: { (num("final.mem.\($0)") ?? 1e9) < (num("final.mem.\($1)") ?? 1e9) })
        var mr = ["Peak memory, whole run<span class=\"sub\">GB, lower is better</span>"]
        for e in ENGINES { mr.append(td("final.mem.\(e)", e == memBest)) }
        for rv in RIVALS {
            let v = mem?[rv]?.pyStr ?? "n/a"
            let cls = v == "WIN" ? "ahead" : v == "LOSS" ? "behind" : v == "TIE" ? "tied" : ""
            mr.append(cls.isEmpty ? tdText(esc(v), "muted") : tdText("<span class=\"tag \(cls)\">\(esc(v))</span>"))
        }
        rows.append(mr)
        return table("Strim against each rival, median of \(num("final.claim.passes").map { String(Int($0)) } ?? "?") passes (bold = best of the three)",
                     ["Measurement", "Strim", "rapid-mlx", "mlx-vlm", "vs rapid-mlx", "vs mlx-vlm"], rows, numcols: [1, 2, 3])
    }

    /// At most 8 rows, from features.json, rival wins included.
    func compareMatrixHTML() -> String {
        let rows = COMPARE_ROWS.compactMap { id in (F["rows"]?.arr ?? []).first(where: { $0["id"]?.str == id }) }
        var body = ""
        for r in rows {
            body += "<tr><th scope=\"row\">\(esc(r["label"]?.pyStr ?? ""))</th>"
            for e in ENGINES {
                let s = r[e]?["s"]?.pyStr ?? "unknown"
                let note = r[e]?["n"]?.pyStr ?? ""
                body += "<td><span class=\"st st-\(s)\">\(esc(SiteBuilder.STATUS_LABEL[s] ?? s))</span>" + (note.isEmpty ? "" : "<span class=\"fn\">\(esc(note))</span>") + "</td>"
            }
            body += "</tr>"
        }
        let v = F["versions"]
        return "<div class=\"tablewrap\" tabindex=\"0\" role=\"region\" aria-label=\"Comparison\"><table class=\"feat\"><caption>Strim, rapid-mlx and mlx-vlm, checked \(esc(F["date"]?.pyStr ?? ""))</caption>"
            + "<thead><tr><th scope=\"col\">Feature</th><th scope=\"col\">Strim</th><th scope=\"col\">rapid-mlx \(esc(v?["rapid-mlx"]?.pyStr ?? ""))</th><th scope=\"col\">mlx-vlm \(esc(v?["mlx-vlm"]?.pyStr ?? ""))</th></tr></thead><tbody>\(body)</tbody></table></div>"
    }

    // MARK: terminal demo (captured, not generated)

    func loadDemo() -> PyJSON? {
        guard let t = readText(root + "/site/data/demo.json"), let j = try? PyJSONParser.parse(t) else { fail("cannot read site/data/demo.json"); return nil }
        return j
    }

    func terminalHTML() -> String {
        guard let d = loadDemo() else { return "" }
        var code = ""
        var first = true
        for s in d["steps"]?.arr ?? [] {
            if !first { code += "\n" }
            first = false
            code += "<span class=\"tp\">$ </span>\(esc(s["cmd"]?.pyStr ?? ""))\n"
            let out = s["out"]?.pyStr ?? ""
            if !out.isEmpty { code += "<span class=\"to\">\(esc(out))</span>\n" }
        }
        return "<figure class=\"term\"><div class=\"termbar\" aria-hidden=\"true\"><i></i><i></i><i></i></div><pre tabindex=\"0\" aria-label=\"Terminal transcript\"><code>\(code)</code></pre>"
            + "<figcaption>\(esc(d["caption"]?.pyStr ?? ""))</figcaption></figure>"
    }

    // MARK: landing page

    func installTabsHTML() -> String {
        func panel(_ cls: String, _ lines: String, _ note: String) -> String { "<div class=\"panel \(cls)\"><pre><code>\(lines)</code></pre><p class=\"small muted\">\(note)</p></div>" }
        let model = "strim pull                  # Qwen3.8-27B 4-bit + MTP head, about 15 GB, resumable\nstrim serve ~/.strim/models/qwen38-4bit ~/.strim/models/qwen38-mtp-4bit --port 8203"
        var o = "<div class=\"tabs\">"
        o += "<input type=\"radio\" name=\"inst\" id=\"inst-brew\" checked><label for=\"inst-brew\">Homebrew</label>"
        o += "<input type=\"radio\" name=\"inst\" id=\"inst-curl\"><label for=\"inst-curl\">curl</label>"
        o += "<input type=\"radio\" name=\"inst\" id=\"inst-src\"><label for=\"inst-src\">From source</label>"
        o += "<div class=\"panels\">"
        o += panel("p-brew", "brew install megasoft1978/strim/strim\n" + model, "Recommended. Apple Silicon, macOS 14 or newer.")
        o += panel("p-curl", "curl -fsSL https://raw.githubusercontent.com/megasoft1978/strim-engine/main/packaging/install.sh | bash\n" + model, "No sudo: installs to <code>~/.local/strim</code>. The tarball is checked against its SHA-256 first.")
        o += panel("p-src", "git clone https://github.com/megasoft1978/strim-engine &amp;&amp; cd strim-engine\nswift build -c release --disable-sandbox\n.build/release/strim pull", "For developers. Needs Xcode with the Swift 6 toolchain.")
        o += "</div></div>"
        return o
    }

    func faqHTML() -> String {
        func item(_ q: String, _ a: String) -> String { "<details class=\"faq\"><summary>\(esc(q))</summary><div class=\"ans\">\(a)</div></details>" }
        var o = ""
        o += item("Why only one model?", "<p>Everything is tuned for one dense model: its attention state, its speculative-decoding head and its prefix cache. That is why these numbers are possible, and why Strim will not run your other models. Others are on the <a href=\"benchmarks.html#roadmap\">roadmap</a>.</p>")
        o += item("Does speculative decoding change the output?", "<p>Draft tokens are verified by the full model, but batching can flip near-tie tokens. Greedy output over 8 fixed prompts and 64 tokens: Strim against itself \(n("final.agree.self")) identical, against rapid-mlx \(n("final.agree.rapid-mlx")), against mlx-vlm \(n("final.agree.mlx-vlm")). <a href=\"benchmarks.html#exact\">Quality and exactness</a>.</p>")
        o += item("Does it run on a 32 GB Mac or an M1?", "<p>Only a 64&nbsp;GB M5 Max has been tested. For 32&nbsp;GB the computed estimate is \(n("qt.t32")) of context (not measured); 16&nbsp;GB and below are unsupported. See <a href=\"benchmarks.html#scope\">supported scope</a>.</p>")
        o += item("Why is cold prefill not faster?", "<p>On a prompt the engine has never seen, prefill is compute-bound and Strim has no faster kernel than the rivals: \(notFasterSentence()) Strim wins by not repeating prefill (exact prefix cache) and by decoding faster.</p>")
        return o
    }

    func buildLandingHTML() -> String {
        let run = H["run"]
        let pts = proofPoints { n($0) }
        var o = """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Strim</title>
<meta name="description" content="Strim is a single-binary Swift engine that runs Qwen3.8-27B on Apple Silicon as a local backend for Claude Code and Codex. Measured against rapid-mlx and mlx-vlm, losses included.">
<link rel="icon" href="assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="assets/style.css">
</head>
<body class="landing">
<a class="skip" href="#main">Skip to content</a>
<header class="site"><div class="wrap">
<a class="brand" href="#top">Strim</a>
<nav aria-label="Sections"><ul>
<li><a href="#results">Results</a></li><li><a href="#install">Install</a></li><li><a href="#compare">Compare</a></li><li><a href="#faq">FAQ</a></li><li><a href="benchmarks.html">Benchmarks</a></li>
</ul></nav></div></header>
<main id="main"><div class="wrap">

<section class="hero lhero" id="top" aria-labelledby="h-hero">
<div class="herotext">
<h1 id="h-hero">Run Qwen3.8-27B on your Mac like a server.</h1>
<p class="lede">One Swift binary, built for one model: a local backend for Claude Code and Codex.</p>
<div class="cta">
<div class="cmd"><code id="hero-cmd">brew install megasoft1978/strim/strim</code><button type="button" class="copy" data-copy="brew install megasoft1978/strim/strim" hidden>Copy</button></div>
<a class="btn" href="benchmarks.html">See the benchmarks</a>
</div>
<p class="small muted">Apple Silicon, macOS 14 or newer. Tested only on a 64&nbsp;GB M5 Max. MIT license.</p>
</div>
<figure class="heroproof"><figcaption>Strim vs rapid-mlx vs mlx-vlm<span>Median of \(n("final.claim.passes")) passes. Qwen3.8-27B 4-bit.</span></figcaption><div class="hvwrap">\(heroProofSVG())</div></figure>
</section>


"""
        o += "<section id=\"proof\" aria-labelledby=\"h-proof\"><h2 id=\"h-proof\" class=\"sr\">What it does well</h2><ul class=\"proofs\">"
        for p in pts { o += "<li><p class=\"pbig\">\(p.head)</p><p>\(p.body)</p></li>" }
        o += "</ul></section>\n\n"

        o += "<section id=\"results\" aria-labelledby=\"h-results\"><h2 id=\"h-results\">All six measurements, losses included</h2>"
        o += "<figure class=\"hvfig herochart\"><figcaption>Each group has its own scale and starts at zero<span>The badge says WIN or LOSS against the rivals, outside a \(esc(run?["tie_band_pct"]?.pyStr ?? "2"))% tie band. Labels are medians.</span></figcaption>"
        o += "<div class=\"hvpair\"><div class=\"hvwrap\">" + heroBarsSVG(standalone: false, ids: Array(GLANCE.prefix(3)), svgId: "hv4") + "</div><div class=\"hvwrap\">" + heroBarsSVG(standalone: false, ids: Array(GLANCE.dropFirst(3)), svgId: "hv7") + "</div></div></figure>"
        o += "<p class=\"honest\"><strong>Where it is not faster.</strong> \(notFaster { n($0) }.prefix(1).uppercased() + notFaster { n($0) }.dropFirst()).</p>"
        o += "<div class=\"callout\" role=\"note\"><p><strong>Validity.</strong> \(validityHTML())</p></div>"
        o += "<p class=\"note\">\(esc(run?["rapid_mlx"]?.pyStr ?? "")) and \(esc(run?["mlx_vlm"]?.pyStr ?? "")), Strim build \(n("final.claim.build")), \(esc(D.meta["machine"]?.pyStr ?? "")), \(n("final.claim.passes")) passes. "
            + "Run <a href=\"../\(esc(FINAL_REL))/summary.md\">\(esc(rawDirName))</a> (<a href=\"../\(esc(FINAL_REL))/results.json\">raw results</a>), \(esc(run?["date"]?.pyStr ?? "")). Full table and method: <a href=\"benchmarks.html#results\">benchmarks</a>.</p>"
        o += "</section>\n\n"

        o += "<section id=\"install\" aria-labelledby=\"h-install\"><h2 id=\"h-install\">Install</h2>" + installTabsHTML()
        o += "<p>Then point Claude Code at <code>ANTHROPIC_BASE_URL=http://127.0.0.1:8203</code>; the token is in <code>~/.strim/token</code>. See <a href=\"../docs/INSTALL.md\">INSTALL.md</a> and <a href=\"../docs/CLIENTS.md\">CLIENTS.md</a> (Codex included).</p>"
        o += terminalHTML() + "</section>\n\n"

        o += "<section id=\"compare\" aria-labelledby=\"h-compare\"><h2 id=\"h-compare\">Compared</h2>" + compareMatrixHTML()
        o += "<p class=\"note\"><strong>Not found</strong> means no evidence was found, not proof of absence. Strim is new and tested on one machine; the others have larger communities and wider platform support. <a href=\"../\(esc(F["source"]?.pyStr ?? ""))\">Evidence per cell</a>.</p></section>\n\n"

        o += "<section id=\"faq\" aria-labelledby=\"h-faq\"><h2 id=\"h-faq\">FAQ</h2>" + faqHTML() + "</section>\n\n"

        o += """
</div></main>
<footer><div class="wrap"><p><a href="benchmarks.html">Benchmarks</a>, <a href="../docs/ARCHITECTURE.md">architecture</a>, <a href="../docs/INSTALL.md">install</a>, <a href="../LICENSE">MIT license</a>. Source: <code>github.com/megasoft1978/strim-engine</code>. Numbers are generated by <code>strim site build</code> from <a href="data/headline.json">site/data/headline.json</a>.</p></div></footer>
<script>
document.querySelectorAll('[data-copy]').forEach(function (b) {
  b.hidden = false;
  b.addEventListener('click', function () {
    if (!navigator.clipboard) return;
    navigator.clipboard.writeText(b.getAttribute('data-copy')).then(function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy'; }, 1500); });
  });
});
</script>
</body>
</html>

"""
        return o
    }
}
