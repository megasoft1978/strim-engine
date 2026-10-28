import Foundation
import StrimMCPClients

// strim mcp-clients list
// strim mcp-clients run NAME --model DIR [--head DIR] [--port N=8212] [--out DIR] [--rerun] [--strim-bin PATH]
//                            [--claude-bin PATH] [--codex-bin PATH] [--codex-home-real DIR] [--parent-model sonnet] [--timeout-s 1500]
// Real Claude Code / Codex -> strim MCP delegation check. Starts a private `strim serve` (own token), runs one case,
// writes runs/NAME/ under --out. Never reads or writes the user's Claude config; Codex auth is copied from --codex-home-real.

func runMcpClients(_ args: [String]) {
    do { exit(try MCPClientsCommand.run(Array(args.dropFirst(2)))) }
    catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
