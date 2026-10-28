import Foundation

/// Port of bench/final_aggregate.py: `<dir>/<engine>/pass*/` raw files -> summary.md + results.json.
public enum Aggregate {
    public static let order = ["strim", "rapid-mlx", "mlx-lm", "tensorfold", "omlx", "mlx-vlm", "llama.cpp", "ollama", "tensorfold-ctx64k"]
    /// supplemental launch: shown, never a winner
    public static let supplemental: Set<String> = ["tensorfold-ctx64k"]
    public static let figKey: [String: String] = [
        "strim": "strim", "rapid-mlx": "rapid-mlx", "mlx-lm": "mlx-lm", "tensorfold": "tensorfold", "omlx": "omlx",
        "mlx-vlm": "mlx-vlm", "llama.cpp": "llamacpp", "ollama": "ollama",
    ]

    struct Cell {
        var label: String, workload: String, variant: String, metric: String, higherIsBetter: Bool, dp: Int
    }

    static let cells: [Cell] = [
        Cell(label: "W1 greedy-64 decode tok/s", workload: "W1", variant: "greedy-64", metric: "decode_tps", higherIsBetter: true, dp: 1),
        Cell(label: "W1 greedy-64 TTFT s", workload: "W1", variant: "greedy-64", metric: "ttft_s", higherIsBetter: false, dp: 3),
        Cell(label: "W1 greedy-256 decode tok/s", workload: "W1", variant: "greedy-256", metric: "decode_tps", higherIsBetter: true, dp: 1),
        Cell(label: "W2 temp0.6-256 decode tok/s", workload: "W2", variant: "temp0.6-256", metric: "decode_tps", higherIsBetter: true, dp: 1),
        Cell(label: "W3 4K cold decode tok/s", workload: "W3", variant: "ctx-4096", metric: "decode_tps", higherIsBetter: true, dp: 1),
        Cell(label: "W3 4K cold TTFT s", workload: "W3", variant: "ctx-4096", metric: "ttft_s", higherIsBetter: false, dp: 2),
        Cell(label: "W3 16K cold decode tok/s", workload: "W3", variant: "ctx-16384", metric: "decode_tps", higherIsBetter: true, dp: 1),
        Cell(label: "W3 16K cold TTFT s", workload: "W3", variant: "ctx-16384", metric: "ttft_s", higherIsBetter: false, dp: 1),
        Cell(label: "W3 32K cold decode tok/s", workload: "W3", variant: "ctx-32768", metric: "decode_tps", higherIsBetter: true, dp: 1),
        Cell(label: "W3 32K cold TTFT s", workload: "W3", variant: "ctx-32768", metric: "ttft_s", higherIsBetter: false, dp: 1),
        Cell(label: "W4 c2 aggregate tok/s", workload: "W4", variant: "distinct-c2", metric: "aggregate_tps", higherIsBetter: true, dp: 1),
        Cell(label: "W4 c2 per-request decode tok/s", workload: "W4", variant: "distinct-c2", metric: "decode_tps", higherIsBetter: true, dp: 1),
        Cell(label: "W4 c4 aggregate tok/s", workload: "W4", variant: "distinct-c4", metric: "aggregate_tps", higherIsBetter: true, dp: 1),
        Cell(label: "W4 c4 per-request decode tok/s", workload: "W4", variant: "distinct-c4", metric: "decode_tps", higherIsBetter: true, dp: 1),
        Cell(label: "W4 c4 TTFT s", workload: "W4", variant: "distinct-c4", metric: "ttft_s", higherIsBetter: false, dp: 1),
        Cell(label: "W5 4x16K shared aggregate tok/s", workload: "W5", variant: "shared16384-c4", metric: "aggregate_tps", higherIsBetter: true, dp: 2),
        Cell(label: "W5 4x16K shared TTFT s", workload: "W5", variant: "shared16384-c4", metric: "ttft_s", higherIsBetter: false, dp: 1),
    ]

    struct CellValue {
        var value: Double?
        var n: Int
        var cv: Double?
        var values: [Double]
    }
    struct CacheAgg { var rows = 0, hitRows = 0, cachedTokens = 0, unknown = 0 }

    struct ReplayStats {
        var prefillSum6: Double?
        var reps6: Int
        var repsComplete: Int
        var repsTotal: Int
        var prefillSum: Double?
        var prefillSums: [Double]
        var t1: Double?
        var t8: Double?
        var cachedFracT8: Double?
        var decodeTps: Double?
        var shortRows: Int
        var rows: Int
    }

    struct SampledStats {
        var nOK: Int
        var nRows: Int
        var medianOK: Double?
        var medianAny: Double?
        var flags: [String]
    }

    struct Engine {
        var passes: [JSONValue] = []
        var cells: [String: CellValue] = [:]
        var replay: [JSONValue] = []
        var sampled: [JSONValue] = []
        var rss: [Int] = []
        var loads: [JSONValue] = []
        var flags = OrderedDict<String?, Int>()
        var cache = OrderedDict<String, CacheAgg>()
        var errors = 0
        var requests = 0
        var replayStats: ReplayStats!
        var sampledStats: SampledStats!
    }

    struct PassRep: Hashable { var pass: String; var rep: Int }
    struct CellKey: Hashable { var wl: String; var variant: String; var metric: String }

    static func listDir(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted { pyLess($0, $1) }
    }

    static func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    static func loadEngine(_ dir: String) -> Engine {
        var E = Engine()
        let passes = listDir(dir).filter { $0.hasPrefix("pass") && isDir(dir + "/" + $0) }
        var percell = OrderedDict<CellKey, OrderedDict<PassRep, Double?>>()
        for pn in passes {
            let p = dir + "/" + pn
            let meta: JSONValue = (try? JSON.parse(Data(contentsOf: URL(fileURLWithPath: p + "/meta.json")))) ?? .null
            var pm = JSONObject()
            pm["pass"] = .string(pn)
            for k in ["status", "ready_s", "warmup_s", "model_id", "cmd", "env", "git_head", "cache", "quant"] { pm[k] = meta[k] }
            E.passes.append(.object(pm))
            let rows = JSON.lines(p + "/scoreboard/raw.jsonl")
            let reqs = rows.filter { $0["kind"].string == "request" }
            for r in rows where r["kind"].string == "rep" {
                if r["peak_rss_kb"].truthy, let v = r["peak_rss_kb"].int { E.rss.append(v) }
                E.loads.append(r["loadavg"])
            }
            E.requests += reqs.count
            E.errors += reqs.filter { $0["error"].truthy }.count
            for r in reqs {
                let f = r["tokens_flag"].string
                E.flags[f] = (E.flags[f] ?? 0) + 1
                let wl = r["workload"].string ?? ""
                var c = E.cache[wl] ?? CacheAgg()
                c.rows += 1
                if let ct = r["cached_tokens"].int {
                    if ct > 0 { c.hitRows += 1; c.cachedTokens += ct }
                } else {
                    c.unknown += 1
                }
                E.cache[wl] = c
            }
            for cell in cells {
                var vals = OrderedDict<PassRep, Double?>()
                if cell.metric == "aggregate_tps" {
                    for b in rows where b["kind"].string == "batch" && b["workload"].string == cell.workload && b["variant"].string == cell.variant {
                        vals[PassRep(pass: pn, rep: b["rep"].int ?? 0)] = .some(b["aggregate_tps"].double)
                    }
                } else {
                    var g = OrderedDict<Int, [Double?]>()
                    for r in reqs where r["workload"].string == cell.workload && r["variant"].string == cell.variant && !r["error"].truthy {
                        let rep = r["rep"].int ?? 0
                        var l = g[rep] ?? []
                        l.append(r[cell.metric].double)
                        g[rep] = l
                    }
                    for (rep, l) in g.items { vals[PassRep(pass: pn, rep: rep)] = .some(Stats.med(l)) }
                }
                let key = CellKey(wl: cell.workload, variant: cell.variant, metric: cell.metric)
                var cur = percell[key] ?? OrderedDict()
                for (k, v) in vals.items { cur[k] = v }
                percell[key] = cur
            }
            for r in JSON.lines(p + "/replay/raw.jsonl") where r["kind"].string == "request" {
                guard case .object(let o) = r else { continue }
                var n = JSONObject()
                n["pass"] = .string(pn)
                for m in o.members { n[m.key] = m.value }
                E.replay.append(.object(n))
            }
            E.sampled.append(contentsOf: JSON.lines(p + "/sampled.jsonl"))
        }
        for cell in cells {
            let key = CellKey(wl: cell.workload, variant: cell.variant, metric: cell.metric)
            let v = (percell[key]?.values ?? []).compactMap { $0 ?? nil }
            var cv: Double?
            if v.count > 1, let m = Stats.mean(v), m != 0 { cv = Stats.pstdev(v)! / m * 100 }
            E.cells[cell.label] = CellValue(value: Stats.median(v), n: v.count, cv: cv, values: v)
        }
        return E
    }

    static func replayStats(_ E: Engine) -> ReplayStats {
        var by = OrderedDict<PassRep, OrderedDict<Int, JSONValue>>()
        for r in E.replay {
            let k = PassRep(pass: r["pass"].string ?? "", rep: r["rep"].int ?? 0)
            var t = by[k] ?? OrderedDict()
            t[r["turn"].int ?? 0] = r
            by[k] = t
        }
        var sums: [Double] = [], sums6: [Double] = [], t1: [Double] = [], t8: [Double] = [], frac8: [Double] = [], dec: [Double] = []
        var short = 0
        for turns in by.values {
            func ok(_ t: JSONValue) -> Bool { !t["error"].truthy && t["ttft_s"].double != nil }
            if (1 ... 6).allSatisfy({ i in turns[i].map(ok) ?? false }) {
                sums6.append(pySum((1 ... 6).map { turns[$0]!["ttft_s"].double! }))
            }
            if turns.count == 8 && turns.values.allSatisfy(ok) {
                sums.append(pySum(turns.values.map { $0["ttft_s"].double! }))
                if let a = turns[1]?["ttft_s"].double { t1.append(a) }
                if let b = turns[8]?["ttft_s"].double { t8.append(b) }
                if let f = turns[8]?["cache_frac"].double { frac8.append(f) }
            }
            for t in turns.values {
                if t["tokens_flag"].string == "short" { short += 1 }
                else if t["decode_tps"].truthy, let d = t["decode_tps"].double { dec.append(d) }
            }
        }
        return ReplayStats(prefillSum6: Stats.median(sums6), reps6: sums6.count, repsComplete: sums.count, repsTotal: by.count,
                           prefillSum: Stats.median(sums), prefillSums: sums, t1: Stats.median(t1), t8: Stats.median(t8),
                           cachedFracT8: Stats.median(frac8), decodeTps: Stats.median(dec), shortRows: short, rows: E.replay.count)
    }

    static func sampledStats(_ E: Engine) -> SampledStats {
        let ok = E.sampled.filter { $0["decode_tps"].truthy && $0["tokens_flag"].string == "ok" }.compactMap { $0["decode_tps"].double }
        let allv = E.sampled.filter { $0["decode_tps"].truthy }.compactMap { $0["decode_tps"].double }
        let flags = Array(Set(E.sampled.map { $0["tokens_flag"].string ?? "None" })).sorted { pyLess($0, $1) }
        return SampledStats(nOK: ok.count, nRows: E.sampled.count, medianOK: Stats.median(ok), medianAny: Stats.median(allv), flags: flags)
    }

    typealias Winner = (label: String, engine: String, value: Double, runnerUp: (String, Double)?, dp: Int)

    /// Writes `<outDir>/summary.md` and `<outDir>/results.json` from `<dir>` (notes.json read from `dir`).
    /// `pathLabel` is the value recorded as `meta.path` (the directory as the Python tool was given it).
    @discardableResult
    public static func run(dir: String, outDir: String? = nil, pathLabel: String? = nil,
                           generatedBy: String = "strim bench http aggregate") throws -> (summary: String, results: String) {
        let out = outDir ?? dir
        let label = pathLabel ?? dir
        guard case .object(let notes) = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: dir + "/notes.json"))) else {
            throw BenchError("\(dir)/notes.json: want an object")
        }
        let notesV = JSONValue.object(notes)
        var R: [String: Engine] = [:]
        for e in order {
            let d = dir + "/" + e.replacingOccurrences(of: "/", with: "_")
            guard isDir(d) else { continue }
            let hasScoreboard = listDir(d).contains { $0.hasPrefix("pass") && FileManager.default.fileExists(atPath: d + "/" + $0 + "/scoreboard/raw.jsonl") }
            if hasScoreboard {
                var E = loadEngine(d)
                E.replayStats = replayStats(E)
                E.sampledStats = sampledStats(E)
                R[e] = E
            }
        }
        let run = order.filter { R[$0] != nil }
        var L: [String] = []
        L.append("# Final all-engine HTTP benchmark: Qwen3.8-27B (2026-10-26/27)\n")
        L.append((notesV["intro"].string ?? "") + "\n")
        L.append("## Scoreboard (median over reps; `(n)` = reps contributing; `n/a` = no valid row)\n")
        L.append("| metric | " + run.joined(separator: " | ") + " |")
        L.append("|---|" + String(repeating: "---|", count: run.count))
        var winners: [Winner] = []
        for c in cells {
            let cs = run.map { R[$0]!.cells[c.label]! }
            var vals: [(String, Double)] = []
            for (e, cv) in zip(run, cs) where cv.value != nil && !supplemental.contains(e) { vals.append((e, cv.value!)) }
            let best: Double? = vals.isEmpty ? nil : (c.higherIsBetter ? vals.map(\.1).max() : vals.map(\.1).min())
            var row: [String] = []
            for (e, cv) in zip(run, cs) {
                var s = cv.value != nil ? "\(fmtOpt(cv.value, c.dp)) (\(cv.n))" : "n/a"
                if let v = cv.value, v == best, !supplemental.contains(e) { s = "**\(s)**" }
                row.append(s)
            }
            L.append("| \(c.label) | " + row.joined(separator: " | ") + " |")
            if !vals.isEmpty {
                let o = stableSorted(vals, key: { $0.1 }, reverse: c.higherIsBetter)
                winners.append((c.label, o[0].0, o[0].1, o.count > 1 ? (o[1].0, o[1].1) : nil, c.dp))
            }
        }
        L.append("\n## Agent replay (synthetic 8 turns, prompts 4.1K to 40.8K, 48 tokens/turn, cache default on)\n")
        L.append("| engine | prefill sum T1-T8 s (sum of per-turn TTFT) | prefill sum T1-T6 s | TTFT T1 s | TTFT T8 s | cached frac T8 | complete reps (8 turns / 6 turns) of total | rows short (ignore_eos not honored) |")
        L.append("|---|---|---|---|---|---|---|---|")
        for e in run {
            let s = R[e]!.replayStats!
            let cf = s.cachedFracT8.map { String(format: "%.1f", $0 * 100) + "%" } ?? "n/a"
            L.append("| \(e) | \(fmtOpt(s.prefillSum, 1)) | \(fmtOpt(s.prefillSum6, 1)) | \(fmtOpt(s.t1, 2)) | \(fmtOpt(s.t8, 1)) | \(cf) | \(s.repsComplete) / \(s.reps6) of \(s.repsTotal) | \(s.shortRows)/\(s.rows) |")
        }
        let pv = run.compactMap { e -> (String, Double)? in
            guard let v = R[e]!.replayStats.prefillSum, !supplemental.contains(e) else { return nil }
            return (e, v)
        }
        let pv6 = run.compactMap { e -> (String, Double)? in
            guard let v = R[e]!.replayStats.prefillSum6, !supplemental.contains(e) else { return nil }
            return (e, v)
        }
        for (lab, list) in [("Replay prefill sum s", pv), ("Replay prefill sum T1-T6 s", pv6)] where !list.isEmpty {
            let o = stableSorted(list, key: { $0.1 }, reverse: false)
            winners.append((lab, o[0].0, o[0].1, o.count > 1 ? (o[1].0, o[1].1) : nil, 1))
        }
        L.append("\n## Sampled decode (temp 1.0, top_p 0.95, top_k 20, seed 1234, 256 tokens)\n")
        L.append("| engine | decode tok/s median (ok rows) | ok rows / rows | flags |")
        L.append("|---|---|---|---|")
        for e in run {
            let s = R[e]!.sampledStats!
            L.append("| \(e) | \(fmtOpt(s.medianOK, 1)) | \(s.nOK)/\(s.nRows) | \(s.flags.joined(separator: ", ")) |")
        }
        let sv = run.compactMap { e -> (String, Double)? in
            guard let v = R[e]!.sampledStats.medianOK, !supplemental.contains(e) else { return nil }
            return (e, v)
        }
        if !sv.isEmpty {
            let o = stableSorted(sv, key: { $0.1 }, reverse: true)
            winners.append(("Sampled decode tok/s", o[0].0, o[0].1, o.count > 1 ? (o[1].0, o[1].1) : nil, 1))
        }
        L.append("\n## Per-metric winners\n")
        L.append("| metric | winner | value | runner-up |")
        L.append("|---|---|---|---|")
        for w in winners {
            let ru = w.runnerUp.map { "\($0.0) \(fmtOpt($0.1, w.dp))" } ?? "-"
            L.append("| \(w.label) | \(w.engine) | \(fmtOpt(w.value, w.dp)) | \(ru) |")
        }
        L.append("\n## Load, memory, cache logging\n")
        L.append("| engine | passes | server ready s | warm-up s (incl. lazy load) | peak RSS GB (server tree) | loadavg at rep start (1m, first..last) | requests / errors | token flags | cache hit rows by workload (hit rows / rows; cached tokens) |")
        L.append("|---|---|---|---|---|---|---|---|---|")
        for e in run {
            let E = R[e]!
            let ready = E.passes.map { fmtOpt($0["ready_s"].double, 0) }.joined(separator: ", ")
            let wu = E.passes.map { fmtOpt($0["warmup_s"].double, 0) }.joined(separator: ", ")
            let rss = E.rss.isEmpty ? "n/a" : String(format: "%.1f", Double(E.rss.max()!) / 1e6)
            var la: [Double] = []
            for x in E.loads {
                guard x.truthy, let s = x.string else { continue }
                let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
                if let first = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, let v = Double(first) { la.append(v) }
            }
            let lad = la.isEmpty ? "n/a" : String(format: "%.1f..%.1f (max %.1f)", la.first!, la.last!, la.max()!)
            var fl = JSONObject()
            for (k, v) in E.flags.items { fl[k ?? "null"] = .int(v) }
            let ch = E.cache.items.sorted { pyLess($0.0, $1.0) }.map { w, c in
                "\(w): \(c.hitRows)/\(c.rows) (\(c.cachedTokens))" + (c.unknown != 0 ? " unk \(c.unknown)" : "")
            }.joined(separator: "; ")
            L.append("| \(e) | \(E.passes.count) | \(ready) | \(wu) | \(rss) | \(lad) | \(E.requests) / \(E.errors) | \(JSON.dumps(.object(fl))) | \(ch) |")
        }
        L.append("\n## Engines: versions, quant, exact launch\n")
        L.append("| engine | version / commit | weights | cache setting | launch (cwd = repo root) |")
        L.append("|---|---|---|---|---|")
        for e in run {
            let p = R[e]!.passes[0]
            let envs = (p["env"].object?.members ?? []).map { "\($0.key)=\(pyStr($0.value))" }.joined(separator: " ")
            let cmd = (p["cmd"].array ?? []).map { pyStr($0) }.joined(separator: " ")
            let launch = (envs + " " + cmd).trimmingCharacters(in: .whitespaces)
            L.append("| \(e) | \(notesV["versions"][e].string ?? "unknown") | \(pyStr(p["quant"])) | \(pyStr(p["cache"])) | `\(launch)` |")
        }
        L.append("\n## Skipped / not comparable\n")
        for m in notesV["skipped"].object?.members ?? [] { L.append("- \(m.key): \(pyStr(m.value))") }
        L.append("\n## Caveats\n")
        for c in notesV["caveats"].array ?? [] { L.append("- \(pyStr(c))") }
        L.append("\n## Run order\n")
        L.append((notesV["order"].string ?? "") + "\n")
        let summary = L.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try summary.write(toFile: out + "/summary.md", atomically: false, encoding: .utf8)

        // results.json: site figure shape + full data
        var figs: [JSONValue] = []
        let figDefs: [(String, String, String, String, Int)] = [
            ("w1_decode", "W1 greedy-64 decode tok/s", "tok/s", "greedy decode, 64 tokens", 1),
            ("w3_4k_ttft", "W3 4K cold TTFT s", "s", "4K cold TTFT", 2),
            ("s3_agg", "W4 c4 aggregate tok/s", "tok/s", "aggregate, 4 concurrent distinct 4K cold prompts (W4 c4)", 1),
        ]
        func fig(_ key: String, _ eng: String, _ v: Double?, _ dp: Int, _ unit: String, _ desc: String, _ n: Int) -> JSONValue {
            let val: JSONValue = v.map { .double(Double(String(format: "%.\(dp)f", $0))!) } ?? .null
            let fc = notesV["fig_caveat"][eng].isNull ? notesV["fig_caveat"]["default"] : notesV["fig_caveat"][eng]
            return .obj([
                "id": .string("final.\(key).\(figKey[eng]!)"), "value": val, "unit": .string(unit),
                "source_path": "bench/results/final-20261026/summary.md",
                "method_note": .string("Final all-engine benchmark: \(eng), \(desc). HTTP, each engine served alone, Qwen3.8-27B, thinking off, medians over reps."),
                "caveat": fc, "n": .string(String(n)), "dataset": "final",
            ])
        }
        for e in run where figKey[e] != nil {
            for (key, lab, unit, desc, dp) in figDefs {
                let c = R[e]!.cells[lab]!
                figs.append(fig(key, e, c.value, dp, unit, desc, c.n))
            }
            let s = R[e]!.replayStats!
            figs.append(fig("replay_prefill", e, s.prefillSum, 1, "s", "agent replay (synthetic 8 turns), summed per-turn TTFT", s.repsComplete))
        }
        var engines = JSONObject()
        for e in run {
            let E = R[e]!
            var cellsO = JSONObject()
            for c in cells {
                let cv = E.cells[c.label]!
                cellsO[c.label] = .obj(["value": JSONValue(cv.value), "n": .int(cv.n), "cv_pct": JSONValue(cv.cv),
                                        "values": .array(cv.values.map { .double($0) })])
            }
            let rs = E.replayStats!
            let ss = E.sampledStats!
            var flagsO = JSONObject()
            for (k, v) in E.flags.items { flagsO[k ?? "null"] = .int(v) }
            var cacheO = JSONObject()
            for (k, c) in E.cache.items {
                cacheO[k] = .obj(["rows": .int(c.rows), "hit_rows": .int(c.hitRows), "cached_tokens": .int(c.cachedTokens), "unknown": .int(c.unknown)])
            }
            engines[e] = .obj([
                "passes": .array(E.passes), "cells": .object(cellsO),
                "replay_stats": .obj([
                    "prefill_sum6_s": JSONValue(rs.prefillSum6), "reps6": .int(rs.reps6), "reps_complete": .int(rs.repsComplete),
                    "reps_total": .int(rs.repsTotal), "prefill_sum_s": JSONValue(rs.prefillSum),
                    "prefill_sums": .array(rs.prefillSums.map { .double($0) }), "ttft_t1_s": JSONValue(rs.t1),
                    "ttft_t8_s": JSONValue(rs.t8), "cached_frac_t8": JSONValue(rs.cachedFracT8), "decode_tps": JSONValue(rs.decodeTps),
                    "short_rows": .int(rs.shortRows), "rows": .int(rs.rows),
                ]),
                "sampled_stats": .obj([
                    "n_ok": .int(ss.nOK), "n_rows": .int(ss.nRows), "median_ok": JSONValue(ss.medianOK),
                    "median_any": JSONValue(ss.medianAny), "flags": .array(ss.flags.map { .string($0) }),
                ]),
                "flags": .object(flagsO), "cache": .object(cacheO), "requests": .int(E.requests), "errors": .int(E.errors),
                "rss": .array(E.rss.map { .int($0) }), "loads": .array(E.loads),
            ])
        }
        let result: JSONValue = .obj([
            "meta": .obj(["title": "Final all-engine benchmark", "model": "Qwen3.8-27B", "path": .string(label),
                          "generated_by": .string(generatedBy)]),
            "datasets": .array([.obj(["id": "final", "label": "Final all-engine benchmark", "path": .string(label), "needs": "summary.md"])]),
            "figures": .array(figs), "skipped": notesV["skipped"], "engines": .object(engines),
        ])
        let resultText = JSON.dumps(result, indent: 1)
        try resultText.write(toFile: out + "/results.json", atomically: false, encoding: .utf8)
        return (summary, resultText)
    }
}
