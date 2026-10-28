import Foundation

/// Registration commands for MCP clients. Never contains the token value; the shell reads the token file.
public enum McpConfig {
    public enum Client: String, Sendable { case claude, codex }

    public static func render(_ client: Client, port: UInt16) -> String {
        let url = "http://127.0.0.1:\(port)/mcp"
        switch client {
        case .claude:
            let hdr = "-t http strim \(url) -H \"Authorization: Bearer $(cat ~/.strim/token)\""
            return "# Run inside the project that should delegate (stays in your private config; saves the ~1.3K-token tool schema tax elsewhere):\n"
                + "claude mcp add -s local \(hdr)\n"
                + "# Alternative, all projects:\n"
                + "claude mcp add -s user \(hdr)\n"
                + "# Do NOT use -s project: it writes the token header into .mcp.json inside the repo.\n"
        case .codex:
            return "export STRIM_TOKEN=$(cat ~/.strim/token)\n"
                + "codex mcp add strim --url \(url) --bearer-token-env-var STRIM_TOKEN\n"
                + "# Then add this line under [mcp_servers.strim] in ~/.codex/config.toml. Without it, Codex with\n"
                + "# approval_policy=never rejects MCP calls (\"MCP tool call requires approval\"). It auto-approves\n"
                + "# delegation to a sandboxed, worktree-only agent; omit it if you prefer prompts.\n"
                + "default_tools_approval_mode = \"approve\"\n"
        }
    }
}
