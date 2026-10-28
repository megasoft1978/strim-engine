import Foundation

extension SiteBuilder {
    func finalState() -> String {
        fileExists(finalDir + "/summary.md") && fileExists(finalDir + "/results.json") ? "present" : "missing"
    }

    /// Soak run dirs (root-relative): bench/results/soak-*/<run>/ (each needs run.json and summary.txt).
    func soakRuns() -> [(dir: String, run: PyJSON)] {
        func listing(_ rel: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: root + "/" + rel)) ?? []).sorted { Array($0.unicodeScalars.map { $0.value }).lexicographicallyPrecedes(Array($1.unicodeScalars.map { $0.value })) }
        }
        var dirs: [String] = []
        for top in listing("bench/results") where top.hasPrefix("soak-") && isDirectory(root + "/bench/results/" + top) {
            let t = "bench/results/" + top
            dirs += listing(t).map { t + "/" + $0 }.filter { isDirectory(root + "/" + $0) }
        }
        var out: [(String, PyJSON)] = []
        for d in dirs {
            let rj = root + "/" + d + "/run.json", sm = root + "/" + d + "/summary.txt"
            guard fileExists(rj), fileExists(sm) else { continue }
            guard let t = readText(rj), let r = try? PyJSONParser.parse(t) else { continue }
            out.append((d, r))
        }
        return out
    }

    /// Latest complete >=30 min run (root-relative dir), or nil. A run in progress has run.json without elapsed_min;
    /// aborted runs and runs whose directory name contains "invalid" are ignored.
    func soakComplete() -> String? {
        var best: String?
        for (d, r) in soakRuns() {
            guard let o = r.obj else { continue }
            let elapsed = o["elapsed_min"] ?? .null
            if !elapsed.isNull, !(o["aborted"]?.truthy ?? false), !(d as NSString).lastPathComponent.contains("invalid") {
                var dur = 0.0
                switch o["duration"] {
                case .some(let v) where v.number != nil: dur = v.number!
                case .some(.string(let s)): dur = Double(pyStrip(s)) ?? 0
                default: dur = 0
                }
                if dur >= 30 { best = d }
            }
        }
        return best
    }

    func refreshSoak() throws {
        guard let d = soakComplete() else {
            log("no complete 30-minute soak run found; soak.* figures stay pending")
            return
        }
        let t = readText(root + "/" + d + "/summary.txt") ?? ""
        let src = d + "/summary.txt"
        func g(_ pat: Pat, int: Bool) throws -> PyJSON {
            guard let m = pat.search(t) else { return .null }
            if int {
                guard let v = Int(m) else { throw SiteError("ValueError: invalid int \(pyReprString(m))") }
                return .int(v)
            }
            guard let v = Double(m) else { throw SiteError("ValueError: could not convert string to float: \(pyReprString(m))") }
            return .double(v)
        }
        typealias T = Pat.Tok
        let cap = T.cap(true), endc = T.cap(false)
        let vals: [(String, PyJSON)] = [
            ("tasks_total", try g(Pat([.lit("Tasks: "), cap, .digits, endc, .lit(" total")]), int: true)),
            ("tasks_passed", try g(Pat([.lit("Tasks: "), .digits, .lit(" total, "), cap, .digits, endc, .lit(" passed")]), int: true)),
            ("pass_claude", try g(Pat([.lit("claude: "), .digits, .lit("/"), .digits, .lit(" passed ("), cap, .numDot, endc, .lit("%)")]), int: false)),
            ("pass_codex", try g(Pat([.lit("codex: "), .digits, .lit("/"), .digits, .lit(" passed ("), cap, .numDot, endc, .lit("%)")]), int: false)),
            ("claude_passed", try g(Pat([.lit("claude: "), cap, .digits, endc, .lit("/"), .digits, .lit(" passed")]), int: true)),
            ("claude_tasks", try g(Pat([.lit("claude: "), .digits, .lit("/"), cap, .digits, endc, .lit(" passed")]), int: true)),
            ("codex_passed", try g(Pat([.lit("codex: "), cap, .digits, endc, .lit("/"), .digits, .lit(" passed")]), int: true)),
            ("codex_tasks", try g(Pat([.lit("codex: "), .digits, .lit("/"), cap, .digits, endc, .lit(" passed")]), int: true)),
            ("elapsed_min", try g(Pat([.lit("elapsed "), cap, .numDot, endc, .lit(" min")]), int: false)),
            ("rss_min", try g(Pat([.lit("RSS MB: min "), cap, .numDot, endc]), int: false)),
            ("rss_max", try g(Pat([.lit("RSS MB: min "), .numDot, .ws, .lit("max "), cap, .numDot, endc]), int: false)),
            ("failures", try g(Pat([.lit("Failures ("), cap, .digits, endc, .lit("):")]), int: true)),
            ("crashes", try g(Pat([.lit("crashes: "), cap, .digits, endc]), int: true)),
            ("restarts", try g(Pat([.lit("restarts: "), cap, .digits, endc]), int: true)),
            ("http5xx", try g(Pat([.lit("http 5xx events: "), cap, .digits, endc]), int: true)),
            ("requests_total", try g(Pat([.lit("requests_total last: "), cap, .digits, endc]), int: true)),
            ("requests_failed", try g(Pat([.lit("requests_total last: "), .digits, .ws, .lit("failed: "), cap, .digits, endc]), int: true)),
            ("rss_slope", try g(Pat([.lit("slope "), cap, .optMinus, .numDot, endc, .lit(" MB/h")]), int: false)),
            ("ttft_q1", try g(Pat([.lit("TTFT ms ("), .lit("n="), .digits, .lit("): first-quartile median "), cap, .numDot, endc]), int: false)),
            ("ttft_q4", try g(Pat([.lit("TTFT ms"), .notNL, .lit("last-quartile median "), cap, .numDot, endc]), int: false)),
            ("ttft_p90", try g(Pat([.lit("p90 "), cap, .numDot, endc]), int: false)),
        ]
        guard let text = SafeIO.readRegular(root: root, path: dataPath, allowSymlinks: allowSymlinkedTree), var raw = (try PyJSONParser.parse(text)).obj else { throw SiteError("cannot read results.json") }
        var figs = raw["figures"]?.arr ?? []
        for idx in figs.indices {
            guard var f = figs[idx].obj, let id = f["id"]?.str else { continue }
            guard id.hasPrefix("soak."), let entry = vals.first(where: { $0.0 == String(id.dropFirst(5)) }), f["dataset"]?.str == "soak" else { continue }
            let k = entry.0
            var v = entry.1
            if case .double(let dv) = v, dv == dv.rounded(.towardZero), k != "pass_claude", k != "pass_codex", k != "rss_slope", k != "rss_min", k != "rss_max" {
                v = .int(Int(dv))
            }
            f["value"] = v
            f["source_path"] = .string(src)
            f["caveat"] = .string("Single complete run of at least 30 minutes. " + ((k.hasPrefix("tasks") || k.hasPrefix("pass") || k.hasSuffix("passed")) ? "Pass = deterministic check + client exit 0 within the cap; failures are listed in the summary file." : ""))
            f["verify"] = v.isNull ? .null : .string(v.pyStr)
            figs[idx] = .object(f)
        }
        raw["figures"] = .array(figs)
        try write(dataPath, PyJSONWriter.dumps(.object(raw)) + "\n")
        log("soak figures refreshed from \(src)")
    }

    func write(_ path: String, _ s: String) throws {
        try SafeIO.write(root: root, path: path, s, allowSymlinks: allowSymlinkedTree)
    }
}
