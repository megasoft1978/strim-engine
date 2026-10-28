import CryptoKit
import Foundation
import StrimAgentBench

/// Post-run verification of a model-edited repo. Order matters: the diff allowlist runs first and nothing executes
/// when it fails; host-owned hidden tests are written next; then the checks. `go test` runs only under the harness
/// sandbox (`Verifier.sandboxProfile`): writes only in the repo and scratch, reads of the home denied, all network
/// denied including loopback. Without a working sandbox-exec nothing runs (fail closed).
public enum SoakVerify {
    public struct Result: Sendable, Equatable {
        public var ok: Bool
        public var detail: String
        /// Whether any executable ran (false for allowlist and infra failures).
        public var ran: Bool
    }

    public struct Env: Sendable {
        /// The real home. The sandbox denies reads under it.
        public var home: String
        public var goBin: String
        public var sandboxExec: String
        /// Test hooks only (planted-code tests pass paths through here); the verify environment is otherwise cleared.
        public var extraEnv: [String: String]
        public var timeout: Double
        /// Host-warmed Go build cache copied into each run's scratch (never written by task code).
        public var cacheSeed: String?

        public init(home: String, goBin: String, sandboxExec: String = Verifier.sandboxExec,
                    extraEnv: [String: String] = [:], timeout: Double = 120, cacheSeed: String? = nil) {
            self.cacheSeed = cacheSeed
            self.home = home; self.goBin = goBin; self.sandboxExec = sandboxExec
            self.extraEnv = extraEnv; self.timeout = timeout
        }
    }

    static let maxFileBytes = 1 << 20

    /// Cleared environment: PATH minimal, every Go and temp location inside scratch.
    public static func verifyEnvironment(scratch: String, extra: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "HOME": scratch + "/home",
            "TMPDIR": scratch + "/tmp",
            "GOCACHE": scratch + "/gocache",
            "GOPATH": scratch + "/gopath",
            "GOTOOLCHAIN": "local", "GOPROXY": "off", "GOFLAGS": "-mod=readonly", "GOTELEMETRY": "off", "CI": "1",
        ]
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Repo-relative paths whose content differs from the task template, plus anything disallowed about the tree.
    /// Empty means the change set is acceptable. Symlinks, special files, oversize files and unexpected files fail.
    public static func allowlistViolations(_ task: SoakTask, repo: String) -> [String] {
        let fm = FileManager.default
        var current: [String: String] = [:]
        var violations: [String] = []
        var templateDirs: Set<String> = []
        for rel in task.files.keys { var d = (rel as NSString).deletingLastPathComponent; while !d.isEmpty { templateDirs.insert(d); d = (d as NSString).deletingLastPathComponent } }
        guard let entries = try? fm.subpathsOfDirectory(atPath: repo) else { return ["repo unreadable"] }
        for rel in entries {
            let full = repo + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: full), let type = attrs[.type] as? FileAttributeType else {
                violations.append("unreadable \(rel)"); continue
            }
            switch type {
            case .typeDirectory:
                // Only template dirs and notes/ may exist; a directory can also shadow a hidden-test path.
                if task.hidden[rel] != nil || !(templateDirs.contains(rel) || rel == "notes" || rel.hasPrefix("notes/")) {
                    violations.append("unexpected directory \(rel)")
                }
                continue
            case .typeRegular:
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                guard size <= maxFileBytes, let data = fm.contents(atPath: full) else {
                    violations.append("oversize or unreadable \(rel)"); continue
                }
                current[rel] = sha256Hex(data)
            case .typeSymbolicLink:
                violations.append("symlink \(rel)")
            default:
                violations.append("special file \(rel)")
            }
        }
        var expected: [String: String] = [:]
        for (rel, text) in task.files { expected[rel] = sha256Hex(Data(text.utf8)) }
        // Any pre-existing entry at a hidden-test path (file, symlink, directory) is a violation: the hidden tests must be ours.
        for rel in task.hidden.keys where current[rel] != nil || fm.fileExists(atPath: repo + "/" + rel) || (try? fm.destinationOfSymbolicLink(atPath: repo + "/" + rel)) != nil {
            violations.append("pre-existing entry at hidden path \(rel)")
        }
        for rel in Set(current.keys).union(expected.keys).sorted() where current[rel] != expected[rel] {
            if task.unchanged.contains(rel) { violations.append("modified unchanged file \(rel)"); continue }
            if task.editable.contains(rel) || (rel.hasPrefix("notes/") && notesAllowed(rel)) { continue }
            violations.append(expected[rel] == nil ? "unexpected file \(rel)" : "modified \(rel)")
        }
        for rel in task.unchanged where expected[rel] == nil {
            violations.append("missing unchanged file \(rel)")
        }
        return violations.sorted()
    }

    /// Notes are plain text only: a `.go`, `.s` or `.c` file there would be compiled by `go test ./...`.
    static func notesAllowed(_ rel: String) -> Bool {
        ["md", "txt", "keep"].contains((rel as NSString).pathExtension.lowercased()) || (rel as NSString).lastPathComponent == ".keep"
    }

    /// Writes the host-owned hidden tests with O_EXCL|O_NOFOLLOW and re-reads them by hash. nil on success, else the reason.
    static func writeHidden(_ task: SoakTask, repo: String) -> String? {
        for (rel, text) in task.hidden.sorted(by: { $0.key < $1.key }) {
            let p = repo + "/" + rel
            let data = Data(text.utf8)
            let fd = open(p, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return "cannot create \(rel): \(String(cString: strerror(errno)))" }
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
            close(fd)
            guard n == data.count else { return "short write to \(rel)" }
        }
        for (rel, text) in task.hidden {
            var st = stat()
            guard lstat(repo + "/" + rel, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  let d = FileManager.default.contents(atPath: repo + "/" + rel),
                  sha256Hex(d) == sha256Hex(Data(text.utf8)) else { return "hidden file \(rel) changed after writing" }
        }
        return nil
    }

    public static func verify(_ task: SoakTask, repo: String, scratch: String, env: Env) -> Result {
        let violations = allowlistViolations(task, repo: repo)
        if !violations.isEmpty {
            return Result(ok: false, detail: "allowlist: " + violations.joined(separator: "; "), ran: false)
        }
        // Nothing has executed yet. Everything below runs only after the allowlist passed.
        let fm = FileManager.default
        if let failure = writeHidden(task, repo: repo) { return Result(ok: false, detail: "hidden: " + failure, ran: false) }
        for d in ["tmp", "home", "gopath"] {
            try? fm.createDirectory(atPath: scratch + "/" + d, withIntermediateDirectories: true)
        }
        if let seed = env.cacheSeed, fm.fileExists(atPath: seed), !fm.fileExists(atPath: scratch + "/gocache") {
            _ = try? Proc.runCaptured(argv: ["/bin/cp", "-Rc", seed, scratch + "/gocache"], env: [:], cwd: "/", timeout: 60, maxBytes: 1024, mergeStderr: true)
        }
        try? fm.createDirectory(atPath: scratch + "/gocache", withIntermediateDirectories: true)
        guard fm.isExecutableFile(atPath: env.sandboxExec), fm.isExecutableFile(atPath: env.goBin) else {
            return Result(ok: false, detail: "infra: sandbox-exec or go missing", ran: false)
        }
        let profile = Verifier.sandboxProfile(work: URL(fileURLWithPath: repo), scratch: URL(fileURLWithPath: scratch),
                                              home: env.home)
        let environment = verifyEnvironment(scratch: scratch, extra: env.extraEnv)
        do {
            let probe = try Proc.runCaptured(argv: [env.sandboxExec, "-p", profile, "/usr/bin/true"], env: environment,
                                             cwd: repo, timeout: 30, maxBytes: 1024, mergeStderr: true)
            if probe.result.exitCode != 0 {
                return Result(ok: false, detail: "infra: sandbox probe rc=\(probe.result.exitCode)", ran: false)
            }
        } catch {
            return Result(ok: false, detail: "infra: sandbox probe could not start", ran: false)
        }

        for (i, check) in task.checks.enumerated() {
            let outcome = run(check, index: i, repo: repo, profile: profile, environment: environment, env: env)
            if let failure = outcome { return Result(ok: false, detail: failure, ran: true) }
        }
        return Result(ok: true, detail: "ok", ran: true)
    }

    /// nil when the check passes, otherwise the failure detail.
    static func run(_ check: SoakCheck, index i: Int, repo: String, profile: String, environment: [String: String],
                    env: Env) -> String? {
        switch check {
        case .goTest:
            do {
                let r = try Proc.runCaptured(argv: [env.sandboxExec, "-p", profile, env.goBin, "test", "./..."],
                                             env: environment, cwd: repo, timeout: env.timeout, maxBytes: 16_000,
                                             mergeStderr: true)
                if r.result.timedOut { return "check \(i) timed out" }
                if r.result.exitCode != 0 { return "check \(i) rc=\(r.result.exitCode)" }
                return nil
            } catch {
                return "check \(i) could not start"
            }
        case .contains(let path, let words):
            guard let text = readText(repo + "/" + path)?.lowercased() else { return "check \(i): \(path) missing" }
            let missing = words.filter { !text.contains($0.lowercased()) }
            return missing.isEmpty ? nil : "check \(i): \(path) lacks \(missing.joined(separator: ", "))"
        case .lines(let path, let expected):
            guard let text = readText(repo + "/" + path) else { return "check \(i): \(path) missing" }
            let got = Set(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            return got == expected ? nil : "check \(i): \(path) lines differ"
        case .absent(let word):
            for rel in (try? FileManager.default.subpathsOfDirectory(atPath: repo)) ?? [] {
                guard let text = readText(repo + "/" + rel) else { continue }
                if text.contains(word) { return "check \(i): \(word) left in \(rel)" }
            }
            return nil
        case .count(let path, let needle, let atMost):
            guard let text = readText(repo + "/" + path) else { return "check \(i): \(path) missing" }
            let n = text.components(separatedBy: needle).count - 1
            return n <= atMost ? nil : "check \(i): \(needle) appears \(n) times in \(path)"
        case .documented(let path):
            guard let text = readText(repo + "/" + path) else { return "check \(i): \(path) missing" }
            let lines = text.components(separatedBy: "\n")
            for (k, line) in lines.enumerated() where isExportedDecl(line) {
                let prev = k > 0 ? lines[k - 1].trimmingCharacters(in: .whitespaces) : ""
                if !prev.hasPrefix("//") { return "check \(i): undocumented \(line.trimmingCharacters(in: .whitespaces))" }
            }
            return nil
        }
    }

    /// Top-level `func Name` / `func (r T) Name` / `type Name` declarations with an exported name.
    static func isExportedDecl(_ line: String) -> Bool {
        let l = line
        if l.hasPrefix("type ") {
            return l.dropFirst(5).first?.isUppercase == true
        }
        guard l.hasPrefix("func ") else { return false }
        var rest = l.dropFirst(5)
        if rest.hasPrefix("(") {
            guard let close = rest.firstIndex(of: ")") else { return false }
            rest = rest[rest.index(after: close)...].drop(while: { $0 == " " })
        }
        return rest.first?.isUppercase == true
    }

    /// Capped read of a regular file; nil when missing or oversized.
    static func readText(_ path: String) -> String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path), (attrs[.type] as? FileAttributeType) == .typeRegular,
              ((attrs[.size] as? NSNumber)?.intValue ?? 0) <= maxFileBytes,
              let data = fm.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension SoakVerify {
    /// Runs the host-owned trivial module once under the same sandbox so later runs can start from a warm Go cache.
    /// Returns the seed dir, or nil when the sandbox or go is unavailable (verify then fails closed on its own).
    public static func warmCache(root: String, env: Env) -> String? {
        let fm = FileManager.default
        let repo = root + "/warm-repo", scratch = root + "/warm-scratch", seed = root + "/gocache-seed"
        let files = ["go.mod": "module warm\n\ngo 1.21\n",
                     "w_test.go": "package warm\n\nimport \"testing\"\n\nfunc TestW(t *testing.T) {}\n"]
        try? fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for (k, v) in files { fm.createFile(atPath: repo + "/" + k, contents: Data(v.utf8)) }
        for d in ["tmp", "home", "gocache", "gopath"] { try? fm.createDirectory(atPath: scratch + "/" + d, withIntermediateDirectories: true) }
        guard fm.isExecutableFile(atPath: env.sandboxExec), fm.isExecutableFile(atPath: env.goBin) else { return nil }
        let profile = Verifier.sandboxProfile(work: URL(fileURLWithPath: repo), scratch: URL(fileURLWithPath: scratch), home: env.home)
        let r = try? Proc.runCaptured(argv: [env.sandboxExec, "-p", profile, env.goBin, "test", "./..."],
                                      env: verifyEnvironment(scratch: scratch), cwd: repo, timeout: 120, maxBytes: 1024, mergeStderr: true)
        guard r?.result.exitCode == 0 else { return nil }
        try? fm.moveItem(atPath: scratch + "/gocache", toPath: seed)
        return fm.fileExists(atPath: seed) ? seed : nil
    }
}
