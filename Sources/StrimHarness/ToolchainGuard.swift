import Foundation

/// Command-line gate for the model's `bash` tool. Language runners (node, bun, deno, cargo, ruby, tsc, npm, npx, python3) may only
/// appear in the forms the paid arms' `runtests` grammar accepts (`RunTestsGrammar`): test runs, never installs, evals, preloads,
/// remote packages, absolute paths or `..`. Programs the grammar refuses outright (pip, gem, bundler, yarn, pnpm, rustup, rustc, mvn,
/// gradle, direct java/javac) are refused too; Java tests go through a repo script such as `sh scripts/javatest.sh`.
///
/// This is a lint on top of the sandbox, not the boundary: the shell can still obscure a program name (`$X`, `eval`, a script file),
/// and the runner executes worktree code. What holds regardless is the job sandbox (no network, no home or credential reads, writes only
/// in the worktree and the per-job tmp), the cleared environment and the offline settings in `Toolchains`. go and swift are not gated.
/// The harness's own verify command is caller-supplied and runs unchecked.
public enum ToolchainGuard {
    static let refusedPrograms: Set<String> = ["pip", "pip3", "pipx", "gem", "bundle", "bundler", "rake", "irb", "yarn", "pnpm", "corepack", "rustup",
                                               "rustc", "mvn", "gradle", "gradlew", "java", "javac", "jar", "uv", "poetry", "conda", "brew", "cargo-install"]
    static let wrappers: Set<String> = ["env", "command", "exec", "time", "nice", "nohup", "xargs", "builtin", "stdbuf", "timeout", "caffeinate"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    struct Word { var text: String; var quoted: Bool }

    /// nil when the command may run, else a one-line reason (what to use instead).
    public static func check(_ command: String, depth: Int = 0) -> String? {
        guard depth < 4 else { return "nested shell commands are too deep" }
        for words in simpleCommands(command) {
            if let why = checkWords(words, depth: depth) { return why }
        }
        return nil
    }

    static func checkWords(_ input: [Word], depth: Int) -> String? {
        var w = input.map(\.text)
        // Leading assignments and wrappers (`FOO=1 env -i nice -n 5 node ...`).
        while let f = w.first {
            if f.contains("="), !f.hasPrefix("="), f.firstIndex(of: "=").map({ !f[..<$0].isEmpty && f[..<$0].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }) == true { w.removeFirst(); continue }
            let base = (f as NSString).lastPathComponent
            if wrappers.contains(base) {
                w.removeFirst()
                while let n = w.first, n.hasPrefix("-") || (base == "nice" || base == "timeout") && n.allSatisfy({ $0.isNumber || $0 == "." || $0 == "s" || $0 == "m" }) { w.removeFirst() }
                continue
            }
            break
        }
        guard let prog0 = w.first else { return nil }
        let base = (prog0 as NSString).lastPathComponent
        let args = Array(w.dropFirst())
        if shells.contains(base) {
            if let i = args.firstIndex(where: { $0.range(of: "^-[a-z]*c$", options: .regularExpression) != nil }), i + 1 < args.count {
                return check(args[i + 1], depth: depth + 1)
            }
            return nil
        }
        if base == "eval" { return check(args.joined(separator: " "), depth: depth + 1) }
        var prog = base
        if prog.hasPrefix("python") { prog = "python3" }   // python, python3, python3.12
        if prog == "javatest" || prog == "runtests" { return "\(base): not a command here" }
        if refusedPrograms.contains(base) {
            let hint = (base == "java" || base == "javac") ? "; run Java tests with the repo script, e.g. `sh scripts/javatest.sh`" : ""
            return "\(base) is not allowed\(hint)"
        }
        guard RunTestsGrammar.covers(prog) else { return nil }
        if let why = RunTestsGrammar.validate([prog] + args) {
            return "\(base) refused: \(why). Allowed: test runs only (node --test, bun test, deno test, cargo test --offline, ruby -Ilib test/x_test.rb, tsc --noEmit, npm test, python3 -I -m unittest)"
        }
        return nil
    }

    /// Splits a command line into simple commands (words with quotes removed, redirections dropped, heredoc bodies skipped).
    /// `$(`, backticks, `;`, `&`, `|`, newlines, parentheses and braces start a new command.
    static func simpleCommands(_ s: String) -> [[Word]] {
        var out: [[Word]] = [], cur: [Word] = [], word = "", has = false, quoted = false
        var skipRedirTarget = false
        var heredocs: [String] = []
        let chars = Array(s)
        var i = 0
        func endWord() {
            guard has else { return }
            has = false
            let t = word; let q = quoted; word = ""; quoted = false
            if skipRedirTarget { skipRedirTarget = false; return }
            if !q, let needsTarget = redirection(t) { skipRedirTarget = needsTarget; return }
            cur.append(Word(text: t, quoted: q))
        }
        func endCommand() { endWord(); skipRedirTarget = false; if !cur.isEmpty { out.append(cur) }; cur = [] }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "'":
                has = true; quoted = true; i += 1
                while i < chars.count, chars[i] != "'" { word.append(chars[i]); i += 1 }
            case "\"":
                has = true; quoted = true; i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 1; word.append(chars[i]) }
                    else if chars[i] == "`" || (chars[i] == "$" && i + 1 < chars.count && chars[i + 1] == "(") {
                        // command substitution inside quotes: its contents are commands of their own
                        let close: Character = chars[i] == "`" ? "`" : ")"
                        var j = i + (close == "`" ? 1 : 2), depth = 1, inner = ""
                        while j < chars.count {
                            if close == ")" { if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1; if depth == 0 { break } } }
                            else if chars[j] == "`" { break }
                            inner.append(chars[j]); j += 1
                        }
                        out.append(contentsOf: simpleCommands(inner)); word += "$X"; i = j
                    } else { word.append(chars[i]) }
                    i += 1
                }
            case "\\":
                has = true
                if i + 1 < chars.count { i += 1; word.append(chars[i]) }
            case " ", "\t": endWord()
            case "#" where !has: while i < chars.count, chars[i] != "\n" { i += 1 }; continue
            case "\n":
                endCommand()
                // skip pending heredoc bodies
                for d in heredocs {
                    i += 1
                    while i < chars.count {
                        var j = i; var line = ""
                        while j < chars.count, chars[j] != "\n" { line.append(chars[j]); j += 1 }
                        i = j + 1
                        if line.trimmingCharacters(in: .whitespaces) == d { break }
                    }
                    i -= 1
                }
                heredocs = []
            case ";", "&", "|", "(", ")", "{", "}":
                if c == "&" || c == ">" || c == "<", has, let l = word.last, l == ">" || l == "<" { word.append(c); break }
                if c == "&" && !has && i > 0 && (chars[i - 1] == ">" || chars[i - 1] == "<") { word.append(c); break }
                endCommand()
            case "`": endCommand()
            case "$" where i + 1 < chars.count && chars[i + 1] == "(": endCommand(); i += 1
            case "<" where i + 1 < chars.count && chars[i + 1] == "<" && !(i + 2 < chars.count && chars[i + 2] == "<"):
                // heredoc: record the delimiter
                endWord()
                var j = i + 2
                if j < chars.count, chars[j] == "-" { j += 1 }
                while j < chars.count, chars[j] == " " { j += 1 }
                var d = ""
                while j < chars.count, !" \t\n;&|<>()".contains(chars[j]) { if chars[j] != "'" && chars[j] != "\"" && chars[j] != "\\" { d.append(chars[j]) }; j += 1 }
                if !d.isEmpty { heredocs.append(d) }
                i = j; continue
            default:
                has = true; word.append(c)
            }
            i += 1
        }
        endCommand()
        return out
    }

    /// `>`, `2>&1`, `>>out`, `<in`: nil for an ordinary word, else whether the operator stands alone and the next word is its file.
    static func redirection(_ t: String) -> Bool? {
        guard let m = t.range(of: "^[0-9]*(>>?|<|>&|<&|&>>?)", options: .regularExpression) else { return nil }
        return m.upperBound == t.endIndex && !t.hasSuffix("&")
    }
}
