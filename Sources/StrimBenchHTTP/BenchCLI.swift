import CryptoKit
import Foundation

/// Minimal long-option parser: `--key value`, `--key=value`, repeatable options, boolean flags.
struct Opts {
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    init(_ args: [String], valued: Set<String>, flags known: Set<String> = []) throws {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") && a.count > 2 {
                var key = String(a.dropFirst(2))
                var inline: String?
                if let eq = key.firstIndex(of: "=") {
                    inline = String(key[key.index(after: eq)...])
                    key = String(key[..<eq])
                }
                if valued.contains(key) {
                    if let inline { values[key, default: []].append(inline) }
                    else {
                        i += 1
                        guard i < args.count else { throw BenchError("--\(key) needs a value") }
                        values[key, default: []].append(args[i])
                    }
                } else if known.contains(key) {
                    flags.insert(key)
                } else {
                    throw BenchError("unknown option --\(key)")
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func one(_ k: String) -> String? { values[k]?.last }
    func all(_ k: String) -> [String] { values[k] ?? [] }
    func int(_ k: String) throws -> Int? {
        guard let s = one(k) else { return nil }
        guard let v = Int(s) else { throw BenchError("--\(k): '\(s)' is not an integer") }
        return v
    }
    func double(_ k: String) throws -> Double? {
        guard let s = one(k) else { return nil }
        guard let v = Double(s) else { throw BenchError("--\(k): '\(s)' is not a number") }
        return v
    }
    func ints(_ k: String) throws -> [Int]? {
        guard let s = one(k) else { return nil }
        return try s.split(separator: ",").map {
            guard let v = Int($0.trimmingCharacters(in: .whitespaces)) else { throw BenchError("--\(k): '\(s)' is not an integer list") }
            return v
        }
    }
}

/// `strim bench http <run|scoreboard|replay|sampled|aggregate|report|all|engines>`.
public enum BenchHTTPCLI {
    public static let usage = """
    usage: strim bench http <subcommand> [options]
      run        --engine E [--pass N] [--out DIR] [--sb-reps N] [--replay-reps N] [--sampled N] [--steps a,b]
                 [--workloads W1,..] [--start-timeout S] [--deadline-min M] [--root DIR] [--scratch DIR]
                 [--fixture PATH] [--engines-file F] [--lock PATH | --no-lock]
                 one engine pass: launch, warm-up, scoreboard W1-W5, 8-turn replay, sampled decode, kill exact pids
      scoreboard --arm NAME[:pending]=URL,MODEL ... [--pid NAME=PID] [--workloads] [--reps] [--out-dir] [--dry-run] ...
                 W6 = agent prompts at each --conc: --w6-prompts FILE.json (array of strings) [--w6-gen N]
      replay     --fixture F --arm NAME=URL,MODEL[,cache=on|off|off-by-nonce] ... [--server-log NAME=PATH] [--reps]
                 [--max-tokens] [--classic] [--out-dir] | --make-synthetic-fixture PATH [--synthetic-turns N]
      sampled    URL MODEL LABEL OUT_JSONL [N=3] [TOKENS=256]
      aggregate  [--dir DIR] [--out-dir DIR] [--path-label S]   summary.md + results.json from a results dir
      report     DIR... [--check]   regenerate scoreboard/replay summary.md from raw.jsonl (--check: diff only)
      all        [--out DIR] [--engines-file F] [--dry-run] [--no-lock]   the full ABAB schedule (final_all.sh)
      profile    [--strim PATH] [--model DIR] [--head DIR] [--lengths a,b] [--chunks a,b] [--decode-lengths a,b] [--reps N>=3]
                 [--sections prefill,ablate,head,decode] [--serve-url URL --serve-model M] [--out DIR] [--dry-run]
                 measurement-only perf profile pack (chunk sweep, GDN ablation, MTP-head cost, decode timing, served cold TTFT);
                 GPU runs: lockf -t 30 -k /tmp/strim-bench.lock strim bench http profile ...
      engines    [--engines-file F] [--root DIR] [--scratch DIR]   print the expanded launch recipes
      needle     --url URL --model M --tokenizer PATH [--lengths 16384,65536] [--reps N] [--seed FILE] [--token-file F]
                 [--out DIR] [--timeout S]   needle-in-a-haystack check (ported from bench/needle.py); exit 1 unless every run answers ZX-4417
    """

    public static func run(_ args: [String], tokenizerFactory: TokenizerFactory?) async throws -> Int32 {
        guard let sub = args.first else { print(usage); return 2 }
        let rest = Array(args.dropFirst())
        let cwd = FileManager.default.currentDirectoryPath
        let log: LogSink = { m in FileHandle.standardError.write(Data((m + "\n").utf8)) }
        switch sub {
        case "-h", "--help", "help": print(usage); return 0
        case "run": return try await cmdRun(rest, factory: tokenizerFactory, cwd: cwd)
        case "scoreboard": return try await cmdScoreboard(rest, factory: tokenizerFactory, cwd: cwd, log: log)
        case "replay": return try await cmdReplay(rest, cwd: cwd, log: log)
        case "sampled": return try await cmdSampled(rest, log: log)
        case "aggregate": return try cmdAggregate(rest)
        case "report": return try cmdReport(rest)
        case "all": return try await cmdAll(rest, factory: tokenizerFactory, cwd: cwd)
        case "engines": return try cmdEngines(rest, cwd: cwd)
        case "profile": return try await cmdProfile(rest, factory: tokenizerFactory, cwd: cwd, log: log)
        case "needle": return try await cmdNeedle(rest, factory: tokenizerFactory, cwd: cwd, log: log)
        default:
            FileHandle.standardError.write(Data("unknown subcommand '\(sub)'\n\(usage)\n".utf8))
            return 2
        }
    }

    static func loadTable(_ o: Opts) throws -> EngineTable {
        if let f = o.one("engines-file") { return try EngineTable(file: f) }
        return try EngineTable.builtin()
    }

    static func cmdRun(_ args: [String], factory: TokenizerFactory?, cwd: String) async throws -> Int32 {
        let o = try Opts(args, valued: ["engine", "pass", "out", "sb-reps", "replay-reps", "sampled", "steps", "workloads", "start-timeout",
                                        "deadline-min", "root", "scratch", "fixture", "engines-file", "lock", "tokenizer"], flags: ["no-lock"])
        guard let engine = o.one("engine") else { throw BenchError("run: --engine is required") }
        let table = try loadTable(o)
        var c = PassConfig(engine: engine, root: o.one("root") ?? cwd)
        applyPassOptions(&c, o)
        return await PassRunner.run(cfg: c, table: table, factory: factory)
    }

    static func applyPassOptions(_ c: inout PassConfig, _ o: Opts) {
        if let v = try? o.int("pass") { c.pass = v }
        if let v = o.one("out") { c.out = v }
        if let v = try? o.int("sb-reps") { c.sbReps = v }
        if let v = try? o.int("replay-reps") { c.replayReps = v }
        if let v = try? o.int("sampled") { c.sampled = v }
        if let v = o.one("steps") { c.steps = Set(v.split(separator: ",").map { String($0) }) }
        if let v = o.one("workloads") { c.workloads = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() } }
        if let v = try? o.double("start-timeout") { c.startTimeout = v }
        if let v = try? o.double("deadline-min") { c.deadlineMin = v }
        if let v = o.one("scratch") { c.scratch = v }
        if let v = o.one("fixture") { c.fixture = v }
        if let v = o.one("tokenizer") { c.tokenizer = v }
        if o.flags.contains("no-lock") { c.lockPath = nil } else if let v = o.one("lock") { c.lockPath = v }
    }

    static func cmdAll(_ args: [String], factory: TokenizerFactory?, cwd: String) async throws -> Int32 {
        let o = try Opts(args, valued: ["out", "engines-file", "root", "scratch", "lock", "start-timeout", "deadline-min", "sampled", "fixture"],
                         flags: ["dry-run", "no-lock"])
        let table = try loadTable(o)
        let sched = table.schedule
        if o.flags.contains("dry-run") {
            for s in sched { print("\(s.engine) pass\(s.pass) sb-reps \(s.sbReps) replay-reps \(s.replayReps)") }
            return 0
        }
        for s in sched {
            var c = PassConfig(engine: s.engine, root: o.one("root") ?? cwd)
            applyPassOptions(&c, o)
            c.pass = s.pass
            c.sbReps = s.sbReps
            c.replayReps = s.replayReps
            let rc = await PassRunner.run(cfg: c, table: table, factory: factory)  // a failed pass does not stop the chain
            print("== \(s.engine) pass\(s.pass) rc=\(rc)")
        }
        print("ALLDONE")
        return 0
    }

    static func cmdEngines(_ args: [String], cwd: String) throws -> Int32 {
        let o = try Opts(args, valued: ["engines-file", "root", "scratch"])
        let table = try loadTable(o)
        let root = o.one("root") ?? cwd
        for n in table.names {
            let l = try table.launch(n, root: root, scratch: o.one("scratch") ?? table.scratchDefault)
            let env = l.env.map { "\($0.key)=\($0.value) " }.joined()
            print("\(n) [port \(l.port)]: \(env)\(PassRunner.shellJoin(l.cmd))")
        }
        return 0
    }

    static func cmdScoreboard(_ args: [String], factory: TokenizerFactory?, cwd: String, log: LogSink) async throws -> Int32 {
        let o = try Opts(args, valued: ["arm", "pid", "workloads", "reps", "w1-tokens", "w2-tokens", "seed", "w3-sizes", "w3-gen", "w4-size",
                                        "w4-gen", "conc", "w5-prefix", "w5-suffix", "w5-gen", "w6-prompts", "w6-gen", "tokenizer", "server-log", "timeout", "out-dir",
                                        "bench-dir"], flags: ["no-think", "no-no-think", "dry-run", "prompt-sha"])
        var arms = try o.all("arm").map(Arm.parse)
        let names = arms.map(\.name)
        if Set(names).count != names.count { throw BenchError("duplicate arm names: \(names)") }
        for s in o.all("pid") {
            let parts = s.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let p = Int(parts[1]) else { throw BenchError("bad --pid '\(s)': want NAME=PID") }
            for i in arms.indices where arms[i].name == parts[0] { arms[i].pid = p }
        }
        var c = ScoreboardConfig(outDir: o.one("out-dir") ?? "bench/results/scoreboard-\(timestamp())")
        c.arms = arms
        if let v = o.one("workloads") { c.workloads = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty } }
        if !Set(c.workloads).isSubset(of: Set(Scoreboard.allWorkloads)) { throw BenchError("unknown workloads: \(c.workloads)") }
        if let v = try o.int("reps") { c.reps = v }
        if let v = try o.ints("w1-tokens") { c.w1Tokens = v }
        if let v = try o.int("w2-tokens") { c.w2Tokens = v }
        if let v = try o.int("seed") { c.seed = v }
        if let v = try o.ints("w3-sizes") { c.w3Sizes = v }
        if let v = try o.int("w3-gen") { c.w3Gen = v }
        if let v = try o.int("w4-size") { c.w4Size = v }
        if let v = try o.int("w4-gen") { c.w4Gen = v }
        if let v = try o.ints("conc") { c.conc = v }
        if let v = try o.int("w5-prefix") { c.w5Prefix = v }
        if let v = try o.int("w5-suffix") { c.w5Suffix = v }
        if let v = try o.int("w5-gen") { c.w5Gen = v }
        if let v = o.one("w6-prompts") { c.w6PromptsFile = v }
        if let v = try o.int("w6-gen") { c.w6Gen = v }
        if c.workloads.contains("W6"), c.w6Prompts.isEmpty { throw BenchError("W6 needs --w6-prompts FILE (JSON array of strings)") }
        if let v = o.one("tokenizer") { c.tokenizer = v } else { c.tokenizer = cwd + "/models/qwen38-4bit/tokenizer.json" }
        if let v = try o.double("timeout") { c.timeout = v }
        if let v = o.one("bench-dir") { c.benchDir = v }
        if o.flags.contains("no-no-think") { c.noThink = false }
        for s in o.all("server-log") {
            if let eq = s.firstIndex(of: "="), arms.contains(where: { $0.name == String(s[..<eq]) }) {
                c.serverLogs[String(s[..<eq])] = String(s[s.index(after: eq)...])
            } else {
                c.serverLogs[""] = s
            }
        }
        if c.arms.isEmpty { throw BenchError("need at least one --arm NAME=BASE_URL,MODEL") }
        if o.flags.contains("dry-run") { try dryRun(c, factory: factory, showSHA: o.flags.contains("prompt-sha")); return 0 }
        do {
            let text = try await Scoreboard.execute(cfg: c, factory: factory, log: { print($0) })
            _ = text
            print("wrote \(c.outDir)")
            return 0
        } catch let e as BenchError {
            FileHandle.standardError.write(Data("\(e)\n".utf8))
            return 2
        }
    }

    static func dryRun(_ cfg: ScoreboardConfig, factory: TokenizerFactory?, showSHA: Bool) throws {
        let active = cfg.arms.filter { !$0.pending }
        let seed = try String(contentsOfFile: cfg.benchDir + "/prompt_seed.txt", encoding: .utf8)
        let prompter = Prompter.make(seed: seed, tokenizerPath: cfg.tokenizer, factory: factory)
        guard case .object(let corpus) = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: cfg.benchDir + "/ab_prompts.json"))) else { return }
        print("tokens: \(prompter.note)")
        print("thinking: \(cfg.noThink ? "disabled (--no-think, default)" : "server default (--no-no-think)")")
        for a in cfg.arms {
            print("arm \(a.name): \(a.pending ? "PENDING (skipped)" : "active") endpoint=\(chatEndpoint(a.url)) model=\(a.model) pid=\(a.pid.map(String.init) ?? "None")")
        }
        var total = 0
        for wl in cfg.workloads {
            let groups = Scoreboard.buildGroups(workload: wl, rep: 0, runID: "dryrun", cfg: cfg, prompter: prompter, corpus: corpus)
            let per = groups.reduce(0) { $0 + $1.items.count }
            print("\(wl): \(per) req/arm/rep in \(groups.count) groups")
            for g in groups {
                let it = g.items[0]
                var tgt = it.target.map { " target=\($0)" } ?? ""
                if showSHA {
                    tgt += " sha=" + SHA256.hash(data: Data(it.prompt.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                }
                print("  \(g.variant.padding(toLength: 18, withPad: " ", startingAt: 0)) conc=\(g.items.count) max_tokens=\(it.maxTokens) "
                    + "temp=\(pyFloatRepr(it.temperature)) seed=\(it.seed.map(String.init) ?? "None") prompt_tokens=\(prompter.count(it.prompt))\(tgt)")
            }
            total += per * active.count * cfg.reps
        }
        print("protocol: reps=\(cfg.reps), rep0 order \(active.map(\.name).joined(separator: " ")), odd reps reversed")
        print("total requests (active arms x reps): \(total)")
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    static func cmdReplay(_ args: [String], cwd: String, log: LogSink) async throws -> Int32 {
        let o = try Opts(args, valued: ["fixture", "arm", "server-log", "reps", "max-tokens", "timeout", "out-dir", "make-synthetic-fixture", "synthetic-turns"],
                         flags: ["no-session-salt", "classic"])
        if let path = o.one("make-synthetic-fixture") {
            let turns = try o.int("synthetic-turns") ?? 6
            let msgs = try SyntheticFixture.write(path: path, turns: turns)
            let pts = Replay.requestPoints(msgs)
            let approx = pts.map { i in JSON.dumps(.array(Array(msgs[...i])), ensureASCII: false).unicodeScalars.count / 4 }
            print("wrote \(path): \(msgs.count) messages, \(pts.count) turns, approx tokens per turn \(approx)")
            return 0
        }
        guard let fixture = o.one("fixture"), !o.all("arm").isEmpty else {
            throw BenchError("need --fixture PATH and at least one --arm (or --make-synthetic-fixture)")
        }
        var arms = try o.all("arm").map(ReplayArm.parse)
        if Set(arms.map(\.name)).count != arms.count { throw BenchError("duplicate arm names: \(arms.map(\.name))") }
        var logs: [String: String] = [:]
        for s in o.all("server-log") {
            guard let eq = s.firstIndex(of: "=") else { throw BenchError("bad --server-log '\(s)': want NAME=PATH") }
            logs[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        for i in arms.indices { arms[i].serverLog = logs[arms[i].name] }
        var c = ReplayConfig(fixture: fixture, arms: arms, outDir: o.one("out-dir") ?? "bench/results/agent-replay-\(timestamp())")
        if let v = try o.int("reps") { c.reps = v }
        if let v = try o.int("max-tokens") { c.maxTokens = v }
        if let v = try o.double("timeout") { c.timeout = v }
        c.noSessionSalt = o.flags.contains("no-session-salt")
        c.classic = o.flags.contains("classic")
        if c.reps < 1 || c.maxTokens < 1 { throw BenchError("--reps and --max-tokens must be >= 1") }
        if !(32 ... 64).contains(c.maxTokens) { log("warning: --max-tokens \(c.maxTokens) is outside the intended 32-64 range") }
        do {
            try await Replay.run(cfg: c, log: log)
            print("wrote \(c.outDir)/raw.jsonl and \(c.outDir)/summary.md")
            return 0
        } catch let e as BenchError {
            FileHandle.standardError.write(Data("\(e)\n".utf8))
            return 2
        }
    }

    static func cmdSampled(_ args: [String], log: LogSink) async throws -> Int32 {
        let o = try Opts(args, valued: [])
        guard o.positional.count >= 4 else { throw BenchError("usage: sampled URL MODEL LABEL OUT_JSONL [N=3] [TOKENS=256]") }
        var c = SampledConfig(url: o.positional[0], model: o.positional[1], label: o.positional[2], outPath: o.positional[3])
        if o.positional.count > 4 { c.n = Int(o.positional[4]) ?? 3 }
        if o.positional.count > 5 { c.tokens = Int(o.positional[5]) ?? 256 }
        try await Sampled.run(cfg: c, log: { print($0) })
        return 0
    }

    static func cmdAggregate(_ args: [String]) throws -> Int32 {
        let o = try Opts(args, valued: ["dir", "out-dir", "path-label", "generated-by"])
        let dir = o.one("dir") ?? o.positional.first ?? "bench/results/final-20261026"
        let r = try Aggregate.run(dir: dir, outDir: o.one("out-dir"), pathLabel: o.one("path-label"),
                                  generatedBy: o.one("generated-by") ?? "strim bench http aggregate")
        let out = o.one("out-dir") ?? dir
        print("wrote \(out)/summary.md \(out)/results.json (\(r.summary.count) + \(r.results.count) chars)")
        return 0
    }

    /// Regenerates summary.md of every scoreboard/replay run found under the given dirs.
    static func cmdReport(_ args: [String]) throws -> Int32 {
        let o = try Opts(args, valued: [], flags: ["check"])
        guard !o.positional.isEmpty else { throw BenchError("report: need at least one DIR") }
        var bad = 0, seen = 0
        for root in o.positional {
            for dir in rawDirs(under: root) {
                let first = JSON.lines(dir + "/raw.jsonl").first ?? .null
                let text: String
                if !first["workloads"].isNull { text = try Scoreboard.summarize(dir: dir) }
                else if !first["fixture"].isNull { text = try Replay.summarize(dir: dir) }
                else { continue }
                seen += 1
                let path = dir + "/summary.md"
                if o.flags.contains("check") {
                    let old = try? String(contentsOfFile: path, encoding: .utf8)
                    if old != text { bad += 1; print("DIFF \(path)") }
                } else {
                    try text.write(toFile: path, atomically: false, encoding: .utf8)
                    print("wrote \(path)")
                }
            }
        }
        if o.flags.contains("check") { print("\(seen - bad)/\(seen) summaries identical") }
        return bad == 0 ? 0 : 1
    }

    static func rawDirs(under root: String) -> [String] {
        var out: [String] = []
        if FileManager.default.fileExists(atPath: root + "/raw.jsonl") { out.append(root) }
        if let en = FileManager.default.enumerator(atPath: root) {
            for case let p as String in en where p.hasSuffix("/raw.jsonl") { out.append(root + "/" + (p as NSString).deletingLastPathComponent) }
        }
        return Array(Set(out)).sorted()
    }
}
