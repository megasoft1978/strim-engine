import Foundation
import StrimAgentBench

/// `strim mcp-clients list` and `strim mcp-clients run NAME --model DIR [options]`.
/// `run` starts a private `strim serve` (own token file, own port), runs one case with a real client, stops the server.
public struct MCPClientsOptions: Equatable {
    public enum Command: Equatable { case list, run(String) }

    public var command: Command
    public var model: String?
    public var head: String?
    public var port: UInt16 = 8212
    public var out = "bench/results/mcp-clients-20261027"
    public var rerun = false
    public var strimBin: String?
    public var claudeBin = "~/.local/bin/claude"
    public var codexBin = "/opt/homebrew/bin/codex"
    public var codexHomeReal = "~/.codex"
    public var parentModel = "sonnet"
    public var timeoutS: Double = 1500

    static let valueOptions: Set<String> = ["model", "head", "port", "out", "strim-bin", "claude-bin", "codex-bin",
                                            "codex-home-real", "parent-model", "timeout-s"]

    public static func parse(_ args: [String]) throws -> MCPClientsOptions {
        var positional: [String] = []
        var values: [String: String] = [:]
        var rerun = false
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                var key = String(a.dropFirst(2))
                var value: String?
                if let eq = key.firstIndex(of: "=") {
                    value = String(key[key.index(after: eq)...])
                    key = String(key[..<eq])
                }
                if key == "rerun" && value == nil {
                    rerun = true
                } else {
                    guard valueOptions.contains(key) else { throw MCPClientsError.usage("unknown option --\(key)") }
                    if value == nil {
                        i += 1
                        guard i < args.count else { throw MCPClientsError.usage("missing value for --\(key)") }
                        value = args[i]
                    }
                    values[key] = value
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
        let command: Command
        switch positional.first ?? "" {
        case "list" where positional.count == 1: command = .list
        case "run" where positional.count == 2: command = .run(positional[1])
        default: throw MCPClientsError.usage(usage)
        }
        var o = MCPClientsOptions(command: command)
        o.rerun = rerun
        o.model = values["model"]
        o.head = values["head"]
        if let p = values["port"] {
            guard let port = UInt16(p), port > 0 else { throw MCPClientsError.usage("bad --port") }
            o.port = port
        }
        if let v = values["out"] { o.out = v }
        o.strimBin = values["strim-bin"]
        if let v = values["claude-bin"] { o.claudeBin = v }
        if let v = values["codex-bin"] { o.codexBin = v }
        if let v = values["codex-home-real"] { o.codexHomeReal = v }
        if let v = values["parent-model"] { o.parentModel = v }
        if let v = values["timeout-s"] {
            guard let t = Double(v), t > 0 else { throw MCPClientsError.usage("bad --timeout-s") }
            o.timeoutS = t
        }
        return o
    }

    static let usage = "usage: strim mcp-clients list | run NAME --model DIR [--head DIR] [--port N=8212] [--out DIR] "
        + "[--rerun] [--strim-bin PATH] [--claude-bin PATH] [--codex-bin PATH] [--codex-home-real DIR] "
        + "[--parent-model sonnet] [--timeout-s 1500]"
}

public enum MCPClientsCommand {
    /// `args` is everything after `mcp-clients`. Returns the process exit status.
    public static func run(_ args: [String]) throws -> Int32 {
        let opts = try MCPClientsOptions.parse(args)
        switch opts.command {
        case .list:
            for c in MCPClientsCases.all {
                print("\(c.name)\t\(c.client.rawValue)\(c.useMCP ? "\tmcp" : "\tno-mcp")\(c.checksFix ? "\tchecked" : "")")
            }
            return 0
        case .run(let name):
            guard let c = MCPClientsCases.named(name) else { throw MCPClientsError.usage("unknown case \(name); see `strim mcp-clients list`") }
            guard let model = opts.model else { throw MCPClientsError.usage("--model DIR is required (the model dir for strim serve)") }
            let cwd = FileManager.default.currentDirectoryPath
            var outRoot = PathArgs.absolute(opts.out, cwd: cwd)
            if opts.rerun { outRoot = (outRoot as NSString).appendingPathComponent("rerun") }
            let runDir = URL(fileURLWithPath: outRoot).appendingPathComponent("runs").appendingPathComponent(c.name)
            let strimBin = opts.strimBin ?? Bundle.main.executablePath ?? CommandLine.arguments[0]

            // Private host: its own token (created 0600 in the temp dir), its own logs. Only this child is stopped.
            let work = try MCPClientsRunner.makeWorkDir("serve")
            defer { try? FileManager.default.removeItem(at: work) }
            let server = try LocalServer.spawn(strimBin: strimBin, model: PathArgs.absolute(model, cwd: cwd),
                                               head: opts.head.map { PathArgs.absolute($0, cwd: cwd) }, port: opts.port,
                                               tokenFile: work.appendingPathComponent("token").path, logDir: work,
                                               readyTimeout: 900)
            defer { server.stop() }
            let bins = MCPClientsBins(claude: PathArgs.absolute(opts.claudeBin, cwd: cwd),
                                      codex: PathArgs.absolute(opts.codexBin, cwd: cwd),
                                      codexHomeReal: PathArgs.absolute(opts.codexHomeReal, cwd: cwd),
                                      parentModel: opts.parentModel, timeoutS: opts.timeoutS)
            let row = try MCPClientsRunner.runCase(c, endpoint: server.endpoint, bins: bins, runDir: runDir)
            print(row)
            return 0
        }
    }
}
