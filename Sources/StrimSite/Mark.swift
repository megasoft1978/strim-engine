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

let BR_ACCENT_LIGHT = "#4F46E5"
let BR_TEXT_LIGHT = "#131419"
let BR_APP_TILE = "#14151A"

/// Approved mark (candidate A): a flat paired-stream S of two offset round-capped capsule strokes in a 64x64 box, centred on (32 32), 10 wide, ink x 12..52, y 9..55.
/// The upper stream runs right to left and turns down, the lower one turns down from the middle and runs out to the left; they overlap on the middle bar.
let MARK_STREAMS = ["M47 14H27A9 9 0 0 0 27 32H34", "M30 32H37A9 9 0 0 1 37 50H17"]
let MARK_STROKE = 10.0

/// "strim" outlined from site/assets/fonts/space-grotesk-var.woff2 at wght 600 (CoreText, 1000 units per em, baseline y 0, y down), advances tracked -0.02em.
/// The i is the dotless stem; its accent capsule is `WORDMARK_DOT`. Ink x 44.1..2340.4, y -653.2..14.0.
let WORDMARK_PATH = "M276.9 14.0Q181.5 14.0 119.4 -28.0Q57.3 -70.0 44.1 -151.3L150.1 -178.0Q157.3 -139.8 175.2 -118.0Q193.1 -96.2 219.5 -86.9Q246.0 -77.6 276.9 -77.6Q323.7 -77.6 347.4 -94.7Q371.1 -111.8 371.1 -138.2Q371.1 -164.9 348.6 -178.2Q326.0 -191.5 279.8 -199.8L248.6 -205.4Q197.7 -215.0 155.7 -232.4Q113.8 -249.7 88.5 -280.1Q63.3 -310.6 63.3 -358.4Q63.3 -430.5 116.5 -469.4Q169.8 -508.2 256.7 -508.2Q339.7 -508.2 393.9 -471.2Q448.1 -434.1 464.4 -372.2L358.1 -340.3Q349.8 -381.8 323.0 -399.2Q296.2 -416.7 256.7 -416.7Q217.4 -416.7 195.9 -402.7Q174.5 -388.7 174.5 -363.3Q174.5 -336.5 196.2 -323.8Q218.0 -311.1 255.1 -304.6L286.3 -299.0Q341.2 -289.4 385.8 -273.1Q430.3 -256.8 456.3 -226.7Q482.2 -196.6 482.2 -145.7Q482.2 -69.2 426.5 -27.6Q370.8 14.0 276.9 14.0ZM765.4 0.0Q718.2 0.0 689.6 -28.7Q661.0 -57.3 661.0 -105.7L661.0 -399.0L531.4 -399.0L531.4 -494.2L661.0 -494.2L661.0 -653.2L775.4 -653.2L775.4 -494.2L917.4 -494.2L917.4 -399.0L775.4 -399.0L775.4 -125.2Q775.4 -95.2 803.8 -95.2L902.9 -95.2L902.9 0.0ZM1014.9 0.0L1014.9 -494.2L1127.3 -494.2L1127.3 -437.4L1144.3 -437.4Q1155.8 -467.9 1181.7 -482.1Q1207.5 -496.2 1244.2 -496.2L1303.6 -496.2L1303.6 -394.0L1241.3 -394.0Q1192.0 -394.0 1160.7 -367.6Q1129.3 -341.1 1129.3 -285.8L1129.3 0.0ZM1386.2 0.0L1386.2 -494.2L1500.6 -494.2L1500.6 0.0ZM1626.9 0.0L1626.9 -494.2L1739.4 -494.2L1739.4 -438.5L1756.3 -438.5Q1769.7 -463.8 1800.2 -483.2Q1830.7 -502.6 1881.8 -502.6Q1935.9 -502.6 1968.7 -481.0Q2001.4 -459.3 2018.3 -425.5L2035.2 -425.5Q2052.2 -458.5 2084.1 -480.5Q2116.0 -502.6 2174.4 -502.6Q2221.1 -502.6 2258.5 -482.9Q2295.9 -463.2 2318.1 -424.3Q2340.4 -385.3 2340.4 -327.2L2340.4 0.0L2225.9 0.0L2225.9 -318.8Q2225.9 -361.7 2203.1 -384.1Q2180.2 -406.5 2138.9 -406.5Q2093.3 -406.5 2067.1 -377.3Q2040.9 -348.0 2040.9 -293.3L2040.9 0.0L1926.4 0.0L1926.4 -318.8Q1926.4 -361.7 1903.6 -384.1Q1880.7 -406.5 1839.4 -406.5Q1793.8 -406.5 1767.6 -377.3Q1741.4 -348.0 1741.4 -293.3L1741.4 0.0Z"
let WORDMARK_DOT = (x: 1386.2, y: -715.0, w: 114.4, h: 130.0)

/// The S mark as stroked paths (no tile). `stroke` is an SVG colour attribute value or, when `css` is set, a CSS colour in a style declaration.
func markStreams(stroke: String, css: Bool = false) -> String {
    let paint = css ? "style=\"stroke:\(stroke)\"" : "stroke=\"\(stroke)\""
    return MARK_STREAMS.map { "<path d=\"\($0)\" fill=\"none\" \(paint) stroke-width=\"\(fnum(MARK_STROKE))\" stroke-linecap=\"round\"/>" }.joined()
}

/// Outlined lowercase wordmark with the accent capsule as the i dot, placed so the baseline origin is (x, y) at font size `size`.
func wordmarkInner(x: Double, y: Double, size: Double, letters: String, accent: String) -> String {
    let d = WORDMARK_DOT
    return "<g transform=\"translate(\(fnum(x)) \(fnum(y))) scale(\(fnum(size / 1000)))\"><path d=\"\(WORDMARK_PATH)\" fill=\"\(letters)\"/>"
        + "<rect x=\"\(fnum(d.x))\" y=\"\(fnum(d.y))\" width=\"\(fnum(d.w))\" height=\"\(fnum(d.h))\" rx=\"\(fnum(d.w / 2))\" fill=\"\(accent)\"/></g>"
}

/// Inline outlined wordmark lockup; colors follow the site theme tokens.
func wordmarkSVG() -> String {
    "<svg class=\"brand-wordmark\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 -715 2341 730\" aria-hidden=\"true\"><path d=\"\(WORDMARK_PATH)\" fill=\"var(--fg)\"/><rect x=\"1386.2\" y=\"-715\" width=\"114.4\" height=\"130\" rx=\"57.2\" fill=\"var(--a)\"/></svg>"
}

/// Standalone mark SVG (logo.svg, favicon.svg) with a light-scheme accent; `inline` (standalone false) gives an aria-hidden fragment that follows the page accent `--a`.
func markSVG(_ p: String = "m", standalone: Bool = true, title: String = "Strim") -> String {
    let ns = standalone ? " xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\"" : ""
    let role = title.isEmpty ? " aria-hidden=\"true\"" : " role=\"img\" aria-label=\"\(esc(title))\""
    let head = title.isEmpty ? "" : "<title>\(esc(title))</title>"
    if !standalone {
        return "<svg viewBox=\"0 0 64 64\"\(role)>" + head + markStreams(stroke: "var(--a,\(BR_ACCENT))", css: true) + "</svg>"
    }
    let style = "<style>@media (prefers-color-scheme:light){path{stroke:\(BR_ACCENT_LIGHT)}}</style>"
    return "<svg\(ns) viewBox=\"0 0 64 64\"\(role)>" + head + style + markStreams(stroke: BR_ACCENT) + "</svg>"
}

/// macOS app icon source: full-bleed #14151A square for the system squircle mask, accent S with 20% vertical optical padding, no filters.
func appIconSVG() -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\"><rect width=\"1024\" height=\"1024\" fill=\"\(BR_APP_TILE)\"/>"
        + "<g transform=\"translate(160.914 160.914) scale(10.971429)\">" + markStreams(stroke: BR_ACCENT) + "</g></svg>"
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
        b += "<g transform=\"translate(80 62)\">\(markStreams(stroke: BR_ACCENT))</g>"
        b += wordmarkInner(x: 157, y: 117, size: 72, letters: BR_TEXT, accent: BR_ACCENT)
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
