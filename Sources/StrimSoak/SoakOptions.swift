import Foundation

/// Flags for `strim soak`. Every path is absolute: relative inputs are resolved against the cwd at parse time.
public struct SoakOptions: Sendable, Equatable {
    public var durationMin = 30.0
    public var clients = ["claude", "codex"]
    public var maxTasks = 0
    public var taskTimeout = 240
    public var concurrentEvery = 6
    public var poll = 15.0
    public var port = 8203
    public var tokenFile: String
    public var readyTimeout = 900
    public var out: String?
    public var tmpRoot: String?
    public var only: [String] = []
    public var model: String
    public var head: String
    public var claudeBin: String
    public var codexBin: String
    public var lockPath: String
    public var lockWaitS: Double?

    /// `both`, `claude` or `codex`: the value recorded in run.json and the summary usage line.
    public var armsName: String { clients.count == 2 ? "both" : clients[0] }
    /// Model id the clients request: the model directory's name, as `strim serve` reports it.
    public var modelId: String { (model as NSString).lastPathComponent }

    public init(cwd: String, home: String, env: [String: String]) {
        tokenFile = home + "/.strim/token"
        model = cwd + "/models/qwen38-4bit"
        head = cwd + "/models/qwen38-mtp-4bit"
        claudeBin = home + "/.local/bin/claude"
        codexBin = "/opt/homebrew/bin/codex"
        lockPath = env["STRIM_BENCH_LOCK"] ?? "/tmp/strim-bench.lock"
    }
}

public enum SoakMode: Sendable, Equatable {
    case run(SoakOptions)
    case listTasks
    case summarize(String)
    case help
}

public struct SoakUsageError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum SoakArgs {
    public static let usage = """
    usage: strim soak [--duration MIN=30] [--arms both|claude|codex] [--max-tasks N=0] [--task-timeout S=240]
                      [--concurrent-every N=6] [--poll S=15] [--port N=8203] [--token-file PATH=~/.strim/token]
                      [--ready-timeout S=900] [--out DIR] [--tmp-root DIR] [--only id,id]
                      [--model DIR=./models/qwen38-4bit] [--head DIR=./models/qwen38-mtp-4bit]
                      [--claude-bin PATH] [--codex-bin PATH] [--lock-path PATH] [--lock-wait-s S]
           strim soak --list-tasks
           strim soak --summarize DIR
    """

    static let valueOptions: Set<String> = [
        "duration", "arms", "max-tasks", "task-timeout", "concurrent-every", "poll", "port", "token-file",
        "ready-timeout", "out", "tmp-root", "only", "model", "head", "claude-bin", "codex-bin", "lock-path",
        "lock-wait-s", "summarize",
    ]

    /// Parses the arguments after `strim soak`. `cwd`, `home` and `env` are injected so tests stay hermetic.
    public static func parse(_ argv: [String], cwd: String, home: String, env: [String: String]) throws -> SoakMode {
        var values: [String: String] = [:]
        var flags = Set<String>()
        var i = 0
        while i < argv.count {
            let a = argv[i]
            guard a.hasPrefix("--") else { throw SoakUsageError("unexpected argument \(a)") }
            var name = String(a.dropFirst(2))
            var inline: String?
            if let eq = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            if name == "help" { flags.insert(name) }
            else if name == "list-tasks" {
                guard inline == nil else { throw SoakUsageError("--list-tasks takes no value") }
                flags.insert(name)
            } else if valueOptions.contains(name) {
                if let v = inline { values[name] = v }
                else {
                    i += 1
                    guard i < argv.count else { throw SoakUsageError("missing value for --\(name)") }
                    values[name] = argv[i]
                }
            } else {
                throw SoakUsageError("unknown option --\(name)")
            }
            i += 1
        }
        if flags.contains("help") { return .help }
        if flags.contains("list-tasks") { return .listTasks }
        if let dir = values["summarize"] { return .summarize(absolute(dir, cwd: cwd, home: home)) }

        var o = SoakOptions(cwd: cwd, home: home, env: env)
        if let v = values["duration"] {
            guard let d = Double(v), d > 0, d.isFinite else { throw SoakUsageError("--duration must be a positive number of minutes") }
            o.durationMin = d
        }
        if let v = values["arms"] { o.clients = try parseArms(v) }
        o.maxTasks = try int(values["max-tasks"], "max-tasks", default: 0, min: 0)
        o.taskTimeout = min(try int(values["task-timeout"], "task-timeout", default: 240, min: 1), 240)
        o.concurrentEvery = try int(values["concurrent-every"], "concurrent-every", default: 6, min: 0)
        if let v = values["poll"] {
            guard let p = Double(v), p > 0, p.isFinite else { throw SoakUsageError("--poll must be a positive number of seconds") }
            o.poll = p
        }
        o.port = try int(values["port"], "port", default: 8203, min: 1)
        guard o.port <= 65535 else { throw SoakUsageError("--port must be 1-65535") }
        o.readyTimeout = try int(values["ready-timeout"], "ready-timeout", default: 900, min: 1)
        if let v = values["token-file"] { o.tokenFile = absolute(v, cwd: cwd, home: home) }
        if let v = values["out"] { o.out = absolute(v, cwd: cwd, home: home) }
        if let v = values["tmp-root"] { o.tmpRoot = absolute(v, cwd: cwd, home: home) }
        if let v = values["model"] { o.model = absolute(v, cwd: cwd, home: home) }
        if let v = values["head"] { o.head = absolute(v, cwd: cwd, home: home) }
        if let v = values["claude-bin"] { o.claudeBin = v.contains("/") ? absolute(v, cwd: cwd, home: home) : v }
        if let v = values["codex-bin"] { o.codexBin = v.contains("/") ? absolute(v, cwd: cwd, home: home) : v }
        if let v = values["lock-path"] { o.lockPath = absolute(v, cwd: cwd, home: home) }
        else { o.lockPath = absolute(o.lockPath, cwd: cwd, home: home) }
        if let v = values["lock-wait-s"] {
            guard let w = Double(v), w >= 0 else { throw SoakUsageError("--lock-wait-s must be >= 0") }
            o.lockWaitS = w
        }
        if let v = values["only"] {
            let ids = v.split(separator: ",").map(String.init)
            let known = Set(SoakTasks.all.map(\.id))
            let unknown = ids.filter { !known.contains($0) }
            guard unknown.isEmpty, !ids.isEmpty else { throw SoakUsageError("unknown task ids: \(unknown.joined(separator: ","))") }
            o.only = ids
        }
        return .run(o)
    }

    static func parseArms(_ v: String) throws -> [String] {
        switch v {
        case "both": return ["claude", "codex"]
        case "claude": return ["claude"]
        case "codex": return ["codex"]
        default: throw SoakUsageError("--arms must be both, claude or codex")
        }
    }

    static func int(_ raw: String?, _ name: String, default d: Int, min lo: Int) throws -> Int {
        guard let raw else { return d }
        guard let v = Int(raw), v >= lo else { throw SoakUsageError("--\(name) must be an integer >= \(lo)") }
        return v
    }

    /// `~` expansion, then lexical standardization against `cwd`. Symlinks are not resolved (the lock and out dir
    /// checks do their own no-follow opens).
    public static func absolute(_ path: String, cwd: String, home: String) -> String {
        var p = path
        if p == "~" { p = home }
        else if p.hasPrefix("~/") { p = home + String(p.dropFirst(1)) }
        if !p.hasPrefix("/") { p = cwd + "/" + p }
        return (p as NSString).standardizingPath
    }
}
