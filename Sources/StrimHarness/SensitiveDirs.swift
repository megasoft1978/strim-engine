import Foundation

/// Directories that hold credentials or host state. A job's `cwd` may never be one of these (or inside one):
/// the workspace is readable by the model and returned to the MCP caller, so a delegated job rooted here would
/// hand over `~/.strim/control-token`, `~/.aws/credentials`, `~/.docker/config.json` and the like.
public enum SensitiveDirs {
    /// Names under `$HOME`; entries ending in `*` are prefix matches (`.claude*` covers `.claude-work`).
    static let homeNames = [".strim", ".ssh", ".aws", ".gnupg", ".config", ".docker", ".kube", ".claude*", ".codex*", "Library"]
    static let absoluteRoots = ["/Library/Keychains", "/private/etc", "/etc"]

    /// A refusal message when `realCwd` (already canonical) is, or is inside, a sensitive directory; nil otherwise.
    /// `home` is the user's home directory (any spelling; both it and its realpath are checked).
    public static func refuse(realCwd: String, home: String = NSHomeDirectory()) -> String? {
        var homes = Set([home])
        if let r = realpath(home, nil) { homes.insert(String(cString: r)); free(r) }
        for h in homes {
            let base = h.count > 1 && h.hasSuffix("/") ? String(h.dropLast()) : h
            guard realCwd.hasPrefix(base + "/") else { continue }
            guard let first = realCwd.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: true).first else { continue }
            let seg = String(first).lowercased()
            for n in homeNames {
                let ln = n.lowercased()
                let hit = ln.hasSuffix("*") ? seg.hasPrefix(String(ln.dropLast())) : seg == ln
                if hit { return "refusing a credentials or host-state directory (~/\(first))" }
            }
        }
        for r in absoluteRoots where realCwd == r || realCwd.hasPrefix(r + "/") {
            return "refusing a credentials or host-state directory (\(r))"
        }
        return nil
    }

    /// Canonicalizes `path` (longest existing ancestor resolved) and applies `refuse`.
    public static func refuse(path: String, home: String = NSHomeDirectory()) -> String? {
        refuse(realCwd: WorkspacePolicy.realPath(of: path) ?? path, home: home)
    }
}
