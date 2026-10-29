import Foundation

// Direction D site marks and share art: flat neutral surfaces with restrained indigo.
// Marks, banner and charts for the README are generated here from data. They use system font stacks and no filters, because GitHub renders SVG files as images.

let BR_NIGHT = "#0C0D10"
let BR_TEXT = "#ECEDEF"
let BR_MUTED = "#A3A6B1"
let BR_ACCENT = "#7C7CF5"
let BR_SANS = "-apple-system,'Helvetica Neue',Arial,sans-serif"
let BR_MONO = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"
let SITE_URL = "https://megasoft1978.github.io/strim-engine/"
let REPO_URL = "https://github.com/megasoft1978/strim-engine"

/// The S of four indigo token capsules: one dashed, round-capped path.
let MARK_PATH = "M46 19H28A8.5 8.5 0 0 0 28 36H36A8.5 8.5 0 0 1 36 53H17"

/// The mark as a rounded navy tile with the capsule S, as an SVG fragment (defs + shapes) to place in a 64x64 box. `p` makes the ids unique.
func markInner(_ p: String, rx: Double = 16) -> String {
    "<rect width=\"64\" height=\"64\" rx=\"\(fnum(rx))\" fill=\"#14151A\"/><rect x=\".5\" y=\".5\" width=\"63\" height=\"63\" rx=\"\(fnum(rx - 0.5))\" fill=\"none\" stroke=\"#2A2C34\"/>"
        + "<path d=\"\(MARK_PATH)\" fill=\"none\" stroke=\"#9393FF\" stroke-width=\"8.5\" stroke-linecap=\"round\" stroke-dasharray=\"14.5 11\" stroke-dashoffset=\"-1\"/>"
}

/// Standalone mark SVG (logo.svg, favicon.svg); `inline` gives an aria-hidden fragment for the page header.
func markSVG(_ p: String = "m", rx: Double = 16, standalone: Bool = true, title: String = "Strim") -> String {
    let ns = standalone ? " xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\"" : ""
    let role = title.isEmpty ? " aria-hidden=\"true\"" : " role=\"img\" aria-label=\"\(esc(title))\""
    return "<svg\(ns) viewBox=\"0 0 64 64\"\(role)>" + (title.isEmpty ? "" : "<title>\(esc(title))</title>") + markInner(p, rx: rx) + "</svg>"
}

/// macOS app icon source: the mark as a 824 px rounded square on a transparent 1024 px canvas (no filters).
func appIconSVG() -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\"><g transform=\"translate(100 100) scale(12.875)\">\(markInner("ai", rx: 14.4))</g></svg>"
}

/// Hex colours (#rgb, #rrggbb) in a CSS or SVG text whose hue is green (70 to 170 degrees) and clearly coloured: the owner does not want green anywhere.
func greenColours(in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: #"(?<![\w&])#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![\w-])"#) else { return [] }
    var out: [String] = []
    for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        var h = String(text[Range(m.range(at: 1), in: text)!])
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = stride(from: 0, to: 6, by: 2).map { i -> Double in
            Double(Int(h[h.index(h.startIndex, offsetBy: i)..<h.index(h.startIndex, offsetBy: i + 2)], radix: 16) ?? 0) / 255
        }
        let mx = v.max()!, mn = v.min()!, d = mx - mn
        guard d > 0, mx > 0.1, d / mx >= 0.12 else { continue }
        var hue: Double
        if mx == v[0] { hue = (v[1] - v[2]) / d; hue = hue < 0 ? hue + 6 : hue }
        else if mx == v[1] { hue = (v[2] - v[0]) / d + 2 }
        else { hue = (v[0] - v[1]) / d + 4 }
        hue *= 60
        if hue >= 70 && hue <= 170 { out.append("#" + h.lowercased()) }
    }
    return out
}

extension SiteBuilder {
    /// Claim text refers only to the five engines measured in the current run.
    func wideClaim() -> String {
        let bars = wideBars().filter { !$0.earlier }
        guard let first = bars.first else { return "" }
        return first.strim ? "fastest among \(bars.count) engines in the current run" : "\(bars.count) engines compared in the current run"
    }

    /// Wide-field hero numeral: Strim's decode median from the current head-to-head.
    func wideNumeral() -> String {
        guard let s = wideBars().first(where: { $0.strim }) else { return "" }
        return fmtFixed(s.value, 1)
    }

    func bannerAlt() -> String {
        "Strim: Qwen3.8-27B on your Mac, like a server. \(wideNumeral()) tok/s decode, \(wideClaim()), run of \(wideDate)"
    }

    /// README banner and og-image source, 1280x640: current decode median plus the labelled earlier-run points.
    func bannerSVG() -> String {
        let bars = wideBars()
        let top = niceTopWide(bars)
        func X(_ v: Double) -> Double { 110 + v / top * 1060 }
        let sans = "font-family=\"\(BR_SANS)\"", mono = "font-family=\"\(BR_MONO)\""
        var b = "<rect width=\"1280\" height=\"640\" fill=\"\(BR_NIGHT)\"/>"
        b += "<g transform=\"translate(80 70) scale(1.125)\">\(markInner("bm"))</g>"
        b += "<text x=\"168\" y=\"122\" \(sans) font-size=\"44\" font-weight=\"700\" letter-spacing=\"-1.5\" fill=\"\(BR_TEXT)\">strim</text>"
        b += "<text x=\"80\" y=\"256\" \(sans) font-size=\"92\" font-weight=\"700\" letter-spacing=\"-4\" fill=\"\(BR_TEXT)\">Your Mac, now a</text>"
        b += "<text x=\"80\" y=\"350\" \(sans) font-size=\"92\" font-weight=\"700\" letter-spacing=\"-4\" fill=\"\(BR_TEXT)\">local AI server.</text>"
        b += "<rect x=\"80\" y=\"396\" width=\"1120\" height=\"170\" rx=\"12\" fill=\"#14151A\" stroke=\"#2A2C34\"/>"
        b += "<text x=\"110\" y=\"436\" \(mono) font-size=\"14\" letter-spacing=\"2\" fill=\"\(BR_MUTED)\">DECODE TOK/S &#183; QWEN3.8-27B &#183; M5 MAX &#183; \(ENGINES.count) CURRENT ENGINES + 2 EARLIER RUNS</text>"
        b += "<line x1=\"110\" x2=\"1170\" y1=\"500\" y2=\"500\" stroke=\"#2A2C34\" stroke-width=\"2\"/>"
        let rest = bars.filter { !$0.strim }
        for (k, r) in rest.enumerated() {
            b += "<circle cx=\"\(fnum(X(r.value)))\" cy=\"500\" r=\"\(k == 0 ? 9 : 6)\" fill=\"\(BR_NIGHT)\" stroke=\"\(BR_TEXT)\" stroke-width=\"2\"\(r.earlier ? " stroke-dasharray=\"2 2\"" : "")/>"
        }
        if let r = rest.first {
            b += "<text x=\"\(fnum(X(r.value)))\" y=\"476\" text-anchor=\"middle\" \(mono) font-size=\"18\" fill=\"\(BR_TEXT)\">\(esc(fmtFixed(r.value, 1)))</text>"
            b += "<text x=\"\(fnum(X(r.value)))\" y=\"456\" text-anchor=\"middle\" \(mono) font-size=\"13\" fill=\"\(BR_MUTED)\">\(esc(r.name))</text>"
        }
        if rest.count > 1, let lo = rest.dropFirst().map(\.value).min(), let hi = rest.dropFirst().map(\.value).max() {
            b += "<text x=\"\(fnum(X((lo + hi) / 2)))\" y=\"476\" text-anchor=\"middle\" \(mono) font-size=\"13\" fill=\"\(BR_MUTED)\">\(esc(fmtFixed(lo, 1))) to \(esc(fmtFixed(hi, 1))): \(rest.count - 1) more engines</text>"
        }
        if let s = bars.first(where: { $0.strim }) {
            let x = X(s.value)
            b += "<circle cx=\"\(fnum(x))\" cy=\"500\" r=\"10\" fill=\"\(BR_ACCENT)\" stroke=\"#9393FF\" stroke-width=\"2\"/>"
            b += "<text x=\"\(fnum(x))\" y=\"454\" text-anchor=\"middle\" \(sans) font-size=\"46\" font-weight=\"700\" letter-spacing=\"-2\" fill=\"\(BR_ACCENT)\">\(esc(fmtFixed(s.value, 1)))</text>"
        }
        b += "<text x=\"110\" y=\"548\" \(mono) font-size=\"13\" fill=\"\(BR_MUTED)\">\(wideFromRun ? "Strim build \(esc(wideBuild)); dashed points are from \(esc(wideArchiveDate))" : "Earlier run points"). brew install megasoft1978/strim/strim</text>"
        let label = bannerAlt()
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1280 640\" width=\"1280\" height=\"640\" role=\"img\" aria-label=\"\(esc(label))\"><title>\(esc(label))</title>\(b)</svg>"
    }

    /// Top of the number-line axis: next multiple of 15 above the fastest engine.
    func niceTopWide(_ bars: [(name: String, value: Double, strim: Bool, earlier: Bool)]) -> Double {
        max(15, (((bars.map(\.value).max() ?? 15) / 15).rounded(.up)) * 15)
    }
}
