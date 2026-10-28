import Foundation

/// Refuses to apply a patch to a repository whose config or attributes could make git run something.
/// This does not rest on a denylist alone: `git apply` (no `--3way`, `--index`, `--cached`) runs no filters, drivers
/// or hooks, git runs with a scrubbed environment and command-line overrides, and this scan is defense in depth over
/// every file git could read: `.git/config`, `config.worktree`, `info/attributes`, every tracked `.gitattributes`,
/// and the effective (include-resolved) configuration as git itself reports it.
enum RepoSafety {
    static let riskySections: Set<String> = ["filter", "merge", "diff", "include", "includeif", "url", "protocol"]
    static let riskyCoreKeys: Set<String> = ["fsmonitor", "hookspath", "sshcommand", "pager", "editor", "askpass", "attributesfile", "excludesfile"]
    static let attributeNeedles = ["filter=", "merge=", "diff=", "textconv"]

    static func refuse(_ why: String) -> ControlError {
        ControlError(400, "risky_repo_config", "refusing to apply: \(why); apply the patch by hand")
    }

    /// Risky entries of one config file (minimal parser: section headers and `key =` lines).
    static func riskyKeys(inConfig text: String) -> [String] {
        var out: [String] = []
        var section = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let inner = line.dropFirst().prefix { $0 != "]" }
                let name = inner.prefix { $0 != " " && $0 != "\t" && $0 != "\"" && $0 != "." }.lowercased()
                section = name
                if riskySections.contains(name) { out.append(String(inner)) }
                // `[core] key = v` on one line
                if let close = line.firstIndex(of: "]"), line.index(after: close) < line.endIndex {
                    let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    let key = rest.prefix { $0 != "=" && $0 != " " }.lowercased()
                    if (section == "core" && riskyCoreKeys.contains(key)) || (section == "extensions" && key == "worktreeconfig") { out.append("\(section).\(key)") }
                }
                continue
            }
            let key = line.prefix { $0 != "=" && $0 != " " && $0 != "\t" }.lowercased()
            if section == "core", riskyCoreKeys.contains(key) { out.append("core.\(key)") }
            if section == "extensions", key == "worktreeconfig" { out.append("extensions.worktreeConfig") }
        }
        return out
    }

    static func riskyAttributes(_ text: String) -> Bool {
        let t = text.lowercased()
        return attributeNeedles.contains { t.contains($0) }
    }

    /// Throws `risky_repo_config` for anything suspicious. `top` is the work tree root.
    static func check(top: String, timeout: TimeInterval) async throws {
        // Where git keeps things (works for linked worktrees too).
        let dirs = try await Git.run(["rev-parse", "--path-format=absolute", "--absolute-git-dir", "--git-common-dir"],
                                     cwd: top, stdin: nil, timeout: timeout)
        let lines = dirs.out.split(separator: "\n").map(String.init)
        guard dirs.status == 0, lines.count >= 2 else { throw refuse("cannot locate the git directory") }
        let gitDir = lines[0], common = lines[1]
        let fm = FileManager.default

        for dir in Set([gitDir, common]) {
            if fm.fileExists(atPath: dir + "/config.worktree") { throw refuse("the repository has a config.worktree") }
            if let a = try? String(contentsOfFile: dir + "/info/attributes", encoding: .utf8),
               !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw refuse("the repository has .git/info/attributes")
            }
        }
        for file in Set([common + "/config", gitDir + "/config"]) {
            if let text = try? String(contentsOfFile: file, encoding: .utf8) {
                let keys = riskyKeys(inConfig: text)
                if !keys.isEmpty { throw refuse("\((file as NSString).lastPathComponent) sets \(keys.prefix(5).joined(separator: ", "))") }
            }
        }

        // What git effectively sees (includes resolved), ignoring our own command-line overrides.
        let eff = try await Git.run(["config", "--show-scope", "--list"], cwd: top, stdin: nil, timeout: timeout)
        if eff.status == 0 {
            var keys: [String] = []
            for l in eff.out.split(separator: "\n") {
                let parts = l.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, parts[0] != "command" else { continue }
                let key = parts[1].prefix { $0 != "=" }.lowercased()
                let sec = key.prefix { $0 != "." }
                if riskySections.contains(String(sec)) || (sec == "core" && riskyCoreKeys.contains(String(key.split(separator: ".").last ?? "")))
                    || key == "extensions.worktreeconfig" { keys.append(String(key)) }
            }
            if !keys.isEmpty { throw refuse("the effective git configuration sets \(keys.prefix(5).joined(separator: ", "))") }
        }

        // Every tracked .gitattributes (any directory).
        let tracked = try await Git.run(["ls-files", "-z", "--", ".gitattributes", "*/.gitattributes"], cwd: top, stdin: nil, timeout: timeout)
        var attrFiles = Set(tracked.out.split(separator: "\0").map { top + "/" + $0 })
        attrFiles.insert(top + "/.gitattributes")
        for f in attrFiles {
            if let t = try? String(contentsOfFile: f, encoding: .utf8), riskyAttributes(t) {
                throw refuse("\((f.dropFirst(top.count + 1)).description) assigns filter/merge/diff/textconv attributes")
            }
        }
    }
}
