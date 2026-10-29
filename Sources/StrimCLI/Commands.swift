import Foundation
import StrimBenchHTTP

/// One standalone subcommand. `cliCommands` is the only dispatch table: `runExtraCommand` and `strim --help`
/// both read it, so a command cannot be dispatched without appearing in help.
struct CLICommand: Sendable {
    let name: String
    var aliases: [String] = []
    let summary: String
    /// Shown by `strim <name> --help`. Defaults to the summary when a command has no longer usage text.
    var usage: String?
    let run: @Sendable ([String]) -> Void
}

private let serveUsage = """
usage: strim serve <model> [mtpHead] [--port N=8203] [--token-file PATH] [--no-auth] [--model-dir DIR]...
                   [--max-inflight N] [--max-background N] [--no-admission] [--prefix-disk] [--prefix-disk-dir DIR]
  Engine + OpenAI-compatible HTTP server on 127.0.0.1. A bearer token is required unless --no-auth (loopback dev only).
  The token lives in ~/.strim/token (0600). Thinking is on by default; see docs/CONTROL-API.md.
"""

private let pullUsage = """
usage: strim pull [--tier 4bit|6bit|8bit|oq4e] [--dir DIR=~/.strim/models] [--revision-lock] [--verify] [--list] [--only REPO_DIR_NAME]
  Downloads the pinned model and MTP head; resumable and sha256-verified. HF_TOKEN is sent as a bearer token if set.
  Progress goes to stderr. Ctrl-C or SIGTERM saves progress; rerun strim pull to resume.
"""

private let doctorUsage = """
usage: strim doctor [--dir DIR=~/.strim/models]
  Prints the version, runtime config, GPU device, a tiny matmul check and the model directory status. Exits 1 if the matmul fails.
"""

private let versionUsage = """
usage: strim --version | -V | version
  Prints the version only. Runtime config is in `strim doctor`.
"""

/// Usage for `strim bench`: the HTTP benchmark harness (docs/BENCH.md).
private let benchUsage = "usage: strim bench http <subcommand> [options]\n\n" + BenchHTTPCLI.usage

let cliCommands: [CLICommand] = [
    CLICommand(name: "serve", summary: "run the engine and the OpenAI-compatible server", usage: serveUsage, run: { runServe($0) }),
    CLICommand(name: "pull", summary: "download the pinned model and MTP head (resumable)", usage: pullUsage, run: { runPull($0) }),
    CLICommand(name: "doctor", summary: "GPU smoke test, runtime config and model directory status", usage: doctorUsage, run: { runDoctor($0) }),
    CLICommand(name: "version", aliases: ["--version", "-V"], summary: "print the version", usage: versionUsage, run: { runVersion($0) }),
    CLICommand(name: "bench", summary: "HTTP benchmark harness (strim bench http ...)", usage: benchUsage, run: { args in
        exitAsync { try await BenchCommand.run(args) } }),
    CLICommand(name: "site", summary: "build the site and README from site/data/results.json", usage: SiteCommand.usage, run: { args in
        exitAsync { try await SiteCommand.run(args) } }),
    CLICommand(name: "quanteval", summary: "quantization accuracy: ref | cmp | bits", usage: "usage: strim quanteval ref <model> <out.bin> <window> <label=ids.txt>... | strim quanteval cmp <model> <ref.bin>", run: { runQuantEval($0) }),
    CLICommand(name: "chat", summary: "interactive chat with the local engine", run: { runEngineChat($0) }),
    CLICommand(name: "enginebench", summary: "engine decode benchmark", run: { runEngineBench($0) }),
    CLICommand(name: "cache", summary: "prefix cache maintenance", run: { runCache($0) }),
    CLICommand(name: "tokenize", summary: "tokenize text with a model's tokenizer", run: { runTokenize($0) }),
    CLICommand(name: "draft-vocab", summary: "build a draft vocabulary", run: { runDraftVocab($0) }),
    CLICommand(name: "mcp-config", summary: "print an MCP client config for strim", run: { runMcpConfig($0) }),
    CLICommand(name: "mcp-clients", summary: "list known MCP clients", run: { runMcpClients($0) }),
    CLICommand(name: "control-token", summary: "print the control API token path", run: { runControlToken($0) }),
    CLICommand(name: "jobs", summary: "list and inspect delegated jobs", run: { runJobs($0) }),
    CLICommand(name: "agentbench", summary: "agent task benchmark", run: { runAgentBench($0) }),
    CLICommand(name: "soak", summary: "soak test against a running strim serve", run: { args in exitAsync { try await SoakCommand.run(args) } }),
    CLICommand(name: "evolve", summary: "evolution harness", run: { args in exitAsync { try await EvolveCommand.run(args) } }),
    CLICommand(name: "install-agent", summary: "install the agent integration", run: { args in exitAsync { try await InstallAgentCommand.run(args) } }),
    CLICommand(name: "benchbatchsplit", summary: "developer bench: batch split", run: { runBatchSplit($0) }),
    CLICommand(name: "benchtensormicro", summary: "developer bench: tensor micro-benchmark", run: { runTensorMicro($0) }),
    CLICommand(name: "bonsaispike", summary: "developer spike: bonsai model", run: { runBonsaiSpike($0) }),
    CLICommand(name: "benchfusedmicro", summary: "developer bench: fused kernels", run: { runFusedMicro($0) }),
    CLICommand(name: "benchqmmcurve", summary: "developer bench: quantized matmul curve", run: { runQmmCurve($0) }),
    CLICommand(name: "benchqmmstep", summary: "developer bench: quantized matmul step", run: { runQmmStep($0) }),
    CLICommand(name: "benchprescreen", summary: "developer bench: prescreen", run: { runPrescreen($0) }),
    CLICommand(name: "benchprescreen2", summary: "developer bench: prescreen (v2)", run: { runPrescreen2($0) }),
    CLICommand(name: "benchdecodeanatomy", summary: "developer bench: decode anatomy", run: { runDecodeAnatomy($0) }),
    CLICommand(name: "benchbatchattn", summary: "developer bench: batch attention", run: { runBatchAttnMicro($0) }),
    CLICommand(name: "benchbatchverify", summary: "developer bench: batch verify", run: { runBatchVerify($0) }),
    CLICommand(name: "checkgdnbatch", summary: "developer check: GDN batch", run: { runGDNBatch($0) }),
    CLICommand(name: "checkbatchparity", summary: "developer check: batch parity", run: { runBatchParity($0) }),
    CLICommand(name: "probesplit", summary: "developer probe: split", run: { runPrefixProbe($0) }),
    CLICommand(name: "checkprefix", summary: "developer check: prefix cache", run: { runPrefixCache($0) }),
    CLICommand(name: "checkprefixcuts", summary: "developer check: prefix cache cuts", run: { runPrefixCuts($0) }),
    CLICommand(name: "checkprefixdisk", summary: "developer check: on-disk prefix cache", run: { runPrefixDiskCheck($0) }),
]

/// Help text, generated from `cliCommands` so it cannot drift from the dispatch.
func cliHelpText() -> String {
    var lines = [
        "usage: strim <command> [options]     strim <command> --help for details",
        "",
        "commands:",
    ]
    let width = cliCommands.map { $0.name.count }.max() ?? 0
    for c in cliCommands {
        lines.append("  " + c.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + c.summary)
    }
    lines += [
        "",
        "  inspect <model-dir>            print the safetensors index and shard summary",
        "  probe <model-dir> [token]      probe the model with one token",
        "",
        "strim --version prints the version; strim doctor prints the runtime config.",
    ]
    return lines.joined(separator: "\n")
}

/// Dispatches the standalone subcommands that each live in their own Cmd_*.swift file.
/// Returns true when args[1] names one of them and it has been run.
func runExtraCommand(_ args: [String]) -> Bool {
    guard args.count >= 2 else { return false }
    if ["--help", "-h", "help"].contains(args[1]) {
        if args.count >= 3, let c = cliCommands.first(where: { $0.name == args[2] || $0.aliases.contains(args[2]) }) {
            print(c.usage ?? c.summary); exit(0)
        }
        print(cliHelpText()); exit(0)
    }
    guard let cmd = cliCommands.first(where: { $0.name == args[1] || $0.aliases.contains(args[1]) }) else { return false }
    if args.dropFirst(2).contains(where: { $0 == "--help" || $0 == "-h" }) {
        print(cmd.usage ?? cmd.summary); exit(0)
    }
    cmd.run(args)
    return true
}

/// Runs an async subcommand to completion on the main thread's run loop and exits with its status code.
/// Each Cmd_<Name>.swift owns `<Name>Command.run(_ args:) async throws -> Int32`.
func exitAsync(_ body: @escaping @Sendable () async throws -> Int32) -> Never {
    Task {
        do { exit(try await body()) }
        catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}
