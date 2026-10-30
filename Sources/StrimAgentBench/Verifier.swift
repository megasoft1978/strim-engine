import CryptoKit
import Foundation
import StrimHarness

public struct VerifyOutcome: Sendable, Equatable {
    public var success: Bool
    public var testsTampered: Bool
    public var verifyExit: Int32?
    public var note: String
    /// The sandbox could not be applied (missing sandbox-exec, bad profile): nothing was run. Never a task failure.
    public var infra = false
}

public enum Verifier {
    static let skipDirs: Set<String> = [".git", "__pycache__", ".pytest_cache"]
    public static let sandboxExec = "/usr/bin/sandbox-exec"

    /// Harness sandbox for model-influenced code: writes only in `work` and `scratch`, no reads of home or secret
    /// paths (~/.strim, ~/.ssh, ...), all network denied including loopback and unix sockets.
    public static func sandboxProfile(work: URL, scratch: URL, home: String, extraReadable: [String] = []) -> String {
        SandboxProfile(access: .write, writableRoots: [work.path, scratch.path], jobTmp: scratch.path + "/tmp",
                       home: home, extraReadable: (toolchainReadable(home: home) + extraReadable).filter { !ReadableRoots.isForbidden($0, home: home) }).profile
            + listingRules(work: work.path, home: home)
    }

    /// `bun test` lists the directories above its working dir. In a benchmark run those sit inside the denied temp area
    /// (`$TMPDIR/strim-agentbench-<pid>/runs/`), so the read denial makes bun fail with `PermissionDenied`. Grant a directory
    /// listing only (`file-read-data` on the literal path, no file reads) for each ancestor of `work` strictly inside a temp root.
    /// The temp root itself, the home and anything under the home are never listed.
    static func listingRules(work: String, home: String) -> String {
        let tempRoots = ["/tmp", "/var/tmp", NSTemporaryDirectory()].map { p in p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
            .flatMap(ClaudeSandbox.variants)
        let homes = ClaudeSandbox.variants(home)
        var dirs = Set<String>()
        for start in ClaudeSandbox.variants(work) {
            var cur = (start as NSString).deletingLastPathComponent
            while cur != "/" && !cur.isEmpty {
                for a in ClaudeSandbox.variants(cur) where tempRoots.contains(where: { a.hasPrefix($0 + "/") }) &&
                    !homes.contains(where: { a == $0 || a.hasPrefix($0 + "/") }) && !ReadableRoots.isForbidden(a, home: home) {
                    dirs.insert(a)
                }
                cur = (cur as NSString).deletingLastPathComponent
            }
        }
        guard !dirs.isEmpty else { return "" }
        return "(allow file-read-data\n  " + dirs.sorted().map { "(literal \(ClaudeSandbox.quote($0)))" }.joined(separator: "\n  ") + ")\n"
    }

    /// Toolchain dirs under the home that verify commands may need to read (never writable).
    static func toolchainReadable(home: String) -> [String] {
        var out: [String] = []
        out += Toolchains.readable(home: home)
        for d in ["go/pkg/mod", "Library/Caches/org.swift.swiftpm"] {
            let p = home + "/" + d
            if FileManager.default.fileExists(atPath: p) { out.append(p) }
        }
        if let extra = ProcessInfo.processInfo.environment["STRIM_BENCH_READABLE"] {
            out += extra.split(separator: ":").map(String.init).filter { $0.hasPrefix(home + "/") }
        }
        return out
    }

    public static func sha256(file: URL) -> String? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Relative file paths under `tree` (sorted; no symlinks; skips .git, __pycache__, .pytest_cache).
    public static func walk(_ tree: URL) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        func rec(_ dir: URL, _ prefix: String) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for n in names.sorted() {
                let u = dir.appendingPathComponent(n)
                guard let attrs = try? fm.attributesOfItem(atPath: u.path) else { continue }
                let type = attrs[.type] as? FileAttributeType
                if type == .typeSymbolicLink { continue }
                let rel = prefix.isEmpty ? n : prefix + "/" + n
                if type == .typeDirectory {
                    if skipDirs.contains(n) { continue }
                    rec(u, rel)
                } else { out.append(rel) }
            }
        }
        rec(tree, "")
        return out
    }

    public static func treeSha(_ tree: URL) -> String {
        var h = SHA256()
        for r in walk(tree) {
            let s = sha256(file: tree.appendingPathComponent(r)) ?? "unreadable"
            h.update(data: Data((r + "\0" + s + "\n").utf8))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Rejects absolute paths and `..` components.
    public static func safeRel(_ p: String) -> String? { RunTestsGrammar.safeRel(p) }

    /// sha256 of every file at or under each path (file or directory).
    public static func hashPaths(_ tree: URL, _ paths: [String]) -> [String: String] {
        var res: [String: String] = [:]
        for r in walk(tree) where paths.contains(where: { r == $0 || r.hasPrefix($0 + "/") }) {
            res[r] = sha256(file: tree.appendingPathComponent(r))
        }
        return res
    }

    /// Replaces each path in `work` with the base copy (files removed, base files copied back).
    public static func restore(base: URL, work: URL, paths: [String]) throws {
        let fm = FileManager.default
        for p in paths {
            let w = work.appendingPathComponent(p), b = base.appendingPathComponent(p)
            if fm.fileExists(atPath: w.path) || (try? fm.destinationOfSymbolicLink(atPath: w.path)) != nil { try fm.removeItem(at: w) }
            guard fm.fileExists(atPath: b.path) else { continue }
            try fm.createDirectory(at: w.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: b, to: w)
        }
    }

    /// Extracts a tarball or copies a directory snapshot into the empty directory `dst`.
    public static func extractSnapshot(_ src: URL, into dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        fm.fileExists(atPath: src.path, isDirectory: &isDir)
        if isDir.boolValue {
            for n in try fm.contentsOfDirectory(atPath: src.path) {
                try fm.copyItem(at: src.appendingPathComponent(n), to: dst.appendingPathComponent(n))
            }
            return
        }
        let r = Proc.capture(["/usr/bin/tar", "-xzf", src.path, "-C", dst.path], cwd: dst.path, scratch: dst.deletingLastPathComponent())
        guard r.code == 0 else { throw LedgerError.io("tar failed for \(src.lastPathComponent): \(r.text.prefix(200))") }
    }

    static func matches(_ pattern: String, in text: String) -> Bool {
        if let re = try? NSRegularExpression(pattern: pattern, options: []) {
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        return text.contains(pattern)
    }

    public static func answerMatches(_ e: ExpectedAnswer, _ answer: String) -> Bool {
        e.allOf.allSatisfy { matches($0, in: answer) }
            && (e.anyOf.isEmpty || e.anyOf.contains { matches($0, in: answer) })
            && !e.noneOf.contains { matches($0, in: answer) }
    }

    /// Independent post-run check: test_paths hash vs base (edited tests fail), restore, offline verify_cmd,
    /// answer oracle for QA, tree-unchanged for no_edit tasks.
    public static func verify(task: TaskSpec, base: URL, work: URL, answer: String?, scratch: URL,
                              timeout: TimeInterval = 300, home: String = NSHomeDirectory(), sandboxExecPath: String = Verifier.sandboxExec,
                              extraEnv: [String: String] = [:]) -> VerifyOutcome {
        var notes: [String] = []
        var fail = false
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        var paths: [String] = []
        for p in task.testPaths {
            if let s = safeRel(p) { paths.append(s) } else { notes.append("unsafe test_path \(p)"); fail = true }
        }
        let baseHashes = hashPaths(base, paths)
        var tampered = false
        if !paths.isEmpty {
            tampered = hashPaths(work, paths) != baseHashes
            if tampered { notes.append("test_paths modified by the agent"); fail = true }
            for (k, v) in task.testSha256 where baseHashes[k] != v {
                notes.append("snapshot test hash mismatch for \(k)"); fail = true
            }
            do {
                try restore(base: base, work: work, paths: paths)
                if hashPaths(work, paths) != baseHashes { notes.append("restore hash check failed"); fail = true }
            } catch { notes.append("restore error: \(error)"); fail = true }
        }
        if task.noEdit, treeSha(work) != treeSha(base) { notes.append("tree modified in a no-edit task"); fail = true }

        var env = scrubbedEnvironment()
        let tmp = scratch.appendingPathComponent("tmp")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let fakeHome = scratch.appendingPathComponent("home")
        try? FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        let realGoMod = home + "/go/pkg/mod"
        if env["GOMODCACHE"] == nil, FileManager.default.fileExists(atPath: realGoMod) { env["GOMODCACHE"] = realGoMod }
        env["HOME"] = fakeHome.path
        env["TMPDIR"] = tmp.path
        env["GOCACHE"] = scratch.appendingPathComponent("gocache").path
        env["GOPROXY"] = "off"
        env["CI"] = "1"
        Toolchains.apply(to: &env, home: home, scratch: scratch.path)
        for (k, v) in extraEnv { env[k] = v }
        let answerFile = scratch.appendingPathComponent("answer.txt")
        if task.isAnswerTask {
            Proc.writeLog(answerFile.path, Data((answer ?? "").utf8))
            env[task.answerEnv] = answerFile.path
            if answer == nil || answer!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notes.append("no answer"); fail = true
            }
        }
        if let e = task.expectedAnswer, !e.isEmpty, task.isAnswerTask, let a = answer, !answerMatches(e, a) {
            notes.append("answer did not match expected"); fail = true
        }

        var exit: Int32?
        var infra = false
        if let cmd = task.verifyCmd, !cmd.trimmingCharacters(in: .whitespaces).isEmpty {
            // Fail closed: no sandbox, no run.
            let profile = sandboxProfile(work: work, scratch: scratch, home: home)
            let probe = FileManager.default.isExecutableFile(atPath: sandboxExecPath)
                ? Proc.capture([sandboxExecPath, "-p", profile, "/usr/bin/true"], cwd: work.path, env: env, timeout: 30, scratch: scratch) : (code: 127, text: "sandbox-exec missing")
            if probe.code != 0 {
                return VerifyOutcome(success: false, testsTampered: tampered, verifyExit: nil,
                                     note: "infra: verify sandbox unavailable (\(probe.text.prefix(120)))", infra: true)
            }
            let argv = [sandboxExecPath, "-p", profile, "/bin/sh", "-c", cmd]
            // Output goes to host-held anonymous fds: the sandboxed command has no path to re-link and the host never
            // reopens anything under scratch/work after the run.
            if let c = try? Proc.runCaptured(argv: argv, env: env, cwd: work.path, timeout: timeout, maxBytes: 4096, mergeStderr: true) {
                exit = c.result.exitCode
                if c.result.timedOut { notes.append("verify timed out") }
                if c.result.exitCode != 0 {
                    fail = true
                    let tail = String(decoding: c.stdout, as: UTF8.self).suffix(200)
                    notes.append("verify exit \(c.result.exitCode): " + tail.replacingOccurrences(of: "\n", with: " | "))
                }
            } else { infra = true; notes.append("infra: verify could not start"); fail = true }
        } else if !(task.expectedAnswer?.isEmpty == false) {
            notes.append("no oracle"); fail = true
        }
        return VerifyOutcome(success: !fail, testsTampered: tampered, verifyExit: exit, note: notes.joined(separator: "; "), infra: infra)
    }
}
