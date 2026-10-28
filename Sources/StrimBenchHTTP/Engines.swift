import Foundation

/// One engine's launch recipe with placeholders expanded.
public struct EngineLaunch: Sendable, Equatable {
    public var name: String
    public var port: Int
    public var cache: String
    public var quant: String
    public var cmd: [String]
    public var env: [(key: String, value: String)]
    public var probePath: String
    public var prepare: [Prepare]
    public var postReady: PostReady?
    public var cleanup: [String]?

    public enum Prepare: Sendable, Equatable {
        case mkdir(String)
        case symlink(link: String, to: String)
    }

    public struct PostReady: Sendable, Equatable {
        public var name: String
        public var gguf: String
        public var numCtx: Int
        public var stop: String
        public var modelfile: String
        public var template: String
    }

    public static func == (a: EngineLaunch, b: EngineLaunch) -> Bool {
        a.name == b.name && a.port == b.port && a.cmd == b.cmd && a.cache == b.cache && a.quant == b.quant
            && a.env.map(\.key) == b.env.map(\.key) && a.env.map(\.value) == b.env.map(\.value)
    }
}

public struct ScheduleEntry: Sendable, Equatable {
    public var engine: String
    public var pass: Int
    public var sbReps: Int
    public var replayReps: Int
}

public struct EngineTable: Sendable {
    let doc: JSONValue

    public static func builtin() throws -> EngineTable { try EngineTable(json: EngineTableData.json) }

    public init(json: String) throws {
        doc = try JSON.parse(json)
        guard doc["engines"].object != nil else { throw BenchError("engine table: missing \"engines\"") }
    }

    public init(file: String) throws {
        try self.init(json: String(contentsOfFile: file, encoding: .utf8))
    }

    public var names: [String] { doc["engines"].object?.keys ?? [] }

    public var scratchDefault: String { doc["scratch_default"].string ?? "/tmp/strim-bench-scratch" }

    public var schedule: [ScheduleEntry] {
        (doc["schedule"].array ?? []).compactMap { e in
            guard let n = e["engine"].string, let p = e["pass"].int else { return nil }
            return ScheduleEntry(engine: n, pass: p, sbReps: e["sb_reps"].int ?? 3, replayReps: e["replay_reps"].int ?? 3)
        }
    }

    /// Expands `${ROOT}`, `${SCRATCH}` and the table's `vars` in every command, env and path field.
    public func launch(_ name: String, root: String, scratch: String) throws -> EngineLaunch {
        let spec = doc["engines"][name]
        guard spec.object != nil else { throw BenchError("unknown engine '\(name)' (have: \(names.joined(separator: ", ")))") }
        var vars: [String: String] = ["ROOT": root, "SCRATCH": scratch]
        for m in doc["vars"].object?.members ?? [] { vars[m.key] = m.value.string ?? pyStr(m.value) }
        func x(_ s: String) -> String {
            var out = s
            // Longest names first so ${PORT} cannot clash with a longer key.
            for k in vars.keys.sorted(by: { $0.count > $1.count }) { out = out.replacingOccurrences(of: "${\(k)}", with: vars[k]!) }
            return out
        }
        let port = spec["port"].int ?? 0
        vars["PORT"] = vars["PORT"] ?? String(port)
        let cmd = (spec["cmd"].array ?? []).compactMap { $0.string }.map(x)
        guard !cmd.isEmpty else { throw BenchError("engine '\(name)': empty cmd") }
        let env = (spec["env"].object?.members ?? []).map { (key: $0.key, value: x($0.value.string ?? "")) }
        var prepare: [EngineLaunch.Prepare] = []
        for p in spec["prepare"].array ?? [] {
            if let d = p["mkdir"].string { prepare.append(.mkdir(x(d))) }
            else if let l = p["symlink"].string, let t = p["to"].string { prepare.append(.symlink(link: x(l), to: x(t))) }
        }
        var post: EngineLaunch.PostReady?
        let pr = spec["post_ready"]
        if pr["kind"].string == "ollama_create" {
            post = EngineLaunch.PostReady(name: pr["name"].string ?? "", gguf: x(pr["gguf"].string ?? ""),
                                          numCtx: pr["num_ctx"].int ?? 65536, stop: pr["stop"].string ?? "<|im_end|>",
                                          modelfile: x(pr["modelfile"].string ?? scratch + "/Modelfile"),
                                          template: doc["ollama_template"].string ?? "")
        }
        return EngineLaunch(name: name, port: port, cache: spec["cache"].string ?? "", quant: spec["quant"].string ?? "",
                            cmd: cmd, env: env, probePath: spec["probe"].string ?? "/v1/models", prepare: prepare,
                            postReady: post, cleanup: spec["cleanup"].array?.compactMap { $0.string }.map(x))
    }
}
