import Foundation

// The two signature visuals of the Aurora direction, generated from data:
//  - the wide field: all engines as beads on one number line, Strim as the glowing orb (parsed from the all-engine run summary);
//  - the ratios: one arc gauge per measurement and rival around the 1.0x tick, wins and losses drawn the same way.

/// Gradient stop: literal colour in standalone files, a CSS variable on the page (follows the theme switch).
private func stop(_ off: String, _ role: Int, _ standalone: Bool, opacity: String? = nil, literal: String? = nil) -> String {
    let lit = literal ?? BR_STOPS[role]
    let op = opacity.map { " stop-opacity=\"\($0)\"" } ?? ""
    if standalone { return "<stop offset=\"\(off)\" stop-color=\"\(lit)\"\(op)/>" }
    return "<stop offset=\"\(off)\" style=\"stop-color:var(--hv-\(["a", "b", "c"][role]))\"\(op)/>"
}

private func gradient(_ id: String, _ standalone: Bool, space: Bool = false, x1: Double = 0, x2: Double = 1, y1: Double = 0, y2: Double = 0) -> String {
    let u = space ? " gradientUnits=\"userSpaceOnUse\"" : ""
    return "<linearGradient id=\"\(id)\"\(u) x1=\"\(fnum(x1))\" y1=\"\(fnum(y1))\" x2=\"\(fnum(x2))\" y2=\"\(fnum(y2))\">"
        + stop("0", 0, standalone) + stop(".5", 1, standalone) + stop("1", 2, standalone) + "</linearGradient>"
}

private func hvSVG(_ id: String, viewBox: (x: Double, y: Double, w: Double, h: Double), cls: String, title: String, desc: String, defs: String, body: String, standalone: Bool) -> String {
    var s = "<svg class=\"hv \(cls)\" viewBox=\"\(fnum(viewBox.x)) \(fnum(viewBox.y)) \(fnum(viewBox.w)) \(fnum(viewBox.h))\" role=\"img\" aria-labelledby=\"\(id)-t \(id)-d\""
    s += standalone ? " xmlns=\"http://www.w3.org/2000/svg\" width=\"\(fnum(viewBox.w))\" height=\"\(fnum(viewBox.h))\">" : ">"
    s += "<title id=\"\(id)-t\">\(esc(title))</title><desc id=\"\(id)-d\">\(esc(desc))</desc>"
    if standalone { s += "<style>\(hvCSSStandalone())</style><rect class=\"bg\" x=\"\(fnum(viewBox.x + 1))\" y=\"\(fnum(viewBox.y + 1))\" width=\"\(fnum(viewBox.w - 2))\" height=\"\(fnum(viewBox.h - 2))\" rx=\"26\"/>" }
    return s + "<defs>\(defs)</defs>" + body + "</svg>"
}

extension SiteBuilder {
    /// Run line under the wide-field chart: date, Strim build, and the honest note that this build was slower than the current one.
    func wideCaption() -> String {
        if wideFromRun {
            let nA = bars_n_a()
            return "Decode speed in tokens per second at 4K context, Qwen3.8-27B 4-bit, Apple M5 Max 64 GB, one engine at a time. Head-to-head of \(wideDate), Strim build \(wideBuild), \(D.text("final.claim.passes")) passes." + (nA.isEmpty ? "" : " No valid value: \(nA).")
        }
        return "Earlier all-engine decode run of \(wideDate), Strim build \(wideBuild), Qwen3.8-27B 4-bit on Apple M5 Max."
    }

    private func bars_n_a() -> String { listWords(ENGINES.filter { hCell("d4k")?["values"]?[$0]?.number == nil }.map { WIDE_NAMES[$0] ?? $0 }) }

    // MARK: wide field

    /// Engines on one number line. Desktop: beads on a single axis with alternating labels; narrow: one mini track per engine.
    func numberLineSVG(narrow: Bool, standalone: Bool) -> String {
        let bars = wideBars()
        let top = niceTopWide(bars)
        let id = standalone ? "nls" : (narrow ? "nlm" : "nld")
        var defs = "", b = ""
        let desc = wideAlt()
        let title = "Decode speed of \(bars.count) engines on Qwen3.8-27B"
        func star(_ x: Double, _ y: Double, _ r: Double) -> String {
            "<circle cx=\"\(fnum(x))\" cy=\"\(fnum(y))\" r=\"\(fnum(r * 2.1))\" fill=\"url(#\(id)h)\"/><circle cx=\"\(fnum(x))\" cy=\"\(fnum(y))\" r=\"\(fnum(r))\" fill=\"url(#\(id)o)\"/><circle cx=\"\(fnum(x - r * 0.27))\" cy=\"\(fnum(y - r * 0.32))\" r=\"\(fnum(r * 0.27))\" class=\"nlspec\"/>"
        }
        defs += "<radialGradient id=\"\(id)o\" cx=\".35\" cy=\".3\" r=\".8\"><stop offset=\"0\" stop-color=\"#FFD1F3\"/>" + stop(".4", 2, standalone) + stop("1", 1, standalone) + "</radialGradient>"
        defs += "<radialGradient id=\"\(id)h\">" + stop("0", 2, standalone, opacity: ".5") + stop("1", 2, standalone, opacity: "0") + "</radialGradient>"
        defs += gradient(id + "t", standalone)
        if !narrow {
            let X0 = 40.0, X1 = 1060.0
            func X(_ v: Double) -> Double { X0 + v / top * (X1 - X0) }
            defs += gradient(id + "x", standalone, space: true, x1: X0, x2: X1)
            let step = top / 5
            for k in 0...5 {
                let v = Double(k) * step, x = X(v)
                b += "<line x1=\"\(fnum(x))\" x2=\"\(fnum(x))\" y1=\"193\" y2=\"207\" class=\"nltk\"/><text x=\"\(fnum(x))\" y=\"226\" text-anchor=\"middle\" class=\"tk mo\">\(fnum(v))</text>"
                if k < 5 { for j in 1...3 { let xm = X(v + step * Double(j) / 4); b += "<line x1=\"\(fnum(xm))\" x2=\"\(fnum(xm))\" y1=\"197\" y2=\"203\" class=\"nltk\"/>" } }
            }
            b += "<line x1=\"\(fnum(X0))\" x2=\"\(fnum(X1))\" y1=\"200\" y2=\"200\" stroke=\"url(#\(id)x)\" stroke-width=\"2.5\" opacity=\".85\"/>"
            for r in bars where r.strim {
                let x = X(r.value)
                    b += "<line x1=\"\(fnum(x))\" x2=\"\(fnum(x))\" y1=\"176\" y2=\"118\" class=\"nlld hot\"/>" + star(x, 200, 22)
                    b += "<text x=\"\(fnum(x))\" y=\"96\" text-anchor=\"middle\" class=\"nlv hot\" style=\"fill:url(#\(id)t)\">\(esc(fmtFixed(r.value, 1)))</text><text x=\"\(fnum(x))\" y=\"118\" text-anchor=\"middle\" class=\"nln hot\">\(esc(r.name))</text>"
            }
            // Labels of the other engines go to lanes (above or below the axis, near or far) chosen left to right so that no label or leader line touches another.
            struct Put { var side: Int; var lane: Int; var x0: Double; var x1: Double; var lx: Double }
            var placed: [Put] = []
            if let s = bars.first(where: { $0.strim }) { placed.append(Put(side: 0, lane: 1, x0: X(s.value) - 62, x1: X(s.value) + 62, lx: X(s.value))) }
            func clash(_ p: Put, _ q: Put) -> Bool {
                guard p.side == q.side else { return false }
                if p.lane == q.lane { return p.x0 < q.x1 + 10 && q.x0 < p.x1 + 10 }
                let (near, far) = p.lane < q.lane ? (p, q) : (q, p)
                return far.lx >= near.x0 - 4 && far.lx <= near.x1 + 4
            }
            let others = bars.sorted(by: { $0.value < $1.value }).filter { !$0.strim }
            func geom(_ r: (name: String, value: Double, strim: Bool, earlier: Bool)) -> (x: Double, x0: Double, x1: Double, atEnd: Bool) {
                let x = X(r.value)
                let w = Double(fmtFixed(r.value, 1).count) * 10.2 + 6 + Double(r.name.count) * 7.5 + 4
                let atEnd = x + 6 + w > 1096
                return (x, atEnd ? x - 6 - w : x + 6, atEnd ? x - 6 : x + 6 + w, atEnd)
            }
            /// Nearest free lane first; when a dense cluster does not fit that way, the staircase (farthest lane for the leftmost label).
            func assign(descending: Bool) -> [Put]? {
                var out = placed
                for r in others {
                    let g = geom(r)
                    var choice: Put?
                    search: for lane in (descending ? [3, 2, 1, 0] : [0, 1, 2, 3]) {
                        for side in 0...1 {
                            let c = Put(side: side, lane: lane, x0: g.x0, x1: g.x1, lx: g.x)
                            if !out.contains(where: { clash(c, $0) }) { choice = c; break search }
                        }
                    }
                    guard let c = choice else { return nil }
                    out.append(c)
                }
                return Array(out.dropFirst(placed.count))
            }
            let plan = assign(descending: false) ?? assign(descending: true) ?? others.enumerated().map { k, r in let g = geom(r); return Put(side: k % 2, lane: 3, x0: g.x0, x1: g.x1, lx: g.x) }
            let lowest = plan.filter { $0.side == 1 }.map { 234 + 24 * Double($0.lane) + 22 }.max() ?? 250
            for (r, c) in zip(others, plan) {
                let g = geom(r)
                let x = g.x, atEnd = g.atEnd
                let up = c.side == 0
                let ly = up ? 176 - 24 * Double(c.lane) : 234 + 24 * Double(c.lane)
                let tx = atEnd ? x - 6 : x + 6
                let anchor = atEnd ? "end" : "start"
                let rad = r.value == bars.filter({ !$0.strim }).map(\.value).max() ? 9.0 : 6.5
                b += "<line x1=\"\(fnum(x))\" x2=\"\(fnum(x))\" y1=\"\(up ? 193 : 207)\" y2=\"\(fnum(up ? ly - 5 : ly + 1))\" class=\"nlld\(r.earlier ? " earlier-run" : "")\"/><circle cx=\"\(fnum(x))\" cy=\"200\" r=\"\(fnum(rad))\" class=\"nldot\(r.earlier ? " earlier-run" : "")\"/>"
                b += "<text x=\"\(fnum(tx))\" y=\"\(fnum(up ? ly : ly + 12))\" text-anchor=\"\(anchor)\" class=\"nln mo\"><tspan class=\"nlv\">\(esc(fmtFixed(r.value, 1)))</tspan> \(esc(r.name))</text>"
            }
            if standalone {
                b += "<text x=\"40\" y=\"362\" class=\"tk mo\" style=\"font-size:11px\">\(esc(wideFromRun ? "Head-to-head of \(wideDate), Strim build \(wideBuild). Higher is faster." : "Run of \(wideDate). Higher is faster."))</text>"
            }
            return hvSVG(id, viewBox: (0, 40, 1100, standalone ? 340 : max(lowest, 250) + 6 - 40), cls: "nl vw", title: title, desc: desc, defs: defs, body: b, standalone: standalone)
        }
        // narrow: one track per engine
        let X0 = 96.0, X1 = 284.0
        func X(_ v: Double) -> Double { X0 + v / top * (X1 - X0) }
        for (k, r) in bars.enumerated() {
            let y = 28 + Double(k) * 40
            defs += k == 0 ? gradient(id + "x", standalone, space: true, x1: X0, x2: X(r.value)) : ""
            b += "<line x1=\"\(fnum(X0))\" x2=\"\(fnum(X1))\" y1=\"\(fnum(y))\" y2=\"\(fnum(y))\" stroke=\"\(standalone ? BR_MUTED : "var(--hv-mu)")\" stroke-width=\"2.5\" opacity=\".35\" stroke-linecap=\"round\"/>"
            if r.strim {
                b += "<line x1=\"\(fnum(X0))\" x2=\"\(fnum(X(r.value)))\" y1=\"\(fnum(y))\" y2=\"\(fnum(y))\" stroke=\"url(#\(id)x)\" stroke-width=\"4\" stroke-linecap=\"round\"/>" + star(X(r.value), y, 10)
                b += "<text x=\"0\" y=\"\(fnum(y + 5))\" class=\"nln hot\">\(esc(r.name))</text><text x=\"360\" y=\"\(fnum(y + 9))\" text-anchor=\"end\" class=\"nlv hot\" style=\"font-size:26px;fill:url(#\(id)t)\">\(esc(fmtFixed(r.value, 1)))</text>"
            } else {
                b += "<line x1=\"\(fnum(X0))\" x2=\"\(fnum(X(r.value)))\" y1=\"\(fnum(y))\" y2=\"\(fnum(y))\" class=\"nlwk\(r.earlier ? " earlier-run" : "")\"/><circle cx=\"\(fnum(X(r.value)))\" cy=\"\(fnum(y))\" r=\"5\" class=\"nldot\(r.earlier ? " earlier-run" : "")\"/>"
                b += "<text x=\"0\" y=\"\(fnum(y + 4))\" class=\"nln mo\" style=\"font-size:12px\">\(esc(r.name))</text><text x=\"360\" y=\"\(fnum(y + 5))\" text-anchor=\"end\" class=\"nlv mo\" style=\"font-size:15px\">\(esc(fmtFixed(r.value, 1)))</text>"
            }
        }
        return hvSVG(id, viewBox: (0, 0, 360, 28 + Double(bars.count - 1) * 40 + 28), cls: "nl vn", title: title, desc: desc, defs: defs, body: b, standalone: false)
    }

    // MARK: ratio gauges

    /// Semicircle gauge in an 80x50 box: log scale 0.5x to 3.2x, tick at 1.0x, arc from the tick to the ratio. Wins sweep right, losses left.
    func gaugeSVGInner(_ r: Double, gradId: String) -> String {
        let lo = Foundation.log(0.5), hi = Foundation.log(3.2)
        func pt(_ t: Double, _ rad: Double = 32) -> (Double, Double) { let th = Double.pi * (1 - t); return (40 + rad * cos(th), 40 - rad * sin(th)) }
        func T(_ v: Double) -> Double { min(1, max(0, (Foundation.log(v) - lo) / (hi - lo))) }
        let a = pt(T(1)), e = pt(T(r)), i0 = pt(T(1), 24.5), i1 = pt(T(1), 35.5)
        let win = r >= 1
        let arc = "M\(fnum(a.0)) \(fnum(a.1))A32 32 0 0 \(win ? 1 : 0) \(fnum(e.0)) \(fnum(e.1))"
        return "<path d=\"M8 40A32 32 0 0 1 72 40\" class=\"gb\"/><path d=\"\(arc)\" class=\"gv\(win ? "" : " lose")\" pathLength=\"1\"\(win ? " stroke=\"url(#\(gradId))\"" : "")/>"
            + "<line x1=\"\(fnum(i0.0))\" y1=\"\(fnum(i0.1))\" x2=\"\(fnum(i1.0))\" y2=\"\(fnum(i1.1))\" class=\"g1\"/><circle cx=\"\(fnum(e.0))\" cy=\"\(fnum(e.1))\" r=\"3.6\" class=\"gd\(win ? "" : " lose")\"/>"
    }

    /// Strim and the best rival of the cell, from the cell values.
    func valuesLine(_ id: String) -> String {
        guard let c = hCell(id), let s = c["values"]?["strim"]?.number else { return "" }
        func f(_ v: Double) -> String { fmtFixed(v, v >= 10 ? 1 : 2) }
        let unit = " " + (c["unit"]?.pyStr ?? "")
        guard let b = bestRival(id), let rv = c["values"]?[b.rival]?.number else { return "Strim \(f(s))" + unit }
        return "Strim \(f(s)) vs \(WIDE_NAMES[b.rival] ?? b.rival) \(f(rv))" + unit
    }

    /// Glass cards with one gauge each (Strim against the best rival of that measurement), for the landing page (HTML so that the numbers stay text).
    func ratioCardsHTML() -> String {
        var o = "<div class=\"cards\">"
        for id in GLANCE {
            guard let c = hCell(id), let b = bestRival(id) else { continue }
            let verdict = c["verdict"]?[b.rival]?.str ?? "n/a"
            let loss = b.claimable && verdict == "LOSS"
            let name = WIDE_NAMES[b.rival] ?? b.rival
            let cls = !b.claimable ? " nc" : loss ? " loss" : ""
            o += "<article class=\"card rev\(cls)\">" + (!b.claimable ? "<span class=\"chip\">not claimable</span>" : loss ? "<span class=\"chip\">honest loss</span>" : "") + "<h3>\(esc(HERO_TITLE[id] ?? id))</h3><div class=\"pair one\">"
            if b.claimable {
                o += "<div class=\"rv\(b.ratio < 1 ? " lo" : "")\"><svg class=\"hv gsvg\" viewBox=\"0 0 80 50\" aria-hidden=\"true\">\(gaugeSVGInner(b.ratio, gradId: "gg"))</svg><div><b class=\"gen\" data-count=\"\(fmtFixed(b.ratio, 2))\" data-suffix=\"x\">\(ratioLabel(b.ratio))</b><i>vs best rival, \(esc(name))</i></div></div>"
                o += "</div><p class=\"gen\">\(esc(valuesLine(id)))</p></article>"
            } else {
                o += "<div class=\"rv lo\"><div><b>not claimable</b><i>vs \(esc(name))</i></div></div></div><p>\(esc(b.why ?? "This comparison does not meet the claim policy."))</p></article>"
            }
        }
        return o + "</div>"
    }

    /// README ratio chart: the glass cards as one standalone SVG (night palette, system fonts, no filters).
    func gaugesSVG() -> String {
        let ids = GLANCE.filter { hCell($0) != nil && bestRival($0) != nil }
        let cw = 300.0, ch = 176.0, gap = 24.0, x0 = 26.0, y0 = 78.0
        let rows = (ids.count + 2) / 3
        let W = 1000.0, Ht = y0 + Double(rows) * (ch + gap) + 30
        var b = "<text x=\"\(fnum(x0))\" y=\"42\" style=\"font-size:22px;font-weight:700;letter-spacing:-.02em\">Strim today, over its best rival in each measurement</text>"
        b += "<text x=\"\(fnum(x0))\" y=\"62\" class=\"m mo\" style=\"font-size:12px\">Ratio to the best rival, 1.00x is equal, above is faster. First-token times are inverted so that right is always better.</text>"
        for (k, id) in ids.enumerated() {
            let cx = x0 + Double(k % 3) * (cw + gap), cy = y0 + Double(k / 3) * (ch + gap)
            guard let c = hCell(id), let r = bestRival(id) else { continue }
            let loss = r.claimable && c["verdict"]?[r.rival]?.str == "LOSS"
            let name = WIDE_NAMES[r.rival] ?? r.rival
            b += "<g transform=\"translate(\(fnum(cx)) \(fnum(cy)))\"><rect width=\"\(fnum(cw))\" height=\"\(fnum(ch))\" rx=\"22\" class=\"gcard\(loss || !r.claimable ? " loss" : "")\"/>"
            b += "<text x=\"20\" y=\"36\" style=\"font-size:16px;font-weight:600\">\(esc(HERO_TITLE[id] ?? id))</text>"
            if loss { b += "<text x=\"\(fnum(cw - 20))\" y=\"58\" text-anchor=\"end\" class=\"m mo\" style=\"font-size:11px;font-weight:700;letter-spacing:.08em\">HONEST LOSS</text>" }
            if r.claimable {
                b += "<g transform=\"translate(20 62) scale(1.6)\">\(gaugeSVGInner(r.ratio, gradId: "gr"))</g>"
                b += "<text x=\"158\" y=\"112\" class=\"gnum\(r.ratio < 1 ? " lose" : "")\"\(r.ratio < 1 ? "" : " style=\"fill:url(#gt)\"")>\(ratioLabel(r.ratio))</text>"
                b += "<text x=\"158\" y=\"132\" class=\"m mo\" style=\"font-size:12px\">vs \(esc(name))</text>"
            } else {
                b += "<text x=\"20\" y=\"98\" class=\"gnum lose\" style=\"font-size:22px\">not claimable</text>"
                b += "<text x=\"20\" y=\"120\" class=\"m mo\" style=\"font-size:12px\">vs \(esc(name))</text>"
            }
            b += "<text x=\"20\" y=\"\(fnum(ch - 14))\" class=\"m mo\" style=\"font-size:11px\">\(esc(valuesLine(id)))</text></g>"
        }
        let run = H_runLine()
        b += "<text x=\"\(fnum(x0))\" y=\"\(fnum(Ht - 12))\" class=\"m mo\" style=\"font-size:11px\">\(esc(run))</text>"
        var defs = gradient("gr", true, space: true, x1: 8, x2: 72)
        defs += gradient("gt", true, x1: 0, x2: 1)
        return hvSVG("hr", viewBox: (0, 0, W, Ht), cls: "gr", title: "Strim against its best rival, ratio per measurement", desc: speedAlt(), defs: defs, body: b, standalone: true)
    }

    private func H_runLine() -> String {
        "Run \(rawDirName), \(H["run"]?["date"]?.pyStr ?? ""), medians of \(D.text("final.claim.passes")) passes, M5 Max 64 GB."
    }
}
