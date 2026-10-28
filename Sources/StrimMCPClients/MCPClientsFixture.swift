import Foundation
#if canImport(Darwin)
import Darwin
#endif
import StrimAgentBench

/// Toy Go module the clients work in. The bug is the same as the soak fixture's slugify: punctuation survives.
/// Go, not Python: the repo, the verify command (`go test ./...`) and the sandbox all use the Go toolchain.
public enum MCPClientsFixture {
    public static let template: [(path: String, text: String)] = [
        ("go.mod", "module mathkit\n\ngo 1.21\n"),
        ("text.go", #"""
        package mathkit

        import (
            "regexp"
            "strings"
        )

        var spaces = regexp.MustCompile(`\s+`)

        // Slugify lowercases s, trims it and joins whitespace runs with "-".
        func Slugify(s string) string {
            return spaces.ReplaceAllString(strings.ToLower(strings.TrimSpace(s)), "-")
        }

        """#),
        ("text_test.go", #"""
        package mathkit

        import "testing"

        func TestSlugifySpaces(t *testing.T) {
            if got := Slugify("Hello World"); got != "hello-world" {
                t.Fatalf("got %q", got)
            }
        }

        func TestSlugifyPunctuation(t *testing.T) {
            if got := Slugify("  Hello,  World! "); got != "hello-world" {
                t.Fatalf("got %q", got)
            }
        }

        """#),
    ]

    /// The only file the fix may change.
    public static let fixFile = "text.go"
    /// Must stay byte-identical to the template.
    public static let testFile = "text_test.go"
    public static let goBin = "/opt/homebrew/bin/go"

    public static func templateText(_ path: String) -> String? {
        template.first { $0.path == path }?.text
    }

    /// Creates `<root>/soak-XXXXXXXX` with the template committed as `base` (git is only used here, before any client runs).
    public static func makeRepo(in root: URL) throws -> URL {
        let fm = FileManager.default
        let repo = root.appendingPathComponent("soak-" + String(UUID().uuidString.prefix(8)).lowercased())
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        for (path, text) in template {
            guard fm.createFile(atPath: repo.appendingPathComponent(path).path, contents: Data(text.utf8)) else {
                throw MCPClientsError.failed("cannot write \(path)")
            }
        }
        var env = ProcessInfo.processInfo.environment
        for (k, v) in ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@l", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@l"] {
            env[k] = v
        }
        for args in [["init", "-q"], ["add", "-A"], ["commit", "-qm", "base"]] {
            let r = try Proc.runCaptured(argv: ["/usr/bin/git"] + args, env: env, cwd: repo.path, timeout: 60)
            guard r.result.exitCode == 0 else { throw MCPClientsError.failed("git \(args[0]) failed in fixture") }
        }
        return repo
    }

    /// realpath(3): `URL.resolvingSymlinksInPath()` does not turn `/var` into `/private/var`, so comparing against the
    /// enumerator's paths would call every file "outside the repo".
    static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    /// Everything in the repo except `.git` must be the template, with `text.go` as the only permitted change.
    /// Returns violations; empty means the tree is allowed. Directories, links and extra files are violations.
    public static func allowlistViolations(repo: URL) -> [String] {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: realPath(repo.path))
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil, options: []) else {
            return ["cannot list repo"]
        }
        var out: [String] = []
        var seen = Set<String>()
        let known = Set(template.map(\.path))
        for case let u as URL in en {
            guard u.path.hasPrefix(base.path + "/") else { out.append("outside repo \(u.path)"); continue }
            let rel = String(u.path.dropFirst(base.path.count + 1))
            if rel == ".git" { en.skipDescendants(); continue }
            let type = (try? fm.attributesOfItem(atPath: u.path))?[.type] as? FileAttributeType
            if type == .typeSymbolicLink { out.append("symlink \(rel)"); continue }
            if type == .typeDirectory { out.append("directory \(rel)"); continue }
            guard type == .typeRegular else { out.append("special \(rel)"); continue }
            guard known.contains(rel) else { out.append("unexpected file \(rel)"); continue }
            seen.insert(rel)
            if rel != fixFile, (try? Data(contentsOf: u)) != Data((templateText(rel) ?? "").utf8) {
                out.append("modified \(rel)")
            }
        }
        for k in known.sorted() where !seen.contains(k) { out.append("missing \(k)") }
        return out
    }

    public struct CheckResult: Sendable {
        public var ok: Bool
        public var detail: String
        /// Combined stdout and stderr of the verify command (empty when nothing ran).
        public var output: String
        public var ran: Bool
    }

    /// Verify for the fix: allowlist first (nothing executes if it fails), then `go test ./...` under the harness
    /// sandbox: writes only in `repo` and `scratch`, reads of `home` and the real home denied, all network denied
    /// including loopback. The environment is cleared to what the scratch dirs need. Output is host-held.
    /// Fails closed when sandbox-exec or go is missing.
    public static func checkSlugifyFix(repo: URL, scratch: URL, home: String = NSHomeDirectory(),
                                       goPath: String = goBin, sandboxExecPath: String = Verifier.sandboxExec,
                                       timeout: TimeInterval = 120) throws -> CheckResult {
        let violations = allowlistViolations(repo: repo)
        if !violations.isEmpty {
            return CheckResult(ok: false, detail: "allowlist: " + violations.joined(separator: "; "), output: "", ran: false)
        }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: sandboxExecPath), fm.isExecutableFile(atPath: goPath) else {
            return CheckResult(ok: false, detail: "infra: sandbox-exec or go missing", output: "", ran: false)
        }
        for d in ["tmp", "home", "gocache", "gopath"] {
            try fm.createDirectory(at: scratch.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        let env = verifyEnvironment(scratch: scratch)
        let profile = Verifier.sandboxProfile(work: repo, scratch: scratch, home: home)
        let probe = try Proc.runCaptured(argv: [sandboxExecPath, "-p", profile, "/usr/bin/true"], env: env, cwd: repo.path,
                                         timeout: 30, maxBytes: 1024, mergeStderr: true)
        if probe.result.exitCode != 0 {
            return CheckResult(ok: false, detail: "infra: sandbox probe rc=\(probe.result.exitCode)", output: "", ran: false)
        }
        let r = try Proc.runCaptured(argv: [sandboxExecPath, "-p", profile, goPath, "test", "./..."], env: env, cwd: repo.path,
                                     timeout: timeout, maxBytes: 16_000, mergeStderr: true)
        let out = r.text
        if r.result.timedOut { return CheckResult(ok: false, detail: "check 0 timed out", output: out, ran: true) }
        if r.result.exitCode != 0 {
            return CheckResult(ok: false, detail: "check 0 rc=\(r.result.exitCode)", output: out, ran: true)
        }
        return CheckResult(ok: true, detail: "ok", output: out, ran: true)
    }

    /// Cleared environment: nothing inherited except what the Go toolchain needs, all state under `scratch`.
    public static func verifyEnvironment(scratch: URL) -> [String: String] {
        [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "HOME": scratch.appendingPathComponent("home").path,
            "TMPDIR": scratch.appendingPathComponent("tmp").path,
            "GOCACHE": scratch.appendingPathComponent("gocache").path,
            "GOPATH": scratch.appendingPathComponent("gopath").path,
            "GOTOOLCHAIN": "local", "GOPROXY": "off", "GOFLAGS": "-mod=readonly", "GOTELEMETRY": "off", "CI": "1",
        ]
    }
}

public enum MCPClientsError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)

    public var description: String {
        switch self {
        case .usage(let s), .failed(let s): return s
        }
    }
}
