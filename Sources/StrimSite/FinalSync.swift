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

        let passCount = (res["cells"]?.arr ?? []).compactMap { $0["per_pass"]?["strim"]?.arr?.count }.min() ?? 0
        let meta = parseRunMeta(summary: text, passes: passCount)
        let runWord = meta.clean ? "" : " Part of the run was load-polluted (see the validity note)."
        let caveats: [String: String] = [
            "strim": "Strim build \(meta.build) (serve defaults: MTP head, admission, batched decode, prefix cache); later commits were not benchmarked.\(runWord)",
            "rapid-mlx": "rapid-mlx\(meta.rapid.map { " " + $0 } ?? "") with MTP on and --max-num-seqs 4 (c=8 queues); rival tuning was not explored.\(runWord)",
            "mlx-vlm": "mlx-vlm\(meta.vlm.map { " " + $0 } ?? "") server defaults: no MTP, no cross-request prefix cache.\(runWord)",
        ]
        func add(_ id: String, _ value: PyJSON, _ unit: String, dp: Int?, method: String, caveat: String, n: String? = nil,
                 md: [(String, String)]? = nil, verify: String? = nil, section: String? = nil, computed: Bool = false,
                 verify_count: (String, String, [String])? = nil) {
            var f = JObject()
            f["id"] = .string(id); f["value"] = value; f["unit"] = .string(unit); f["source_path"] = .string(FINAL_SRC)
            f["method_note"] = .string(method); f["caveat"] = .string(caveat); f["dataset"] = .string("final")
            if let dp { f["dp"] = .int(dp) }
            if let n { f["n"] = .string(n) }
            if computed { f["computed"] = .bool(true) }
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
                    method: "Head-to-head \(meta.date) (\(meta.id)): \(c.label), \(e). Median of \(c.passes[e] ?? 0) passes (1 rep each); HTTP, one engine at a time, Qwen3.8-27B 4-bit, thinking off, greedy.",
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
        // ---- greedy agreement (parsed from the summary)
        let agreeLines = try mdSec(secs, "Greedy agreement")
        let agree: [(String, String, String)] = [
            ("self", "(self)", "Strim pass 1 against Strim pass 2, 8 fixed prompts, 64 greedy tokens."),
            ("rapid-mlx", "strim vs rapid-mlx", "Strim against rapid-mlx, 8 fixed prompts, 64 greedy tokens."),
            ("mlx-vlm", "strim vs mlx-vlm", "Strim against mlx-vlm, 8 fixed prompts, 64 greedy tokens."),
        ]
        for (k, key, what) in agree {
            guard let line = agreeLines.first(where: { pyContains($0, key) }), let m = firstMatch(#"(\d+/\d+) identical"#, in: line) else {
                throw SiteError("summary.md: no greedy agreement line for \(k)")
            }
            add("final.agree.\(k)", .string(m[1]), "prompts identical", dp: nil, method: what,
                caveat: "Sanity check only: near-ties diverge, one divergence flips every later token.", verify: m[0], section: "Greedy agreement")
        }
        // ---- claim ranges: recomputed from the displayed ratios (no hand-typed wording to match)
        func rng(_ ids: [String], _ rivals: [String], pct: Bool, lower: Bool = false) throws -> String {
            var v: [Double] = []
            for i in ids { for rv in rivals {
                guard let x = ratios[i]?[rv] else { throw SiteError("claim range: no ratio for \(i)/\(rv)") }
                v.append(pct ? (lower ? 100 - x * 100 : x * 100 - 100) : x)
            } }
            let lo = v.min() ?? 0, hi = v.max() ?? 0
            return pct ? "\(fmtFixed(lo, 0))-\(fmtFixed(hi, 0))%" : "\(fmtFixed(lo, 1))-\(fmtFixed(hi, 1))x"
        }
        /// Cells where Strim is worse than the best rival by more than the 2% tie band: (gap range text, count). lowerBetter cells compare against the smallest rival value.
        func lossGap(_ ids: [String]) throws -> (String, Int) {
            var gaps: [Int] = []
            for i in ids {
                guard let c = cells.first(where: { $0.id == i }) else { throw SiteError("claim range: no cell \(i)") }
                let rivalVals = RIVALS.map { c.median[$0] ?? 0 }
                let s = c.median["strim"] ?? 0
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
        claim("decode_vs_rapid", .string(try rng(["d4k", "d16k", "d32k"], ["rapid-mlx"], pct: true)), "Decode speed gain over rapid-mlx (MTP on) at 4K, 16K and 32K context: range of strim/rapid-mlx - 1 over the three decode cells.")
        claim("decode_vs_vlm", .string(try rng(["d4k", "d16k", "d32k"], ["mlx-vlm"], pct: false)), "Decode speed ratio over mlx-vlm at 4K, 16K and 32K context: range of strim/mlx-vlm over the three decode cells.")
        claim("w5_speedup", .string(try rng(["aw5"], RIVALS, pct: false)), "Aggregate throughput of 4 clients sharing a 16K prefix: range of strim/rival over both rivals.")
        claim("ttft_p50_lower", .string(try rng(p50, RIVALS, pct: true, lower: true)), "Median first-token latency at 4 and 8 concurrent requests (512-token, agent and 4K prompts): range of 1 - strim/rival over six cells and both rivals.")
        let agg = try lossGap(aggs), p95 = try lossGap(p95s)
        claim("agg_lower", .string(agg.0), "Aggregate throughput gap to the best rival at c=4 and c=8 over the six concurrency cells, counting only cells where Strim is more than 2% behind.")
        claim("agg_lower_n", .int(agg.1), "Number of the six aggregate-throughput cells where Strim is more than 2% behind the best rival.", unit: "cells")
        claim("p95_worse", .string(p95.0), "p95 first-token gap to the best rival over the six c=4/c=8 cells, counting only cells where Strim is more than 2% slower.")
        claim("p95_worse_n", .int(p95.1), "Number of the six p95 cells where Strim is more than 2% slower than the best rival.", unit: "cells")
        claim("prefill_gap", .string(try lossGap(pfs.map { $0.1 }).0), "Cold prefill (tok/s) gap to the best rival over 4K, 16K and 32K, counting only sizes where Strim is more than 2% behind.")
        claim("prefill_loss", .string(try sizes(pfs, loss: true)), "Cold prompt sizes where Strim prefill is more than 2% behind the best rival.")
        claim("prefill_tie", .string(try sizes(pfs, loss: false)), "Cold prompt sizes where Strim prefill is within 2% of, or ahead of, the best rival.")
        claim("passes", .int(passCount), "Passes per engine (pass 1 order strim, rapid-mlx, mlx-vlm; pass 2 reversed).", unit: "passes")
        add("final.claim.build", .string(meta.build), "", dp: nil, method: "Strim commit that was benchmarked (from the summary title).",
            caveat: "Commits after this one were not benchmarked.", verify: meta.build)
        // ---- run validity: load and swap, parsed from the summary
        if let ns = meta.sessions, let np = meta.polluted {
            add("final.val.sessions", .int(ns), "sessions", dp: nil, method: "Engine sessions (engine x pass x cell group) listed in the per-session load table.",
                caveat: "", verify_count: ("Completeness", " pass ", ["| "]))
            add("final.val.polluted", .int(np), "sessions", dp: nil, method: "Sessions the summary marks POLLUTED (foreign CPU load above the protocol limit of 3).",
                caveat: "A polluted session is not a clean measurement; rerun before treating the numbers as final.", verify_count: ("Completeness", "POLLUTED", ["| "]))
        }
        if let ml = meta.maxLoad {
            add("final.val.load_max", .double(ml), "", dp: 1, method: "Highest 1-minute load average recorded at a cell start, over all sessions (per-session table).",
                caveat: "Includes the engine's own load; the protocol limit for a clean session is 3 from non-engine work.", verify: fmtFixed(ml, 1), section: "Completeness")
        }
        if let sw = meta.maxSwapMB {
            add("final.claim.swap", .int(sw), "MB", dp: nil, method: "Largest swap growth in any benchmark session.", caveat: "Baseline swap was pre-existing.",
                verify: "swap growth max \(sw) MB", section: "Run conditions")
        }

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
        // retarget the hand-entered head-to-head figures and the dataset/meta pointers at the current run directory
        var retargeted: [PyJSON] = []
        for f in figList {
            guard let id = f["id"]?.str, ["ver.rapid", "ver.mlxvlm", "ver.strim_h2h", "ver.hw"].contains(id), var o = f.obj else { retargeted.append(f); continue }
            var value = o["value"]?.pyStr ?? ""
            switch id {
            case "ver.rapid": if let v = meta.rapid { value = "rapid-mlx " + v }
            case "ver.mlxvlm": if let v = meta.vlm { value = "mlx-vlm " + v }
            case "ver.strim_h2h": value = "Strim 0.1.0 (\(meta.build))"; o["caveat"] = .string("Commits after this build were not benchmarked.")
            default: break
            }
            o["value"] = .string(value)
            o["verify"] = .string(id == "ver.strim_h2h" ? meta.build : value)
            o["source_path"] = .string(FINAL_SRC)
            retargeted.append(.object(o))
        }
        figList = retargeted
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
