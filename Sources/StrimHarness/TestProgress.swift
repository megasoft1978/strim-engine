import Foundation

/// Recognition only, not an execution allowlist. Reuse the shell tokenizer used by the existing tool guard.
enum TestCommand {
    static func isTest(_ command: String, verify: String? = nil, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }
        var verifyWords = verify.map { ToolchainGuard.simpleCommands($0).map { $0.map(\.text) } } ?? []
        // Setup/output-filter commands in a compound verify command are not themselves verification.
        let ancillary: Set<String> = ["cd", "export", "set", "head", "tail", "grep", "sed", "awk", "tee", "sort", "wc", "echo", "printf"]
        while verifyWords.count > 1, let last = verifyWords.last?.first,
              ancillary.contains((last as NSString).lastPathComponent) { verifyWords.removeLast() }
        verifyWords = Array(verifyWords.suffix(1))
        for input in ToolchainGuard.simpleCommands(command) {
            var w = input.map(\.text)
            if !w.isEmpty, verifyWords.contains(where: { !$0.isEmpty && w.starts(with: $0) }) { return true }
            while let f = w.first {
                if f.range(of: #"^[A-Za-z_][A-Za-z_0-9]*="#, options: .regularExpression) != nil { w.removeFirst(); continue }
                let base = (f as NSString).lastPathComponent
                guard ToolchainGuard.wrappers.contains(base) else { break }
                w.removeFirst()
                while let n = w.first, n.hasPrefix("-") || ((base == "timeout" || base == "nice") && n.first?.isNumber == true) { w.removeFirst() }
            }
            guard let first = w.first else { continue }
            let prog = (first as NSString).lastPathComponent
            let args = Array(w.dropFirst())
            if ToolchainGuard.shells.contains(prog), let i = args.firstIndex(where: { $0.range(of: #"^-[a-z]*c$"#, options: .regularExpression) != nil }), i + 1 < args.count {
                if isTest(args[i + 1], verify: verify, depth: depth + 1) { return true }
            }
            if ["go", "bun", "cargo", "swift", "deno", "npm"].contains(prog) {
                // Do not mistake `go run test` or `cargo build --test ...` for a test subcommand.
                let subcommand = args.first { !$0.hasPrefix("-") && !$0.hasPrefix("+") }
                if subcommand == "test" { return true }
            }
            if prog == "node", args.contains("--test") || args.contains(where: { $0.hasPrefix("--test=") }) { return true }
            if prog == "pytest" || prog.hasPrefix("pytest-") || prog == "tsc" { return true }
            if prog.hasPrefix("python"), args.contains("pytest") || args.contains("unittest") { return true }
            if prog == "rake", args.isEmpty || args.contains(where: { $0 == "test" || $0.hasPrefix("test:") }) { return true }
            if prog == "ruby", args.contains(where: { $0.hasSuffix(".rb") && ($0.contains("test") || $0.contains("spec")) }) { return true }
            if prog == "javatest.sh" || (ToolchainGuard.shells.contains(prog) && args.contains(where: { ($0 as NSString).lastPathComponent == "javatest.sh" })) { return true }
        }
        return false
    }
}

/// Compact runner-independent evidence. Raw locations are useful in the digest, but excluded from signatures.
struct TestEvidence {
    var names: [String] = []
    var assertions: [String] = []
    var locations: [String] = []
    var passed: Int?
    var failed: Int?
    var exit: Int32

    private static func captures(_ text: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    private static func replace(_ s: String, _ pattern: String, _ replacement: String = "") -> String {
        s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    static func normalize(_ line: String) -> String {
        var s = replace(line, #"(?<![\w./\\-])(?:[A-Za-z]:)?[/\\]?(?:[\w.\-]+[/\\])*[\w.\-]+\.(?:go|[cm]?[jt]sx?|rs|swift|py|rb|java|sh):\d+(?::\d+)?"#, "<location>")
        s = FailureFeedback.normalized(s)
        // Strip timing annotations entirely and all file locations (including relative and Windows paths).
        s = replace(s, #"[\[(][^\])]*<duration>[^\])]*[\])]"#)
        s = replace(s, #"\b(?:after|in|took) <duration>\.?"#)
        s = replace(s, #"(?<![A-Za-z0-9_])(?:[A-Za-z]:)?(?:[/\\]|\.?\.?[/\\])[^\s'\"()]+"#, "<path>")
        s = replace(s, #"(?<![\w./\\-])(?:[\w.\-]+[/\\])*[\w.\-]+\.(?:go|[cm]?[jt]sx?|rs|swift|py|rb|java|sh):\d+(?::\d+)?"#, "<location>")
        s = replace(s, #"<tmp>(?::\d+){0,2}"#, "<location>")
        s = replace(s, #"\s+"#, " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(output: String, exit: Int32) {
        self.exit = exit
        // Tool output is already bounded at 64 KiB. Also bound custom tools and individual diagnostic lines.
        let lines = String(output.prefix(256 * 1024)).components(separatedBy: .newlines)
        var nameSet: Set<String> = [], assertionSet: Set<String> = [], locationSet: Set<String> = []
        var observedPass = 0
        for raw in lines {
            let line = Self.replace(String(raw.prefix(1200)), #"\x1B\[[0-?]*[ -/]*[@-~]"#).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("--- PASS:") { observedPass += 1 }
            let namePatterns = [
                #"--- FAIL:\s*(\S+)"#,
                #"^not ok\s+\d+\s*-?\s*(.+?)(?:\s+#.*)?$"#,
                #"^test\s+(.+?)\s+\.\.\.\s+FAILED"#,
                #"^Test Case\s+'(.+?)'\s+failed"#,
                #"^[✘✖✗×]\s*(?:Test\s+)?(.+?)(?:\s+(?:failed|\[))"#,
                #"^\(fail\)\s+(.+)$"#,
                #"^FAILED\s+(\S+)"#,
            ]
            for pattern in namePatterns {
                if let name = Self.captures(line, pattern)?.first {
                    let n = Self.normalize(name)
                    if nameSet.insert(n).inserted, names.count < 16 { names.append(n) }
                    break
                }
            }
            if let c = Self.captures(line, #"(\d+)\s+(?:tests?\s+)?passed\b.*?(\d+)\s+(?:tests?\s+)?failed\b"#) {
                passed = Int(c[0]); failed = Int(c[1])
            } else if let c = Self.captures(line, #"(\d+)\s+passed;\s*(\d+)\s+failed"#) {
                passed = Int(c[0]); failed = Int(c[1])
            }
            if let c = Self.captures(line, #"^(?:#\s*)?(?:pass|tests passed)\s+(\d+)\b"#) { passed = Int(c[0]) }
            if let c = Self.captures(line, #"^(?:#\s*)?(?:fail|tests failed)\s+(\d+)\b"#) { failed = Int(c[0]) }
            if let c = Self.captures(line, #"^(\d+)\s+pass\b"#) { passed = Int(c[0]) }
            if let c = Self.captures(line, #"^(\d+)\s+fail\b"#) { failed = Int(c[0]) }
            if let c = Self.captures(line, #"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?"#), let total = Int(c[0]), let failures = Int(c[1]) {
                failed = failures; passed = max(0, total - failures)
            }
            if let c = Self.captures(line, #"(\d+)\s+failures?,\s*(\d+)\s+errors?"#) { failed = (Int(c[0]) ?? 0) + (Int(c[1]) ?? 0) }
            if let c = Self.captures(line, #"(?<![\w./\\-])((?:[A-Za-z]:)?[\w./\\-]+\.(?:go|[cm]?[jt]sx?|rs|swift|py|rb|java|sh):\d+(?::\d+)?)"#)?.first,
               locationSet.insert(c).inserted, locations.count < 8 { locations.append(c) }
            if line.range(of: #"(?i)(assert\w*|XCTAssert\w*|expected\b|actual\b|received\b|\bgot\b.*\bwant\b|\berror(?:\[|:)|undefined:|cannot find|too many arguments|left:|right:|failure/error:)"#, options: .regularExpression) != nil {
                let n = Self.normalize(line)
                if assertionSet.insert(n).inserted, assertions.count < 12 { assertions.append(n) }
            }
        }
        if passed == nil, observedPass > 0 { passed = observedPass }
        if failed == nil, !names.isEmpty { failed = names.count }
    }

    var isFailure: Bool {
        if exit != 0 || (failed ?? 0) > 0 || !names.isEmpty { return true }
        // Plain mode can mask a compiler/assertion failure behind a successful output filter.
        return failed == nil && assertions.contains {
            $0.range(of: #"(?i)(\berror(?:\[|:)|AssertionError|undefined:|XCTAssert.*failed|assertion.*failed|too many arguments|cannot find)"#, options: .regularExpression) != nil
        }
    }
    var signature: String {
        let evidence = names.sorted() + assertions.sorted()
        // Exit-only failures can still recur when a pipe has discarded all diagnostics.
        return evidence.isEmpty ? "test exit \(exit); failures \(failed.map(String.init) ?? "unknown") (no assertion captured)" : evidence.joined(separator: " | ")
    }
    var digest: String {
        var lines = ["[test status] exit code: \(exit) (pipefail)"]
        if passed != nil || failed != nil { lines.append("pass: \(passed.map(String.init) ?? "?"); fail: \(failed.map(String.init) ?? "?")") }
        if !names.isEmpty { lines.append("failing: " + names.joined(separator: ", ")) }
        lines += assertions
        if !locations.isEmpty { lines.append("refs: " + locations.joined(separator: ", ")) }
        return String(decoding: Array(lines.joined(separator: "\n").utf8.prefix(1500)), as: UTF8.self)
    }
}

/// Per-job progress. An edit, a passing run or changed evidence resets the unchanged-failure streak.
struct TestProgress {
    private(set) var editedSinceTest = false
    private(set) var unchangedFailures = 0
    private var lastFailure: String?
    private var lastSource: String?
    private var pendingThinking = false

    mutating func edited() { editedSinceTest = true }
    mutating func read(path: String) { if Self.isSource(path) { lastSource = path } }
    mutating func stallNudged() { pendingThinking = true }
    mutating func takeThinkingTurn() -> Bool {
        defer { pendingThinking = false }
        return pendingThinking
    }
    static func isSource(_ path: String) -> Bool {
        let p = path.lowercased()
        let components = p.split(separator: "/")
        let file = (p as NSString).lastPathComponent
        let isTest = components.contains { ["test", "tests", "spec", "specs", "__tests__"].contains($0) }
            || file.contains("_test.") || file.contains(".test.") || file.contains(".spec.") || file.hasSuffix("tests.swift")
        return !isTest && ["swift", "go", "js", "jsx", "ts", "tsx", "rs", "py", "rb", "java", "c", "cpp", "h"].contains((p as NSString).pathExtension)
    }
    struct Decision { var note: String?; var blocked: String? }
    mutating func record(_ evidence: TestEvidence, gate: Bool, sourcePaths: [String]) -> Decision {
        defer { editedSinceTest = false }
        guard evidence.isFailure else { lastFailure = nil; unchangedFailures = 0; return Decision() }
        if lastFailure == evidence.signature && !editedSinceTest { unchangedFailures += 1 }
        else { unchangedFailures = 1 }
        lastFailure = evidence.signature
        if unchangedFailures == 2 { pendingThinking = true }
        guard gate else { return Decision() }
        let source = lastSource ?? sourcePaths.first(where: Self.isSource)
        let target = source.map { "source file \($0)" } ?? "a specific source file (locate the symbol exercised by the failing test)"
        let unchanged = Compaction.sanitize(evidence.signature, max: 400)
        if unchangedFailures >= 3 {
            return Decision(blocked: "blocked: three identical failing test runs without an edit. Unchanged evidence: \(unchanged). Read and edit \(target) before retrying.")
        }
        if unchangedFailures == 2 {
            return Decision(note: "[harness progress gate] Unchanged evidence: \(unchanged). Two identical failures with no edit. State failing assertion → source file/symbol → intended change; read and edit \(target) now, or call finish(status: failed) with a blocked summary.")
        }
        return Decision(note: "[harness progress gate] Test failed. State failing assertion → source file/symbol → intended change, then read/edit that source before running the suite again.")
    }
}

/// Best-effort, bounded metadata snapshots of tracked files; no subprocess per test and no file content reads.
/// This is progress evidence only. Missing git, large repos and symlinks simply disable shell-edit detection.
struct TrackedFileSnapshot {
    let root: String
    let paths: [String]
    static func load(root: String) async -> Self {
        guard FileManager.default.fileExists(atPath: root + "/.git"), let git = try? GitWorktreeIsolation.gitExecutable(),
              let result = try? await GitWorktreeIsolation.exec(git, GitWorktreeIsolation.hardening + ["ls-files", "-z"],
                cwd: root, env: GitWorktreeIsolation.env, timeout: 2, maxOut: 1024 * 1024), result.status == 0 else {
            return Self(root: root, paths: [])
        }
        let paths = String(decoding: result.out, as: UTF8.self).split(separator: "\0").map(String.init)
        return Self(root: root, paths: paths.count <= 2_000 ? paths.filter { !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") } : [])
    }
    func capture() -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        for p in paths {
            let full = root + "/" + p
            // Never follow a workspace symlink out to the host.
            guard URL(fileURLWithPath: full).resolvingSymlinksInPath().path.hasPrefix(realRoot + "/"),
                  let a = try? fm.attributesOfItem(atPath: full), a[.type] as? FileAttributeType == .typeRegular else { continue }
            result[p] = "\(a[.size] ?? 0):\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(a[.systemFileNumber] ?? 0)"
        }
        return result
    }
}
