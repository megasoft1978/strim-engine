import Foundation

/// Dispatches the standalone subcommands that each live in their own Cmd_*.swift file.
/// Returns true when args[1] names one of them and it has been run.
func runExtraCommand(_ args: [String]) -> Bool {
    guard args.count >= 2 else { return false }
    switch args[1] {
    case "benchbatchsplit": runBatchSplit(args)
    case "benchbatchverify": runBatchVerify(args)
    case "checkgdnbatch": runGDNBatch(args)
    case "checkbatchparity": runBatchParity(args)
    case "probesplit": runPrefixProbe(args)
    case "checkprefix": runPrefixCache(args)
    case "checkprefixcuts": runPrefixCuts(args)
    case "enginebench": runEngineBench(args)
    case "chat": runEngineChat(args)
    case "serve": runServe(args)
    case "mcp-config": runMcpConfig(args)
    case "mcp-clients": runMcpClients(args)
    case "control-token": runControlToken(args)
    case "tokenize": runTokenize(args)
    case "draft-vocab": runDraftVocab(args)
    case "jobs": runJobs(args)
    case "agentbench": runAgentBench(args)
    case "soak": exitAsync { try await SoakCommand.run(args) }
    case "bench": exitAsync { try await BenchCommand.run(args) }
    case "site": exitAsync { try await SiteCommand.run(args) }
    case "evolve": exitAsync { try await EvolveCommand.run(args) }
    case "install-agent": exitAsync { try await InstallAgentCommand.run(args) }
    default: return false
    }
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
