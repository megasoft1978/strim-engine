import Foundation
import StrimHost

// strim mcp-config --claude|--codex [--port N=8203]
// Prints the client registration command. The token is read by the shell from ~/.strim/token, never printed.

func runMcpConfig(_ args: [String]) {
    func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
    var client: McpConfig.Client?
    var port: UInt16 = 8203
    var i = 2
    while i < args.count {
        let a = args[i]
        if a == "--claude" { client = .claude }
        else if a == "--codex" { client = .codex }
        else if a == "--port" || a.hasPrefix("--port=") {
            let v: String
            if let eq = a.firstIndex(of: "="), a.hasPrefix("--") { v = String(a[a.index(after: eq)...]) }
            else { i += 1; guard i < args.count else { fail("missing value for --port") }; v = args[i] }
            guard let p = UInt16(v), p > 0 else { fail("bad --port") }
            port = p
        } else { fail("unknown option \(a)") }
        i += 1
    }
    guard let client else { fail("usage: strim mcp-config --claude|--codex [--port N=8203]") }
    print(McpConfig.render(client, port: port), terminator: "")
}
