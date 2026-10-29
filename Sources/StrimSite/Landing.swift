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
        o += "<div><dt>Run</dt><dd><a href=\"\(raw)/summary.md\">\(esc(rawDirName))</a> (<a href=\"\(raw)/results.json\">results.json</a>), \(esc(run?["date"]?.pyStr ?? ""))</dd></div>"
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
        for (id, v) in nc.items {
            let label = cellLabel(id)
            for (rv, why) in v.obj?.items ?? [] { items += "<li><strong>\(esc(label))</strong> vs \(esc(WIDE_NAMES[rv] ?? rv)): \(esc(why.pyStr))</li>" }
        }
        return "<div class=\"callout\" role=\"note\" id=\"claim-policy\"><p><strong>Not claimable.</strong> Verdicts are only printed for a cell when every pass of both engines is present, none was excluded (abort, memory guard, OOM, timeout) and every session was clean. The numbers below stay visible; no WIN or LOSS is attached to these comparisons:</p><ul>\(items)</ul></div>"
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
            "<div class=\"cmd\"><code><span class=\"pr\">$</span> \(esc(c))\(comment.isEmpty ? "" : " <span class=\"cm\"># \(esc(comment))</span>")</code><button type=\"button\" class=\"copy\" data-copy=\"\(esc(c))\" hidden>Copy</button></div>"
        }
        var o = "<div class=\"tabs\">"
        o += "<input type=\"radio\" name=\"inst\" id=\"inst-brew\" checked><label for=\"inst-brew\">Homebrew</label>"
        o += "<input type=\"radio\" name=\"inst\" id=\"inst-curl\"><label for=\"inst-curl\">curl</label>"
        o += "<input type=\"radio\" name=\"inst\" id=\"inst-dmg\"><label for=\"inst-dmg\">DMG</label>"
        o += "<div class=\"panels\">"
        o += "<div class=\"panel p-brew\">" + cmd(Self.BREW_CMD) + cmd(Self.CASK_CMD) + cmd(Self.PULL_CMD)
            + "<p class=\"cap\">Installs the <code>strim</code> command. The menu-bar app (second line) is optional; it already contains the CLI.</p></div>"
        o += "<div class=\"panel p-curl\">" + cmd(Self.CURL_CMD) + cmd(Self.PULL_CMD)
            + "<p class=\"cap\">No sudo. Installs to <code>~/.local/strim</code> and links <code>~/.local/bin/strim</code>. Checks the SHA-256 before installing.</p></div>"
        o += "<div class=\"panel p-dmg\"><div class=\"dmgrow\"><a class=\"btn\" href=\"\(REPO_URL)/releases/latest\">Download the DMG (arm64)</a>"
            + "<span class=\"cap\">Open the DMG. Drag Strim to Applications. Launch Strim from the menu bar.</span></div>"
            + "<p class=\"warn\"><strong>Not notarized yet: right-click Open.</strong> macOS warns on first launch. Right-click Strim in Applications and choose Open, or click Open Anyway in System Settings, Privacy and Security, or run <code>\(esc(Self.XATTR_CMD))</code>. Homebrew avoids the warning.</p></div>"
        o += "</div></div>"
        return o
    }

    func faqHTML() -> String {
        func item(_ q: String, _ a: String) -> String { "<details class=\"faq\"><summary>\(esc(q))</summary><div class=\"ans\">\(a)</div></details>" }
        var o = ""
        o += item("Why only one model?", "<p>Everything is tuned for one dense model: its attention state, its speculative-decoding head and its prefix cache. That is why these numbers are possible, and why Strim will not run your other models. Others are on the <a href=\"benchmarks.html#roadmap\">roadmap</a>.</p>")
        o += item("Does it run on a 32 GB Mac or an M1?", "<p>Only a 64&nbsp;GB M5 Max has been tested. For 32&nbsp;GB the computed estimate is \(n("qt.t32")) of context (not measured); 16&nbsp;GB and below are unsupported. See <a href=\"benchmarks.html#scope\">supported scope</a>.</p>")
        o += item("Does speculative decoding change the output?", "<p>Draft tokens are verified by the full model, but batching can flip near-tie tokens. Greedy output over 8 fixed prompts and 64 tokens: Strim against itself \(n("final.agree.self")) identical, \(RIVALS.filter { D.figs["final.agree.\($0)"] != nil }.map { "against \(WIDE_NAMES[$0] ?? $0) \(n("final.agree.\($0)"))" }.joined(separator: ", ")). <a href=\"benchmarks.html#exact\">Quality and exactness</a>.</p>")
        return o
    }

    /// Real-window captures of the running app (copied from docs/img/app-live/ into site/assets/app/, downscaled). The section renders only when the hero capture exists.
    static let APP_DIR = "site/assets/app/"
    func appLive(_ name: String) -> Bool { fileExists(root + "/" + Self.APP_DIR + name) }

    static let APP_CAPTION = "Captured from the running app against a live server on a 64 GB M5 Max; real numbers."

    /// Dark and light variants of one shot; the theme switch and prefers-color-scheme pick one in CSS. width/height keep the layout stable.
    /// One expandable screenshot: a button holding the small embed (dark and light variants, CSS shows one) that opens the full-resolution original in the lightbox.
    private func zoomTile(base: String, light: String?, alt: String, cap: String, w: Int, h: Int, cls: String) -> String {
        func img(_ src: String, _ t: String?) -> String { "<img class=\"\(cls)\(t.map { " if-" + $0 } ?? "")\" src=\"assets/app/\(src).png\" alt=\"\(esc(alt))\" width=\"\(w)\" height=\"\(h)\" loading=\"lazy\" decoding=\"async\">" }
        let full = light == nil ? "assets/app/full/\(base).png" : "assets/app/full/\(base)-dark.png"
        let fl = light.map { " data-full-light=\"assets/app/full/\($0).png\"" } ?? ""
        let imgs = light == nil ? img(base, nil) : img(base + "-dark", "dark") + img(base + "-light", "light")
        return "<button type=\"button\" class=\"zoom\" data-full=\"\(full)\"\(fl) data-alt=\"\(esc(alt))\" data-cap=\"\(esc(cap))\" aria-label=\"Expand screenshot: \(esc(cap))\">\(imgs)<span class=\"xp\" aria-hidden=\"true\"><svg viewBox=\"0 0 16 16\" width=\"14\" height=\"14\"><path d=\"M9 2h5v5M7 14H2V9M14 2L9.5 6.5M2 14l4.5-4.5\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.6\" stroke-linecap=\"round\"/></svg></span></button>"
    }

    /// Modal viewer shared by every .zoom tile; the script in assets/site.js drives it (arrows, swipe, counter, caption).
    func lightboxHTML() -> String {
        "<dialog id=\"lb\" aria-label=\"Screenshot viewer\"><div class=\"lbstage\"><img id=\"lbi\" alt=\"\"></div>"
        + "<p class=\"lbbar\"><span id=\"lbc\"></span><span id=\"lbcap\"></span></p>"
        + "<button type=\"button\" id=\"lbx\" class=\"lbb\" aria-label=\"Close\">&times;</button>"
        + "<button type=\"button\" id=\"lbp\" class=\"lbb\" aria-label=\"Previous screenshot\">&lsaquo;</button>"
        + "<button type=\"button\" id=\"lbn\" class=\"lbb\" aria-label=\"Next screenshot\">&rsaquo;</button></dialog>\n"
    }

    func appSectionHTML() -> String {
        guard appLive("app-hero-live.png") else { return "" }
        var o = "<section id=\"app\" aria-labelledby=\"h-app\"><div class=\"sh\"><p class=\"kick\">Menu-bar app</p><h2 id=\"h-app\">The <span>app.</span></h2></div>"
        let heroAlt = "The Strim menu-bar app with a running server: decode speed, MTP acceptance and memory, from a live session"
        o += "<figure class=\"appfig\"><div class=\"macwin rev\"><div class=\"mbar\" aria-hidden=\"true\"><i></i><i></i><i></i></div>" + zoomTile(base: "app-hero-live", light: nil, alt: heroAlt, cap: "Menu-bar app, live session", w: 1072, h: 628, cls: "apphero") + "</div><figcaption class=\"cap\">\(Self.APP_CAPTION)</figcaption></figure>"
        let strip: [(String, String, Int, Int)] = [("status", "Status", 800, 707), ("chat", "Chat", 754, 800), ("jobs", "Jobs", 800, 683)]
        if strip.allSatisfy({ appLive("\($0.0)-dark.png") && appLive("\($0.0)-light.png") }) {
            o += "<div class=\"appstrip\">" + strip.map { "<figure>\(zoomTile(base: $0.0, light: $0.0 + "-light", alt: "Strim app, \($0.1.lowercased()) view, real session", cap: "\($0.1) view", w: $0.2, h: $0.3, cls: "tile"))<figcaption class=\"cap\">\($0.1)</figcaption></figure>" }.joined() + "</div>"
        }
        return o + "</section>\n\n"
    }

    func buildLandingHTML() -> String {
        let engines = ENGINES.count
        var o = pageHead(title: "Strim: Qwen3.8-27B on your Mac, like a server",
                         desc: "Strim is a single-binary Swift engine that runs Qwen3.8-27B on Apple Silicon as a local backend for Claude Code and Codex. Measured against \(RIVALS.map { WIDE_NAMES[$0] ?? $0 }.joined(separator: ", ")), losses included.",
                         path: "", bodyClass: "landing")
        o += headerHTML([("Install", "#install"), ("Speed", "#field"), ("Ratios", "#ratios"), ("App", "#app"), ("FAQ", "#faq"), ("Benchmarks", "benchmarks.html")], brandHref: "#top")
        o += "<main id=\"main\"><div class=\"wrap\">\n\n"
        o += "<section class=\"hero\" id=\"top\" aria-labelledby=\"h-hero\">"
        o += "<p class=\"pill\"><i></i>Qwen3.8-27B &middot; one Swift binary &middot; Apple silicon</p>"
        o += "<h1 id=\"h-hero\">Your Mac, now a <span>local AI server.</span></h1>"
        o += "<p class=\"lede\"><b>Strim</b> runs Qwen3.8-27B as a local backend for Claude Code and Codex. Nothing leaves the machine.</p>"
        o += "<div class=\"inst\" id=\"install\">" + installTabsHTML() + "</div>"
        o += "<p class=\"sub\">Model weights (about 16&nbsp;GB) come separately with <code>strim pull</code>. Apple Silicon, macOS 14 or newer, tested on a 64&nbsp;GB M5 Max. MIT.</p>"
        o += "</section>\n\n"

        o += "<section id=\"field\" aria-labelledby=\"h-field\"><div class=\"sh\"><p class=\"kick\">Decode speed &middot; \(engines) current engines</p><h2 id=\"h-field\">The wide field, on <span>one line.</span></h2></div>"
        o += "<div class=\"glass rev\"><div class=\"hvwrap\">\(numberLineSVG(narrow: false, standalone: false))\(numberLineSVG(narrow: true, standalone: false))</div>"
        o += "<p class=\"cap gen\"><span class=\"earlier-legend\"><svg width=\"18\" height=\"18\" viewBox=\"0 0 18 18\" aria-hidden=\"true\"><circle cx=\"9\" cy=\"9\" r=\"5\" fill=\"none\" stroke=\"currentColor\" stroke-dasharray=\"2 2\"/></svg>Hollow dashed beads: llama.cpp and Ollama, earlier run.</span> \(esc(wideCaption())) <a href=\"benchmarks.html#wide\">Full results</a>.</p></div></section>\n\n"

        o += "<section id=\"ratios\" aria-labelledby=\"h-ratios\"><div class=\"sh\"><p class=\"kick\">Strim today &middot; right of the line is faster</p><h2 id=\"h-ratios\">The honest <span>ratios.</span></h2></div>"
        o += ratioCardsHTML()
        let loss = esc(lossLine()).replacingOccurrences(of: "All losses: benchmarks.", with: "All losses: <a href=\"benchmarks.html\">benchmarks</a>.")
        o += "<p class=\"honest\">\(loss)</p>"
        o += "<p class=\"note\">\(validityText { n($0) }) <a href=\"benchmarks.html#method\">Method</a> and <a href=\"benchmarks.html#r-final\">every cell</a>.</p>"
        o += "</section>\n\n"

        o += appSectionHTML()
        o += "<section id=\"faq\" aria-labelledby=\"h-faq\"><div class=\"sh\"><p class=\"kick\">FAQ</p><h2 id=\"h-faq\">Questions.</h2></div><div class=\"faqs\">" + faqHTML() + "</div></section>\n\n"
        o += "</div></main>\n"
        if appLive("app-hero-live.png") { o += lightboxHTML() }
        o += footerHTML()
        return o
    }
}
