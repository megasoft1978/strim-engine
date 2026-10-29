import Foundation

/// Regime classes of the scoreboard and the hero chart. `cells` are final-block cell ids (one verdict each, no cell counted twice).
struct Regime {
    let id: String
    let label: String
    let metric: String
    let cells: [String]
}

let REGIMES: [Regime] = [
    Regime(id: "decode", label: "Decode", metric: "tok/s at 4K, 16K, 32K context", cells: ["d4k", "d16k", "d32k"]),
    Regime(id: "prefill", label: "Cold prefill", metric: "tok/s on a cold 4K, 16K, 32K prompt", cells: ["c4k_pf", "c16k_pf", "c32k_pf"]),
    Regime(id: "shared", label: "Shared prefix", metric: "4 agents on a 16K prefix (aggregate, p50, p95) and 8-turn replay", cells: ["aw5", "p50_w5", "p95_w5", "rp8"]),
    Regime(id: "concurrency", label: "Concurrency", metric: "aggregate tok/s at c=4 and c=8, three prompt sizes", cells: ["a512c4", "a512c8", "aagc4", "aagc8", "a4kc4", "a4kc8"]),
    Regime(id: "latency", label: "Latency", metric: "TTFT p50 and p95 at c=4 and c=8, three prompt sizes", cells: ["p50_512c4", "p95_512c4", "p50_512c8", "p95_512c8", "p50_agc4", "p95_agc4", "p50_agc8", "p95_agc8", "p50_4kc4", "p95_4kc4", "p50_4kc8", "p95_4kc8"]),
]

/// Short chart labels per cell id.
let SHORT: [String: String] = [
    "d4k": "decode @ 4K", "d16k": "decode @ 16K", "d32k": "decode @ 32K",
    "c4k_pf": "cold prefill 4K", "c16k_pf": "cold prefill 16K", "c32k_pf": "cold prefill 32K",
    "aw5": "4 agents, 16K prefix: tok/s", "p50_w5": "4 agents: p50 TTFT", "p95_w5": "4 agents: p95 TTFT", "rp8": "8-turn replay prefill",
    "a512c4": "c=4 512-tok: tok/s", "a512c8": "c=8 512-tok: tok/s", "aagc4": "c=4 agent: tok/s", "aagc8": "c=8 agent: tok/s", "a4kc4": "c=4 4K: tok/s", "a4kc8": "c=8 4K: tok/s",
    "p50_512c4": "c=4 512-tok: p50 TTFT", "p95_512c4": "c=4 512-tok: p95 TTFT", "p50_512c8": "c=8 512-tok: p50 TTFT", "p95_512c8": "c=8 512-tok: p95 TTFT",
    "p50_agc4": "c=4 agent: p50 TTFT", "p95_agc4": "c=4 agent: p95 TTFT", "p50_agc8": "c=8 agent: p50 TTFT", "p95_agc8": "c=8 agent: p95 TTFT",
    "p50_4kc4": "c=4 4K: p50 TTFT", "p95_4kc4": "c=4 4K: p95 TTFT", "p50_4kc8": "c=8 4K: p50 TTFT", "p95_4kc8": "c=8 4K: p95 TTFT",
]

/// Rows of the hero chart, in order, per regime id.
let HERO_ROWS: [(regime: String, cells: [String])] = [
    ("decode", ["d4k", "d16k", "d32k"]),
    ("prefill", ["c4k_pf", "c16k_pf", "c32k_pf"]),
    ("shared", ["aw5", "p50_w5", "p95_w5", "rp8"]),
    ("concurrency", ["a512c4", "a512c8", "aagc4", "aagc8", "a4kc4", "a4kc8"]),
    ("latency", ["p50_512c4", "p95_512c4", "p50_512c8", "p95_512c8"]),
]

/// Memory cells of summary.md "Peak memory per cell": id -> label.
let MEM_LABEL: [String: String] = [
    "warmup": "warmup", "agree": "greedy agreement", "w3": "cold 4K and 16K", "w3_32k": "cold 32K", "w4": "c=4/8, 4K prompts",
    "w4s": "c=4/8, 512-token prompts", "w6": "c=4/8, agent prompts", "w5": "4 agents, 16K shared prefix", "replay": "8-turn replay",
]

func jobj(_ items: [(String, PyJSON)]) -> PyJSON {
    var o = JObject()
    for (k, v) in items { o[k] = v }
    return .object(o)
}

func jround(_ v: Double, _ dp: Int) -> PyJSON { .double(pyRound(v, dp)) }

func verdictOfRatio(_ r: Double, lowerBetter: Bool, band: Double = 0.02) -> String {
    let adv = lowerBetter ? 1 / r : r   // advantage of Strim, > 1 is better
    if adv > 1 + band { return "WIN" }
    if adv < 1 - band { return "LOSS" }
    return "TIE"
}

extension SiteBuilder {
    var headlinePath: String { root + "/site/data/headline.json" }
    var featuresPath: String { root + "/site/data/features.json" }

    /// Build site/data/headline.json from the already synchronised final.* figures and summary.md (per-cell memory).
    func buildHeadline() throws -> PyJSON {
        let cells = finalCells()
        guard !cells.isEmpty else { throw SiteError("headline: no final head-to-head cells (is \(FINAL_REL) present?)") }
        func figNum(_ id: String) throws -> Double {
            guard let v = D.figs[id]?.value.number else { throw SiteError("headline: missing figure \(id)") }
            return v
        }
        var cellJSON: [PyJSON] = []
        var verdicts: [String: [String: String]] = [:]
        for c in cells {
            let regime = REGIMES.first(where: { $0.cells.contains(c.id) })?.id ?? (c.id.hasSuffix("_tt") ? "prefill_ttft" : "other")
            var values = JObject(), speed = JObject(), verdict = JObject(), claim = JObject()
            for e in ENGINES { if let v = D.figs[fid(c.id, e)]?.value.number { values[e] = .double(v) } }
            let s = values["strim"]?.number
            for rv in RIVALS {
                if let s, let r = values[rv]?.number, s > 0, r > 0 {
                    speed[rv] = jround(c.better == "lower" ? r / s : s / r, 3)
                }
                if let v = D.figs[fverdict(c.id, rv)]?.value.str { verdict[rv] = .string(v); verdicts[c.id, default: [:]][rv] = v }
                if let why = D.raw["final"]?["not_claimable"]?[c.id]?[rv]?.str { claim[rv] = .string(why) }
            }
            cellJSON.append(jobj([
                ("id", .string(c.id)), ("regime", .string(regime)), ("label", .string(c.label)), ("short", .string(SHORT[c.id] ?? c.label)),
                ("unit", .string(c.unit)), ("better", .string(c.better)),
                ("values", .object(values)), ("speedup", .object(speed)), ("verdict", .object(verdict)), ("not_claimable", .object(claim)),
                ("source", .string("\(FINAL_SRC) section Results, row \(c.label)")),
            ]))
        }
        // scoreboard: verdict counts per regime and rival
        func tally(_ ids: [String], _ rv: String) -> PyJSON {
            var w = 0, t = 0, l = 0, nc = 0
            for id in ids {
                switch verdicts[id]?[rv] ?? "" {
                case "WIN": w += 1
                case "TIE": t += 1
                case "LOSS": l += 1
                case "NC": nc += 1
                default: break
                }
            }
            return jobj([("WIN", .int(w)), ("TIE", .int(t)), ("LOSS", .int(l)), ("NC", .int(nc))])
        }
        // memory: whole run from the figures, per-cell from summary.md
        guard let text = readText(finalDir + "/summary.md") else { throw SiteError("headline: cannot read \(FINAL_SRC)") }
        let (mh, mb) = try mdTable(try mdSec(mdSections(text), "Peak memory"))
        var whole = JObject()
        for e in ENGINES { whole[e] = .double(try figNum("final.mem.\(e)")) }
        var memVerdict = JObject()
        for rv in RIVALS {
            let r = (whole["strim"]?.number ?? 0) / (whole[rv]?.number ?? 1)
            memVerdict[rv] = .string(verdictOfRatio(r, lowerBetter: true))
        }
        var memCells: [PyJSON] = []
        var lowest = 0, counted = 0
        for row in mb {
            guard let name = row.first, name != "**whole run**" else { continue }
            var vals = JObject()
            for e in ENGINES {
                guard let ci = mh.firstIndex(of: "\(e) footprint / RSS"), ci < row.count else { throw SiteError("headline: no memory column for \(e)") }
                if row[ci].hasPrefix("n/a") { continue }   // the engine never ran this cell (or its footprint was unreadable)
                guard let mbText = row[ci].split(separator: " ").first, let mbv = Double(mbText) else { throw SiteError("headline: cannot parse memory cell for \(name)/\(e)") }
                vals[e] = jround(mbv / 1000, 1)
            }
            counted += 1
            if let sv = vals["strim"]?.number, RIVALS.allSatisfy({ vals[$0]?.number.map { sv < $0 } ?? true }) { lowest += 1 }
            memCells.append(jobj([("id", .string(name)), ("label", .string(MEM_LABEL[name] ?? name)), ("values", .object(vals))]))
        }
        let abort: PyJSON = firstMatch(#"(\d+) GB (?:abort )?limit"#, in: text).flatMap { Int($0[1]) }.map { PyJSON.int($0) } ?? .null
        let memory = jobj([
            ("unit", .string("GB")), ("source", .string("\(FINAL_SRC) section Peak memory per cell (phys_footprint of the engine process tree, max over passes and sessions)")),
            ("abort_limit_gb", abort), ("whole_run", .object(whole)), ("whole_run_verdict", .object(memVerdict)),
            ("strim_lowest_cells", .int(lowest)), ("cells_total", .int(counted)), ("cells", .array(memCells)),
        ])
        var regimeJSON: [PyJSON] = []
        var tot: [String: [String: Int]] = Dictionary(uniqueKeysWithValues: RIVALS.map { ($0, ["WIN": 0, "TIE": 0, "LOSS": 0, "NC": 0]) })
        func addTotals(_ rv: String, _ t: PyJSON) {
            for k in ["WIN", "TIE", "LOSS", "NC"] { tot[rv]![k]! += Int(t[k]?.number ?? 0) }
        }
        for r in REGIMES {
            var vs = JObject()
            for rv in RIVALS { let t = tally(r.cells, rv); vs[rv] = t; addTotals(rv, t) }
            regimeJSON.append(jobj([("id", .string(r.id)), ("label", .string(r.label)), ("metric", .string(r.metric)), ("cells", .array(r.cells.map { .string($0) })), ("vs", .object(vs))]))
        }
        var memVs = JObject()
        for rv in RIVALS {
            let t = verdictTally(memVerdict[rv]?.str ?? "")
            memVs[rv] = t; addTotals(rv, t)
        }
        regimeJSON.append(jobj([("id", .string("memory")), ("label", .string("Memory")), ("metric", .string("peak footprint over the whole run")), ("cells", .array([.string("whole_run")])), ("vs", .object(memVs))]))
        var totalJSON = JObject()
        for rv in RIVALS { totalJSON[rv] = jobj([("WIN", .int(tot[rv]!["WIN"]!)), ("TIE", .int(tot[rv]!["TIE"]!)), ("LOSS", .int(tot[rv]!["LOSS"]!)), ("NC", .int(tot[rv]!["NC"]!))]) }
        let vmeta = D.raw["final"]?["validity"]
        func optNum(_ id: String) -> PyJSON { D.figs[id]?.value ?? .null }
        let validity = jobj([
            ("clean", vmeta?["clean"] ?? .bool(false)), ("sessions", optNum("final.val.sessions")), ("polluted", optNum("final.val.polluted")),
            ("load_max", optNum("final.val.load_max")), ("swap_growth_max_mb", optNum("final.claim.swap")),
            ("text", .string(validityText { D.text($0) })),
        ])
        let run = jobj([
            ("id", vmeta?["run"] ?? .string(FINAL_REL)), ("date", vmeta?["date"] ?? .string("")), ("source", .string(FINAL_SRC)), ("raw_dir", .string(FINAL_REL)),
            ("machine", .string(D.meta["machine"]?.pyStr ?? "")), ("model", .string("Qwen3.8-27B 4-bit + MTP head")),
            ("strim_build", .string(D.text("final.claim.build"))), ("versions", jobj(RIVALS.map { ($0, PyJSON.string(D.figs["ver.h2h.\($0)"] != nil ? D.text("ver.h2h.\($0)") : "")) })),
            ("passes", .int(Int(try figNum("final.claim.passes")))), ("reps_per_pass", .int(1)), ("tie_band_pct", .int(2)),
            ("validity", validity),
        ])
        let engines = jobj(ENGINES.map { e in (e, jobj([("label", .string(engLabel(e))), ("name", .string(WIDE_NAMES[e] ?? e)), ("mtp", .string(engineMeta[e]?["mtp"] ?? "")), ("prefix_cache", .string(engineMeta[e]?["prefix_cache"] ?? "")), ("flags", .string(engineMeta[e]?["flags"] ?? ""))])) })
        let hero = jobj([("rows", .array(HERO_ROWS.map { jobj([("regime", .string($0.regime)), ("cells", .array($0.cells.map { .string($0) }))]) }))])
        return jobj([
            ("schema", .string("strim-headline/1")),
            ("comment", .string("Generated by `strim site build` from the final head-to-head summary; every number the charts and scoreboards show is here. Do not hand-edit. Schema: site/data/headline.schema.md.")),
            ("run", run), ("engines", engines), ("hero", hero), ("cells", .array(cellJSON)), ("memory", memory),
            ("scoreboard", jobj([("regimes", .array(regimeJSON)), ("total", .object(totalJSON))])),
        ])
    }

    func verdictTally(_ v: String) -> PyJSON {
        jobj([("WIN", .int(v == "WIN" ? 1 : 0)), ("TIE", .int(v == "TIE" ? 1 : 0)), ("LOSS", .int(v == "LOSS" ? 1 : 0))])
    }

    /// site/data/features.json, validated.
    func loadFeatures() throws -> PyJSON {
        guard let text = readText(featuresPath) else { throw SiteError("cannot read site/data/features.json") }
        let f = try PyJSONParser.parse(text)
        let ok: Set<String> = ["yes", "partial", "no", "notfound", "unknown", "info"]
        guard let rows = f["rows"]?.arr, !rows.isEmpty else { throw SiteError("features.json: no rows") }
        for r in rows {
            let id = r["id"]?.pyStr ?? "?"
            for e in FEATURE_ENGINES {
                guard let s = r[e]?["s"]?.str, ok.contains(s) else { throw SiteError("features.json: row \(id) engine \(e): bad status") }
            }
            guard let src = r["source"]?.str, fileExists(root + "/" + src) else { throw SiteError("features.json: row \(id): source file missing") }
        }
        return f
    }
}
