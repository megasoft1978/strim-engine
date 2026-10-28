import Foundation
import StrimAgentBench

// strim agentbench run    [--arms H,C | H,C,P,M] [--tasks N|all  (N = tasks PER CLASS, first N sorted ids of each class)] [--task-ids a,b] [--classes c1,c2] [--reps N=1]
//                         [--seed S] [--out DIR] [--ledger FILE] [--tasks-dir DIR] [--model DIR] [--head DIR]
//                         [--port N=8231] [--attach] [--token-file FILE] [--strim-bin PATH] [--claude-bin PATH]
//                         [--parent-model sonnet] [--timeout-s 900] [--verify-timeout-s 300]
//                         [--allow-paid --max-parent-runs N] [--dry-run] [--lock-held] [--lock-path P] [--lock-wait-s S]
//                         [--keep-workdirs]
// strim agentbench validate [--tasks-dir D] [--task-ids a,b]   offline: verify fails on each snapshot, passes with solution.patch
// strim agentbench prepare  [--tasks-dir D] [--write]           check (or rewrite) tree/test hashes and manifest.json
// strim agentbench report <ledger> [--out results.json] [--include-dry-run]
//
// Arms P and M use the paid Claude subscription: refused unless --allow-paid AND --max-parent-runs N are given.

func runAgentBench(_ args: [String]) {
    func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
    let usage = "usage: strim agentbench run [options] | report <ledger> [--out results.json]  (see Sources/StrimCLI/Cmd_AgentBench.swift)"
    guard args.count >= 3 else { fail(usage) }
    var opts: [String: String] = [:]
    var flags = Set<String>()
    var positional: [String] = []
    let boolFlags: Set<String> = ["allow-paid", "dry-run", "attach", "lock-held", "keep-workdirs", "write", "include-dry-run"]
    var i = 3
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            var name = String(a.dropFirst(2))
            if let eq = name.firstIndex(of: "=") { opts[String(name[..<eq])] = String(name[name.index(after: eq)...]) }
            else if boolFlags.contains(name) { flags.insert(name) }
            else {
                i += 1
                guard i < args.count else { fail("missing value for --\(name)") }
                opts[name] = args[i]
            }
            name = ""
        } else { positional.append(a) }
        i += 1
    }

    // Relative paths are resolved now: the spawned server runs with the output dir as cwd.
    for k in ["model", "head", "out", "ledger", "tasks-dir", "token-file", "lock-path", "strim-bin"] {
        if let v = opts[k] { opts[k] = PathArgs.absolute(v) }
    }
    if let c = opts["claude-bin"], c.contains("/") { opts["claude-bin"] = PathArgs.absolute(c) }

    switch args[2] {
    case "report":
        guard let path = positional.first else { fail("usage: strim agentbench report <ledger> [--out results.json]") }
        let rows = Ledger(url: URL(fileURLWithPath: path)).read()
        if rows.isEmpty { fail("no rows in \(path)") }
        let report = Reporter.build(rows, includeDryRun: flags.contains("include-dry-run") || rows.allSatisfy(\.dryRun))
        print(Reporter.render(report), terminator: "")
        let outPath = opts["out"] ?? (URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("results.json").path)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(report).write(to: URL(fileURLWithPath: outPath)); print("wrote \(outPath)") }
        catch { fail("cannot write \(outPath): \(error)") }
    case "validate", "prepare":
        let root = URL(fileURLWithPath: PathArgs.absolute(opts["tasks-dir"] ?? "bench/agenttasks"))
        let ids = (opts["task-ids"] ?? "").split(separator: ",").map(String.init)
        let tasks = TaskLoader.select(TaskLoader.load(root: root), limit: nil, ids: ids, classes: [])
        if tasks.isEmpty { fail("no tasks found under \(root.path)") }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentbench-\(args[2])-\(getpid())")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) } // our own temp dir
        if args[2] == "validate" {
            var results: [ValidationResult] = []
            for t in tasks {
                if let lang = t.language, let why = SelfCheck.check(language: lang, scratch: scratch.appendingPathComponent("sc-\(t.id)")) { fail("infra: \(why)") }
                results.append(Corpus.validate(t, scratch: scratch.appendingPathComponent(t.id)))
                FileHandle.standardError.write(Data("validated \(t.id)\n".utf8))
            }
            print(Corpus.render(results), terminator: "")
            exit(results.allSatisfy(\.ok) ? 0 : 1)
        } else {
            let lines = Corpus.prepare(root: root, tasks: tasks, write: flags.contains("write"), scratch: scratch)
            lines.forEach { print($0) }
            exit(lines.contains { $0.contains("MISMATCH") || $0.contains("unreadable") || $0.contains("cannot") } ? 1 : 0)
        }
    case "run":
        runAgentBenchRun(opts: opts, flags: flags, fail: fail)
    default:
        fail(usage)
    }
}

private func runAgentBenchRun(opts: [String: String], flags: Set<String>, fail: (String) -> Never) {
    let fm = FileManager.default
    let dry = flags.contains("dry-run")
    guard let arms = Arm.parseList(opts["arms"] ?? "H,C") else { fail("bad --arms (use letters from H,C,P,M)") }
    do { try BudgetGuard.validate(arms: arms, allowPaid: flags.contains("allow-paid"), maxParentRuns: opts["max-parent-runs"].flatMap(Int.init)) }
    catch { fail("refused: \(error)") }

    if !dry, arms.contains(where: { $0.usesLocalModel }), !flags.contains("attach") {
        guard let m = opts["model"] else { fail("--model DIR is required for arms H, C, M (or --attach to use a running host)") }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: m, isDirectory: &isDir), isDir.boolValue else { fail("model directory not found: \(m)") }
        if let h = opts["head"] {
            guard fm.fileExists(atPath: h, isDirectory: &isDir), isDir.boolValue else { fail("head directory not found: \(h)") }
        }
    }
    let tasksDir = URL(fileURLWithPath: PathArgs.absolute(opts["tasks-dir"] ?? "bench/agenttasks"))
    var tasks = TaskLoader.load(root: tasksDir)
    let limit: Int? = opts["tasks"].flatMap { $0 == "all" ? nil : Int($0) }
    let ids = (opts["task-ids"] ?? "").split(separator: ",").map(String.init)
    let classes = (opts["classes"] ?? "").split(separator: ",").map(String.init)
    tasks = TaskLoader.select(tasks, limit: limit, ids: ids, classes: classes)
    if tasks.isEmpty { fail("no tasks found under \(tasksDir.path)") }

    let stamp: String = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date())
    }()
    let outDir = URL(fileURLWithPath: opts["out"] ?? "bench/results/agentbench-\(stamp)")
    let ledgerURL = URL(fileURLWithPath: opts["ledger"] ?? outDir.appendingPathComponent(dry ? "ledger.dry-run.jsonl" : "ledger.jsonl").path)
    let workRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("strim-agentbench-\(getpid())")
    try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: workRoot, withIntermediateDirectories: true)

    var cfg = RunnerConfig(arms: arms, ledgerURL: ledgerURL, eventsURL: ledgerURL.appendingPathExtension("events"), outDir: outDir, workRoot: workRoot)
    cfg.reps = Int(opts["reps"] ?? "") ?? 1
    cfg.seed = UInt64(opts["seed"] ?? "") ?? 20261027
    cfg.allowPaid = flags.contains("allow-paid")
    cfg.maxParentRuns = opts["max-parent-runs"].flatMap(Int.init)
    cfg.timeoutS = TimeInterval(opts["timeout-s"] ?? "") ?? 900
    cfg.verifyTimeoutS = TimeInterval(opts["verify-timeout-s"] ?? "") ?? 300
    cfg.dryRun = dry
    cfg.keepWorkdirs = flags.contains("keep-workdirs")

    Interrupt.install()
    var lock: FileLock?
    var server: LocalServer?
    var executors: [Arm: ArmExecutor] = [:]
    let needsLocal = arms.contains { $0.usesLocalModel }
    if dry {
        for a in arms { executors[a] = FakeExecutor() }
    } else {
        if needsLocal {
            if !flags.contains("lock-held") {
                let path = opts["lock-path"] ?? FileLock.defaultPath
                do {
                    lock = try FileLock.acquire(path: path, timeout: opts["lock-wait-s"].flatMap(TimeInterval.init)) {
                        print("waiting for GPU lock \(path) ...")
                    }
                } catch { fail("\(error)") }
            }
            let port = UInt16(opts["port"] ?? "") ?? 8231
            do {
                if flags.contains("attach") {
                    server = try LocalServer.attach(port: port, tokenFile: opts["token-file"] ?? NSHomeDirectory() + "/.strim/token",
                                                    modelId: opts["model-id"] ?? "qwen38-4bit")
                } else {
                    guard let model = opts["model"] else { fail("--model DIR is required for arms H, C, M (or --attach to use a running host)") }
                    let bin = opts["strim-bin"] ?? (Bundle.main.executablePath ?? CommandLine.arguments[0])
                    let tokenFile = outDir.appendingPathComponent("server.token").path
                    server = try LocalServer.spawn(strimBin: bin, model: model, head: opts["head"], port: port, tokenFile: tokenFile,
                                                   logDir: outDir, readyTimeout: 900)
                }
            } catch { fail("\(error)") }
        }
        let claudeBin = opts["claude-bin"] ?? NSHomeDirectory() + "/.local/bin/claude"
        let parentModel = opts["parent-model"] ?? "sonnet"
        for a in arms {
            switch a {
            case .H: executors[a] = HarnessArm(endpoint: server!.endpoint)
            case .C: executors[a] = ClaudeArm(mode: .local(server!.endpoint), claudeBin: claudeBin, model: server!.endpoint.modelId)
            case .P: executors[a] = ClaudeArm(mode: .paid, claudeBin: claudeBin, model: parentModel)
            case .M: executors[a] = ClaudeArm(mode: .paidWithMCP(server!.endpoint), claudeBin: claudeBin, model: parentModel)
            }
        }
    }
    defer { server?.stop(); lock?.release() }

    let srv = server
    let runner = BenchRunner(config: cfg, tasks: tasks, executors: executors, healthCheck: srv.map { s in { s.isAlive } }) { print($0); fflush(stdout) }
    if !dry { runner.selfCheck = { SelfCheck.check(language: $0, scratch: $1) } }
    do {
        let s = try runner.run()
        print("planned \(s.planned), skipped (already in ledger) \(s.skipped), executed \(s.executed), passed \(s.passed)"
              + (s.budgetStopped ? ", STOPPED at --max-parent-runs" : "") + (s.interrupted ? ", interrupted" : ""))
        print("ledger: \(ledgerURL.path)")
        try? fm.removeItem(at: workRoot) // our own temp dir
        server?.stop(); lock?.release()
        exit(s.budgetStopped ? 3 : 0)
    } catch {
        server?.stop(); lock?.release()
        fail("\(error)")
    }
}
