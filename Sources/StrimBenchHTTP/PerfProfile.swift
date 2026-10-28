import Foundation

// `strim bench http profile`: measurement-only prefill/decode profile pack (opus.md section 9, items 2-3).
// It drives the existing in-process subcommands (`benchprefill`, `benchspec`) as subprocesses with
// ablation env flags, plus optional cold requests against a served endpoint. No engine behaviour changes.
// Parsing, aggregation, planning and rendering are pure so they are unit-tested without a GPU.

// MARK: - Statistics

public struct PerfStat: Sendable, Equatable {
    public var n: Int
    public var mean: Double
    public var median: Double
    public var stdev: Double
    /// Coefficient of variation in percent (sample stdev / mean).
    public var cv: Double

    public static func of(_ v: [Double]) -> PerfStat? {
        guard let mean = Stats.mean(v), let med = Stats.median(v) else { return nil }
        let sd = Stats.stdev(v) ?? 0
        return PerfStat(n: v.count, mean: mean, median: med, stdev: sd, cv: mean != 0 ? sd / abs(mean) * 100 : 0)
    }
}

// MARK: - Output parsers

public struct PrefillSample: Sendable, Equatable { public var n: Int; public var chunk: Int; public var seconds: Double; public var tokPerSec: Double; public var rep: Int }
public struct SpecRepSample: Sendable, Equatable {
    public var passes: Int; public var emitted: Int; public var tokPerPass: Double; public var tokPerSec: Double
    public var decodeTokPerSec: Double; public var accept: Double; public var msPerPass: Double; public var seconds: Double
}
public struct TimingSample: Sendable, Equatable {
    public var draftMs: Double; public var verifyMs: Double; public var reseedMs: Double
    public var rounds: Int; public var depthAvg: Double; public var syncsPerRound: Double
}

public enum PerfParse {
    /// `n=4096 chunk=1024 4.12 s  994 tok/s  (rep 0)` (main.swift benchprefill).
    public static func prefillLine(_ line: String) -> PrefillSample? {
        let t = line.split(whereSeparator: { $0 == " " }).map(String.init)
        guard t.count >= 8, t[0].hasPrefix("n="), t[1].hasPrefix("chunk="),
              let n = Int(t[0].dropFirst(2)), let c = Int(t[1].dropFirst(6)),
              let s = Double(t[2]), t[3] == "s", let r = Double(t[4]), t[5] == "tok/s",
              t[6] == "(rep", let rep = Int(t[7].dropLast()) else { return nil }
        return PrefillSample(n: n, chunk: c, seconds: s, tokPerSec: r, rep: rep)
    }

    /// `rep 1 spec: passes 40  emitted 128  3.20 tok/pass  50.1 tok/s  55.3 decode  accept 80% (96/120)  18.5 ms/pass  2.55s`
    /// (SpecStats.summary).
    public static func specRepLine(_ line: String) -> SpecRepSample? {
        guard let r = line.range(of: " spec: ") else { return nil }
        let t = line[r.upperBound...].split(separator: " ").map(String.init)
        // passes P emitted E X tok/pass Y tok/s Z decode accept A% (a/b) W ms/pass S s
        guard t.count >= 16, t[0] == "passes", t[2] == "emitted", t[5] == "tok/pass", t[7] == "tok/s", t[9] == "decode",
              t[10] == "accept", t[14] == "ms/pass",
              let passes = Int(t[1]), let emitted = Int(t[3]), let tpp = Double(t[4]), let tps = Double(t[6]),
              let dec = Double(t[8]), let acc = Double(t[11].dropLast()), let mpp = Double(t[13]),
              t[15].hasSuffix("s"), let secs = Double(t[15].dropLast()) else { return nil }
        return SpecRepSample(passes: passes, emitted: emitted, tokPerPass: tpp, tokPerSec: tps, decodeTokPerSec: dec,
                             accept: acc, msPerPass: mpp, seconds: secs)
    }

    /// `ms/pass: mtp_draft 3.1, verify 14.2, reseed 0.4, rounds 40, depth avg 2.50, syncs/round 1.00` (STRIM_TIMING).
    public static func timingLine(_ line: String) -> TimingSample? {
        guard line.hasPrefix("ms/pass:") else { return nil }
        func num(_ key: String) -> Double? {
            guard let r = line.range(of: key + " ") else { return nil }
            let rest = line[r.upperBound...]
            let tok = rest.prefix { "0123456789.-".contains($0) }
            return Double(tok)
        }
        guard let d = num("mtp_draft"), let v = num("verify"), let rs = num("reseed"), let rounds = num("rounds"),
              let da = num("depth avg"), let sy = num("syncs/round") else { return nil }
        return TimingSample(draftMs: d, verifyMs: v, reseedMs: rs, rounds: Int(rounds), depthAvg: da, syncsPerRound: sy)
    }
}

// MARK: - Result model

public struct PerfRow: Sendable, Equatable {
    public var section: String
    public var label: String
    /// true: not a valid engine output (env ablation); never compare as a product number.
    public var ablation: Bool
    public var length: Int
    public var chunk: Int?
    public var env: [String: String]
    public var metric: String
    public var unit: String
    public var samples: [Double]
    public var note: String = ""
    public var stat: PerfStat? { PerfStat.of(samples) }
}

public struct PerfDerived: Sendable, Equatable {
    public var name: String
    public var length: Int
    public var value: Double?
    public var unit: String
    public var note: String
}

public struct PerfMachine: Sendable, Equatable {
    public var model = "", cpu = "", memGB = 0.0, os = "", load1 = 0.0, load5 = 0.0, load15 = 0.0, gitSHA = "", gitDirty = false
    public var hostname = "", date = "", thermal = ""

    public static func capture(repoRoot: String) -> PerfMachine {
        var m = PerfMachine()
        func sysctlString(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
            return String(cString: buf)
        }
        m.model = sysctlString("hw.model")
        m.cpu = sysctlString("machdep.cpu.brand_string")
        var mem: UInt64 = 0; var sz = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &mem, &sz, nil, 0) == 0 { m.memGB = Double(mem) / 1_073_741_824 }
        m.os = ProcessInfo.processInfo.operatingSystemVersionString
        var l = [Double](repeating: 0, count: 3)
        if getloadavg(&l, 3) == 3 { m.load1 = l[0]; m.load5 = l[1]; m.load15 = l[2] }
        m.hostname = ProcessInfo.processInfo.hostName
        m.thermal = "\(ProcessInfo.processInfo.thermalState)"
        m.date = ISO8601DateFormatter().string(from: Date())
        if let o = try? PerfShell.runSync("/usr/bin/git", ["-C", repoRoot, "rev-parse", "--short", "HEAD"]) { m.gitSHA = o.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let o = try? PerfShell.runSync("/usr/bin/git", ["-C", repoRoot, "status", "--porcelain", "--untracked-files=no"]) { m.gitDirty = !o.isEmpty }
        return m
    }
}

public struct PerfReport: Sendable {
    public var machine: PerfMachine
    public var config: [String: String]
    public var rows: [PerfRow]
    public var derived: [PerfDerived]
    public var skipped: [String]
}

// MARK: - Derived metrics (pure)

public enum PerfAnalysis {
    static func seconds(_ row: PerfRow) -> Double? { // per-run seconds for a prefill tok/s row
        row.stat.map { Double(row.length) / $0.median }
    }

    /// Share of prefill time removed by an ablation: (T_ref - T_abl) / T_ref, medians of tok/s converted to time.
    public static func ablationShare(ref: PerfRow, abl: PerfRow) -> Double? {
        guard let a = seconds(ref), let b = seconds(abl), a > 0 else { return nil }
        return (a - b) / a * 100
    }

    /// Percent change of `b` over `a` (medians), positive = b faster.
    public static func gain(base: PerfRow, other: PerfRow) -> Double? {
        guard let a = base.stat?.median, let b = other.stat?.median, a > 0 else { return nil }
        return (b / a - 1) * 100
    }

    public static func derive(_ rows: [PerfRow]) -> [PerfDerived] {
        var out: [PerfDerived] = []
        func find(_ section: String, _ label: String, _ len: Int, chunk: Int? = nil, metric: String? = nil) -> PerfRow? {
            rows.first { $0.section == section && $0.label == label && $0.length == len && (chunk == nil || $0.chunk == chunk)
                && (metric == nil || $0.metric == metric) }
        }
        let lengths = Array(Set(rows.map { $0.length })).sorted()
        for len in lengths {
            // P3: chunk sweep vs 1024.
            if let base = find("prefill-chunk", "chunk", len, chunk: 1024) {
                for c in [512, 2048, 4096] {
                    if let r = find("prefill-chunk", "chunk", len, chunk: c), let g = gain(base: base, other: r) {
                        out.append(PerfDerived(name: "chunk \(c) vs 1024", length: len, value: g, unit: "% tok/s", note: "valid outputs"))
                    }
                }
            }
            // P5: GDN recurrence share, two paths. Skip-rec rows are ablations.
            let blocked = find("gdn-ablation", "default", len), skipB = find("gdn-ablation", "skip_rec", len)
            if let r = blocked, let a = skipB, let s = ablationShare(ref: r, abl: a) {
                out.append(PerfDerived(name: "GDN recurrence share, blocked kernel path (STRIM_SKIP_REC)", length: len, value: s, unit: "% of prefill time",
                                       note: "ablation; STRIM_SKIP_REC is only read on the tensor path, so ~0 here means the flag is a no-op on the blocked path"))
            }
            let tensor = find("gdn-ablation", "tensor", len), skipT = find("gdn-ablation", "tensor_skip_rec", len)
            if let r = tensor, let a = skipT, let s = ablationShare(ref: r, abl: a) {
                out.append(PerfDerived(name: "GDN recurrence share, tensor path (MAX_S=8 + SKIP_REC)", length: len, value: s, unit: "% of tensor-path prefill time",
                                       note: "ablation; tensor recurrence is ~2.7x slower than the blocked kernel, so this overstates the default-path share"))
            }
            if let r = blocked, let t = tensor, let g = gain(base: t, other: r) {
                out.append(PerfDerived(name: "blocked kernel vs tensor recurrence", length: len, value: g, unit: "% tok/s", note: "valid outputs (STRIM_GDN_METAL_MAX_S=8 is a supported A/B)"))
            }
            // MTP head cost over the full prompt: e2e seconds depth2 - depth0 at n=2 tokens.
            if let d0 = find("mtp-head", "depth0", len), let d2 = find("mtp-head", "depth2", len),
               let a = d0.stat?.median, let b = d2.stat?.median {
                out.append(PerfDerived(name: "MTP head prompt seed cost (depth2 - depth0, e2e)", length: len, value: (b - a) * 1000, unit: "ms",
                                       note: "includes ~1 extra draft+verify round; share of prefill: \(String(format: "%.1f%%", a > 0 ? (b - a) / a * 100 : 0))"))
            }
        }
        // D2: decode slowdown long vs short.
        let dec = rows.filter { $0.section == "decode" && $0.metric == "decode tok/s" }.sorted { $0.length < $1.length }
        if let s = dec.first, let l = dec.last, s.length != l.length, let a = s.stat?.median, let b = l.stat?.median, a > 0 {
            out.append(PerfDerived(name: "decode tok/s slowdown \(l.length) vs \(s.length)", length: l.length, value: (1 - b / a) * 100, unit: "%", note: "in-process, STRIM_TIMING=1 spec decode"))
            for metric in ["ms/pass", "verify ms", "draft ms", "reseed ms"] {
                if let x = rows.first(where: { $0.section == "decode" && $0.metric == metric && $0.length == s.length })?.stat?.median,
                   let y = rows.first(where: { $0.section == "decode" && $0.metric == metric && $0.length == l.length })?.stat?.median {
                    out.append(PerfDerived(name: "\(metric) delta \(l.length) - \(s.length)", length: l.length, value: y - x, unit: "ms", note: ""))
                }
            }
        }
        return out
    }

    /// Kill criteria from opus.md: chunk 4096 < +2% vs 1024; GDN share < 6%. Returns human lines.
    public static func killCriteria(_ derived: [PerfDerived]) -> [String] {
        var lines: [String] = []
        let ch = derived.filter { $0.name == "chunk 4096 vs 1024" }
        if ch.isEmpty { lines.append("P3 (chunk 4096 >= +2% vs 1024): NOT MEASURED") }
        for d in ch {
            let v = d.value ?? 0
            lines.append(String(format: "P3 at %d tok: chunk 4096 vs 1024 = %+.1f%% -> %@", d.length, v, v < 2 ? "KILL (below +2%)" : "kept"))
        }
        let sh = derived.filter { $0.name.hasPrefix("GDN recurrence share, blocked") }
        if sh.isEmpty { lines.append("P5 (GDN share >= 6%): NOT MEASURED") }
        for d in sh {
            let v = d.value ?? 0
            lines.append(String(format: "P5 at %d tok (blocked path, STRIM_SKIP_REC): %.1f%% -> %@", d.length, v,
                                abs(v) < 1 ? "INCONCLUSIVE (flag is a no-op on blocked path; needs engine hook)" : (v < 6 ? "KILL (below 6%)" : "kept")))
        }
        for d in derived.filter({ $0.name.hasPrefix("GDN recurrence share, tensor") }) {
            lines.append(String(format: "P5 at %d tok (tensor path upper bound): %.1f%% of tensor-path time", d.length, d.value ?? 0))
        }
        return lines
    }
}

// MARK: - Rendering

public enum PerfRender {
    static func f(_ x: Double?, _ dp: Int = 1) -> String { x.map { String(format: "%.\(dp)f", $0) } ?? "-" }

    public static func json(_ r: PerfReport) -> String {
        var m = JSONObject()
        let mm = r.machine
        m["model"] = .string(mm.model); m["cpu"] = .string(mm.cpu); m["mem_gb"] = .double(mm.memGB); m["os"] = .string(mm.os)
        m["load_avg"] = .array([.double(mm.load1), .double(mm.load5), .double(mm.load15)])
        m["git_sha"] = .string(mm.gitSHA); m["git_dirty"] = .bool(mm.gitDirty); m["hostname"] = .string(mm.hostname)
        m["date"] = .string(mm.date); m["thermal"] = .string(mm.thermal)
        var cfg = JSONObject()
        for (k, v) in r.config.sorted(by: { $0.key < $1.key }) { cfg[k] = .string(v) }
        let rows: [JSONValue] = r.rows.map { row in
            var o = JSONObject()
            o["section"] = .string(row.section); o["label"] = .string(row.label); o["ablation"] = .bool(row.ablation)
            o["valid_output"] = .bool(!row.ablation)
            o["length"] = .int(row.length); o["chunk"] = JSONValue(row.chunk)
            var env = JSONObject(); for (k, v) in row.env.sorted(by: { $0.key < $1.key }) { env[k] = .string(v) }
            o["env"] = .object(env)
            o["metric"] = .string(row.metric); o["unit"] = .string(row.unit)
            o["samples"] = .array(row.samples.map { .double($0) })
            if let s = row.stat {
                o["n"] = .int(s.n); o["mean"] = .double(s.mean); o["median"] = .double(s.median)
                o["stdev"] = .double(s.stdev); o["cv_pct"] = .double(s.cv)
            }
            o["note"] = .string(row.note)
            return .object(o)
        }
        let der: [JSONValue] = r.derived.map {
            .obj(["name": .string($0.name), "length": .int($0.length), "value": JSONValue($0.value), "unit": .string($0.unit), "note": .string($0.note)])
        }
        let top: JSONValue = .obj(["machine": .object(m), "config": .object(cfg), "rows": .array(rows), "derived": .array(der),
                                   "kill_criteria": .array(PerfAnalysis.killCriteria(r.derived).map { .string($0) }),
                                   "skipped": .array(r.skipped.map { .string($0) })])
        return JSON.dumps(top, indent: 2) + "\n"
    }

    public static func markdown(_ r: PerfReport) -> String {
        var s = "# Perf profile \(r.machine.date.prefix(10))\n\n"
        let m = r.machine
        s += "Machine: \(m.cpu) (\(m.model)), \(String(format: "%.0f", m.memGB)) GB, \(m.os), load avg \(f(m.load1, 2)) / \(f(m.load5, 2)) / \(f(m.load15, 2)), thermal \(m.thermal), "
        s += "git \(m.gitSHA)\(m.gitDirty ? " (dirty)" : ""). Reps per cell: \(r.config["reps"] ?? "?") (first in-process rep discarded as warm-up). CV = sample stdev / mean.\n\n"
        s += "Rows marked **ABLATION** disable real work through env flags: their outputs are not valid and their numbers must never be quoted as product speed.\n\n"
        for (section, title) in [("prefill-chunk", "Prefill tok/s by chunk size (in-process `benchprefill`, valid outputs)"),
                                 ("gdn-ablation", "GDN recurrence ablation (in-process, chunk 1024)"),
                                 ("mtp-head", "MTP head prompt-seed cost (in-process `benchspec`, n=2)"),
                                 ("decode", "Decode with STRIM_TIMING=1 (in-process `benchspec`, depth 2)"),
                                 ("served", "Served path (cold requests, chunk fixed at PrefixPrefill.chunk)")] {
            let sel = r.rows.filter { $0.section == section }
            guard !sel.isEmpty else { continue }
            s += "## \(title)\n\n| tokens | variant | chunk | metric | n | median | mean | CV% | unit | note |\n|---:|---|---:|---|---:|---:|---:|---:|---|---|\n"
            for row in sel {
                let st = row.stat
                s += "| \(row.length) | \(row.label)\(row.ablation ? " **ABLATION**" : "") | \(row.chunk.map(String.init) ?? "-") | \(row.metric) | \(st?.n ?? 0) | \(f(st?.median, 2)) | \(f(st?.mean, 2)) | \(f(st?.cv, 1)) | \(row.unit) | \(row.note) |\n"
            }
            s += "\n"
        }
        if !r.derived.isEmpty {
            s += "## Derived\n\n| tokens | metric | value | unit | note |\n|---:|---|---:|---|---|\n"
            for d in r.derived { s += "| \(d.length) | \(d.name) | \(f(d.value, 2)) | \(d.unit) | \(d.note) |\n" }
            s += "\n"
        }
        s += "## Kill criteria\n\n" + PerfAnalysis.killCriteria(r.derived).map { "- \($0)" }.joined(separator: "\n") + "\n"
        if !r.skipped.isEmpty { s += "\n## Not measured\n\n" + r.skipped.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return s
    }
}

// MARK: - Process plumbing

public struct PerfProcOutput: Sendable { public var stdout: String; public var stderr: String; public var status: Int32
    public init(stdout: String, stderr: String, status: Int32) { self.stdout = stdout; self.stderr = stderr; self.status = status } }
public typealias PerfRunner = @Sendable (_ exe: String, _ args: [String], _ env: [String: String]) async throws -> PerfProcOutput

/// Per-child memory watchdog: polls the child's phys_footprint (`footprint -p`, includes Metal) and system swap.
/// Aborts the child when footprint > 40 GB or swap grew > 2 GB over its value at start (or is > 12 GB absolute).
public final class PerfWatchdog: @unchecked Sendable {
    public let pid: Int32
    public var peakMB = 0
    public var abortReason: String?
    static let maxFootprintMB = 40 * 1024, maxSwapGrowthMB = 2 * 1024, maxSwapMB = 12 * 1024
    private let baseSwap: Int
    public init(pid: Int32) { self.pid = pid; baseSwap = Self.swapUsedMB() }
    static func swapUsedMB() -> Int {
        let out = (try? PerfShell.runSync("/usr/sbin/sysctl", ["-n", "vm.swapusage"])) ?? ""
        guard let r = out.range(of: "used = ") else { return 0 }
        return Int(Double(out[r.upperBound...].prefix { $0.isNumber || $0 == "." }) ?? 0)
    }
    func footprintMB() -> Int {
        let out = (try? PerfShell.runSync("/usr/bin/footprint", ["-p", String(pid)])) ?? ""
        guard let r = out.range(of: "Footprint: ") else { return 0 }
        let parts = out[r.upperBound...].split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let v = Double(parts[0]) else { return 0 }
        switch parts[1].prefix(2) { case "GB": return Int(v * 1024); case "MB": return Int(v); case "KB": return Int(v / 1024); default: return 0 }
    }
    public func poll() -> String? {
        let f = footprintMB(); peakMB = max(peakMB, f)
        if f > Self.maxFootprintMB { return "footprint \(f) MB > \(Self.maxFootprintMB)" }
        let sw = Self.swapUsedMB()
        if sw - baseSwap > Self.maxSwapGrowthMB || sw > Self.maxSwapMB { return "swap \(sw) MB (start \(baseSwap))" }
        return nil
    }
}

public enum PerfShell {
    public static func runSync(_ exe: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    /// Real runner: child inherits the environment plus `env`; stdout/stderr go to temp files (benchspec can print large arrays).
    public static let real: PerfRunner = { exe, args, env in
        let dir = NSTemporaryDirectory() + "perfprof-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/o", contents: nil); FileManager.default.createFile(atPath: dir + "/e", contents: nil)
        let o = try FileHandle(forWritingTo: URL(fileURLWithPath: dir + "/o")), e = try FileHandle(forWritingTo: URL(fileURLWithPath: dir + "/e"))
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for k in ["STRIM_SKIP_REC", "STRIM_GDN_METAL_MAX_S", "STRIM_TIMING"] { environment[k] = nil }  // never leak ablations from the caller
        for (k, v) in env { environment[k] = v }
        p.environment = environment; p.standardOutput = o; p.standardError = e
        try p.run()
        let wd = PerfWatchdog(pid: p.processIdentifier)
        let watcher = Task.detached { [wd] in
            while !Task.isCancelled {
                if let why = wd.poll() { wd.abortReason = why; kill(wd.pid, SIGTERM); return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        let status: Int32 = await withCheckedContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            if !p.isRunning { cont.resume(returning: p.terminationStatus) }
        }
        watcher.cancel()
        try? o.close(); try? e.close()
        FileHandle.standardError.write(Data("  peak footprint \(wd.peakMB) MB\(wd.abortReason.map { " WATCHDOG ABORT: " + $0 } ?? "")  (\(args.prefix(2).joined(separator: " ")))\n".utf8))
        return PerfProcOutput(stdout: (try? String(contentsOfFile: dir + "/o", encoding: .utf8)) ?? "",
                              stderr: (try? String(contentsOfFile: dir + "/e", encoding: .utf8)) ?? "", status: status)
    }
}

// MARK: - Plan + execution

public struct PerfConfig: Sendable {
    public var strim = ""
    public var modelDir = "models/qwen38-4bit"
    public var headDir = "models/qwen38-mtp-4bit"
    public var lengths = [1024, 4096, 16384, 32768]
    public var chunks = [512, 1024, 2048, 4096]
    public var decodeLengths = [4096, 32768]
    public var ablationChunk = 1024
    public var reps = 3
    public var decodeTokens = 128
    public var sections: Set<String> = ["prefill", "ablate", "head", "decode"]
    public var serveURL: String?
    public var serveModel = "qwen38-4bit"
    public var tokenizerPath = "models/qwen38-4bit/tokenizer.json"
    public var seedFile = "bench/prompt_seed.txt"
    public var outDir = ""
    public var dryRun = false
    public init() {}
}

/// One planned subprocess invocation producing one or more rows.
public struct PerfStep: Sendable, Equatable {
    public var section: String
    public var label: String
    public var ablation: Bool
    public var length: Int
    public var chunk: Int?
    public var args: [String]
    public var env: [String: String]
}

public enum PerfPlan {
    /// Distinct, valid chunks for a prompt length: chunk > length is identical to chunk == length and is skipped.
    public static func chunks(for length: Int, _ all: [Int]) -> [Int] { all.filter { $0 <= length } }

    public static func steps(_ c: PerfConfig, idsArg: (Int) -> String) -> [PerfStep] {
        var out: [PerfStep] = []
        let r1 = String(c.reps + 1)  // +1: first rep is warm-up and discarded
        if c.sections.contains("prefill") {
            for L in c.lengths { for ch in chunks(for: L, c.chunks) {
                out.append(PerfStep(section: "prefill-chunk", label: "chunk", ablation: false, length: L, chunk: ch,
                                    args: ["benchprefill", c.modelDir, String(L), r1, String(ch)], env: [:]))
            } }
        }
        if c.sections.contains("ablate") {
            let variants: [(String, Bool, [String: String])] = [
                ("default", false, [:]),
                ("skip_rec", true, ["STRIM_SKIP_REC": "1"]),
                ("tensor", false, ["STRIM_GDN_METAL_MAX_S": "8"]),
                ("tensor_skip_rec", true, ["STRIM_GDN_METAL_MAX_S": "8", "STRIM_SKIP_REC": "1"]),
            ]
            for L in c.lengths { let ch = min(c.ablationChunk, L); for (name, abl, env) in variants {
                out.append(PerfStep(section: "gdn-ablation", label: name, ablation: abl, length: L, chunk: ch,
                                    args: ["benchprefill", c.modelDir, String(L), r1, String(ch)], env: env))
            } }
        }
        if c.sections.contains("head") {
            for L in c.lengths { for d in [0, 2] {
                out.append(PerfStep(section: "mtp-head", label: "depth\(d)", ablation: false, length: L, chunk: nil,
                                    args: ["benchspec", c.modelDir, c.headDir, "2", String(d), idsArg(L), String(c.reps)], env: [:]))
            } }
        }
        if c.sections.contains("decode") {
            for L in c.decodeLengths {
                out.append(PerfStep(section: "decode", label: "depth2", ablation: false, length: L, chunk: nil,
                                    args: ["benchspec", c.modelDir, c.headDir, String(c.decodeTokens), "2", idsArg(L), String(c.reps)],
                                    env: ["STRIM_TIMING": "1"]))
            }
        }
        return out
    }

    /// Turns one step's captured output into rows. `reps` = requested reps (benchprefill ran reps+1).
    public static func rows(for step: PerfStep, out: PerfProcOutput, reps: Int) -> (rows: [PerfRow], problems: [String]) {
        var problems: [String] = []
        let base = PerfRow(section: step.section, label: step.label, ablation: step.ablation, length: step.length, chunk: step.chunk,
                           env: step.env, metric: "", unit: "", samples: [])
        if out.status != 0 { problems.append("\(step.section)/\(step.label)/\(step.length): exit \(out.status)") }
        func row(_ metric: String, _ unit: String, _ s: [Double], note: String = "") -> PerfRow {
            var r = base; r.metric = metric; r.unit = unit; r.samples = s; r.note = note; return r
        }
        switch step.section {
        case "prefill-chunk", "gdn-ablation":
            let all = out.stdout.split(separator: "\n").compactMap { PerfParse.prefillLine(String($0)) }
            let kept = Array(all.dropFirst())  // drop warm-up rep
            if kept.count < reps { problems.append("\(step.section)/\(step.label)/\(step.length): expected \(reps) reps, got \(kept.count)") }
            let note = step.ablation ? "ABLATION: output invalid" : ""
            return ([row("prefill tok/s", "tok/s", kept.map { $0.tokPerSec }, note: note)], problems)
        case "mtp-head":
            let reps_ = out.stdout.split(separator: "\n").compactMap { PerfParse.specRepLine(String($0)) }
            if reps_.count < reps { problems.append("\(step.section)/\(step.label)/\(step.length): expected \(reps) reps, got \(reps_.count)") }
            let exact = out.stdout.contains("MISMATCH") ? "parity MISMATCH" : ""
            if !exact.isEmpty { problems.append("\(step.section)/\(step.label)/\(step.length): parity MISMATCH") }
            return ([row("e2e seconds (n=2)", "s", reps_.map { $0.seconds }, note: exact)], problems)
        case "decode":
            let sp = out.stdout.split(separator: "\n").compactMap { PerfParse.specRepLine(String($0)) }
            let tm = Array(out.stderr.split(separator: "\n").compactMap { PerfParse.timingLine(String($0)) }.suffix(reps))
            if sp.count < reps { problems.append("decode/\(step.length): expected \(reps) reps, got \(sp.count)") }
            if tm.count < reps { problems.append("decode/\(step.length): expected \(reps) STRIM_TIMING lines, got \(tm.count)") }
            var rs = [row("decode tok/s", "tok/s", sp.map { $0.decodeTokPerSec }),
                      row("ms/pass", "ms", sp.map { $0.msPerPass }),
                      row("tokens/pass", "tok", sp.map { $0.tokPerPass }),
                      row("accept", "%", sp.map { $0.accept })]
            if !tm.isEmpty {
                rs += [row("verify ms", "ms", tm.map { $0.verifyMs }), row("draft ms", "ms", tm.map { $0.draftMs }),
                       row("reseed ms", "ms", tm.map { $0.reseedMs })]
            }
            return (rs, problems)
        default:
            return ([], ["unknown section \(step.section)"])
        }
    }
}

public enum PerfProfile {
    /// Executes the plan (sequentially; GPU work must hold `lockf -k /tmp/strim-bench.lock` around the whole command).
    public static func run(_ c: PerfConfig, ids: (Int) throws -> String, runner: PerfRunner, served: ((PerfConfig) async -> [PerfRow])?,
                           repoRoot: String, log: @Sendable (String) -> Void) async throws -> PerfReport {
        var lazy: [Int: String] = [:]
        var idErr: Error?
        let steps = PerfPlan.steps(c) { L in
            if let s = lazy[L] { return s }
            do { let s = try ids(L); lazy[L] = s; return s } catch { idErr = error; return "" }
        }
        if let idErr { throw idErr }
        var rows: [PerfRow] = [], skipped: [String] = []
        for (i, st) in steps.enumerated() {
            log("[\(i + 1)/\(steps.count)] \(st.section) \(st.label) L=\(st.length)\(st.chunk.map { " chunk=\($0)" } ?? "") env=\(st.env)")
            let out = try await runner(c.strim, st.args, st.env)
            let (r, problems) = PerfPlan.rows(for: st, out: out, reps: c.reps)
            rows += r; skipped += problems.map { "step failed or short: \($0)" }
        }
        if c.serveURL != nil, let served { rows += await served(c) }
        else if c.sections.contains("served") { skipped.append("served path: no --serve-url given") }
        skipped.append("attention vs MLP vs MTP-head shares: no ablation flag exists in the engine (only STRIM_SKIP_REC for the GDN recurrence); needs an engine hook")
        skipped.append("MTP head over last-N prompt tokens: no flag exists; only the full-prompt seed cost (depth2 - depth0) is reported")
        skipped.append("served-path chunk sweep: chunk is the constant PrefixPrefill.chunk=1024 (StrimCore/PrefixCache.swift); served rows are cold TTFT at that chunk only")
        var m = PerfMachine.capture(repoRoot: repoRoot)
        m.date = ISO8601DateFormatter().string(from: Date())
        var cfg: [String: String] = ["reps": String(c.reps), "lengths": c.lengths.map(String.init).joined(separator: ","),
                                     "chunks": c.chunks.map(String.init).joined(separator: ","), "model": c.modelDir, "head": c.headDir,
                                     "decode_tokens": String(c.decodeTokens), "sections": c.sections.sorted().joined(separator: ","),
                                     "prompt": "benchprefill: repeating 8-token pattern; benchspec: repeated bench/prompt_seed.txt tokens"]
        if let u = c.serveURL { cfg["serve_url"] = u }
        let rowsAll = rows
        return PerfReport(machine: m, config: cfg, rows: rowsAll, derived: PerfAnalysis.derive(rowsAll), skipped: skipped)
    }

    /// Served path: per length, `reps` cold salted requests; TTFT-derived prefill tok/s and stream decode tok/s.
    public static func servedRows(_ c: PerfConfig, factory: TokenizerFactory?, log: @Sendable (String) -> Void) async -> [PerfRow] {
        guard let url = c.serveURL else { return [] }
        let seed = (try? String(contentsOfFile: c.seedFile, encoding: .utf8)) ?? "The quick brown fox jumps over the lazy dog. "
        let prompter = Prompter.make(seed: seed, tokenizerPath: c.tokenizerPath, factory: factory)
        let arm = Arm(name: "served", url: url, model: c.serveModel)
        var rows: [PerfRow] = []
        for L in c.lengths {
            var pre: [Double] = [], dec: [Double] = [], ttft: [Double] = []
            for rep in 0 ... c.reps {  // rep 0 = warm-up, discarded
                let text = prompter.text(L, salt: "perf-\(UUID().uuidString)-\(L)-\(rep)")
                let item = Item(item: "perf", prompt: text, maxTokens: c.decodeTokens, temperature: 0, seed: nil, target: L)
                log("served L=\(L) rep \(rep)")
                let r = await Scoreboard.streamRequest(arm: arm, item: item, timeout: 1800, noThink: true)
                guard rep > 0, r.error == nil, let tf = r.tFirst, let te = r.tEnd else { continue }
                let promptTokens = r.usage?["prompt_tokens"].int ?? L
                let completion = r.usage?["completion_tokens"].int ?? 0
                ttft.append(tf - r.tSend)
                pre.append(Double(promptTokens) / (tf - r.tSend))
                if completion > 1, te > tf { dec.append(Double(completion - 1) / (te - tf)) }
            }
            func mk(_ metric: String, _ unit: String, _ s: [Double]) -> PerfRow {
                PerfRow(section: "served", label: "cold", ablation: false, length: L, chunk: 1024, env: [:], metric: metric, unit: unit, samples: s,
                        note: prompter.approx ? "approx token count (no tokenizer)" : "")
            }
            rows += [mk("prefill tok/s (prompt_tokens/TTFT)", "tok/s", pre), mk("TTFT", "s", ttft), mk("decode tok/s (stream)", "tok/s", dec)]
        }
        return rows
    }
}

// MARK: - CLI

extension BenchHTTPCLI {
    static func cmdProfile(_ args: [String], factory: TokenizerFactory?, cwd: String, log: @escaping LogSink) async throws -> Int32 {
        let o = try Opts(args, valued: ["strim", "model", "head", "lengths", "chunks", "decode-lengths", "reps", "sections", "serve-url",
                                        "serve-model", "out", "decode-tokens", "ablation-chunk", "seed-file", "date"], flags: ["dry-run"])
        var c = PerfConfig()
        c.strim = o.one("strim") ?? CommandLine.arguments[0]
        if !c.strim.hasPrefix("/") { c.strim = cwd + "/" + c.strim }
        if let v = o.one("model") { c.modelDir = v }
        if let v = o.one("head") { c.headDir = v }
        if let v = try o.ints("lengths") { c.lengths = v }
        if let v = try o.ints("chunks") { c.chunks = v }
        if let v = try o.ints("decode-lengths") { c.decodeLengths = v }
        if let v = try o.int("reps") { c.reps = v }
        if let v = try o.int("decode-tokens") { c.decodeTokens = v }
        if let v = try o.int("ablation-chunk") { c.ablationChunk = v }
        if let v = o.one("sections") { c.sections = Set(v.split(separator: ",").map { String($0) }) }
        if let v = o.one("serve-url") { c.serveURL = v; c.sections.insert("served") }
        if let v = o.one("serve-model") { c.serveModel = v }
        if let v = o.one("seed-file") { c.seedFile = v }
        c.tokenizerPath = c.modelDir + "/tokenizer.json"
        c.dryRun = o.flags.contains("dry-run")
        guard c.reps >= 3 else { throw BenchError("--reps must be >= 3") }
        let date = o.one("date") ?? { let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date()) }()
        c.outDir = o.one("out") ?? "bench/results/perf-profile-\(date)"

        // Prompt ids for benchspec: tokenizer-encoded repetition of the seed text, cut to length.
        let seed = (try? String(contentsOfFile: c.seedFile, encoding: .utf8)) ?? "The quick brown fox jumps over the lazy dog. "
        func ids(_ n: Int) throws -> String {
            guard let factory else { throw BenchError("no tokenizer backend linked") }
            let tok = try factory(c.modelDir)
            let base = tok.encode(seed)
            guard !base.isEmpty else { throw BenchError("seed text tokenised to nothing") }
            var out: [Int] = []; out.reserveCapacity(n)
            while out.count < n { out += base }
            return out.prefix(n).map(String.init).joined(separator: ",")
        }
        if c.dryRun {
            let steps = PerfPlan.steps(c) { "<\($0) ids>" }
            for s in steps {
                let envs = s.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                print("\(s.section)\t\(s.label)\t\(s.ablation ? "ABLATION" : "valid")\t\(envs) \(c.strim) \(s.args.joined(separator: " "))")
            }
            if c.serveURL != nil { print("served\tcold\tvalid\t\(c.lengths.count) lengths x \(c.reps + 1) requests") }
            print("\(steps.count) subprocess steps; run under: lockf -t 30 -k /tmp/strim-bench.lock")
            return 0
        }
        var cc = c
        let served: ((PerfConfig) async -> [PerfRow])? = c.serveURL == nil ? nil : { cfg in await PerfProfile.servedRows(cfg, factory: factory, log: log) }
        let report = try await PerfProfile.run(cc, ids: ids, runner: PerfShell.real, served: served, repoRoot: cwd, log: log)
        cc.outDir = c.outDir
        try FileManager.default.createDirectory(atPath: c.outDir, withIntermediateDirectories: true)
        try PerfRender.json(report).write(toFile: c.outDir + "/results.json", atomically: true, encoding: .utf8)
        let md = PerfRender.markdown(report)
        try md.write(toFile: c.outDir + "/summary.md", atomically: true, encoding: .utf8)
        print(md)
        return 0
    }
}
