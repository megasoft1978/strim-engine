import Foundation

/// Markdown helpers for bench/results/final-*/summary.md.
struct MdSections {
    var keys: [String] = []
    var lines: [String: [String]] = [:]
}

func mdSections(_ text: String) -> MdSections {
    var s = MdSections()
    var cur: String?
    for line in pySplitlines(text) {
        if line.hasPrefix("## ") {
            let k = pyStrip(String(line.dropFirst(3)))
            cur = k
            if s.lines[k] == nil { s.keys.append(k) }
            s.lines[k] = []
        } else if let c = cur {
            s.lines[c]!.append(line)
        }
    }
    return s
}

func mdSec(_ secs: MdSections, _ prefix: String) throws -> [String] {
    for k in secs.keys where k.hasPrefix(prefix) { return secs.lines[k]! }
    throw SiteError("summary.md: no section starting with \(pyReprString(prefix))")
}

func mdTable(_ lines: [String]) throws -> (header: [String], body: [[String]]) {
    let rows = lines.filter { $0.hasPrefix("|") }.map { l in
        pyStrip(pyStrip(l), chars: ["|"]).split(separator: "|", omittingEmptySubsequences: false).map { pyStrip(String($0)) }
    }
    if rows.count < 3 { throw SiteError("summary.md: table not found") }
    return (rows[0], Array(rows[2...]))
}

/// Cell of the first table in section, selected by row label and column header; `**` removed.
func mdCell(_ text: String, _ section: String, _ row: String, _ col: String) throws -> String? {
    let (hdr, body) = try mdTable(try mdSec(mdSections(text), section))
    guard let ci = hdr.firstIndex(of: col) else { return nil }
    for r in body where r.first == row {
        guard ci < r.count else { throw SiteError("IndexError: row \(row) has no column \(col)") }
        return r[ci].replacingOccurrences(of: "**", with: "")
    }
    return nil
}

struct NumCell { var value: Double; var dp: Int; var n: String?; var exp: Int? = nil }

/// '63.3 (4)' -> (63.3, 1 decimal place, "4"); 'n/a' -> nil.
func numCell(_ cell: String) throws -> NumCell? {
    let c = pyStrip(cell.replacingOccurrences(of: "**", with: ""))
    if c == "n/a" { return nil }
    func bad() -> SiteError { SiteError("summary.md: cannot parse cell \(pyReprString(c))") }
    let s = Array(c.unicodeScalars)
    var i = 0
    func digits() -> String {
        var r = String.UnicodeScalarView()
        while i < s.count, s[i].value >= 0x30, s[i].value <= 0x39 { r.append(s[i]); i += 1 }
        return String(r)
    }
    var numText = ""
    if i < s.count, s[i] == "-" { numText = "-"; i += 1 }
    let ip = digits()
    if ip.isEmpty { throw bad() }
    numText += ip
    var fracLen = 0
    if i < s.count, s[i] == "." {
        i += 1
        let fp = digits()
        if fp.isEmpty { throw bad() }
        numText += "." + fp
        fracLen = fp.unicodeScalars.count
    }
    var expo: Int?
    if i < s.count, s[i] == "e" || s[i] == "E" {   // printf %.4g: 1.526e+04
        var j = i + 1
        var sign = 1
        if j < s.count, s[j] == "+" || s[j] == "-" { sign = s[j] == "-" ? -1 : 1; j += 1 }
        var dd = ""
        while j < s.count, s[j].value >= 0x30, s[j].value <= 0x39 { dd.unicodeScalars.append(s[j]); j += 1 }
        guard let e = Int(dd) else { throw bad() }
        expo = sign * e; i = j
    }
    var nTxt: String?
    if i < s.count, s[i] == " " {
        // optional " (n)"
        var j = i + 1
        if j < s.count, s[j] == "(" {
            j += 1
            var dd = String.UnicodeScalarView()
            while j < s.count, s[j].value >= 0x30, s[j].value <= 0x39 { dd.append(s[j]); j += 1 }
            if !dd.isEmpty, j < s.count, s[j] == ")" { nTxt = String(dd); i = j + 1 }
        }
    }
    if i < s.count, s[i] == "%" { i += 1 }
    if i != s.count { throw bad() }
    guard var v = Double(numText) else { throw bad() }
    if let expo { v = Double(numText + "e" + String(expo)) ?? v }
    return NumCell(value: v, dp: expo.map { max(0, fracLen - $0) } ?? fracLen, n: nTxt, exp: expo)
}

/// '1.33x' -> 1.33 (2 decimal places); 'n/a' -> nil.
func ratioCell(_ cell: String) throws -> NumCell? {
    let c = pyStrip(cell.replacingOccurrences(of: "**", with: ""))
    if c == "n/a" { return nil }
    guard c.hasSuffix("x"), let p = try? numCell(String(c.dropLast())) else { throw SiteError("summary.md: cannot parse ratio \(pyReprString(c))") }
    return p
}

struct HCell {
    var id: String
    var label: String
    var unit: String
    var better: String
    var median: [String: Double]      // absent key = n/a (null in results.json)
    var passes: [String: Int]
    /// claim_eligible per engine (schema 2); nil when the run predates it (all cells then count as claimable).
    var eligible: [String: Bool]? = nil
    var excluded: [String: [Int]] = [:]
    var sessionStatus: [String: [String]] = [:]
}

extension SiteBuilder {
    /// Regenerate the final.* figures and the raw["final"] layout block from bench/results/h2h-final-20261028/.
    func syncFinal(_ rawIn: PyJSON) throws -> PyJSON {
        guard var top = rawIn.obj else { throw SiteError("results.json: not an object") }
        var figList: [PyJSON] = []
        for f in top["figures"]?.arr ?? [] where f["dataset"]?.str != "final" { figList.append(f) }
        top["figures"] = .array(figList)
        top["final"] = nil
        let smP = finalDir + "/summary.md", rjP = finalDir + "/results.json"
        guard fileExists(smP), fileExists(rjP) else { return .object(top) }
        guard let text = readText(smP), let rjText = readText(rjP) else { throw SiteError("cannot read \(FINAL_REL) files") }
        let res = try PyJSONParser.parse(rjText)
        let engs = (res["engines"]?.arr ?? []).compactMap { $0.str }
        guard engs.count >= 2, engs[0] == "strim" else { throw SiteError("results.json: engines must list strim first and at least one rival") }
        engineList = engs
        engineMeta = [:]
        for (e, m) in res["engine_meta"]?.obj?.items ?? [] {
            var d: [String: String] = [:]
            for (k, v) in m.obj?.items ?? [] { d[k] = v.pyStr }
            engineMeta[e] = d
        }
        let secs = mdSections(text)
        var figs: [PyJSON] = []

        let passCount = (res["cells"]?.arr ?? []).compactMap { $0["per_pass"]?["strim"]?.arr?.count }.min() ?? 0
        var meta = parseRunMeta(summary: text, passes: passCount, engines: engs)
        // schema 2 runs carry their session records in results.json (the summary has a session table instead of the old completeness table)
        var latest: [String: PyJSON] = [:]
        for s in res["sessions"]?.arr ?? [] {
            let key = (s["engine"]?.pyStr ?? "") + "|" + String(Int(s["pass"]?.number ?? 0)) + "|" + (s["cells"]?.arr ?? []).map { $0.pyStr }.joined(separator: ",")
            if let old = latest[key], (old["end"]?.number ?? 0) > (s["end"]?.number ?? 0) { continue }
            latest[key] = s
        }
        let sessionsFromJSON = !(res["sessions"]?.arr ?? []).isEmpty
        var primary: [String: PyJSON] = [:]
        for s in res["sessions"]?.arr ?? [] {
            let key = (s["engine"]?.pyStr ?? "") + "|" + String(Int(s["pass"]?.number ?? 0)) + "|" + (s["cells"]?.arr ?? []).map { $0.pyStr }.joined(separator: ",")
            if let old = primary[key], (old["end"]?.number ?? .greatestFiniteMagnitude) <= (s["end"]?.number ?? .greatestFiniteMagnitude) { continue }
            primary[key] = s
        }
        if sessionsFromJSON {
            meta.sessions = primary.count
            meta.polluted = primary.values.filter { ($0["status"]?.pyStr ?? "UNKNOWN") != "CLEAN" }.count
            meta.maxLoad = primary.values.compactMap { $0["load_max"]?.number }.max()
        }
        if meta.build == "unknown", let v = engineMeta["strim"]?["version"], !v.isEmpty, v != "n/a" { meta.build = v }
        runVersions = meta.versions
        let runWord = ""
        var caveats: [String: String] = [
            "strim": "Strim build \(meta.build) (serve defaults: MTP head, admission, batched decode, prefix cache); later commits were not benchmarked.\(runWord)",
        ]
        for e in engs.dropFirst() {
            let ver = engVersion(e).map { " " + $0 } ?? ""
            if let m = engineMeta[e], m["flags"] != nil {
                caveats[e] = "\(WIDE_NAMES[e] ?? e)\(ver), flags: \(m["flags"] ?? ""); MTP: \(m["mtp"] ?? "n/a"); prefix cache: \(m["prefix_cache"] ?? "n/a"); rival tuning was not explored.\(runWord)"
            } else if e == "rapid-mlx" {
                caveats[e] = "rapid-mlx\(ver) with MTP on and --max-num-seqs 4 (c=8 queues); rival tuning was not explored.\(runWord)"
            } else if e == "mlx-vlm" {
                caveats[e] = "mlx-vlm\(ver) server defaults: no MTP, no cross-request prefix cache.\(runWord)"
            } else {
                caveats[e] = "\(WIDE_NAMES[e] ?? e)\(ver) with its server defaults; rival tuning was not explored.\(runWord)"
            }
        }
        func add(_ id: String, _ value: PyJSON, _ unit: String, dp: Int?, method: String, caveat: String, n: String? = nil,
                 md: [(String, String)]? = nil, verify: String? = nil, section: String? = nil, computed: Bool = false,
                 verify_count: (String, String, [String])? = nil, na: Bool = false) {
            var f = JObject()
            f["id"] = .string(id); f["value"] = value; f["unit"] = .string(unit); f["source_path"] = .string(FINAL_SRC)
            f["method_note"] = .string(method); f["caveat"] = .string(caveat); f["dataset"] = .string("final")
            if let dp { f["dp"] = .int(dp) }
            if let n { f["n"] = .string(n) }
            if computed { f["computed"] = .bool(true) }
            if na { f["na"] = .bool(true) }
            if let vc = verify_count {
                var o = JObject()
                o["section"] = .string(vc.0); o["contains"] = .string(vc.1); o["line_prefix"] = .array(vc.2.map { .string($0) })
                f["verify_count"] = .object(o)
            }
            if let md {
                var m = JObject()
                for (k, v) in md { m[k] = .string(v) }
                f["verify_md"] = .object(m)
            }
            if let verify, !verify.isEmpty {
                f["verify"] = .string(verify)
                f["verify_section"] = section.map { .string($0) } ?? .null
            }
            figs.append(.object(f))
        }
        func numD(_ v: PyJSON?) throws -> Double? {
            if v == nil || v!.isNull { return nil }
            guard let d = v?.number else { throw SiteError("results.json: expected a number or null, got \(v.map { pyReprValue($0) } ?? "nothing")") }
            return d
        }

        // ---- cells
        var cells: [HCell] = []
        for c in res["cells"]?.arr ?? [] {
            var med: [String: Double] = [:], pp: [String: Int] = [:]
            for e in engs {
                if let v = try numD(c["median"]?[e]) { med[e] = v }
                pp[e] = c["per_pass"]?[e]?.arr?.count ?? 0
            }
            var hc = HCell(id: c["id"]?.pyStr ?? "", label: c["cell"]?.pyStr ?? "", unit: c["unit"]?.pyStr ?? "", better: c["better"]?.pyStr ?? "", median: med, passes: pp)
            if let ce = c["claim_eligible"]?.obj {
                var el: [String: Bool] = [:]
                for e in engs { if case .bool(let b)? = ce[e] { el[e] = b } else { el[e] = false } }
                hc.eligible = el
            }
            for (e, v) in c["excluded_passes"]?.obj?.items ?? [] { hc.excluded[e] = (v.arr ?? []).compactMap { $0.number }.map { Int($0) } }
            for (e, v) in c["session_status"]?.obj?.items ?? [] { hc.sessionStatus[e] = (v.arr ?? []).compactMap { $0.str } }
            cells.append(hc)
        }
        let sessionFlags: [(engine: String, pass: Int, cell: String, flag: String)] = (res["flags"]?.arr ?? []).map {
            ($0["engine"]?.pyStr ?? "", Int($0["pass"]?.number ?? 0), $0["cell"]?.pyStr ?? "", $0["flag"]?.pyStr ?? "")
        }
        /// Why Strim-vs-rival is not claimable for this cell: the first engine that is not eligible, with the exclusion flags and session states; nil = claimable.
        func notClaimable(_ c: HCell, _ rv: String) -> String? {
            guard let el = c.eligible else { return nil }
            var why: [String] = []
            for e in ["strim", rv] where el[e] != true {
                let name = WIDE_NAMES[e] ?? e
                var parts: [String] = []
                if c.median[e] == nil { parts.append("no valid value") }
                for p in c.excluded[e] ?? [] {
                    let fl = Array(Set(sessionFlags.filter { $0.engine == e && $0.pass == p && ["memory_abort_watchdog", "engine_guard_abort", "engine_oom", "cell_timeout"].contains($0.flag) }.map { $0.flag })).sorted()
                    parts.append("pass \(p) excluded" + (fl.isEmpty ? "" : " (" + fl.joined(separator: ", ") + ")"))
                }
                let bad = Array(Set((c.sessionStatus[e] ?? []).filter { $0 != "CLEAN" })).sorted()
                if !bad.isEmpty { parts.append("session " + bad.joined(separator: "/")) }
                if parts.isEmpty { parts.append("not every pass is clean") }
                why.append("\(name): " + parts.joined(separator: ", "))
            }
            return why.isEmpty ? nil : why.joined(separator: "; ")
        }
        var claimNotes = JObject()   // cell id -> { rival -> reason } for the cells that cannot carry a verdict
        let (hdr, body) = try mdTable(try mdSec(secs, "Results"))
        guard body.count == cells.count else { throw SiteError("summary.md Results has \(body.count) rows, results.json has \(cells.count) cells") }
        var ratios: [String: [String: Double]] = [:]   // cell id -> rival -> displayed ratio (claimable cells only)
        for r in body {
            guard let c = cells.first(where: { $0.label == r[0] }) else { throw SiteError("summary.md row \(pyReprString(r[0])) has no results.json cell") }
            let isFrac = c.unit == "frac"
            let unit = isFrac ? "%" : c.unit
            for e in engs {
                guard let ci = hdr.firstIndex(of: e), ci < r.count else { throw SiteError("summary.md Results has no column \(e)") }
                guard let p = try numCell(r[ci]) else {
                    guard c.median[e] == nil else { throw SiteError("\(c.label)/\(e): summary.md says n/a, results.json says \(pyRepr(c.median[e] ?? 0))") }
                    add(fid(c.id, e), .null, unit, dp: nil,
                        method: "Head-to-head \(meta.date) (\(meta.id)): \(c.label), \(e). No valid value: every pass of this cell was excluded or the engine aborted (n/a in summary.md).",
                        caveat: caveats[e] ?? "", n: String(c.passes[e] ?? 0),
                        md: [("section", "Results"), ("row", c.label), ("col", e), ("cell", "n/a")], na: true)
                    continue
                }
                guard let jv = c.median[e] else { throw SiteError("\(c.label)/\(e): summary.md says \(pyReprString(r[ci])), results.json says null") }
                if p.exp != nil ? abs(jv - p.value) > abs(p.value) * 1e-3 : pyRound(jv, p.dp) != p.value { throw SiteError("\(c.label)/\(e): summary.md says \(pyReprString(r[ci])), results.json says \(pyRepr(jv))") }
                let shown = isFrac ? pyRound(p.value * 100, max(p.dp - 2, 0)) : p.value
                add(fid(c.id, e), .double(shown), unit, dp: isFrac ? max(p.dp - 2, 0) : p.dp,
                    method: "Head-to-head \(meta.date) (\(meta.id)): \(c.label), \(e). Median of \(c.passes[e] ?? 0) passes (1 rep each); HTTP, one engine at a time, Qwen3.8-27B 4-bit, thinking off, greedy.",
                    caveat: caveats[e] ?? "", n: String(c.passes[e] ?? 0),
                    md: [("section", "Results"), ("row", c.label), ("col", e), ("cell", r[ci].replacingOccurrences(of: "**", with: ""))])
            }
            for rv in engs.dropFirst() {
                guard let ri = hdr.firstIndex(of: "strim/\(rv)"), let vi = hdr.firstIndex(of: "vs \(rv)"), ri < r.count, vi < r.count else { throw SiteError("summary.md Results lacks ratio columns for \(rv)") }
                let blocked = notClaimable(c, rv)
                if let p = try ratioCell(r[ri]) {
                    let want = (c.median["strim"] ?? 0) / (c.median[rv] ?? 1)
                    if abs(pyRound(want, 2) - p.value) > 0.0051 { throw SiteError("\(c.label): ratio \(r[ri]) vs rival \(rv) disagrees with results.json (\(pyRepr(want)))") }
                    if blocked == nil { ratios[c.id, default: [:]][rv] = p.value }
                    add(fratio(c.id, rv), .double(p.value), "x", dp: 2,
                        method: "Final head-to-head: \(c.label), Strim median divided by \(rv) median (displayed in summary.md).", caveat: "Ratio of two medians of two passes; the TIE band is 2%.",
                        md: [("section", "Results"), ("row", c.label), ("col", "strim/\(rv)"), ("cell", r[ri])])
                }
                let v = r[vi].replacingOccurrences(of: "**", with: "")
                if !["WIN", "LOSS", "TIE", "n/a"].contains(v) { throw SiteError("\(c.label): unknown verdict \(pyReprString(v))") }
                var shownVerdict = v
                var caveat = "Verdicts at the edge of the 2% band can flip with one pass (summary.md lists six such cells)."
                if let why = blocked, v != "n/a" {
                    shownVerdict = "NC"
                    caveat = "Not claimable: \(why). The summary.md verdict is withheld here because the cell is not claim_eligible."
                }
                if let why = blocked {
                    var o = claimNotes[c.id]?.obj ?? JObject()
                    o[rv] = .string(why)
                    claimNotes[c.id] = .object(o)
                }
                add(fverdict(c.id, rv), .string(shownVerdict), "", dp: nil,
                    method: "Final head-to-head: verdict for \(c.label) against \(rv). Higher-is-better cells win with ratio above 1, lower-is-better cells (TTFT, time) with ratio below 1; TIE is within 2%.\(cells.contains { $0.eligible != nil } ? " NC = not claimable (claim_eligible is not true for Strim or the rival)." : "")",
                    caveat: caveat,
                    md: [("section", "Results"), ("row", c.label), ("col", "vs \(rv)"), ("cell", v)])
            }
        }
        // ---- peak memory, whole run (footprint of the engine process tree)
        let (mh, mb) = try mdTable(try mdSec(secs, "Peak memory"))
        guard let whole = mb.first(where: { $0.first == "**whole run**" }) else { throw SiteError("summary.md: no whole-run memory row") }
        for e in engs {
            guard let ci = mh.firstIndex(of: "\(e) footprint / RSS"), ci < whole.count else { throw SiteError("summary.md memory table lacks \(e)") }
            let cell = whole[ci].replacingOccurrences(of: "**", with: "")
            guard let mbText = cell.split(separator: " ").first, let mbv = Double(mbText) else { throw SiteError("summary.md memory cell \(pyReprString(cell))") }
            add("final.mem.\(e)", .double(pyRound(mbv / 1000, 1)), "GB", dp: 1,
                method: "Peak physical footprint of the engine process tree over the whole run (max over passes and sessions), \(e): \(cell) MB footprint / RSS in summary.md, shown here in GB.",
                caveat: "phys_footprint includes Metal buffers. Whole-run maximum, not steady state; abort limit was 42 GB.",
                md: [("section", "Peak memory"), ("row", "**whole run**"), ("col", "\(e) footprint / RSS"), ("contains", String(mbText))])
        }
        // ---- greedy agreement (parsed from the summary)
        let agreeLines = try mdSec(secs, "Greedy agreement")
        var agree: [(String, String, String)] = [("self", "(self)", "Strim pass 1 against Strim pass 2, 8 fixed prompts, 64 greedy tokens.")]
        for e in engs.dropFirst() { agree.append((e, "strim vs \(e)", "Strim against \(e), 8 fixed prompts, 64 greedy tokens.")) }
        for (k, key, what) in agree {
            guard let line = agreeLines.first(where: { pyContains($0, key) }), let m = firstMatch(#"(\d+/\d+) identical"#, in: line) else {
                if k != "self" && engs.count > 3 { continue }   // a rival without an agreement line (n/a in the summary) is simply not shown
                throw SiteError("summary.md: no greedy agreement line for \(k)")
            }
            add("final.agree.\(k)", .string(m[1]), "prompts identical", dp: nil, method: what,
                caveat: "Sanity check only: near-ties diverge, one divergence flips every later token.", verify: m[0], section: "Greedy agreement")
        }
        // ---- claim ranges: recomputed from the displayed ratios (no hand-typed wording to match)
        func rng(_ ids: [String], _ rivals: [String], pct: Bool, lower: Bool = false) throws -> String {
            var v: [Double] = []
            for i in ids { for rv in rivals {
                guard let x = ratios[i]?[rv] else {
                    if claimNotes[i]?[rv] != nil || cells.first(where: { $0.id == i })?.median[rv] == nil { continue }   // n/a or not claimable: no number
                    throw SiteError("claim range: no ratio for \(i)/\(rv)")
                }
                v.append(pct ? (lower ? 100 - x * 100 : x * 100 - 100) : x)
            } }
            guard let lo = v.min(), let hi = v.max() else { return "n/a" }
            return pct ? "\(fmtFixed(lo, 0))-\(fmtFixed(hi, 0))%" : "\(fmtFixed(lo, 1))-\(fmtFixed(hi, 1))x"
        }
        /// Cells where Strim is worse than the best rival by more than the 2% tie band: (gap range text, count). lowerBetter cells compare against the smallest rival value.
        func lossGap(_ ids: [String]) throws -> (String, Int) {
            var gaps: [Int] = []
            for i in ids {
                guard let c = cells.first(where: { $0.id == i }) else { throw SiteError("claim range: no cell \(i)") }
                let rivalVals = engs.dropFirst().filter { claimNotes[i]?[$0] == nil }.compactMap { c.median[$0] }
                guard let s = c.median["strim"], !rivalVals.isEmpty, claimNotes[i]?["strim"] == nil else { continue }
                let low = c.better == "lower"
                let best = low ? (rivalVals.min() ?? 1) : (rivalVals.max() ?? 1)
                guard best > 0 else { continue }
                let r = s / best
                if low ? r > 1.02 : r < 0.98 {
                    let rr = pyRound(r, 2)
                    gaps.append(Int((low ? rr * 100 - 100 : 100 - rr * 100).rounded()))
                }
            }
            guard let lo = gaps.min(), let hi = gaps.max() else { return ("none", 0) }
            return (lo == hi ? "\(lo)%" : "\(lo)-\(hi)%", gaps.count)
        }
        func sizes(_ pairs: [(String, String)], loss: Bool) throws -> String {
            let hit = try pairs.filter { (_, id) in try lossGap([id]).1 > 0 }.map { $0.0 }
            let pick = loss ? hit : pairs.map { $0.0 }.filter { !hit.contains($0) }
            if pick.isEmpty { return "none" }
            return pick.count == 1 ? pick[0] : pick.dropLast().joined(separator: ", ") + " and " + pick[pick.count - 1]
        }
        let p50 = ["p50_512c4", "p50_512c8", "p50_agc4", "p50_agc8", "p50_4kc4", "p50_4kc8"]
        let aggs = ["a512c4", "a512c8", "aagc4", "aagc8", "a4kc4", "a4kc8"]
        let p95s = ["p95_512c4", "p95_512c8", "p95_agc4", "p95_agc8", "p95_4kc4", "p95_4kc8"]
        let pfs = [("4K", "c4k_pf"), ("16K", "c16k_pf"), ("32K", "c32k_pf")]
        let note = "Recomputed from the displayed ratios by strim site build; there is no hand-typed claim wording."
        func claim(_ k: String, _ v: PyJSON, _ what: String, unit: String = "") {
            add("final.claim.\(k)", v, unit, dp: nil, method: what, caveat: note, computed: true)
        }
        for rv in engs.dropFirst() {
            let name = WIDE_NAMES[rv] ?? rv
            let xs = ["d4k", "d16k", "d32k"].compactMap { ratios[$0]?[rv] }
            let pct = (xs.max() ?? 0) < 2
            claim("decode_vs.\(rv)", .string(try rng(["d4k", "d16k", "d32k"], [rv], pct: pct)),
                  "Decode speed over \(name) at 4K, 16K and 32K context: range of strim/\(rv)\(pct ? " - 1, as a percentage," : "") over the three decode cells (claimable cells only).")
        }
        claim("w5_speedup", .string(try rng(["aw5"], engs.dropFirst().map { $0 }, pct: false)), "Aggregate throughput of 4 clients sharing a 16K prefix: range of strim/rival over all rivals.")
        claim("ttft_p50_lower", .string(try rng(p50, Array(engs.dropFirst()), pct: true, lower: true)), "Median first-token latency at 4 and 8 concurrent requests (512-token, agent and 4K prompts): range of 1 - strim/rival over six cells and all rivals.")
        let agg = try lossGap(aggs), p95 = try lossGap(p95s)
        claim("agg_lower", .string(agg.0), "Aggregate throughput gap to the best rival at c=4 and c=8 over the six concurrency cells, counting only cells where Strim is more than 2% behind.")
        claim("agg_lower_n", .int(agg.1), "Number of the six aggregate-throughput cells where Strim is more than 2% behind the best rival.", unit: "cells")
        claim("p95_worse", .string(p95.0), "p95 first-token gap to the best rival over the six c=4/c=8 cells, counting only cells where Strim is more than 2% slower.")
        claim("p95_worse_n", .int(p95.1), "Number of the six p95 cells where Strim is more than 2% slower than the best rival.", unit: "cells")
        claim("prefill_gap", .string(try lossGap(pfs.map { $0.1 }).0), "Cold prefill (tok/s) gap to the best rival over 4K, 16K and 32K, counting only sizes where Strim is more than 2% behind.")
        claim("prefill_loss", .string(try sizes(pfs, loss: true)), "Cold prompt sizes where Strim prefill is more than 2% behind the best rival.")
        claim("prefill_tie", .string(try sizes(pfs, loss: false)), "Cold prompt sizes where Strim prefill is within 2% of, or ahead of, the best rival.")
        claim("passes", .int(passCount), "Passes per engine (pass 1 in the order of the engines list, pass 2 reversed).", unit: "passes")
        add("final.claim.build", .string(meta.build), "", dp: nil, method: "Strim commit that was benchmarked (from the summary title).",
            caveat: "Commits after this one were not benchmarked.", verify: meta.build)
        // ---- run validity: load and swap, parsed from the summary
        if let ns = meta.sessions, let np = meta.polluted {
            add("final.val.sessions", .int(ns), "sessions", dp: nil, method: "Engine sessions (engine x pass x cell group) listed in the per-session load table.",
                caveat: "", computed: sessionsFromJSON, verify_count: sessionsFromJSON ? nil : ("Completeness", " pass ", ["| "]))
            add("final.val.polluted", .int(np), "sessions", dp: nil, method: "Sessions the summary marks POLLUTED (foreign CPU load above the protocol limit of 3).",
                caveat: "A polluted session is not a clean measurement; rerun before treating the numbers as final.", computed: sessionsFromJSON, verify_count: sessionsFromJSON ? nil : ("Completeness", "POLLUTED", ["| "]))
            add("final.val.clean", .int(max(0, ns - np)), "sessions", dp: nil, method: "Primary engine sessions marked CLEAN; later retries are retained separately.",
                caveat: "Claims additionally require claim_eligible for both engines in each cell.", computed: true)
        }
        if let ml = meta.maxLoad {
            add("final.val.load_max", .double(ml), "", dp: 1, method: "Highest 1-minute load average recorded at a cell start, over all sessions (per-session table).",
                caveat: "Includes the engine's own load; the protocol limit for a clean session is 3 from non-engine work.", verify: sessionsFromJSON ? nil : fmtFixed(ml, 1), section: sessionsFromJSON ? nil : "Completeness", computed: sessionsFromJSON)
        }
        if let sw = meta.maxSwapMB {
            add("final.claim.swap", .int(sw), "MB", dp: nil, method: "Largest swap growth in any benchmark session.", caveat: "Baseline swap was pre-existing.",
                verify: "swap growth max \(sw) MB", section: "Run conditions")
        }

        var ci = JObject()
        ci["source"] = .string(FINAL_SRC)
        ci["engines"] = .array(ENGINES.map { .string($0) })
        if !claimNotes.keys.isEmpty { ci["not_claimable"] = .object(claimNotes) }
        ci["cells"] = .array(cells.map { c in
            var o = JObject()
            o["id"] = .string(c.id); o["label"] = .string(c.label); o["unit"] = .string(c.unit == "frac" ? "%" : c.unit); o["better"] = .string(c.better)
            o["median"] = jobj(engs.compactMap { e in c.median[e].map { (e, PyJSON.double($0)) } })
            o["per_pass"] = jobj(engs.map { e in (e, PyJSON.array((res["cells"]?.arr?.first(where: { $0["id"]?.str == c.id })?["per_pass"]?[e]?.arr ?? []).map { $0 })) })
            o["claim_eligible"] = jobj(engs.map { e in (e, PyJSON.bool(c.eligible?[e] ?? (c.median[e] != nil))) })
            return .object(o)
        })
        let ids = figs.compactMap { $0["id"]?.str }
        if ids.count != Set(ids).count { throw SiteError("duplicate final figure ids") }
        // retarget the hand-entered head-to-head figures and the dataset/meta pointers at the current run directory
        var retargeted: [PyJSON] = []
        for f in figList {
            guard let id = f["id"]?.str, ["ver.rapid", "ver.mlxvlm", "ver.strim_h2h", "ver.hw"].contains(id), var o = f.obj else { retargeted.append(f); continue }
            var value = o["value"]?.pyStr ?? ""
            switch id {
            case "ver.rapid": if let v = engVersion("rapid-mlx") { value = "rapid-mlx " + v }
            case "ver.mlxvlm": if let v = engVersion("mlx-vlm") { value = "mlx-vlm " + v }
            case "ver.strim_h2h": value = "\(engineMeta["strim"]?["version"] ?? "Strim") (\(meta.build))"; o["caveat"] = .string("Commits after this build were not benchmarked.")
            default: break
            }
            o["value"] = .string(value)
            let verifyText = id == "ver.strim_h2h" ? meta.build : value
            if id == "ver.strim_h2h" || pyContains(text, verifyText) { o["verify"] = .string(verifyText); o["computed"] = nil } else { o["verify"] = nil; o["computed"] = .bool(true) }   // the hardware line is not in every summary
            o["source_path"] = .string(FINAL_SRC)
            retargeted.append(.object(o))
        }
        figList = retargeted
        // one version figure per rival of the run (engine_meta.version, else the summary title); verified against the summary text when it states the version
        for e in engs.dropFirst() {
            guard let v = engVersion(e) else { continue }
            var f = JObject()
            f["id"] = .string("ver.h2h.\(e)"); f["value"] = .string("\(WIDE_NAMES[e] ?? e) \(v)"); f["unit"] = .string(""); f["source_path"] = .string(FINAL_SRC)
            f["method_note"] = .string("Measured version of \(e) in the head-to-head run (engine_meta.version in results.json, listed in the summary).")
            f["caveat"] = .string(""); f["dataset"] = .string("final")
            if pyContains(text, v) { f["verify"] = .string(v) } else { f["computed"] = .bool(true) }
            figs.append(.object(f))
        }
        if var ds = top["datasets"]?.arr {
            for k in ds.indices where ds[k]["id"]?.str == "final" {
                if var o = ds[k].obj { o["path"] = .string(FINAL_REL); ds[k] = .object(o) }
            }
            top["datasets"] = .array(ds)
        }
        if var m = top["meta"]?.obj, let g = m["generated"]?.str {
            m["generated"] = .string(g.replacingOccurrences(of: #"bench/results/h2h-[a-z0-9-]+"#, with: FINAL_REL, options: .regularExpression))
            top["meta"] = .object(m)
        }
        top["figures"] = .array(figList + figs)
        ci["validity"] = .object({
            var v = JObject()
            v["run"] = .string(meta.id); v["date"] = .string(meta.date); v["build"] = .string(meta.build)
            v["clean"] = .bool(meta.clean)
            v["sessions"] = .array((res["sessions"]?.arr ?? []).map { s in
                jobj([("engine", s["engine"] ?? .string("")), ("pass", s["pass"] ?? .null),
                      ("cells", s["cells"] ?? .array([])), ("status", s["status"] ?? .string("UNKNOWN")),
                      ("load_max", s["load_max"] ?? .null), ("end", s["end"] ?? .null)])
            })
            return v
        }())
        top["final"] = .object(ci)
        return .object(top)
    }

    /// Independent re-parse of the source table for a figure with verify_md. Returns an error string or nil.
    func mdCheck(_ f: Figure) throws -> String? {
        guard let m = f.raw["verify_md"]?.obj else { return nil }
        let text = readText(root + "/" + f.sourcePath) ?? ""
        let section = m["section"]?.pyStr ?? "", row = m["row"]?.pyStr ?? "", col = m["col"]?.pyStr ?? ""
        guard let got = try mdCell(text, section, row, col) else { return "\(f.id): no cell at \(section) / \(row) / \(col)" }
        if let contains = m["contains"]?.pyStr {
            return pyContains(got, contains) ? nil : "\(f.id): cell \(pyReprString(got)) lacks \(pyReprString(contains))"
        }
        let want = m["cell"]?.pyStr ?? ""
        return got == want ? nil : "\(f.id): source cell is \(pyReprString(got)), figure says \(pyReprString(want))"
    }
}
