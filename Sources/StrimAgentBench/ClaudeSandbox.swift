import Foundation
import StrimHarness

/// sandbox-exec wrapper for every Claude Code child (arms C, P, M). Reuses the harness `SandboxProfile`
/// (file writes only in the workdir and run dir, no reads of home or secret paths, no mach-lookup, no
/// network) and then opens exactly what Claude Code needs:
/// - C (local model, untrusted shell commands): outbound to loopback port `serverPort` only.
/// - P / M (real Claude, needs Anthropic): all network; the filesystem restrictions are unchanged.
public enum ClaudeSandbox {
    public enum Net: Sendable, Equatable { case loopback(port: UInt16), anthropic }

    public static let sandboxExec = "/usr/bin/sandbox-exec"

    /// Directories under the home that the claude binary / node runtime live in (read-only).
    public static func runtimeReadable(claudeBin: String, home: String = NSHomeDirectory()) -> [String] {
        var out: [String] = []
        if let r = realpath(claudeBin, nil) {
            out.append((String(cString: r) as NSString).deletingLastPathComponent)
            free(r)
        }
        out.append((claudeBin as NSString).deletingLastPathComponent)
        for d in [".local/share/claude", ".nvm", ".pyenv", ".cargo", ".rustup", "go", ".cache/go-build"] {
            let p = home + "/" + d
            if FileManager.default.fileExists(atPath: p) { out.append(p) }
        }
        // Homebrew toolchains are outside /Users and already readable.
        return out
    }

    /// Profile text. `authFile`: the single real file P/M may read for login (never the rest of ~/.claude*).
    public static func profile(workdir: String, runDir: String, net: Net, claudeBin: String, authFile: String? = nil,
                               home: String = NSHomeDirectory(), goCache: String? = nil, extraReadable: [String] = []) -> String {
        var sp = SandboxProfile(access: .write, writableRoots: [workdir, runDir] + (goCache.map { [$0] } ?? []), jobTmp: runDir + "/tmp",
                                home: home, extraReadable: (runtimeReadable(claudeBin: claudeBin, home: home) + extraReadable).filter { !ReadableRoots.isForbidden($0, home: home) })
        sp.gitWritable = []
        var p = sp.profile
        switch net {
        case .loopback(let port):
            p += "(allow network-outbound (remote ip \"localhost:\(port)\"))\n"
        case .anthropic:
            // IP only: no blanket unix-socket access to local daemons.
            p += "(allow network-outbound (remote ip))\n"
            // Login/keychain and DNS need mach services for the real client.
            p = p.replacingOccurrences(of: "(deny mach-lookup)\n", with: "")
            if let a = authFile {
                for v in variants(a) { p += "(allow file-read* (literal \(quote(v))))\n" }
            }
        }
        return p
    }

    /// `sandbox-exec -p <profile> <argv...>`
    public static func wrap(_ argv: [String], profile: String) -> [String] {
        [sandboxExec, "-p", profile] + argv
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func variants(_ path: String) -> [String] {
        guard let r = realpath(path, nil) else { return [path] }
        defer { free(r) }
        let resolved = String(cString: r)
        return resolved == path ? [path] : [path, resolved]
    }

}

/// Prefix-scoped Bash permissions for the Claude children (replaces a bare `Bash`).
public enum BashAllow {
    static let readOnlyTools = ["ls", "cat", "head", "tail", "wc", "grep", "find", "sed", "awk", "sort", "diff", "pwd", "mkdir", "touch", "cp", "mv"]
    static let gitReads = ["git apply", "git diff", "git status", "git log", "git show", "git grep", "git ls-files"]
    static let shellWords: Set<String> = ["test", "[", "[[", "!", "cd", "true", "false", "echo", "export", "set", "exit", "if", "then", "fi", "do", "done", "for", "while", "env", "command", "exec", "time"]
    /// Never allowed even if a verify command names them.
    static let neverAllowed: Set<String> = ["rm", "curl", "wget", "ssh", "scp", "sudo", "nc", "git", "sh", "bash", "zsh"]

    /// Command words used by a verify command (first word of each simple command, env assignments skipped).
    public static func verifyBinaries(_ cmd: String?) -> [String] {
        guard let cmd else { return [] }
        var out: [String] = []
        func add(_ w: String) { if !out.contains(w) { out.append(w) } }
        let segments = cmd.replacingOccurrences(of: "&&", with: "\n").replacingOccurrences(of: "||", with: "\n")
            .replacingOccurrences(of: ";", with: "\n").replacingOccurrences(of: "|", with: "\n")
            .replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ").split(separator: "\n")
        for seg in segments {
            for raw in seg.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                var w = String(raw)
                if w.contains("=") && !w.hasPrefix("\"${") && w.firstIndex(of: "=")! < (w.firstIndex(of: "/") ?? w.endIndex) { continue }
                // "${VAR:-default}" -> default
                if w.contains("${"), let r = w.range(of: ":-") {
                    let rest = w[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
                    if !rest.isEmpty { add(String(rest)) }
                    break
                }
                w = w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                if w.isEmpty || w.hasPrefix("-") || w == "!" { continue }
                if shellWords.contains(w) { if w == "!" { continue }; break }
                add(w)
                break
            }
        }
        return out.filter { !neverAllowed.contains($0) }
    }

    /// `Bash(<prefix>:*)` entries: git reads, inspection tools, and the runners the task's verify command uses
    /// (plus the usual test runner for the task language).
    public static func allowedPrefixes(for t: TaskSpec, language: String? = nil) -> [String] {
        var p = gitReads + readOnlyTools
        if !t.isAnswerTask {
            var bins = verifyBinaries(t.verifyCmd)
            switch language ?? "" {
            case "go": bins += ["go", "gofmt"]
            case "swift": bins += ["swift"]
            default: break
            }
            for b in bins where !p.contains(b) { p.append(b) }
        }
        var rules = p.map { "Bash(\($0):*)" }
        if !t.isAnswerTask {
            for r in verifyRules(t.verifyCmd) where !rules.contains(r) { rules.append(r) }
        }
        return rules
    }

    static func splitSegments(_ cmd: String) -> [String] {
        cmd.replacingOccurrences(of: "&&", with: "\n").replacingOccurrences(of: "||", with: "\n")
            .replacingOccurrences(of: ";", with: "\n").replacingOccurrences(of: "|", with: "\n")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Words of one simple command with redirections (`> f`, `2>&1`, `< f`) and a leading `!` removed.
    static func words(_ seg: String) -> [String] {
        var out: [String] = []
        var skipNext = false
        for w in seg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            if skipNext { skipNext = false; continue }
            if w == "!" { continue }
            if w == ">" || w == ">>" || w == "<" || w == "2>" || w == "&>" { skipNext = true; continue }
            if w.hasPrefix(">") || w.hasPrefix("2>") || w.hasPrefix("&>") || w.hasPrefix("<") { continue }
            out.append(w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
        }
        return out
    }

    /// Exact-prefix rules for the verify command: leading env assignments + program (+ `-m module`
    /// or the go subcommand), each also without the env assignments. Path-scoped (absolute interpreter), no blanket allow.
    public static func verifyRules(_ cmd: String?) -> [String] {
        guard let cmd else { return [] }
        var rules: [String] = []
        func add(_ r: String) { let x = "Bash(\(r):*)"; if !rules.contains(x) { rules.append(x) } }
        for seg in splitSegments(cmd) {
            let w = words(seg)
            guard let pi = w.firstIndex(where: { !($0.contains("=") && !$0.hasPrefix("/") && !$0.hasPrefix("-")) }) else { continue }
            let env = Array(w[0..<pi]), prog = w[pi]
            if neverAllowed.contains(prog) || shellWords.contains(prog) { continue }
            var tail: [String] = []
            let rest = Array(w[(pi + 1)...])
            if rest.count >= 2, rest[0] == "-m" { tail = ["-m", rest[1]] }
            else if (prog == "go" || prog.hasSuffix("/go")), let sub = rest.first, !sub.hasPrefix("-") { tail = [sub] }
            add(([prog] + tail).joined(separator: " "))
            if !env.isEmpty { add((env + [prog] + tail).joined(separator: " ")) }
        }
        return rules
    }

    /// Approximates Claude's Bash rule matching (every simple command of a compound must match a `prefix:*` rule),
    /// used to test that the rules admit the verify forms.
    public static func permits(_ command: String, rules: [String]) -> Bool {
        let prefixes = rules.compactMap { r -> String? in
            guard r.hasPrefix("Bash("), r.hasSuffix(":*)") else { return nil }
            return String(r.dropFirst(5).dropLast(3))
        }
        return splitSegments(command).allSatisfy { seg in
            let joined = words(seg).joined(separator: " ")
            return prefixes.contains { joined == $0 || joined.hasPrefix($0 + " ") }
        }
    }

    /// Always denied, on top of the allow list.
    public static let denied = ["Bash(rm -rf:*)", "Bash(rm -fr:*)", "Bash(rm -r:*)", "Bash(curl:*)", "Bash(wget:*)", "Bash(ssh:*)",
                                "Bash(scp:*)", "Bash(sudo:*)", "Bash(nc:*)", "Bash(git push:*)", "Bash(git remote:*)", "Bash(git config:*)"]
}

/// Roots that must never be made readable to a sandbox: `/`, `/Users`, `/Volumes`, the home and any ancestor of it.
public enum ReadableRoots {
    public static func isForbidden(_ root: String, home: String = NSHomeDirectory()) -> Bool {
        let r = (root as NSString).standardizingPath
        if r.isEmpty || ["/", "/Users", "/Volumes", "/private", "/opt", "/usr"].contains(r) { return true }
        for h in [home, (try? FileManager.default.destinationOfSymbolicLink(atPath: home)) ?? home] {
            let hs = (h as NSString).standardizingPath
            if r == hs || hs.hasPrefix(r + "/") { return true }
        }
        return false
    }
}
