import Foundation

/// Strict argv grammar for the host-side `runtests` service. Each runner has a whitelist of flags (anything else is refused),
/// positional arguments are relative paths inside the worktree or plain test-name filters, and nothing that fetches, evals
/// or names another program is expressible: no `-e/-p/--eval`, `--require/--import/-r`, `--config`, `npm install`,
/// `npx <remote package>`, `go run`, `cargo run`, absolute paths or `..`. The runner still executes worktree code (the tests),
/// which is why it only ever runs inside the no-network, credential-free verify sandbox.
public enum RunTestsGrammar {
    /// Rejects absolute paths and `..` components (shared with `Verifier.safeRel`).
    public static func safeRel(_ p: String) -> String? {
        let t = p.hasSuffix("/") ? String(p.dropLast()) : p
        guard !t.isEmpty, !t.hasPrefix("/"), !t.split(separator: "/").contains("..") else { return nil }
        return t
    }

    struct Rule: Sendable {
        var subs: Set<String> = []                 // allowed args[1] ("" = none, flags start at args[1])
        var flags: Set<String> = []                // no value
        var valueFlags: Set<String> = []           // value inline (--f=v) or as the next argument
        var attached: [String] = []                // attached-value short flags, e.g. -Ilib
        var required: Set<String> = []             // must appear
        var positional: @Sendable (String) -> Bool = { _ in false }
        var stopAtFirstPositional = false          // everything after the first positional goes to `trailing`
        var trailing: @Sendable (String) -> Bool = { _ in false }
        var passthrough: @Sendable (String) -> Bool = { _ in false }  // after a bare `--`
        var valueOK: @Sendable (String, String) -> Bool = { _, v in !v.isEmpty && !v.contains("\0") }
    }

    static func relPath(_ s: String) -> Bool { !s.hasPrefix("-") && safeRel(s) != nil && !s.contains("~") && !s.contains(":") && !s.contains("$") && !s.contains("`") && !s.contains("\\") }
    static func safeText(_ s: String) -> Bool {
        s.range(of: "^[-A-Za-z0-9_./:=,+@ ]*$", options: .regularExpression) != nil
    }
    static func ident(_ s: String) -> Bool { s.range(of: "^[A-Za-z0-9_:.]+$", options: .regularExpression) != nil }
    static func number(_ s: String) -> Bool { s.range(of: "^[0-9]{1,6}$", options: .regularExpression) != nil }

    static let rules: [String: Rule] = {
        var node = Rule(subs: ["--test"])
        node.flags = ["--experimental-strip-types", "--no-warnings", "--test-only", "--no-experimental-strip-types"]
        node.valueFlags = ["--test-name-pattern", "--test-reporter", "--test-timeout", "--test-concurrency"]
        node.positional = relPath
        node.valueOK = { f, v in
            if f == "--test-reporter" { return ["spec", "tap", "dot"].contains(v) }
            if f == "--test-timeout" || f == "--test-concurrency" { return number(v) }
            return !v.isEmpty && !v.contains("\0")
        }
        var bun = Rule(subs: ["test"])
        bun.flags = ["--bail", "--only"]
        bun.valueFlags = ["--timeout", "-t", "--test-name-pattern"]
        bun.positional = relPath
        bun.valueOK = { f, v in f == "--timeout" ? number(v) : (!v.isEmpty && !v.contains("\0")) }
        var deno = Rule(subs: ["test"])
        deno.flags = ["--no-check", "--no-remote", "--no-lock", "--quiet", "-q", "--fail-fast", "--allow-read=.", "--allow-write=."]
        deno.valueFlags = ["--filter", "--reporter"]
        deno.positional = relPath
        deno.valueOK = { f, v in f == "--reporter" ? ["pretty", "dot", "tap"].contains(v) : (!v.isEmpty && !v.contains("\0")) }
        var cargo = Rule(subs: ["test", "build", "check"])
        cargo.flags = ["--offline", "--quiet", "-q", "--lib", "--bins", "--tests", "--all-targets", "--release", "--no-fail-fast", "--locked", "--frozen",
                       "--workspace", "--all", "--no-run", "--doc", "--examples"]
        cargo.valueFlags = ["-p", "--package", "--test", "--bin", "--features", "--jobs", "-j", "--manifest-path"]
        cargo.required = ["--offline"]
        cargo.positional = ident
        cargo.passthrough = { a in
            ["--nocapture", "--show-output", "--exact", "--ignored", "--include-ignored", "--quiet", "-q", "--list"].contains(a)
                || a.range(of: "^--test-threads=[0-9]{1,3}$", options: .regularExpression) != nil || ident(a)
        }
        cargo.valueOK = { f, v in
            switch f {
            case "--manifest-path": return relPath(v) && v.hasSuffix("Cargo.toml")
            case "--jobs", "-j": return number(v)
            default: return ident(v) || v.range(of: "^[A-Za-z0-9_,-]+$", options: .regularExpression) != nil
            }
        }
        var ruby = Rule(subs: [""])
        ruby.flags = ["-w", "-W0", "-W1", "-W2"]
        ruby.valueFlags = ["-I"]
        ruby.attached = ["-I"]
        ruby.positional = { relPath($0) && $0.hasSuffix(".rb") }
        ruby.stopAtFirstPositional = true
        ruby.trailing = { a in
            ["-n", "--name", "-v", "--verbose", "-s", "--seed", "-p", "--pride"].contains(a) || (!a.hasPrefix("-") && safeText(a)) || a.range(of: "^--(name|seed)=[A-Za-z0-9_/.:-]+$", options: .regularExpression) != nil
        }
        ruby.valueOK = { _, v in relPath(v) }
        var tsc = Rule(subs: [""])
        tsc.flags = ["--noEmit", "--strict", "--skipLibCheck"]
        tsc.valueFlags = ["-p", "--project"]
        tsc.required = ["--noEmit"]
        tsc.valueOK = { _, v in relPath(v) }
        var npm = Rule(subs: ["test", "run"])
        npm.flags = ["--silent", "-s", "--offline"]
        npm.positional = { $0.range(of: "^[A-Za-z][A-Za-z0-9:_-]*$", options: .regularExpression) != nil }
        var npx = Rule(subs: ["--no-install"])
        npx.positional = { $0.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil }
        npx.stopAtFirstPositional = true
        npx.trailing = safeText
        let py = Rule(subs: [""])   // validated by validatePython
        var java = Rule(subs: [""])       // `runtests javatest [ClassName]`: fixed host-defined runner script
        java.positional = ident
        return ["node": node, "bun": bun, "deno": deno, "cargo": cargo, "ruby": ruby, "tsc": tsc, "npm": npm, "npx": npx, "javatest": java, "python3": py]
    }()

    /// True for a program the table covers (node, bun, deno, cargo, ruby, tsc, npm, npx, javatest, python3).
    public static func covers(_ prog: String) -> Bool { rules[prog] != nil }

    /// nil when `args` (program first) is allowed by the table; go and swift are handled by the caller.
    public static func validate(_ args: [String]) -> String? {
        guard let rule = rules[args[0]] else { return "not an allowed runner" }
        if args[0] == "python3" { return validatePython(args) }
        var i = 1
        if !rule.subs.contains("") {
            guard args.count > 1, rule.subs.contains(args[1]) else { return "\(args[0]): only \(rule.subs.sorted().joined(separator: "|")) is allowed" }
            i = 2
        }
        if args[0] == "npm", args.count > 1, args[1] == "run" {
            let rest = args.dropFirst(2).filter { !$0.hasPrefix("-") }
            guard rest.count == 1 else { return "npm run needs exactly one script name" }
        }
        if args[0] == "npm", args.count > 1, args[1] == "test", args.dropFirst(2).contains(where: { !rule.flags.contains($0) }) { return "npm test takes no arguments" }
        var seen = Set<String>()
        var positionals = 0
        while i < args.count {
            let a = args[i]; i += 1
            if a == "--" {
                guard !rule.passthrough("x") || args[0] == "cargo" else { return "`--` not allowed" }
                for r in args[i...] where !rule.passthrough(r) { return "argument \(r) not allowed after --" }
                return rule.required.isSubset(of: seen) ? nil : "missing \(rule.required.subtracting(seen).sorted().joined(separator: ", "))"
            }
            if a.hasPrefix("-") {
                if let p = rule.attached.first(where: { a.hasPrefix($0) && a.count > $0.count }) {
                    let v = String(a.dropFirst(p.count))
                    guard rule.valueOK(p, v) else { return "bad value for \(p)" }
                    continue
                }
                let name: String, inline: String?
                if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") { name = String(a[..<eq]); inline = String(a[a.index(after: eq)...]) } else { name = a; inline = nil }
                if rule.flags.contains(a) { seen.insert(a); continue }
                guard rule.valueFlags.contains(name) else { return "flag \(name) is not allowed for \(args[0])" }
                var v = inline
                if v == nil { guard i < args.count else { return "\(name) needs a value" }; v = args[i]; i += 1 }
                guard rule.valueOK(name, v!) else { return "bad value for \(name)" }
                seen.insert(name)
                continue
            }
            guard rule.positional(a) else { return "argument \(a) is not allowed for \(args[0])" }
            positionals += 1
            if rule.stopAtFirstPositional {
                for r in args[i...] where !rule.trailing(r) { return "argument \(r) is not allowed" }
                if args[0] == "npx", args.count > i { /* script args are charset-limited above */ }
                i = args.count
            }
        }
        if args[0] == "ruby" && positionals == 0 { return "ruby: a relative test script path (.rb) is required" }
        if args[0] == "npx" && positionals == 0 { return "npx: a local binary name is required" }
        if args[0] == "javatest" && positionals > 1 { return "javatest takes at most one class name" }
        return rule.required.isSubset(of: seen) ? nil : "missing \(rule.required.subtracting(seen).sorted().joined(separator: ", "))"
    }

    /// `python3 -I [-B] -m unittest [discover] [-s dir] [-t dir] [-p pattern] [-v|-q|-b|-f] [-k pattern] [dotted.test.names]`.
    /// -I (isolated) is mandatory: no PYTHON* variables, no user site, no implicit cwd on sys.path. No -c, no scripts, no other modules.
    static func validatePython(_ args: [String]) -> String? {
        var i = 1
        var isolated = false
        while i < args.count, args[i] != "-m" {
            switch args[i] {
            case "-I": isolated = true
            case "-B": break
            default: return "python3: flag \(args[i]) is not allowed before -m"
            }
            i += 1
        }
        guard isolated else { return "python3: -I (isolated mode) is required" }
        guard i + 1 < args.count, args[i] == "-m", args[i + 1] == "unittest" else { return "python3: only -m unittest is allowed" }
        i += 2
        let pat = { (s: String) in s.range(of: "^[A-Za-z0-9_.*?]+$", options: .regularExpression) != nil }
        if i < args.count, args[i] == "discover" { i += 1 }
        while i < args.count {
            let a = args[i]; i += 1
            switch a {
            case "-v", "-q", "-b", "-f", "--verbose", "--quiet", "--buffer", "--failfast", "--locals": continue
            case "-s", "--start-directory", "-t", "--top-level-directory":
                guard i < args.count, relPath(args[i]) || args[i] == "." else { return "python3: bad directory for \(a)" }
                i += 1
            case "-p", "--pattern", "-k":
                guard i < args.count, pat(args[i]) else { return "python3: bad value for \(a)" }
                i += 1
            default:
                guard !a.hasPrefix("-"), ident(a) else { return "python3: argument \(a) is not allowed" }
            }
        }
        return nil
    }

    /// The program argv the host runs for a validated request (`javatest` maps to the fixed repo runner script).
    public static func argv(_ args: [String]) -> [String] {
        if args[0] == "javatest" { return ["/bin/sh", "scripts/javatest.sh"] + args.dropFirst() }
        return args
    }
}
