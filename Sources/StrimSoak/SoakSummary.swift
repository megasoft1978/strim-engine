import Foundation

/// Python-compatible number handling. The summary is read by the site generator (`StrimSite/Soak.swift`), so the
/// text must match the harness's historical output: `round(x, 1)` on the exact binary value, `repr` of floats,
/// and ints printed without `.0`.
public enum PyNum: Equatable, Sendable {
    case int(Int)
    case float(Double)

    public var text: String {
        switch self {
        case .int(let i): return String(i)
        case .float(let d): return pyFloat(d)
        }
    }
}

/// Python `repr(float)`: shortest round-trip, always with a fraction or exponent (8687.0, 1e+16).
public func pyFloat(_ d: Double) -> String { "\(d)" }

/// Python `round(x, n)` for n >= 0: nearest double to the correctly rounded decimal.
public func pyRound(_ x: Double, _ n: Int) -> Double {
    Double(String(format: "%.\(n)f", x)) ?? x
}

/// Python `statistics.median` over floats, then `round(., 1)`.
public func pyMedian(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    let n = s.count
    let m = n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    return pyRound(m, 1)
}

/// `round(statistics.median(ints), 1)`: an odd count keeps the int, an even count is a float (Python true division).
public func pyMedian(_ xs: [Int]) -> PyNum? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    let n = s.count
    if n % 2 == 1 { return .int(s[n / 2]) }
    return .float(pyRound(Double(s[n / 2 - 1] + s[n / 2]) / 2, 1))
}

/// Least-squares slope of y over x, in units per hour, rounded to 0.1. nil with fewer than 5 points or no x spread.
public func soakSlopePerHour(_ pts: [(Double, Double)]) -> Double? {
    guard pts.count >= 5 else { return nil }
    let n = Double(pts.count)
    let mx = pts.reduce(0) { $0 + $1.0 } / n
    let my = pts.reduce(0) { $0 + $1.1 } / n
    let den = pts.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
    if den == 0 { return nil }
    let num = pts.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
    return pyRound(num / den * 3600, 1)
}

/// Renders summary.txt. Inputs are the parsed run.json, tasks.jsonl and server.jsonl rows, and the raw server.log.
/// Row keys are read by name; numbers that the harness wrote as floats are read through `dbl` so `.0` is kept.
public enum SoakSummary {
    static let logKeys = ["error", "unhealthy", "insufficient_memory"]
    static let logNeedles = ["error", "unhealthy", "insufficient memory"]
    static let errorEvents: Set<String> = ["http_5xx", "unhealthy", "crash", "restart_failed"]

    public static func render(name: String, cfg: [String: Any], tasks: [[String: Any]],
                              events: [[String: Any]], serverLog: String) -> String {
        var L: [String] = []
        func w(_ s: String) { L.append(s) }
        let duration = dbl(cfg, "duration") ?? 30
        let clients = (cfg["clients"] as? String) ?? "both"
        w("strim soak summary  \(name)")
        w("usage: strim soak --duration \(pyFloat(duration)) --arms \(clients) --task-timeout \(int(cfg, "task_timeout") ?? 240)"
          + " --concurrent-every \(int(cfg, "concurrent_every") ?? 6) --poll \(pyFloat(dbl(cfg, "poll") ?? 15))")
        let elapsed = dbl(cfg, "elapsed_min").map { pyFloat($0) } ?? "?"
        w("started \((cfg["started"] as? String) ?? "unknown")  elapsed \(elapsed) min")
        w("")

        let passed = tasks.filter { bool($0, "pass") }.count
        let total = tasks.count
        let pct = total > 0 ? pyFloat(pyRound(100 * Double(passed) / Double(total), 1)) : "0"
        w("Tasks: \(total) total, \(passed) passed (\(pct)%)")
        for c in ["claude", "codex"] {
            let ct = tasks.filter { str($0, "client") == c }
            if !ct.isEmpty {
                let p = ct.filter { bool($0, "pass") }.count
                w("  \(c): \(p)/\(ct.count) passed (\(pyFloat(pyRound(100 * Double(p) / Double(ct.count), 1)))%)")
            }
        }
        for ph in ["seq", "conc"] {
            let pt = tasks.filter { str($0, "phase") == ph }
            if !pt.isEmpty {
                w("  phase \(ph): \(pt.filter { bool($0, "pass") }.count)/\(pt.count) passed")
            }
        }
        w("  timeouts: \(tasks.filter { bool($0, "timed_out") }.count)")
        if let longest = longestTask(tasks) {
            w("  longest task: \(str(longest, "client") ?? "") \(str(longest, "task") ?? "") "
              + "\(pyFloat(dbl(longest, "wall_s") ?? 0))s (seq \(int(longest, "seq") ?? 0))")
        }
        w("")

        w("Server:")
        let crashes = events.filter { str($0, "event") == "crash" }.count
        let restarts = events.filter { str($0, "event") == "restart" }.count
        let restartFailed = events.filter { str($0, "event") == "restart_failed" }.count
        w("  crashes: \(crashes)  restarts: \(restarts)  restart_failures: \(restartFailed)")
        let samples = events.filter { str($0, "event") == "sample" }
        let pids = Set(samples.compactMap { int($0, "pid") })
        w("  pids seen: \(pids.count)  polls: \(samples.count)")
        let fiveXX = events.filter { str($0, "event") == "http_5xx" }.count
        let unhealthy = events.filter { str($0, "event") == "unhealthy" }.count
        w("  http 5xx events: \(fiveXX)  unhealthy samples: \(unhealthy)")
        var hits = [Int](repeating: 0, count: logKeys.count)
        for e in events where str(e, "event") == "log_hit" {
            if let i = logKeys.firstIndex(of: str(e, "pattern") ?? "") { hits[i] += 1 }
        }
        let hitText = zip(logKeys, hits).map { "'\($0)': \($1)" }.joined(separator: ", ")
        w("  log hits (first 20/poll kept): {\(hitText)}")
        if let last = samples.last, let rt = int(last, "requests_total") {
            let rf = int(last, "requests_failed").map(String.init) ?? "None"
            w("  server requests_total last: \(rt)  failed: \(rf)")
        }

        let rss: [(Double, Double)] = samples.compactMap { s in
            guard let r = dbl(s, "rss_mb") else { return nil }
            return (dbl(s, "elapsed_s") ?? 0, r)
        }
        if !rss.isEmpty {
            let vals = rss.map { $0.1 }
            let q = max(1, vals.count / 4)
            let slope = soakSlopePerHour(rss).map(pyFloat) ?? "None"
            w("RSS MB: min \(pyFloat(vals.min()!))  max \(pyFloat(vals.max()!))  "
              + "first-quartile median \(pyFloat(pyMedian(Array(vals[..<q]))!))  "
              + "last-quartile median \(pyFloat(pyMedian(Array(vals[(vals.count - q)...]))!))  slope \(slope) MB/h")
        } else {
            w("RSS MB: no samples")
        }

        let ttft = ttftValues(serverLog)
        if !ttft.isEmpty {
            let q = max(1, ttft.count / 4)
            let sorted = ttft.sorted()
            let p90 = sorted[min(sorted.count - 1, Int(0.9 * Double(sorted.count)))]
            w("TTFT ms (n=\(ttft.count)): first-quartile median \(pyMedian(Array(ttft[..<q]))!.text)  "
              + "last-quartile median \(pyMedian(Array(ttft[(ttft.count - q)...]))!.text)  p90 \(p90)")
        } else {
            w("TTFT ms: none (STRIM_SERVER_LOG lines not found)")
        }
        w("")

        let fails = tasks.filter { !bool($0, "pass") }
        w("Failures (\(fails.count)):")
        for t in fails {
            let reason = bool(t, "timed_out") ? "timeout" : "exit \(int(t, "exit_code") ?? 0)"
            w("  - seq \(int(t, "seq") ?? 0) \(str(t, "client") ?? "") \(str(t, "task") ?? "") [\(str(t, "phase") ?? "")]: "
              + "\(reason); \(str(t, "check_detail") ?? "")")
            if let errs = t["client_error_events"] as? [String], !errs.isEmpty {
                w("      client error events: \(pyListRepr(Array(errs.prefix(2))))")
            }
            let trimmed = (str(t, "stderr_tail") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let tailLines = trimmed.isEmpty ? [] : trimmed.components(separatedBy: .newlines)
            for line in tailLines.suffix(2) { w("      stderr: \(String(line.prefix(200)))") }
            if let wd = str(t, "workdir"), !wd.isEmpty { w("      workdir kept: \(wd)") }
        }
        w("")

        let errs = events.filter { errorEvents.contains(str($0, "event") ?? "") }
        w("Server error events (\(errs.count)):")
        for e in errs.prefix(50) {
            let fields = e.keys.filter { !["t", "event", "log_tail"].contains($0) }.sorted()
                .map { "\($0)=\(pyValue(e[$0]))" }
            w("  - \(str(e, "t") ?? "") \(str(e, "event") ?? "") " + fields.joined(separator: ", "))
        }
        w("")
        w("Files: tasks.jsonl server.jsonl server.log summary.txt")
        return L.joined(separator: "\n") + "\n"
    }

    /// Python `max(tasks, key=wall_s)`: the first task with the largest wall time.
    static func longestTask(_ tasks: [[String: Any]]) -> [String: Any]? {
        var best: [String: Any]?
        for t in tasks {
            if best == nil || (dbl(t, "wall_s") ?? 0) > (dbl(best!, "wall_s") ?? 0) { best = t }
        }
        return best
    }

    static func ttftValues(_ log: String) -> [Int] {
        guard let rx = try? NSRegularExpression(pattern: "ttft=(\\d+)ms") else { return [] }
        var out: [Int] = []
        for line in log.components(separatedBy: .newlines) {
            let ns = line as NSString
            if let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let v = Int(ns.substring(with: m.range(at: 1))) {
                out.append(v)
            }
        }
        return out
    }

    // Accessors over JSON-decoded rows. Missing or null values read as nil.
    static func dbl(_ r: [String: Any], _ k: String) -> Double? { (r[k] as? NSNumber)?.doubleValue }
    static func int(_ r: [String: Any], _ k: String) -> Int? { (r[k] as? NSNumber).flatMap { $0.isBool ? nil : $0.intValue } }
    static func str(_ r: [String: Any], _ k: String) -> String? { r[k] as? String }
    static func bool(_ r: [String: Any], _ k: String) -> Bool { (r[k] as? NSNumber)?.boolValue ?? false }

    /// Python `str()` of a decoded JSON value: floats keep `.0`, bools print True/False, null prints None.
    static func pyValue(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return "None"
        case let s as String: return s
        case let n as NSNumber:
            if n.isBool { return n.boolValue ? "True" : "False" }
            return n.isFloat ? pyFloat(n.doubleValue) : n.stringValue
        case let a as [Any]: return "[" + a.map { pyReprValue($0) }.joined(separator: ", ") + "]"
        default: return String(describing: v!)
        }
    }

    static func pyReprValue(_ v: Any) -> String {
        if let s = v as? String { return pyStrRepr(s) }
        return pyValue(v)
    }

    static func pyListRepr(_ xs: [String]) -> String {
        "[" + xs.map(pyStrRepr).joined(separator: ", ") + "]"
    }

    /// Python `repr(str)`: single quotes unless the text has a single quote and no double quote.
    static func pyStrRepr(_ s: String) -> String {
        let q: Character = (s.contains("'") && !s.contains("\"")) ? "\"" : "'"
        var out = String(q)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case q: out += "\\\(q)"
            default: out.append(ch)
            }
        }
        return out + String(q)
    }
}

extension NSNumber {
    /// JSON true/false decode to a CFBoolean-backed NSNumber.
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
    /// JSON numbers with a fraction or exponent decode as doubles; integers as int types.
    var isFloat: Bool { let t = String(cString: objCType); return t == "d" || t == "f" }
}
