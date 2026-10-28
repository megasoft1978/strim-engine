import Foundation
import StrimAgentBench
import StrimEvolve

// strim evolve plan   [common]
// strim evolve run    [common] [--budget-minutes N] [--background] [--release-eval --split test]
//                     live: --model DIR [--head DIR] [--port N=8231] [--strim-bin P] [--lock-path P] [--lock-wait-s S]
//                           [--lock-held] [--timeout-s 900] [--verify-timeout-s 300]
// strim evolve report [common]
// strim evolve adopt  [common] [--no-active]
//
// common: --out DIR (default bench/results/evolve-<date>)  --tasks-dir DIR (bench/agenttasks)  --dry-run (fake runner)
//         --store DIR (~/.strim/packs)  --coordinates a,b (names as in Coordinate, default all 10)
//         --max-tasks N (search splits: first N per class, sorted ids; test untouched)  --train-reps N=1  --val-reps N=2
//         --max-rounds N=2  --min-gain-pp X=5  --seed S
// --include-unplumbed is deprecated and ignored (every coordinate is consumed by the harness since 7bb62fb).
// See docs/EVOLVE.md.
enum EvolveCommand {
    static let boolFlags: Set<String> = ["dry-run", "background", "release-eval", "include-unplumbed", "lock-held", "no-active"]

    static func run(_ args: [String]) async throws -> Int32 {
        func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        let usage = "usage: strim evolve plan|run|report|adopt [options]  (see docs/EVOLVE.md)"
        guard args.count >= 3 else { err(usage); return 2 }
        var opts: [String: String] = [:]
        var flags = Set<String>()
        var i = 3
        while i < args.count {
            guard args[i].hasPrefix("--") else { err("unexpected argument \(args[i])"); return 2 }
            var name = String(args[i].dropFirst(2))
            if let eq = name.firstIndex(of: "=") { opts[String(name[..<eq])] = String(name[name.index(after: eq)...]) }
            else if boolFlags.contains(name) { flags.insert(name) }
            else {
                i += 1
                guard i < args.count else { err("missing value for --\(name)"); return 2 }
                opts[name] = args[i]
            }
            name = ""
            i += 1
        }
        do {
            let ctx = try EvolveContext(opts: opts, flags: flags)
            switch args[2] {
            case "plan": return try ctx.plan()
            case "run": return try await ctx.run()
            case "report": return try ctx.report()
            case "adopt": return try ctx.adopt()
            default: err(usage); return 2
            }
        } catch let e as EvolveError {
            err("refused: \(e)"); return 2
        }
    }
}

struct EvolveContext {
    let opts: [String: String]
    let flags: Set<String>
    let out: URL
    let tasksDir: URL
    let dry: Bool
    let config: EvolveConfig
    let tasks: [LoadedTask]
    let split: CorpusSplit
    let store: PackStore

    /// Dry-run data never mixes with real data. report/adopt without --dry-run fall back to the dry-run ledger only when no real one exists.
    var ledgerURL: URL {
        let dryURL = out.appendingPathComponent("ledger.dry-run.jsonl"), real = out.appendingPathComponent("ledger.jsonl")
        if dry { return dryURL }
        return FileManager.default.fileExists(atPath: real.path) || !FileManager.default.fileExists(atPath: dryURL.path) ? real : dryURL
    }

    init(opts: [String: String], flags: Set<String>) throws {
        self.opts = opts; self.flags = flags
        dry = flags.contains("dry-run")
        let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date()) }()
        out = URL(fileURLWithPath: opts["out"] ?? "bench/results/evolve-\(stamp)")
        tasksDir = URL(fileURLWithPath: opts["tasks-dir"] ?? "bench/agenttasks")
        store = PackStore(root: opts["store"].map { URL(fileURLWithPath: $0) } ?? PackStore.defaultRoot)

        var cfg = EvolveConfig()
        if let v = opts["train-reps"].flatMap(Int.init) { cfg.trainReps = max(1, v) }
        if let v = opts["val-reps"].flatMap(Int.init) { cfg.valReps = max(1, v) }
        if let v = opts["max-rounds"].flatMap(Int.init) { cfg.maxRounds = max(1, v) }
        if let v = opts["min-gain-pp"].flatMap(Double.init) { cfg.minGainPP = v }
        if let v = opts["seed"].flatMap(UInt64.init) { cfg.seed = v }
        if flags.contains("include-unplumbed") {
            FileHandle.standardError.write(Data("note: --include-unplumbed is deprecated and ignored (all coordinates are consumed by the harness)\n".utf8))
        }
        if let raw = opts["max-tasks"] {
            guard let v = Int(raw), v >= 1 else { throw EvolveError.usage("--max-tasks takes a whole number >= 1") }
            cfg.maxTasksPerClass = v
        }
        if let list = opts["coordinates"] {
            let cs = list.split(separator: ",").map(String.init).compactMap { Coordinate(rawValue: $0) }
            guard cs.count == list.split(separator: ",").count, !cs.isEmpty else {
                throw EvolveError.usage("bad --coordinates; choose from \(Coordinate.allCases.map(\.rawValue).joined(separator: ","))")
            }
            cfg.coordinates = cs
        }
        // An existing config.json wins; flags that disagree with it are refused (a changed config would mix incomparable rows).
        let cfgURL = out.appendingPathComponent("config.json")
        let configFlags = ["train-reps", "val-reps", "max-rounds", "min-gain-pp", "seed", "coordinates", "max-tasks"].contains { opts[$0] != nil }
        if let d = try? Data(contentsOf: cfgURL), let saved = try? JSONDecoder().decode(EvolveConfig.self, from: d) {
            if configFlags && saved != cfg { throw EvolveError.usage("config.json in \(out.path) differs from the flags given; use a new --out") }
            cfg = saved
        }
        config = cfg
        let loaded = TaskLoader.load(root: tasksDir)
        guard !loaded.isEmpty else { throw EvolveError.usage("no tasks found under \(tasksDir.path)") }
        tasks = loaded
        let full = try CorpusSplit.frozen(dir: out, tasks: loaded.map { ($0.id, $0.spec.taskClass) })
        let classOf = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0.spec.taskClass) })
        split = cfg.maxTasksPerClass.map { full.limited(perClass: $0, classOf: classOf) } ?? full
    }

    func saveConfig() throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try enc.encode(config).write(to: out.appendingPathComponent("config.json"), options: .atomic)
    }

    func rows() -> [FitnessRow] { FitnessLedger(url: ledgerURL).read() }
    var classes: [String: String] { Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.spec.taskClass) }) }

    // MARK: plan

    func plan() throws -> Int32 {
        try saveConfig()
        print("max tasks per class: \(config.maxTasksPerClass.map(String.init) ?? "all")")
        print("tasks: \(tasks.count)  train \(split.train.count)  val \(split.val.count)  test \(split.test.count) (frozen)")
        print("coordinates: \(config.coordinates.map(\.rawValue).joined(separator: ", "))")
        let cands = config.coordinates.reduce(0) { $0 + max(0, $1.variants(of: .baseline).count - 1) }
        let trainRuns = cands * split.train.count * config.trainReps
        let valRuns = config.coordinates.count * 2 * split.val.count * config.valReps
        print("round 1 upper bound: \(trainRuns) train runs + \(valRuns) val runs (+ baseline train \(split.train.count * config.trainReps)); max rounds \(config.maxRounds)")
        let est = Double(opts["est-run-minutes"] ?? "") ?? 3
        print(String(format: "at %.1f min/run: about %.1f h for round 1", est, Double(trainRuns + valRuns + split.train.count) * est / 60))
        print("gate: val gain >= \(config.minGainPP) pp (paired, \(config.valReps) reps), no rep regression, false-done <= \(Int(config.maxFalseDoneRate * 100))%; kill rule after \(config.maxRounds) rounds")
        print("out: \(out.path)")
        return 0
    }

    // MARK: run

    func run() async throws -> Int32 {
        try saveConfig()
        let wantsTest = opts["split"] == "test"
        if let s = opts["split"], SplitName(rawValue: s) == nil && s != "search" { throw EvolveError.usage("--split takes search or test") }
        if wantsTest { try SplitGuard.check(.test, releaseEval: flags.contains("release-eval")) }
        if flags.contains("release-eval") && !wantsTest { throw EvolveError.usage("--release-eval needs --split test") }

        Interrupt.install()
        if flags.contains("background") { setpriority(PRIO_PROCESS, 0, 15) }
        let deadline = opts["budget-minutes"].flatMap(Double.init).map { Date().addingTimeInterval($0 * 60) }
        let ledger = FitnessLedger(url: ledgerURL)

        var lock: FileLock?
        var server: LocalServer?
        defer { server?.stop(); lock?.release() }
        let runner: TaskRunner
        if dry {
            runner = FakeTaskRunner.standard
        } else {
            guard let model = opts["model"] else { throw EvolveError.usage("--model DIR is required for a live run (or use --dry-run)") }
            if !flags.contains("lock-held") {
                let path = opts["lock-path"] ?? "/tmp/strim-bench.lock"
                lock = try FileLock.acquire(path: path, timeout: opts["lock-wait-s"].flatMap(TimeInterval.init)) { print("waiting for GPU lock \(path) ...") }
            }
            let liveDir = out.appendingPathComponent("live-pack")
            let serverEnv = BenchTaskRunner.environmentForServer(liveDir: liveDir)
            try PackStore.materialize(.baseline, into: liveDir)
            let bin = opts["strim-bin"] ?? (Bundle.main.executablePath ?? CommandLine.arguments[0])
            let port = UInt16(opts["port"] ?? "") ?? 8231
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let s = try LocalServer.spawn(strimBin: bin, model: model, head: opts["head"], port: port, tokenFile: out.appendingPathComponent("server.token").path,
                                          logDir: out, readyTimeout: 900, extraEnv: serverEnv)
            server = s
            var venv: [String: String] = [:]
            if let py = ProcessInfo.processInfo.environment["STRIM_BENCH_PYTHON"] { venv["PYTHON"] = py }
            let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("strim-evolve-\(getpid())")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            runner = BenchTaskRunner(tasks: tasks, executor: HarnessArm(endpoint: s.endpoint), liveDir: liveDir, workRoot: work,
                                     outDir: out.appendingPathComponent("runs"),
                                     timeoutS: TimeInterval(opts["timeout-s"] ?? "") ?? 900,
                                     verifyTimeoutS: TimeInterval(opts["verify-timeout-s"] ?? "") ?? 300,
                                     verifyEnv: venv, healthCheck: { s.isAlive })
        }
        let ev = Evaluator(runner: runner, ledger: ledger, split: split, classes: classes, config: config, deadline: deadline, dryRun: dry,
                           stopRequested: { Interrupt.requested }, log: { print($0); fflush(stdout) })

        let summary: EvolveRunSummary
        if wantsTest {
            let state = SearchPlanner.replay(rows: ledger.read(), split: split, config: config)
            guard state.finished else { throw EvolveError.refused("search is not finished (\(state.pending.count) runs pending); release eval needs the final pack") }
            summary = try await ev.releaseEval(chosen: state.incumbent, reps: config.valReps)
        } else {
            summary = try await ev.run()
        }
        print("executed \(summary.executed) runs" + (summary.budgetStopped ? ", STOPPED at --budget-minutes (resume by running again)" : "")
              + (summary.infraStopped ? ", STOPPED on an infrastructure failure (resume reruns it)" : "") + (summary.interrupted ? ", interrupted" : ""))
        _ = try report()
        if summary.infraStopped { return 4 }
        if summary.interrupted { return 5 }
        if summary.budgetStopped { return 3 }
        if !wantsTest, SearchPlanner.replay(rows: ledger.read(), split: split, config: config).killed { return 6 }
        return 0
    }

    // MARK: report

    func report() throws -> Int32 {
        let rs = rows()
        let st = SearchPlanner.replay(rows: rs, split: split, config: config)
        print("ledger: \(ledgerURL.path)  rows \(rs.count)\(rs.contains(where: \.dryRun) ? "  (DRY RUN, fake data)" : "")")
        print("candidate         label                                  train n fit  pass  fd%   | val n fit  pass  fd%   tokens")
        var fps = Array(Set(rs.map(\.candidate)))
        fps.sort()
        for fp in fps {
            let label = st.candidates[fp]?.label ?? (try? store.load(fp))?.label ?? "?"
            func cell(_ sp: SplitName) -> String {
                guard let s = Selection.score(fp, split: sp, rows: rs) else { return "-" }
                return String(format: "%3d %5.2f %4.0f%% %3.0f%%", s.n, s.fitness, s.passRate * 100, s.falseDoneRate * 100)
            }
            let tok = Selection.score(fp, split: .val, rows: rs)?.tokens ?? Selection.score(fp, split: .train, rows: rs)?.tokens ?? 0
            print("\(fp)  \(label.padding(toLength: 38, withPad: " ", startingAt: 0)) \(cell(.train)) | \(cell(.val))  \(Int(tok))")
        }
        for s in st.steps {
            switch s.outcome {
            case .noProposal: print("r\(s.round) \(s.coordinate.rawValue): no option beat the incumbent on train")
            case .confirmed(let w, let d):
                print(String(format: "r%d %@: %@ val gain %+.1f pp (per rep %@) fd %.0f%%->%.0f%% pairs %d: %@", s.round, s.coordinate.rawValue, w, d.gainPP,
                             d.perRepGainPP.sorted { $0.key < $1.key }.map { String(format: "%+.1f", $0.value) }.joined(separator: "/"),
                             d.incumbentFalseDoneRate * 100, d.challengerFalseDoneRate * 100, d.pairs, d.adopt ? "ADOPT" : "reject (\(d.reason.rawValue))"))
            }
        }
        for r in st.rounds { print(String(format: "round %d: adoptions %d, best val gain %+.1f pp", r.round, r.adoptions, r.bestValGainPP)) }
        if st.finished {
            print("search finished (\(st.stopReason?.rawValue ?? "")): chosen \(st.chosenFingerprint) [\(st.incumbent.label)]")
            if st.killed { print("KILL RULE: no val gain >= \(config.minGainPP) pp after \(st.rounds.count) round(s). Stop; do not build the proposer.") }
        } else {
            print("search in progress: \(st.pending.count) runs pending for the current step; current pack \(st.chosenFingerprint)")
        }
        if let v = Selection.releaseVerdict(chosen: st.chosenFingerprint, baseline: PackLibrary.fingerprint(.baseline), rows: rs) {
            print(String(format: "release (test): chosen vs baseline %+.1f pp over %d pairs%@", v.gainPP, v.pairs, v.regressed ? "  REGRESSED" : ""))
        } else if rs.contains(where: { $0.split == .test }) == false {
            print("test split: untouched")
        }
        return 0
    }

    // MARK: adopt

    func adopt() throws -> Int32 {
        let rs = rows()
        let st = SearchPlanner.replay(rows: rs, split: split, config: config)
        if dry && opts["store"] == nil { throw EvolveError.refused("--dry-run adopt needs an explicit --store (fake data never goes to ~/.strim/packs)") }
        let d = Adoption.check(rows: rs, state: st, allowDryRun: dry)
        guard d.ok else {
            print("not adopting: " + d.reasons.joined(separator: "; "))
            return 1
        }
        let last = st.steps.last { $0.adopted != nil }
        var gain: Double?
        if case .confirmed(_, let c)? = last?.outcome { gain = c.gainPP }
        let prov = Provenance(fingerprint: d.fingerprint, parent: PackLibrary.fingerprint(.baseline), coordinate: last?.coordinate.rawValue,
                              round: last?.round, valGainPP: gain, ledger: ledgerURL.path, seed: config.seed, dryRun: dry)
        let dir = try store.save(st.incumbent, provenance: prov)
        if !flags.contains("no-active") { try store.setActive(d.fingerprint) }
        print("adopted \(d.fingerprint) [\(st.incumbent.label)] -> \(dir.path)")
        print("use: STRIM_PACK_DIR=\(dir.path) strim serve ...")
        return 0
    }
}
