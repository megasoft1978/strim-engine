import Foundation

let NB = "\u{00A0}"

/// THE head-to-head run the site and README present. Everything (figures, charts, run date, build, versions, validity text, raw-results link) is derived from this directory;
/// to swap in a clean rerun change this one line and run `strim site build`.
let FINAL_REL = "bench/results/h2h-final3-20261028"
let FINAL_SRC = FINAL_REL + "/summary.md"
/// Engines of the features matrix (hand-filled site/data/features.json); the head-to-head engines come from the run (SiteBuilder.ENGINES).
let FEATURE_ENGINES = ["strim", "rapid-mlx", "mlx-vlm"]

func ek(_ e: String) -> String { e }

/// Figure ids of the generated final head-to-head block: final.<cell>.<engine>, .ratio.<rival>, .verdict.<rival>.
func fid(_ cell: String, _ e: String) -> String { "final.\(cell).\(e)" }
func fratio(_ cell: String, _ rival: String) -> String { "final.\(cell).ratio.\(rival)" }
func fverdict(_ cell: String, _ rival: String) -> String { "final.\(cell).verdict.\(rival)" }

public struct SiteOptions {
    public var check = false
    public var listFigures = false
    public var refreshSoak = false
    public init(check: Bool = false, listFigures: Bool = false, refreshSoak: Bool = false) {
        self.check = check; self.listFigures = listFigures; self.refreshSoak = refreshSoak
    }
}

/// Swift generator for the site and README (replaced the retired Python script). Paths are relative to `root` (the repo root).
public final class SiteBuilder {
    public let root: String
    var site: String { root + "/site" }
    var dataPath: String { root + "/site/data/results.json" }
    var outHTML: String { root + "/site/index.html" }
    var readmeTpl: String { root + "/site/README.template.md" }
    var outReadme: String { root + "/README.md" }
    var finalDir: String { root + "/" + FINAL_REL }

    /// Engines of the head-to-head run (results.json `engines`; engines[0] is the reference, Strim) and their engine_meta strings. Set by syncFinal, restored from the final block.
    var engineList: [String] = ["strim", "rapid-mlx", "mlx-vlm"]
    var engineMeta: [String: [String: String]] = [:]
    var ENGINES: [String] { engineList }
    var RIVALS: [String] { Array(engineList.dropFirst()) }
    var ENG_LABEL: [String: String] { Dictionary(uniqueKeysWithValues: engineList.map { ($0, engLabel($0)) }) }

    /// Display name: "Strim", "rapid-mlx (MTP)", "mlx-vlm (no MTP)", "oMLX (no MTP)"; the MTP suffix comes from engine_meta.mtp (yes... / no...).
    func engLabel(_ e: String) -> String {
        if e == engineList.first { return WIDE_NAMES[e] ?? e }
        let name = WIDE_NAMES[e] ?? e
        guard let m = engineMeta[e]?["mtp"]?.lowercased() else { return e == "rapid-mlx" ? "rapid-mlx (MTP)" : e == "mlx-vlm" ? "mlx-vlm (no MTP)" : name }
        return name + (m.hasPrefix("yes") ? " (MTP)" : m.hasPrefix("no") ? " (no MTP)" : "")
    }
    /// Measured version of an engine in the head-to-head run (engine_meta, else the run summary title); nil when unknown.
    func engVersion(_ e: String) -> String? {
        if var v = engineMeta[e]?["version"], !v.isEmpty, v != "n/a" {
            if v.lowercased().hasPrefix(e.lowercased() + " ") { v = String(v.dropFirst(e.count + 1)) }
            return v
        }
        return runVersions[e]
    }
    var runVersions: [String: String] = [:]
    /// The benchmarks page shows the archived eight-engine run next to the current one: it flips this while it renders the archive section.
    var wideForceArchive = false

    var D: SiteData!
    /// Parsed site/data/headline.json (generated) and site/data/features.json (hand-filled): the data behind the comparison charts and matrix.
    var H: PyJSON = .null
    var F: PyJSON = .null
    /// First fatal condition hit by a non-throwing page helper (Python would have crashed there).
    var failure: String?
    /// Tests only: roots registered via SafeIO.registerTestRoot may contain symlinked components (overlay trees). Never true for the CLI.
    var allowSymlinkedTree: Bool { SafeIO.isTestRoot(root) }
    public var log: (String) -> Void = { print($0) }

    /// `root` is resolved once with realpath; all later paths are checked below that real path.
    public init(root: String) {
        if let rp = realpath(root, nil) { self.root = String(cString: rp); free(rp) } else { self.root = root }
    }

    func fail(_ m: String) { if failure == nil { failure = m } }

    func fig(_ i: String) -> Figure {
        if let f = D.figs[i] { return f }
        fail("KeyError: '\(i)'")
        return Figure(raw: JObject(), value: .null)
    }

    func num(_ i: String) -> Double? { fig(i).value.number }

    // MARK: figure spans and tables

    func figSpan(_ i: String, withUnit: Bool = true) -> String {
        let f = fig(i)
        if D.isNA(i) { return "<span class=\"na\" title=\"\(esc(i))\">n/a</span>" }
        if D.pending(i) { return "<span class=\"pending\" title=\"\(esc(i))\">pending</span>" }
        var t = esc(D.text(i))
        let u = f.unit
        if withUnit && !u.isEmpty {
            if u == "x" || u == "%" { t += u == "x" ? "×" : "%" } else { t += NB + esc(u) }
        }
        return "<span class=\"fig\" title=\"\(esc(i))\">\(t)</span>"
    }

    func n(_ i: String) -> String { figSpan(i, withUnit: false) }
    func u(_ i: String) -> String { figSpan(i) }

    func td(_ i: String, _ best: Bool = false, unit: Bool = false) -> String {
        let f = fig(i)
        let cls = "num" + (best ? " best" : "")
        if D.isNA(i) { return "<td class=\"num muted\" title=\"\(esc(i))\">n/a</td>" }
        if D.pending(i) { return "<td class=\"num\"><span class=\"pending\" title=\"\(esc(i))\">pending</span></td>" }
        let uu = unit ? f.unit : ""
        let suffix: String
        switch uu {
        case "x": suffix = "\u{00d7}"
        case "%": suffix = "%"
        case "": suffix = ""
        default: suffix = NB + esc(uu)
        }
        return "<td class=\"\(cls)\" title=\"\(esc(i))\">\(esc(D.text(i)))\(suffix)</td>"
    }

    func tdText(_ s: String, _ cls: String = "") -> String {
        cls.isEmpty ? "<td>\(s)</td>" : "<td class=\"\(cls)\">\(s)</td>"
    }

    func table(_ caption: String, _ headers: [String], _ rows: [[String]], numcols: Set<Int> = [], foot: String? = nil) -> String {
        var h = ""
        for (k, x) in headers.enumerated() { h += "<th scope=\"col\"\(numcols.contains(k) ? " class=num" : "")>\(esc(x))</th>" }
        var body = ""
        for r in rows {
            body += "<tr><th scope=\"row\">\(r[0])</th>\(r.dropFirst().joined())</tr>"
        }
        let cap = caption.isEmpty ? "" : "<caption>\(esc(caption))</caption>"
        var out = "<div class=\"tablewrap\" tabindex=\"0\" role=\"region\" aria-label=\"\(esc(caption))\"><table>\(cap)<thead><tr>\(h)</tr></thead><tbody>\(body)</tbody></table></div>"
        if let foot, !foot.isEmpty { out += "<p class=\"note\">\(foot)</p>" }
        return out
    }

    func niceMax(_ m: Double) -> Double {
        if m <= 0 { return 1 }
        let ex = Int(floor(log10(m)))
        var e = 1.0
        if ex >= 0 { for _ in 0..<ex { e *= 10 } } else { e = pow(10.0, Double(ex)) }
        for k in [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 10.0] where k * e >= m { return k * e }
        return 10 * e
    }

    typealias Bar = (label: String, id: String, cls: String)

    func chart(_ title: String, _ desc: String, _ groups: [(String?, [Bar])], _ unit: String, axisMax: Double? = nil) -> String {
        var vals: [Double] = []
        for (_, rows) in groups { for r in rows where !D.pending(r.id) { if let v = num(r.id) { vals.append(v) } } }
        let mx = axisMax ?? niceMax(vals.max() ?? 1)
        var out = "<figure class=\"chart\"><figcaption>\(esc(title))<span>\(esc(desc))</span></figcaption><ul class=\"bars\">"
        for (glabel, rows) in groups {
            out += "<li class=\"group\">" + (glabel.map { "<span class=\"glab\">\(esc($0))</span>" } ?? "") + "<ul class=\"bars\">"
            for r in rows {
                let pend = D.pending(r.id)
                let w: Double, val: String, aria: String
                if pend {
                    w = 0; let word = D.isNA(r.id) ? "n/a" : "pending"
                    val = "<span class=\"val\">\(word)</span>"; aria = "\(r.label): \(word)"
                } else {
                    let v = num(r.id) ?? 0
                    w = max(0.0, min(100.0, 100.0 * v / mx))
                    let shown = D.text(r.id)
                    val = "<span class=\"val\" title=\"\(esc(r.id))\">\(esc(shown))</span>"
                    aria = "\(r.label): \(shown) \(fig(r.id).unitJSON.pyStr)"
                }
                let fill = pend ? "" : "<rect class=\"fill\" x=\"0\" y=\"0\" width=\"\(fmtFixed(w, 2))\" height=\"10\"/>"
                out += "<li class=\"bar \(r.cls)\(pend ? " pend" : "")\"><span class=\"lab\">\(esc(r.label))</span>\(val)"
                    + "<svg viewBox=\"0 0 100 10\" preserveAspectRatio=\"none\" role=\"img\" aria-label=\"\(esc(aria))\"><title>\(esc(aria))</title>"
                    + "<rect class=\"rail\" x=\"0\" y=\"0\" width=\"100\" height=\"10\"/>\(fill)</svg></li>"
            }
            out += "</ul></li>"
        }
        out += "</ul><div class=\"axis\" aria-hidden=\"true\"><span>0</span><span>\(String(format: "%g", mx)) \(esc(unit))</span></div></figure>"
        return out
    }

    func srcLink(_ path: String, rel: String = "../") -> String {
        if path.hasPrefix("bench/soak/results/<") || path.hasPrefix("(derived)") || !fileExists(root + "/" + path) {
            return "<code>\(esc(path))</code>"
        }
        return "<a href=\"\(rel)\(esc(path))\"><code>\(esc(path))</code></a>"
    }
}
