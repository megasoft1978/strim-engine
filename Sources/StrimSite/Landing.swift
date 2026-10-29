import Foundation

/// Cells shown in the README table, the landing table and the hero chart, in order. Wins and losses are both in here on purpose.
let GLANCE: [String] = ["d4k", "d32k", "aw5", "p50_agc8", "c32k_tt", "aagc8"]
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

    /// Figure ids of the engines that have a value in a cell (n/a cells carry no value).
    func engineHas(_ cell: String, _ e: String) -> Bool { D.figs[fid(cell, e)].map { !$0.value.isNull } ?? false }

    /// Values for a cell in run order, with n/a engines omitted.
    func valuesAcross(_ cell: String, _ f: (String) -> String, sep: String = " ") -> String {
        ENGINES.filter { engineHas(cell, $0) }.map { "\(WIDE_NAMES[$0] ?? $0)\(sep)\(f(fid(cell, $0)))" }.joined(separator: " vs ")
    }

    /// Decode gain sentence from the claim figures: "17-24% faster than rapid-mlx, 2.0-2.1x the speed of mlx-lm", closest rival first.
    func decodeVs(_ f: (String) -> String) -> (head: String, tail: String) {
        let closest = bestRival("d4k")?.rival
        let order = RIVALS.filter { $0 == closest } + RIVALS.filter { $0 != closest }
        func phrase(_ rv: String) -> String? {
            let id = "final.claim.decode_vs.\(rv)"
            guard D.figs[id] != nil, D.text(id) != "n/a" else { return nil }
            return D.text(id).hasSuffix("%") ? "\(f(id)) faster than \(WIDE_NAMES[rv] ?? rv)" : "\(f(id)) the speed of \(WIDE_NAMES[rv] ?? rv)"
        }
        let ps = order.compactMap(phrase)
        guard let first = order.first(where: { phrase($0) != nil }) else { return ("n/a", "") }
        let id = "final.claim.decode_vs.\(first)"
        let head = D.text(id).hasSuffix("%") ? "\(f(id)) faster decode" : "\(f(id)) the decode speed"
        let rest = Array(ps.dropFirst())
        let lead = D.text(id).hasSuffix("%") ? "than \(WIDE_NAMES[first] ?? first), the closest rival" : "of \(WIDE_NAMES[first] ?? first), the closest rival"
        return (head, lead + (rest.isEmpty ? "" : "; " + listWords(rest)))
    }

    /// Three proof points as (headline, detail).
    func proofPoints(_ f: (String) -> String) -> [(head: String, body: String)] {
        let d = decodeVs(f)
        let p50 = valuesAcross("p50_w5", { f($0) + " s" })
        return [
            (d.head, d.tail + ". At 4K: " + valuesAcross("d4k", f) + " tok/s."),
            ("\(f("final.claim.w5_speedup")) faster for agents sharing a prefix",
             "with four clients on one 16K prefix. Median first token: \(p50)."),
            ("\(f("final.claim.ttft_p50_lower")) lower median first token",
             "at 4 to 8 concurrent requests, against each rival."),
        ]
    }

    // MARK: run facts

    /// "rapid-mlx 0.15.7 (MTP on, ...), mlx-vlm 0.7.10 (server defaults, no MTP)" for the rivals of the run.
    func rivalsFactText() -> String {
        RIVALS.map { rv -> String in
            let name = WIDE_NAMES[rv] ?? rv
            let ver = engVersion(rv).map { " " + $0 } ?? ""
            if let m = engineMeta[rv]?["mtp"] {
                return "\(esc(name))\(esc(ver)) (\(m.lowercased().hasPrefix("yes") ? "MTP on" : "no MTP")" + (rv == "rapid-mlx" ? ", <code>--max-num-seqs 4</code>" : "") + ")"
            }
            if rv == "rapid-mlx" { return "\(esc(run_ver(rv))) (MTP on, <code>--max-num-seqs 4</code>)" }
            if rv == "mlx-vlm" { return "\(esc(run_ver(rv))) (server defaults, no MTP)" }
            return esc(name + ver)
        }.joined(separator: ", ")
    }

    private func run_ver(_ rv: String) -> String { D.figs["ver.h2h.\(rv)"] != nil ? D.text("ver.h2h.\(rv)") : (WIDE_NAMES[rv] ?? rv) + (engVersion(rv).map { " " + $0 } ?? "") }

    func runBannerHTML() -> String {
        let run = H["run"]
        let raw = "../" + esc(FINAL_REL)
        var o = "<dl class=\"facts runfacts\">"
        o += "<div><dt>Run</dt><dd><a href=\"\(raw)/summary.md\">\(esc(rawDirName))</a> (<a href=\"\(raw)/results.json\">results.json</a>), <span style=\"white-space:nowrap\">\(esc(run?["date"]?.pyStr ?? ""))</span></dd></div>"
        o += "<div><dt>Strim build</dt><dd>\(n("final.claim.build")), \(n("final.claim.passes")) passes of one rep, medians, \(esc(run?["tie_band_pct"]?.pyStr ?? "2"))% tie band</dd></div>"
        o += "<div><dt>Rivals</dt><dd>\(rivalsFactText())</dd></div>"
        o += "<div><dt>Machine</dt><dd>\(esc(D.meta["machine"]?.pyStr ?? "")); model \(esc(run?["model"]?.pyStr ?? ""))</dd></div>"
        o += "</dl>"
        o += "<div class=\"callout\" role=\"note\"><p><strong>Validity.</strong> \(validityHTML())</p></div>"
        o += claimPolicyHTML()
        return o
    }

    /// Claim policy and what it withheld in this run: cells that cannot carry a WIN or LOSS, with the reason, and the flags that excluded passes.
    func claimPolicyHTML() -> String {
        guard let nc = D.raw["final"]?["not_claimable"]?.obj, !nc.keys.isEmpty else { return "" }
        var items = ""
        var count = 0
        for (id, v) in nc.items {
            let label = cellLabel(id)
            for (rv, why) in v.obj?.items ?? [] { count += 1; items += "<li><strong>\(esc(label))</strong> vs \(esc(WIDE_NAMES[rv] ?? rv)): \(esc(why.pyStr))</li>" }
        }
        return "<div class=\"callout\" role=\"note\" id=\"claim-policy\"><details><summary><strong>Not claimable:</strong> \(count) comparisons excluded (open for the list)</summary><p> Verdicts are only printed for a cell when every pass of both engines is present, none was excluded (abort, memory guard, OOM, timeout) and every session was clean. The numbers below stay visible; no WIN or LOSS is attached to these comparisons:</p><ul>\(items)</ul></details></div>"
    }

    /// Claims block of the benchmarks page (data-driven cards, then the not-faster list).
    func claimsSection() -> String {
        func F(_ cell: String, _ e: String) -> String { n(fid(cell, e)) }
        let d = decodeVs { n($0) }
        let names = listWords(RIVALS.map { WIDE_NAMES[$0] ?? $0 })
        var o = "<section id=\"claims\" aria-labelledby=\"h-claims\"><h2 id=\"h-claims\">What the data supports, and what it does not</h2>"
        o += "<p>Strim against \(esc(names)) on Qwen3.8-27B 4-bit, one machine. Every claim below is computed from the cells in <a href=\"#r-final\">Results</a>; losses are listed next to the wins.</p>"
        o += "<ul class=\"claims\">"
        o += "<li class=\"claim\"><h3>Decode</h3><p class=\"big\">\(d.head) </p><p>\(d.tail), at 4K to 32K context. At 4K: \(valuesAcross("d4k", { n($0) }))&nbsp;tok/s.</p><p class=\"cav\">Engines differ in speculative decoding (MTP) and prefix caching; see the table of rivals above. <a href=\"#r-final\">Details</a></p></li>"
        o += "<li class=\"claim\"><h3>Four agents, one 16K prefix</h3><p class=\"big\">\(n("final.claim.w5_speedup")) <span class=\"vs\">faster aggregate</span></p><p>Four clients on one 16K prefix, aggregate tok/s. Median first token: \(valuesAcross("p50_w5", { n($0) + "&nbsp;s" })).</p><p class=\"cav\">Engines without a cross-request prefix cache cannot share the prefix in this setup. <a href=\"#r-final\">Details</a></p></li>"
        o += "<li class=\"claim\"><h3>Median first token under concurrency</h3><p class=\"big\">\(n("final.claim.ttft_p50_lower")) <span class=\"vs\">lower, 4 to 8 concurrent</span></p><p>Against each rival, over 512-token, agent-style and 4K prompts.</p><p class=\"cav\">Some rivals report first tokens batch-synchronously, so their median is a weaker number. <a href=\"#r-final\">Details</a></p></li>"
        if engineHas("rp8", "strim") {
            let ver = RIVALS.filter { engineHas("rp8", $0) }.map { "\(esc(WIDE_NAMES[$0] ?? $0)) (\(F("rp8", $0))&nbsp;s): \(n(fverdict("rp8", $0)))" }.joined(separator: "; ")
            o += "<li class=\"claim\"><h3>Agent replay</h3><p class=\"big\">\(F("rp8", "strim"))&nbsp;s <span class=\"vs\">8-turn replay</span></p><p>Summed prefill. Verdict against \(ver).</p><p class=\"cav\">Engines without a cross-request prefix cache re-prefill every turn. <a href=\"#r-final\">Details</a></p></li>"
        }
        o += "</ul>"
        o += "<div class=\"notahead\" role=\"note\" aria-labelledby=\"h-notahead\"><h3 id=\"h-notahead\">Where Strim is not faster</h3><ul>"
        o += "<li>\(notFasterSentence())</li>"
        o += "<li><strong>No \"fastest overall\".</strong> \(RIVALS.count) rivals, one model, one machine, thinking off. No head-to-head against llama.cpp, Ollama or LM Studio exists, so none is claimed.</li>"
        o += "</ul></div></section>\n\n"
        return o
    }

    // MARK: tables

    /// Rows for the glance tables: (cell id, label, unit, direction).
    func glanceRows(_ ids: [String] = GLANCE) -> [(id: String, label: String, unit: String, better: String)] {
        ids.compactMap { id in finalCells().first(where: { $0.id == id }).map { (id, SHORT[id] ?? $0.label, $0.unit, $0.better) } }
    }

    func glanceMarkdown() -> String {
        var rows = ["| Measurement | " + ENGINES.map { WIDE_NAMES[$0] ?? $0 }.joined(separator: " | ") + " | " + RIVALS.map { "vs \(WIDE_NAMES[$0] ?? $0)" }.joined(separator: " | ") + " |", "|---|" + ENGINES.map { _ in "---:" }.joined(separator: "|") + "|" + RIVALS.map { _ in ":---:" }.joined(separator: "|") + "|"]
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
        if let c = finalCells().first(where: { $0.id == "rp8" }), engineHas("rp8", "strim") { rows.append(cellRow("rp8", "8-turn agent replay, summed prefill", c.unit, c.better)) }
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
        return table("Strim against each rival, median of \(num("final.claim.passes").map { String(Int($0)) } ?? "?") passes (bold = best of the \(ENGINES.count))",
                     ["Measurement"] + ENGINES.map { WIDE_NAMES[$0] ?? $0 } + RIVALS.map { "vs \(WIDE_NAMES[$0] ?? $0)" }, rows, numcols: Set(1...ENGINES.count))
    }

    // MARK: landing page

    static let BREW_CMD = "brew install megasoft1978/strim/strim"
    static let CASK_CMD = "brew install --cask megasoft1978/strim/strim-app"
    static let PULL_CMD = "strim pull"
    static let CURL_CMD = "curl -fsSL https://raw.githubusercontent.com/megasoft1978/strim-engine/main/packaging/install.sh | bash"
    static let XATTR_CMD = "xattr -dr com.apple.quarantine /Applications/Strim.app"

    /// Three install paths as tabs (text from packaging/INSTALL-SNIPPETS.md), each command with its own copy button.
    func installTabsHTML() -> String {
        func cmd(_ c: String, comment: String = "") -> String {
            "<div class=\"cmd\"><code><span class=\"pr\">$</span> \(escCmd(c))\(comment.isEmpty ? "" : " <span class=\"cm\"># \(esc(comment))</span>")</code><button type=\"button\" class=\"copy\" aria-label=\"Copy command\" data-copy=\"\(esc(c))\" hidden>Copy</button></div>"
        }
        var o = "<div class=\"tabs\">"
        o += "<input type=\"radio\" name=\"inst\" id=\"inst-brew\" checked><label for=\"inst-brew\">Homebrew</label>"
        o += "<input type=\"radio\" name=\"inst\" id=\"inst-curl\"><label for=\"inst-curl\">curl</label>"
        o += "<input type=\"radio\" name=\"inst\" id=\"inst-dmg\"><label for=\"inst-dmg\">DMG</label>"
        o += "<div class=\"panels\">"
        o += "<div class=\"panel p-brew\">" + cmd(Self.BREW_CMD) + cmd(Self.PULL_CMD) + "<p class=\"cmdnote\"># optional: menu-bar app, includes the CLI</p>" + cmd(Self.CASK_CMD)
            + "<p class=\"cap\">Installs the <code>strim</code> command, then downloads the model.</p></div>"
        o += "<div class=\"panel p-curl\">" + cmd(Self.CURL_CMD) + cmd(Self.PULL_CMD)
            + "<p class=\"cap\">No sudo. Installs to <code>~/.local/strim</code> and links <code>~/.local/bin/strim</code>. Checks the SHA-256 before installing.</p></div>"
        o += "<div class=\"panel p-dmg\"><div class=\"dmgrow\"><a class=\"btn\" href=\"\(REPO_URL)/releases/latest\">Download the DMG (arm64)</a>"
            + "<span class=\"cap\">Open the DMG. Drag Strim to Applications. Launch Strim from the menu bar.</span></div>"
            + "<p class=\"warn\"><strong>Not notarized yet: right-click &rarr; Open the first time.</strong> macOS warns on first launch. Right-click Strim in Applications and choose Open, or click Open Anyway in System Settings, Privacy and Security, or run <code>\(esc(Self.XATTR_CMD))</code>. Homebrew avoids the warning.</p></div>"
        o += "</div></div>"
        return o
    }

    func faqHTML() -> String {
        func item(_ q: String, _ a: String) -> String { "<details class=\"faq\"><summary>\(esc(q))</summary><div class=\"ans\">\(a)</div></details>" }
        var o = ""
        o += item("Why only one model?", "<p>Everything is tuned for one dense model: its attention state, its speculative-decoding head and its prefix cache. That is why these numbers are possible, and why Strim will not run your other models. Others are on the <a href=\"benchmarks.html#roadmap\">roadmap</a>.</p>")
        o += item("Does it run on a 32 GB Mac or an M1?", "<p>Only a 64&nbsp;GB M5 Max has been tested. For 32&nbsp;GB the computed estimate is \(n("qt.t32")) of context (not measured); 16&nbsp;GB and below are unsupported. See <a href=\"benchmarks.html#scope\">supported scope</a>.</p>")
        o += item("Does speculative decoding change the output?", "<p>Draft tokens are verified by the full model, but batching can flip near-tie tokens. Greedy output over 8 fixed prompts and 64 tokens: Strim against itself \(n("final.agree.self")) identical, \(RIVALS.filter { D.figs["final.agree.\($0)"] != nil }.map { "against \(WIDE_NAMES[$0] ?? $0) \(n("final.agree.\($0)"))" }.joined(separator: ", ")). <a href=\"benchmarks.html#exact\">Quality and exactness</a>.</p>")
        o += item("Does anything leave my Mac?", "<p>No prompts or files do. The server binds <code>127.0.0.1</code> only and requires a bearer token. The one network step is the model download from Hugging Face, with <code>strim pull</code> or on first launch of the app.</p>")
        if let m = peakMemoryRange(), let mine = figRounded("final.mem.strim", digits: 1),
           let loS = figRounded("final.mem.\(m.lo.rv)", digits: 1), let hiS = figRounded("final.mem.\(m.hi.rv)", digits: 1) {
            o += item("How much memory does it need?", "<p>Measured peak over the whole benchmark run: \(mine)&nbsp;GB on \(esc(runHW)) (\(esc(m.others == "the others" ? "the rivals" : m.others)) peaked at \(loS)\(m.lo.rv == m.hi.rv ? "" : " to \(hiS)")&nbsp;GB). For 32&nbsp;GB the computed estimate is \(n("qt.t32")) of context, not measured; 16&nbsp;GB and below are unsupported.</p>")
        }
        o += item("Why use Ollama or LM Studio instead?", "<p>Use them if you want many models or a model browser: Strim runs one model, tuned for agent work. The current benchmark does not include them, so no comparison is claimed. See <a href=\"benchmarks.html#scope\">supported scope</a>.</p>")
        o += item("Is the DMG notarized?", "<p>Not yet. The first time, right-click Strim in Applications and choose Open. Installing with Homebrew avoids the warning.</p>")
        return o
    }

    // MARK: Direction E landing sections

    static let APP_DIR = "site/assets/app/"
    func appLive(_ name: String) -> Bool { fileExists(root + "/" + Self.APP_DIR + name) }
    static let DMG_URL = REPO_URL + "/releases/latest"

    /// Modal viewer shared by every .zoom tile; the script in assets/site.js drives it (arrows, swipe, counter, caption).
    func lightboxHTML() -> String {
        "<dialog id=\"lb\" aria-label=\"Screenshot viewer\"><div class=\"lbstage\"><img id=\"lbi\" alt=\"\"></div>"
        + "<p class=\"lbbar\"><span id=\"lbc\"></span><span id=\"lbcap\"></span></p>"
        + "<button type=\"button\" id=\"lbx\" class=\"lbb\" aria-label=\"Close\">&times;</button>"
        + "<button type=\"button\" id=\"lbp\" class=\"lbb\" aria-label=\"Previous screenshot\">&lsaquo;</button>"
        + "<button type=\"button\" id=\"lbn\" class=\"lbb\" aria-label=\"Next screenshot\">&rsaquo;</button></dialog>\n"
    }

    /// A cited figure rendered with `digits` decimals (the span title names the data id, so the number stays traceable).
    func figRounded(_ id: String, digits: Int) -> String? {
        guard let v = num(id) else { return nil }
        return "<span class=\"fig\" title=\"\(esc(id))\">\(fmtFixed(v, digits))</span>"
    }

    /// Strim over the closest rival, only when the comparison is claim-eligible and a WIN. Returns (numeral html, rival name, figure id of the ratio).
    func claimedRatio(_ cell: String) -> (num: String, rival: String)? {
        guard let b = bestRival(cell), b.claimable, b.ratio > 1.02, hCell(cell)?["verdict"]?[b.rival]?.str == "WIN" else { return nil }
        let id = "final.\(cell).ratio.\(b.rival)"
        let t = ratioLabel(b.ratio).replacingOccurrences(of: "x", with: "")
        let span = D.figs[id] != nil ? "<span class=\"fig\" title=\"\(esc(id))\">\(t)</span>" : "<span class=\"fig\">\(t)</span>"
        return (span, WIDE_NAMES[b.rival] ?? b.rival)
    }

    func buildLandingHTML() -> String {
        var o = pageHead(title: "Strim: the local model server built for coding agents",
                         desc: "Strim is a single-binary Swift engine that runs Qwen3.8-27B on Apple Silicon as a local backend for Claude Code and Codex. Measured against \(RIVALS.map { WIDE_NAMES[$0] ?? $0 }.joined(separator: ", ")), losses included.",
                         path: "", bodyClass: "landing")
        o += headerHTML([("Benchmarks", "benchmarks.html"), ("Features", "#features"), ("App", "#app"), ("Install", "#install"), ("FAQ", "#faq")], brandHref: "#top", cta: true)
        o += "<main id=\"main\">\n"
        o += "<section class=\"hero\" id=\"top\" aria-labelledby=\"h-hero\"><div class=\"wrap\">"
        o += "<h1 id=\"h-hero\">The local model server <span>built for coding agents.</span></h1>"
        let tps = figRounded("final.d4k.strim", digits: 1).map { " at \($0) tok/s" } ?? ""
        o += "<p class=\"lede\">Qwen3.8-27B on Apple silicon\(tps). Point Claude Code or Codex at localhost. One Swift binary, a menu-bar app, and nothing leaves your Mac.</p>"
        o += "<div class=\"actions\"><a class=\"btn big\" href=\"\(Self.DMG_URL)\">Download for Mac</a>"
        o += "<div class=\"cmdchip\"><code><span class=\"pr\">$</span> \(escCmd(Self.BREW_CMD))</code><button type=\"button\" class=\"copy\" aria-label=\"Copy command\" data-copy=\"\(esc(Self.BREW_CMD))\" hidden>Copy</button></div></div>"
        o += "<p class=\"meta\">macOS 14+ &middot; Apple silicon &middot; MIT &middot; <a href=\"#install\">Other install options</a></p>"
        o += "</div>\(heroStageHTML())</section>\n\n"
        o += "<div class=\"wrap\">\n"
        o += "<section class=\"slim\" aria-label=\"Highlights\">\(proofStripHTML())</section>\n\n"
        o += benchmarksSectionHTML()
        o += "<section id=\"features\" aria-labelledby=\"h-features\">" + secHead("What is inside", id: "h-features") + featureBentoHTML() + "</section>\n\n"
        o += "<section id=\"works\" aria-labelledby=\"h-works\">" + secHead("A minute with Strim", id: "h-works") + walkthroughHTML() + "</section>\n\n"
        o += appSectionHTML()
        let req = "<p class=\"req\">Apple Silicon, macOS 14 or newer. The app downloads the model on first launch; with the command line, <code>strim pull</code> does it. Tested on \(esc(runHW)).</p>"
        o += "<section id=\"install\" aria-labelledby=\"h-install\"><div class=\"split\"><div class=\"shd\"><h2 id=\"h-install\">Install</h2>\(req)</div><div class=\"sbody\"><div class=\"inst\">" + installTabsHTML() + "</div></div></div></section>\n\n"
        o += "<section id=\"faq\" aria-labelledby=\"h-faq\"><div class=\"split\">" + secHead("Questions", id: "h-faq") + "<div class=\"sbody faqs\">" + faqHTML() + "</div></div></section>\n\n"
        o += "</div></main>\n"
        o += lightboxHTML()
        o += footerHTML()
        return o
    }
}
