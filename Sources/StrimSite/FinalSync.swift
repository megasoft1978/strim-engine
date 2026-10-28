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

struct NumCell { var value: Double; var dp: Int; var n: String? }

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
    guard let v = Double(numText) else { throw bad() }
    return NumCell(value: v, dp: fracLen, n: nTxt)
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
    var median: [String: Double]
    var passes: [String: Int]
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
        let secs = mdSections(text)
        var figs: [PyJSON] = []

        let caveats: [String: String] = [
            "strim": "Strim build 2df65e7 (serve defaults: MTP head, admission, batched decode, prefix cache); it predates the server hardening commits, HEAD was not re-benchmarked.",
            "rapid-mlx": "rapid-mlx 0.15.7 with MTP on and --max-num-seqs 4 (c=8 queues); rival tuning was not explored.",
            "mlx-vlm": "mlx-vlm 0.7.10 server defaults: no MTP, no cross-request prefix cache. Rival pass 1 ran under higher system load.",
        ]
        func add(_ id: String, _ value: PyJSON, _ unit: String, dp: Int?, method: String, caveat: String, n: String? = nil,
                 md: [(String, String)]? = nil, verify: String? = nil, section: String? = nil) {
            var f = JObject()
            f["id"] = .string(id); f["value"] = value; f["unit"] = .string(unit); f["source_path"] = .string(FINAL_SRC)
            f["method_note"] = .string(method); f["caveat"] = .string(caveat); f["dataset"] = .string("final")
            if let dp { f["dp"] = .int(dp) }
            if let n { f["n"] = .string(n) }
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
        func numD(_ v: PyJSON?) throws -> Double {
            guard let d = v?.number else { throw SiteError("results.json: expected a number, got \(v.map { pyReprValue($0) } ?? "nothing")") }
            return d
        }

        // ---- cells
        var cells: [HCell] = []
        for c in res["cells"]?.arr ?? [] {
            var med: [String: Double] = [:], pp: [String: Int] = [:]
            for e in ENGINES {
                med[e] = try numD(c["median"]?[e])
                pp[e] = c["per_pass"]?[e]?.arr?.count ?? 0
            }
            cells.append(HCell(id: c["id"]?.pyStr ?? "", label: c["cell"]?.pyStr ?? "", unit: c["unit"]?.pyStr ?? "", better: c["better"]?.pyStr ?? "", median: med, passes: pp))
        }
        let (hdr, body) = try mdTable(try mdSec(secs, "Results"))
        guard body.count == cells.count else { throw SiteError("summary.md Results has \(body.count) rows, results.json has \(cells.count) cells") }
        var ratios: [String: [String: Double]] = [:]   // cell id -> rival -> displayed ratio
        for r in body {
            guard let c = cells.first(where: { $0.label == r[0] }) else { throw SiteError("summary.md row \(pyReprString(r[0])) has no results.json cell") }
            let isFrac = c.unit == "frac"
            let unit = isFrac ? "%" : c.unit
            for e in ENGINES {
                guard let ci = hdr.firstIndex(of: e), ci < r.count else { throw SiteError("summary.md Results has no column \(e)") }
                guard let p = try numCell(r[ci]) else { continue }
                let jv = c.median[e] ?? 0
                if pyRound(jv, p.dp) != p.value { throw SiteError("\(c.label)/\(e): summary.md says \(pyReprString(r[ci])), results.json says \(pyRepr(jv))") }
                let shown = isFrac ? pyRound(p.value * 100, max(p.dp - 2, 0)) : p.value
                add(fid(c.id, e), .double(shown), unit, dp: isFrac ? max(p.dp - 2, 0) : p.dp,
                    method: "Final head-to-head 2026-10-28: \(c.label), \(e). Median of \(c.passes[e] ?? 0) passes (1 rep each); HTTP, one engine at a time, Qwen3.8-27B 4-bit, thinking off, greedy.",
                    caveat: caveats[e] ?? "", n: String(c.passes[e] ?? 0),
                    md: [("section", "Results"), ("row", c.label), ("col", e), ("cell", r[ci].replacingOccurrences(of: "**", with: ""))])
            }
            for rv in RIVALS {
                guard let ri = hdr.firstIndex(of: "strim/\(rv)"), let vi = hdr.firstIndex(of: "vs \(rv)"), ri < r.count, vi < r.count else { throw SiteError("summary.md Results lacks ratio columns for \(rv)") }
                if let p = try ratioCell(r[ri]) {
                    let want = (c.median["strim"] ?? 0) / (c.median[rv] ?? 1)
                    if abs(pyRound(want, 2) - p.value) > 0.0051 { throw SiteError("\(c.label): ratio \(r[ri]) vs rival \(rv) disagrees with results.json (\(pyRepr(want)))") }
                    ratios[c.id, default: [:]][rv] = p.value
                    add(fratio(c.id, rv), .double(p.value), "x", dp: 2,
                        method: "Final head-to-head: \(c.label), Strim median divided by \(rv) median (displayed in summary.md).", caveat: "Ratio of two medians of two passes; the TIE band is 2%.",
                        md: [("section", "Results"), ("row", c.label), ("col", "strim/\(rv)"), ("cell", r[ri])])
                }
                let v = r[vi].replacingOccurrences(of: "**", with: "")
                if !["WIN", "LOSS", "TIE", "n/a"].contains(v) { throw SiteError("\(c.label): unknown verdict \(pyReprString(v))") }
                add(fverdict(c.id, rv), .string(v), "", dp: nil,
                    method: "Final head-to-head: verdict for \(c.label) against \(rv). Higher-is-better cells win with ratio above 1, lower-is-better cells (TTFT, time) with ratio below 1; TIE is within 2%.",
                    caveat: "Verdicts at the edge of the 2% band can flip with one pass (summary.md lists six such cells).",
                    md: [("section", "Results"), ("row", c.label), ("col", "vs \(rv)"), ("cell", v)])
            }
        }
        // ---- peak memory, whole run (footprint of the engine process tree)
        let (mh, mb) = try mdTable(try mdSec(secs, "Peak memory"))
        guard let whole = mb.first(where: { $0.first == "**whole run**" }) else { throw SiteError("summary.md: no whole-run memory row") }
        for e in ENGINES {
            guard let ci = mh.firstIndex(of: "\(e) footprint / RSS"), ci < whole.count else { throw SiteError("summary.md memory table lacks \(e)") }
            let cell = whole[ci].replacingOccurrences(of: "**", with: "")
            guard let mbText = cell.split(separator: " ").first, let mbv = Double(mbText) else { throw SiteError("summary.md memory cell \(pyReprString(cell))") }
            add("final.mem.\(e)", .double(pyRound(mbv / 1000, 1)), "GB", dp: 1,
                method: "Peak physical footprint of the engine process tree over the whole run (max over passes and sessions), \(e): \(cell) MB footprint / RSS in summary.md, shown here in GB.",
                caveat: "phys_footprint includes Metal buffers. Whole-run maximum, not steady state; abort limit was 42 GB.",
                md: [("section", "Peak memory"), ("row", "**whole run**"), ("col", "\(e) footprint / RSS"), ("contains", String(mbText))])
        }
        // ---- greedy agreement
        let agree: [(String, String, String, String)] = [
            ("self", "8/8", "strim pass1 vs pass2 (self): 8/8 identical", "Strim pass 1 against Strim pass 2, 8 fixed prompts, 64 greedy tokens."),
            ("rapid-mlx", "7/8", "strim vs rapid-mlx (pass1): 7/8 identical", "Strim against rapid-mlx, 8 fixed prompts, 64 greedy tokens (same in pass 2)."),
            ("mlx-vlm", "6/8", "strim vs mlx-vlm (pass1): 6/8 identical", "Strim against mlx-vlm, 8 fixed prompts, 64 greedy tokens (same in pass 2)."),
        ]
        for (k, v, needle, what) in agree {
            add("final.agree.\(k)", .string(v), "prompts identical", dp: nil, method: what,
                caveat: "Sanity check only: near-ties diverge, one divergence flips every later token.", verify: needle, section: "Greedy agreement")
        }
        // ---- claim ranges: recomputed from the displayed ratios and compared with the quoted wording
        func rng(_ ids: [String], _ rivals: [String], pct: Bool, lower: Bool = false) throws -> String {
            var v: [Double] = []
            for i in ids { for rv in rivals {
                guard let x = ratios[i]?[rv] else { throw SiteError("claim range: no ratio for \(i)/\(rv)") }
                v.append(pct ? (lower ? 100 - x * 100 : x * 100 - 100) : x)
            } }
            let lo = v.min() ?? 0, hi = v.max() ?? 0
            return pct ? "\(fmtFixed(lo, 0))-\(fmtFixed(hi, 0))%" : "\(fmtFixed(lo, 1))-\(fmtFixed(hi, 1))x"
        }
        func bestRivalGap(_ ids: [String]) throws -> String {
            var v: [Double] = []
            for i in ids {
                guard let c = cells.first(where: { $0.id == i }) else { throw SiteError("claim range: no cell \(i)") }
                let best = RIVALS.map { c.median[$0] ?? 0 }.max() ?? 1
                v.append(100 - pyRound((c.median["strim"] ?? 0) / best, 2) * 100)
            }
            return "\(fmtFixed(v.min() ?? 0, 0))-\(fmtFixed(v.max() ?? 0, 0))%"
        }
        func worstP95(_ ids: [String]) throws -> String {
            var v: [Double] = []
            for i in ids {
                guard let c = cells.first(where: { $0.id == i }) else { throw SiteError("claim range: no cell \(i)") }
                let best = RIVALS.map { c.median[$0] ?? 0 }.min() ?? 1
                v.append(pyRound((c.median["strim"] ?? 0) / best, 2) * 100 - 100)
            }
            return "\(fmtFixed(v.min() ?? 0, 0))-\(fmtFixed(v.max() ?? 0, 0))%"
        }
        let p50 = ["p50_512c4", "p50_512c8", "p50_agc4", "p50_agc8", "p50_4kc4", "p50_4kc8"]
        let aggs = ["a512c4", "a512c8", "aagc4", "aagc8", "a4kc4", "a4kc8"]
        let claims: [(String, String, String, String, String)] = [
            ("decode_vs_rapid", try rng(["d4k", "d16k", "d32k"], ["rapid-mlx"], pct: true), "24-41% faster than rapid-mlx", "Decode speed gain over rapid-mlx (MTP on) at 4K, 16K and 32K context: range of strim/rapid-mlx - 1 over the three decode cells.", "%"),
            ("decode_vs_vlm", try rng(["d4k", "d16k", "d32k"], ["mlx-vlm"], pct: false), "1.9-2.3x faster than mlx-vlm", "Decode speed ratio over mlx-vlm at 4K, 16K and 32K context: range of strim/mlx-vlm over the three decode cells.", "x"),
            ("w5_speedup", try rng(["aw5"], RIVALS, pct: false), "2.7-2.9x faster", "Aggregate throughput of 4 clients sharing a 16K prefix: range of strim/rival over both rivals.", "x"),
            ("ttft_p50_lower", try rng(p50, RIVALS, pct: true, lower: true), "(21-44% lower)", "Median first-token latency at 4 and 8 concurrent requests (512-token, agent and 4K prompts): range of 1 - strim/rival over six cells and both rivals.", "%"),
            ("agg_lower", try bestRivalGap(aggs), "4-14% lower on aggregate", "Aggregate throughput gap to the best rival at c=4 and c=8 (512-token, agent and 4K prompts): range of 1 - strim/best rival over six cells.", "%"),
            ("p95_worse", try worstP95(["p95_512c4", "p95_512c8"]), "22-31% worse p95", "p95 first-token latency gap to the best rival at c=4 and c=8 with 512-token prompts: strim/best rival - 1.", "%"),
        ]
        var claimIds: [String] = []
        for (k, v, needle, what, _) in claims {
            let quoted = needle.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            guard pyContains(text, needle) || pyContains(text, quoted) else { throw SiteError("summary.md claim wording lacks \(pyReprString(needle)); recomputed range is \(v)") }
            guard pyContains(needle, v) else { throw SiteError("claim \(k): recomputed \(v) is not what summary.md quotes (\(pyReprString(needle)))") }
            add("final.claim.\(k)", .string(v), "", dp: nil, method: what, caveat: "Recomputed from the displayed ratios by strim site build and matched against the claim wording in summary.md.",
                verify: needle, section: "Supported claim wording")
            claimIds.append("final.claim.\(k)")
        }
        add("final.claim.prefill_slower", .string("2-3%"), "", dp: nil,
            method: "Cold prefill at 16K and 32K: Strim is slower than the best rival (16K and 32K TTFT ratios 1.03; prefill ratios 0.97 against mlx-vlm).",
            caveat: "Quoted from summary.md; the gap sits at the edge of the 2% TIE band and was consistent in both passes.", verify: "slightly slower (2-3%)", section: "Supported claim wording")
        add("final.claim.passes", .int(2), "passes", dp: nil, method: "Passes per engine (pass 1 order strim, rapid-mlx, mlx-vlm; pass 2 reversed).",
            caveat: "One rep per pass, so a median over two values is their mean.", verify: "2 passes", section: "Completeness and validity")
        add("final.claim.build", .string("2df65e7"), "", dp: nil, method: "Strim commit that was benchmarked.", caveat: "Predates the server hardening commits; engine hot paths are otherwise unchanged at HEAD.",
            verify: "exactly commit 2df65e7", section: "Completeness and validity")
        add("final.claim.swap", .int(0), "MB", dp: nil, method: "Swap growth in every benchmark session.", caveat: "Baseline swap (about 5.7 GB of 7 GB) was pre-existing and constant.",
            verify: "Swap growth 0 MB in every session", section: "Completeness and validity")
        add("final.claim.cells", .int(48), "cells", dp: nil, method: "Cells run: 3 engines x 2 passes x 8 cells; all present, rc=0.", caveat: "Nothing had to be rerun.",
            verify: "all 48 cells present", section: "Completeness and validity")
        let flips = "only 6 of 33 cells change verdict"
        add("final.claim.flips", .int(6), "cells", dp: nil, method: "Cells whose verdict changes between pass 1 and pass 2 (of 33).", caveat: "All sit in the 2-4% band; concurrency and decode conclusions do not change.",
            verify: flips, section: "Completeness and validity")

        var ci = JObject()
        ci["source"] = .string(FINAL_SRC)
        ci["engines"] = .array(ENGINES.map { .string($0) })
        ci["cells"] = .array(cells.map { c in
            var o = JObject()
            o["id"] = .string(c.id); o["label"] = .string(c.label); o["unit"] = .string(c.unit == "frac" ? "%" : c.unit); o["better"] = .string(c.better)
            return .object(o)
        })
        let ids = figs.compactMap { $0["id"]?.str }
        if ids.count != Set(ids).count { throw SiteError("duplicate final figure ids") }
        top["figures"] = .array(figList + figs)
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
