import Foundation

/// Direction E, pass 2: hero stage, proof strip, FIG 1 decode bars, FIG 2 ratio ladder, bento, walkthrough, tabbed app gallery.
/// Every number is read from the run data (headline.json / results.json) or from docs/img/app-live/live-status.json; a claim with no data is omitted.
extension SiteBuilder {
    /// A generated, data-derived span: counted by the "every number traces to the data" test as cited.
    func gen(_ s: String) -> String { "<span class=\"gen\">\(esc(s))</span>" }

    var runMachine: String { H["run"]?["machine"]?.pyStr ?? D.meta["machine"]?.pyStr ?? "" }
    /// "Apple M5 Max, 64 GB" from "Apple M5 Max, 64 GB, macOS 27.0.1".
    var runHW: String { runMachine.components(separatedBy: ", macOS").first ?? runMachine }
    /// "macOS 27.0.1", nil when the machine string carries no OS.
    var runOS: String? { runMachine.range(of: "macOS").map { String(runMachine[$0.lowerBound...]) } }
    var runDate: String { H["run"]?["date"]?.pyStr ?? "" }
    var runBuild: String { H["run"]?["strim_build"]?.pyStr ?? "" }
    var runPasses: String { D.text("final.claim.passes") }

    /// Decode tok/s of the live capture (docs/img/app-live/live-status.json), shown in the hero menu-bar strip; nil when the capture data is missing.
    func liveDecode() -> String? {
        guard let t = readText(root + "/docs/img/app-live/live-status.json"), let j = try? PyJSONParser.parse(t), let v = j["decode_tps"]?.number else { return nil }
        return fmtFixed(v, 1)
    }

    /// Active agent jobs in the live capture (docs/img/app-live/live-status.json); nil when the capture data is missing.
    func liveActiveJobs() -> Int? {
        guard let t = readText(root + "/docs/img/app-live/live-status.json"), let j = try? PyJSONParser.parse(t), let v = j["active_jobs"]?.number else { return nil }
        return Int(v)
    }

    /// The sentence under the hero capture, shared by the site and the README. Plain text: the capture ran while agent jobs were active, the benchmarks run one request at a time.
    func liveCaptionText() -> String {
        let hw = runHW
        var s = "Live capture" + (hw.isEmpty ? "" : " on \(hw)")
        if let n = liveActiveJobs() { s += (hw.isEmpty ? "" : ",") + " while \(n) agent \(n == 1 ? "job was" : "jobs were") running" }
        return s + ". The benchmarks below run one request at a time."
    }

    /// Pixel size of a PNG read from its IHDR chunk; nil when the file is missing or not a PNG.
    func pngSize(_ rel: String) -> (w: Int, h: Int)? {
        guard let fh = FileHandle(forReadingAtPath: root + "/" + rel) else { return nil }
        defer { try? fh.close() }
        guard let d = try? fh.read(upToCount: 24), d.count == 24, Array(d[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return nil }
        func be(_ o: Int) -> Int { (Int(d[o]) << 24) | (Int(d[o + 1]) << 16) | (Int(d[o + 2]) << 8) | Int(d[o + 3]) }
        let w = be(16), h = be(20)
        return w > 0 && h > 0 ? (w, h) : nil
    }

    /// ` width="W" height="H"` from the real PNG so the browser reserves the right box; empty when unreadable (CSS height:auto still lays it out).
    func sizeAttrs(_ file: String) -> String {
        pngSize(Self.APP_DIR + file).map { " width=\"\($0.w)\" height=\"\($0.h)\"" } ?? ""
    }

    // MARK: hero

    /// One theme variant of an app image. `mobile` names a dedicated narrow crop (swapped by media query). Sizes are read from the PNG files.
    private func appPic(_ stem: String, mobile: String? = nil, theme t: String, alt: String, eager: Bool) -> String {
        let src = mobile.map { "<source media=\"(max-width:40rem)\" srcset=\"assets/app/\($0)-\(t).png\"\(sizeAttrs("\($0)-\(t).png"))>" } ?? ""
        let load = eager ? "fetchpriority=\"high\" decoding=\"async\"" : "loading=\"lazy\" decoding=\"async\""
        return "<picture class=\"if-\(t)\">\(src)<img src=\"assets/app/\(stem)-\(t).png\" alt=\"\(esc(alt))\"\(sizeAttrs("\(stem)-\(t).png")) \(load)></picture>"
    }

    /// A button that opens the full-size gallery image of the same view in the lightbox.
    private func appZoom(wrap: String, full: String, cap: String, alt: String, pics: (String) -> String) -> String {
        "<button type=\"button\" class=\"zoom \(wrap)\" data-full=\"assets/app/\(full)-dark.png\" data-full-light=\"assets/app/\(full)-light.png\" data-alt=\"\(esc(alt))\" data-cap=\"\(esc(cap))\" aria-label=\"Expand screenshot: \(esc(cap))\">\(pics("dark"))\(pics("light"))</button>"
    }

    /// Hero stage: menu-bar strip with the live decode speed, the live popover hanging from the glyph, the status window bleeding off the bottom.
    func heroStageHTML() -> String {
        guard appLive("hero-window-dark.png") else { return "" }
        let winAlt = "The Strim status window: live decode speed, memory by component and engine counters"
        let win = appZoom(wrap: "win", full: "gallery-status", cap: "Status: live decode speed, memory by component, engine counters", alt: winAlt) {
            appPic("hero-window", mobile: "hero-window-m", theme: $0, alt: winAlt, eager: true)
        }
        let popAlt = "The Strim menu-bar panel while generating: decode speed, memory and server controls"
        let pop = appZoom(wrap: "pop", full: "gallery-menu", cap: "Menu bar: the live panel", alt: popAlt) {
            appPic("hero-popover", theme: $0, alt: popAlt, eager: true)
        }
        let glyph = "<svg viewBox=\"0 0 64 64\" aria-hidden=\"true\">\(markStreams(stroke: "currentColor"))</svg>"
        let live = liveDecode().map { "<span class=\"mbt\">\(gen($0)) tok/s</span>" } ?? ""
        let strip = "<div class=\"mbar\" aria-hidden=\"true\"><span class=\"mbg\">\(glyph)</span>\(live)</div>"
        var o = "<div class=\"wrap\"><div class=\"stage\"><div class=\"stagein\">\(strip)\(win)\(pop)</div></div>"
        o += "<p class=\"cap stagecap\">\(gen(liveCaptionText()))</p></div>"
        return o
    }

    // MARK: proof strip

    /// Four-cell proof strip: decode, shared-prefix ratio, peak memory, loopback. A cell is dropped when its comparison is not claim-eligible.
    func proofStripHTML() -> String {
        var tiles: [String] = []
        func tile(_ num: String, _ unit: String, _ label: String) {
            tiles.append("<li><p class=\"pn\">\(num)\(unit.isEmpty ? "" : "<span class=\"pu\">\(unit)</span>")</p><p class=\"pl\">\(label)</p></li>")
        }
        if let v = figRounded("final.d4k.strim", digits: 1) {
            var label = "decode at 4K context"
            if let r = claimedRatio("d4k") { label += ", " + r.num + "x the next engine" }
            tile(v, "&nbsp;tok/s", label)
        }
        if let r = claimedRatio("aw5") { tile(r.num, "x", "four agents on a shared 16K prefix") }
        if let m = peakMemoryRange(), let mine = figRounded("final.mem.strim", digits: 1),
           let loS = figRounded("final.mem.\(m.lo.rv)", digits: 1), let hiS = figRounded("final.mem.\(m.hi.rv)", digits: 1) {
            tile(mine, "&nbsp;GB", "peak memory, vs \(loS)\(m.lo.rv == m.hi.rv ? "" : " to \(hiS)")&nbsp;GB for \(m.others)")
        }
        tile("<code class=\"ip\">127.0.0.1</code>", "", "binds loopback only; nothing leaves your Mac")
        return "<ul class=\"proof\" aria-label=\"Measured highlights\">" + tiles.joined() + "</ul>"
    }

    /// The one peak-memory range shared by the proof strip, the FAQ and the README table: Strim against the claim-eligible rivals only
    /// (a rival that aborted in any README row, or did not win the whole-run comparison, is left out and named in `others`).
    func peakMemoryRange() -> (mine: Double, lo: (rv: String, v: Double), hi: (rv: String, v: Double), rivals: [String], others: String)? {
        let mem = H["memory"]?["whole_run"]
        guard let mine = mem?["strim"]?.number else { return nil }
        let eligible = readmeTableRivals().filter { H["memory"]?["whole_run_verdict"]?[$0]?.pyStr == "WIN" }
        let vs = eligible.compactMap { rv in mem?[rv]?.number.map { (rv: rv, v: $0) } }
        guard let lo = vs.min(by: { $0.v < $1.v }), let hi = vs.max(by: { $0.v < $1.v }) else { return nil }
        let names = vs.map { WIDE_NAMES[$0.rv] ?? $0.rv }
        return (mine, lo, hi, vs.map { $0.rv }, vs.count == RIVALS.count ? "the others" : listWords(names))
    }

    // MARK: FIG 1, decode bars

    private func engVer(_ e: String) -> String { engVersion(e).map { "<i class=\"ev\">\(esc($0))</i>" } ?? "" }

    /// Sorted horizontal decode bars, zero baseline, 20-unit gridlines; HTML with real text so labels stay crisp and selectable at any width.
    func fig1HTML() -> String {
        guard let c = hCell("d4k") else { return "" }
        let rows = ENGINES.compactMap { e in c["values"]?[e]?.number.map { (e: e, v: $0) } }.sorted { $0.v > $1.v }
        guard let top = rows.first?.v else { return "" }
        let axis = (top / 10).rounded(.up) * 10
        func pct(_ v: Double) -> String { fmtFixed(100 * v / axis, 2) + "%" }
        let ticks = stride(from: 0.0, through: axis, by: 20.0).map { $0 }
        var o = "<figure class=\"fig1\" aria-labelledby=\"f1t\"><p class=\"figlab\" id=\"f1t\">FIG 1 &nbsp; Decode speed at 4K context, \(RIVALS.count + 1) engines</p>"
        o += "<div class=\"b1\" role=\"list\">"
        for r in rows {
            let name = WIDE_NAMES[r.e] ?? r.e
            let s = r.e == ENGINES.first
            o += "<div class=\"r\(s ? " strim" : "")\" role=\"listitem\"><span class=\"en\">\(esc(name))\(engVer(r.e))</span>"
            o += "<span class=\"tr\"><span class=\"ax\">" + ticks.map { "<u style=\"left:\(pct($0))\"></u>" }.joined()
            o += "<b style=\"width:\(pct(r.v))\"></b><span class=\"vv\" style=\"left:\(pct(r.v))\">\(gen(fmtFixed(r.v, 1)))</span></span></span></div>"
        }
        o += "<div class=\"r tk\" aria-hidden=\"true\"><span></span><span class=\"tr\"><span class=\"ax\">" + ticks.map { "<s style=\"left:\(pct($0))\">\(fnum($0))</s>" }.joined() + "</span></span></div></div>"
        o += "<p class=\"axt\">tokens per second, higher is better &rarr;</p>"
        o += "<figcaption class=\"fcap\"><p>Workload: decode at 4K context, Qwen3.8-27B 4-bit, one engine at a time.</p>"
        o += "<p>Hardware: \(gen(runHW))" + (runOS.map { ", " + gen($0) } ?? "") + ". Method: medians of \(gen(runPasses)) passes, \(gen(runDate)), build \(gen(runBuild)).</p>"
        o += "<p class=\"figlinks\"><a href=\"../bench/h2h/RUNBOOK.md\">Reproduce</a><span aria-hidden=\"true\">&middot;</span><a href=\"../\(esc(FINAL_REL))/results.json\">Raw data</a></p></figcaption>"
        o += "<details class=\"dtab\"><summary>Show data table</summary><div class=\"tablewrap\"><table><thead><tr><th scope=\"col\">Engine</th><th scope=\"col\" class=\"num\">tok/s</th><th scope=\"col\" class=\"num\">Strim vs engine</th></tr></thead><tbody>"
        for r in rows {
            let ratio = r.e == ENGINES.first ? "" : ratioLabel(top / r.v)
            o += "<tr><th scope=\"row\">\(esc(engLabel(r.e)))</th><td class=\"num\">\(gen(fmtFixed(r.v, 1)))</td><td class=\"num\">\(ratio.isEmpty ? "&ndash;" : gen(ratio))</td></tr>"
        }
        o += "</tbody></table></div></details></figure>"
        return o
    }

    // MARK: FIG 2, ratio ladder

    static let LADDER: [String] = ["d4k", "d32k", "aw5", "p50_agc8", "aagc8", "c32k_tt", "a512c4", "a512c8"]
    static let LADDER_LABEL: [String: String] = [
        "a512c4": "4 short requests at once: total throughput", "a512c8": "8 short requests at once: total throughput",
    ]
    /// Half-width of the ratio axis in log2 units: 0.31x to 3.2x with the 1.00x hairline in the middle.
    static let LAD_HALF = 1.7

    func ladderRows() -> [(id: String, label: String, ratio: Double, rival: String, verdict: String)] {
        Self.LADDER.compactMap { id in
            guard let b = bestRival(id), b.claimable, let c = hCell(id) else { return nil }
            return (id, Self.LADDER_LABEL[id] ?? HERO_TITLE[id] ?? cellLabel(id), b.ratio, b.rival, c["verdict"]?[b.rival]?.str ?? "n/a")
        }.sorted { $0.ratio > $1.ratio }
    }

    func fig2HTML() -> String {
        let rows = ladderRows()
        guard !rows.isEmpty else { return "" }
        func pos(_ r: Double) -> Double { 50 + 50 * Foundation.log2(r) / Self.LAD_HALF }
        func p(_ x: Double) -> String { fmtFixed(min(100, max(0, x)), 2) + "%" }
        var o = "<figure class=\"fig2\" aria-labelledby=\"f2t\"><p class=\"figlab\" id=\"f2t\">FIG 2 &nbsp; Strim over its closest rival, by workload</p>"
        o += "<div class=\"lad\" role=\"list\">"
        o += "<div class=\"lr lh\" aria-hidden=\"true\"><span></span><span class=\"lt\"><span class=\"dir sl\">&larr; slower</span><span class=\"dir fa\">faster &rarr;</span>"
        for (t, label) in [(0.5, "0.5x"), (1.0, "1x"), (2.0, "2x"), (3.0, "3x")] { o += "<span class=\"gen tl\" style=\"left:\(p(pos(t)))\">\(label)</span>" }
        o += "</span><span></span></div>"
        for r in rows {
            let slower = r.verdict == "LOSS"
            let tie = r.verdict == "TIE" || fmtFixed(r.ratio, 2) == "1.00"   // a tie is neutral: no bar, no accent
            let a = pos(r.ratio), mid = 50.0
            let left = min(a, mid), w = max(abs(a - mid), 0.8)
            let word = slower ? "slower" : tie ? "tie" : ""
            let name = WIDE_NAMES[r.rival] ?? r.rival
            o += "<div class=\"lr\(slower ? " slow" : tie ? " tie" : "")\" role=\"listitem\"><span class=\"ll\">\(esc(r.label))</span>"
            o += "<span class=\"lt\"><u style=\"left:\(p(pos(0.5)))\"></u><u style=\"left:\(p(pos(2)))\"></u><u style=\"left:\(p(pos(3)))\"></u><i class=\"one\"></i>\(tie ? "" : "<b style=\"left:\(p(left));width:\(fmtFixed(w, 2))%\"></b>")</span>"
            o += "<span class=\"lv\">\(gen(ratioLabel(r.ratio)))\(word.isEmpty ? "" : "<small>\(word)</small>")</span>"
            o += "<span class=\"ld\">\(gen(valuesLine(r.id)))<span class=\"sr\"> (closest rival \(esc(name)))</span></span></div>"
        }
        o += "</div>"
        let v = H["run"]?["validity"]
        let total = Int(v?["sessions"]?.number ?? 0), bad = Int(v?["polluted"]?.number ?? 0)
        let clean = total > 0 ? "\(gen(String(total - bad))) of \(gen(String(total))) sessions were clean; claims use only claim-eligible cells." : "Claims use only claim-eligible cells."
        o += "<p class=\"fcap\">Grey bars left of 1x are where Strim is slower. \(clean) <a href=\"benchmarks.html#method\">Method</a> &middot; <a href=\"benchmarks.html#r-final\">Every cell</a></p>"
        let loss = esc(lossLine()).replacingOccurrences(of: "All losses: benchmarks.", with: "All losses: <a href=\"benchmarks.html\">benchmarks</a>.")
        o += "<details class=\"dtab\"><summary>Every loss in the data</summary><p class=\"honest\">\(loss)</p></details></figure>"
        return o
    }

    // MARK: bento

    private func svgWrap(_ viewBox: String, _ body: String, label: String) -> String {
        "<svg class=\"fv\" viewBox=\"\(viewBox)\" role=\"img\" aria-label=\"\(esc(label))\">\(body)</svg>"
    }

    private func featureMTP() -> String {
        var b = "<text x=\"0\" y=\"16\" class=\"ft\">drafted, one cheap step</text>"
        for i in 0..<4 { b += "<rect x=\"\(i * 78)\" y=\"28\" width=\"66\" height=\"38\" rx=\"9\" class=\"fo\"/>" }
        b += "<text x=\"0\" y=\"106\" class=\"ft\">verified, one pass of the full model</text>"
        for i in 0..<4 { b += "<rect x=\"\(i * 78)\" y=\"118\" width=\"66\" height=\"38\" rx=\"9\" class=\"\(i < 3 ? "fa" : "fo")\"/>" }
        for i in 0..<3 { b += "<path d=\"M\(i * 78 + 25) 137 l8 8 l14 -16\" class=\"fk\"/>" }
        b += "<path d=\"M\(3 * 78 + 25) 128 l16 16 m0 -16 l-16 16\" class=\"fx\"/>"
        b += "<text x=\"330\" y=\"46\" class=\"ft\">accepted</text><rect x=\"330\" y=\"58\" width=\"22\" height=\"14\" rx=\"4\" class=\"fa\"/>"
        b += "<text x=\"330\" y=\"100\" class=\"ft\">rejected</text><path d=\"M334 110 l12 12 m0 -12 l-12 12\" class=\"fx\"/>"
        return svgWrap("0 0 400 168", b, label: "Four drafted tokens, three accepted by one verification pass")
    }

    private func featurePrefix() -> String {
        var b = "<rect x=\"72\" y=\"8\" width=\"170\" height=\"134\" rx=\"9\" class=\"fshared\"/><text x=\"157\" y=\"79\" class=\"fm c\">shared prefix</text>"
        for (i, name) in ["agent 1", "agent 2", "agent 3"].enumerated() {
            let y = 14 + i * 46
            b += "<text x=\"0\" y=\"\(y + 22)\" class=\"ft\">\(name)</text>"
            b += "<rect x=\"250\" y=\"\(y)\" width=\"\(54 + i * 22)\" height=\"34\" rx=\"7\" class=\"fo\"/>"
        }
        b += "<text x=\"250\" y=\"168\" class=\"ft\">own tail</text><text x=\"72\" y=\"168\" class=\"ft\">computed once</text>"
        return svgWrap("0 0 364 176", b, label: "Three agents reuse one cached prefix and only compute their own tail")
    }

    private func featureSandbox() -> String {
        let s = "<div class=\"term\"><span class=\"nonet\">no network</span><code><span class=\"d\">$</span> go test ./...\n<span class=\"d\">ok  stats  0.4s</span>\n<span class=\"d\">writes: project folder only</span></code></div>"
        return s
    }

    private func featureAPIs() -> String {
        var b = ""
        for (i, p) in ["/v1/chat/completions", "/v1/messages", "/v1/responses", "MCP"].enumerated() {
            let y = 6 + i * 38
            b += "<rect x=\"0\" y=\"\(y)\" width=\"172\" height=\"28\" rx=\"14\" class=\"fo\"/><text x=\"86\" y=\"\(y + 19)\" class=\"fm c\">\(p)</text>"
            b += "<path d=\"M172 \(y + 14) H204 V80\" class=\"fl\"/>"
        }
        b += "<rect x=\"204\" y=\"62\" width=\"66\" height=\"36\" rx=\"10\" class=\"fa\"/><text x=\"237\" y=\"85\" class=\"fm c on\">strim</text>"
        return svgWrap("0 0 276 156", b, label: "Chat Completions, Messages, Responses and MCP all reach one local server")
    }

    private func featureBinary() -> String {
        "<ul class=\"chipsrow\" aria-label=\"Parts of the one binary\">" + ["engine", "server", "harness", "MCP"].map { "<li>\($0)</li>" }.joined() + "</ul>"
    }

    func featureBentoHTML() -> String {
        func tile(_ cls: String, _ visual: String, _ title: String, _ body: String) -> String {
            "<article class=\"tile \(cls)\"><div class=\"tv\">\(visual)</div><h3>\(title)</h3><p>\(body)</p></article>"
        }
        let popAlt = "The Strim menu-bar panel: decode speed, memory and server controls"
        let menu = ["dark", "light"].map { "<img class=\"menuimg if-\($0)\" src=\"assets/app/hero-popover-\($0).png\" alt=\"\(popAlt)\"\(sizeAttrs("hero-popover-\($0).png")) decoding=\"async\">" }.joined()
        var o = "<div class=\"bento\">"
        o += tile("c7", featureMTP(), "Speculative decoding", "A built-in MTP head drafts several tokens per step and the full model verifies them. \(u("pc.mtp_accept_4k")) of drafted tokens were accepted in the 4K prefix-cache run.")
        o += tile("c5", featurePrefix(), "Exact prefix cache", "Agents that share a prompt prefix reuse its computed state, so the repeated part is not read again. A 4K prefix hit returned the first token \(n("pc.4k.speedup"))x sooner.")
        o += tile("c4", featureSandbox(), "Sandboxed agent harness", "Bash runs under <code>sandbox-exec</code> with network denied and writes limited to the project worktree.")
        o += tile("c4", featureAPIs(), "Your clients, unchanged", "OpenAI Chat Completions, Anthropic Messages and OpenAI Responses endpoints, plus an MCP server.")
        o += tile("c4 menu", menu, "Menu-bar app", "Start, stop and pause the server, watch memory and decode speed, and open the full window.")
        o += tile("c12 wide", featureBinary(), "One Swift binary, no Python", "Engine, server, harness and MCP ship as a single native binary. Nothing to set up beyond the model download.")
        return o + "</div>"
    }

    // MARK: a minute with Strim

    func walkthroughHTML() -> String {
        func cmd(_ c: String, comment: String = "") -> String {
            "<div class=\"cmd\"><code><span class=\"pr\">$</span> \(escCmd(c))\(comment.isEmpty ? "" : " <span class=\"cm\"># \(esc(comment))</span>")</code><button type=\"button\" class=\"copy\" aria-label=\"Copy command\" data-copy=\"\(esc(c))\" hidden>Copy</button></div>"
        }
        func step(_ n: Int, _ title: String, _ body: String, note: String = "") -> String {
            "<li class=\"step\"><div class=\"sh\"><span class=\"sn\">0\(n)</span><h3>\(title)</h3></div><div class=\"sb\">\(body)\(note.isEmpty ? "" : "<p class=\"small\">\(note)</p>")</div></li>"
        }
        var o = "<ol class=\"steps\">"
        o += step(1, "Install", cmd(Self.BREW_CMD))
        o += step(2, "Get the model", cmd(Self.PULL_CMD), note: "Or let the menu-bar app download it on first launch.")
        o += step(3, "Point your agent at it", cmd("export ANTHROPIC_BASE_URL=http://127.0.0.1:8203") + cmd("export OPENAI_BASE_URL=http://127.0.0.1:8203/v1"),
                  note: "Start the server from the menu-bar app or with <code>strim serve</code>.")
        o += "</ol><p class=\"works\">Works with Claude Code, Codex CLI, OpenAI and Anthropic SDKs, MCP clients.</p>"
        return o
    }

    // MARK: app gallery

    func appSectionHTML() -> String {
        guard appLive("gallery-status-dark.png") else { return "" }
        let shots: [(id: String, label: String, cap: String, alt: String)] = [
            ("status", "Status", "Status: live decode speed, memory by component, engine counters.", "Strim status window with live decode speed, memory by component and engine counters"),
            ("chat", "Chat", "Chat: an agent reading files and running tools against the local model.", "Strim chat window: an agent reading files and running a test against the local model"),
            ("jobs", "Jobs", "Jobs: background agent jobs with a queue you can pause.", "Strim jobs window: background agent jobs and their patches"),
            ("menu", "Menu bar", "Menu bar: start, stop and pause the server and watch memory without opening the window.", "Strim menu-bar panel with decode speed, memory and server controls"),
        ]
        var o = "<section id=\"app\" aria-labelledby=\"h-app\"><div class=\"shd\"><h2 id=\"h-app\">The app</h2></div><div class=\"gal\">"
        for (i, s) in shots.enumerated() { o += "<input type=\"radio\" name=\"gal\" id=\"gal-\(s.id)\"\(i == 0 ? " checked" : "")><label for=\"gal-\(s.id)\">\(s.label)</label>" }
        o += "<div class=\"gpanels\">"
        for s in shots {
            let z = appZoom(wrap: "gshot\(s.id == "menu" ? " gmenu" : "")", full: "gallery-\(s.id)", cap: s.cap, alt: s.alt) {
                appPic("gallery-\(s.id)", theme: $0, alt: s.alt, eager: false)
            }
            o += "<figure class=\"gp gp-\(s.id)\">\(z)<figcaption>\(esc(s.cap))</figcaption></figure>"
        }
        o += "</div></div><p class=\"cap\">Live captures of the running app against a real server on \(gen(runHW)). <span class=\"dk\">Click any screenshot to enlarge.</span><span class=\"mb\">Tap to enlarge.</span></p></section>\n\n"
        return o
    }

    // MARK: sections

    func secHead(_ lead: String, _ dim: String = "", id: String) -> String {
        "<div class=\"shd\"><h2 id=\"\(id)\">\(lead)\(dim.isEmpty ? "" : " <span>\(dim)</span>")</h2></div>"
    }

    func benchmarksSectionHTML() -> String {
        let words = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight"]
        let n = ENGINES.count
        let head = n < words.count ? words[n] : String(n)
        var o = "<section id=\"field\" aria-labelledby=\"h-field\">" + secHead("\(head) engines, one Mac.", "Losses included.", id: "h-field")
        o += fig1HTML()
        o += "</section>\n\n<section id=\"ratios\" aria-labelledby=\"h-ratios\">" + secHead("Every ratio, wins and losses.", id: "h-ratios")
        o += fig2HTML()
        o += "</section>\n\n"
        return o
    }
}
