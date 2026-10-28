import Foundation
import Darwin
import StrimEngine
import StrimTemplate

/// Runs one harness job end to end: job dir, workspace isolation, prompt, `AgentLoop`, patch collection,
/// artifacts (`patch.diff`, `result.json`, `events.jsonl`) and cleanup. The parent tree is never written.
public actor HarnessRunner {
    public static let maxInlinePatchBytes = 16 * 1024
    public static let defaultVerifyTimeout: TimeInterval = 120
    public static let maxVerifyCommandChars = 500
    public static var defaultJobsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".strim/jobs")
    }

    let engine: EngineClient
    let isolation: WorkspaceIsolation
    let sandboxed: Bool
    let keepWorkspace: Bool
    let jobsDir: URL
    let now: @Sendable () -> Date
    let priority: Priority
    let verifyTimeout: TimeInterval
    /// nil: read `STRIM_PACK_DIR/knobs.json` at every assemble (the evolve live-pack swap), absent file = defaults.
    let knobsOverride: HarnessKnobs?
    private var kept: [String: Workspace] = [:]
    var chats: [String: ChatSessionState] = [:]

    /// - sandboxed: run `bash` under `sandbox-exec` (false only in tests of the harness itself).
    /// - keepWorkspace: retain the workspace after the run (for the app diff view); see `keptWorkspace(jobID:)`.
    public init(engine: EngineClient, isolation: WorkspaceIsolation = GitWorktreeIsolation(),
                sandboxed: Bool = true, keepWorkspace: Bool = false,
                jobsDir: URL = HarnessRunner.defaultJobsDir,
                now: @escaping @Sendable () -> Date = { Date() }, priority: Priority = .background,
                verifyTimeout: TimeInterval = HarnessRunner.defaultVerifyTimeout,
                knobs: HarnessKnobs? = nil) {
        self.knobsOverride = knobs
        self.engine = engine; self.isolation = isolation; self.sandboxed = sandboxed
        self.keepWorkspace = keepWorkspace; self.jobsDir = jobsDir; self.now = now; self.priority = priority
        self.verifyTimeout = verifyTimeout
    }

    /// Workspace retained for `jobID` (only with `keepWorkspace`).
    public func keptWorkspace(jobID: String) -> Workspace? { kept[jobID] }

    func keepSessionWorkspace(_ id: String, _ ws: Workspace) { kept[id] = ws }

    /// Cleans up a retained workspace.
    public func discardWorkspace(jobID: String) async {
        if let ws = kept.removeValue(forKey: jobID) { await Self.shielded { await self.isolation.cleanup(ws) } }
    }

    // MARK: run

    public func run(spec: HarnessJobSpec, jobID: String,
                    onEvent: @Sendable (HarnessEvent) -> Void) async -> HarnessJobResult {
        guard Self.validJobID(jobID) else {
            onEvent(.finished(.failed))
            return HarnessJobResult(status: .failed, summary: "invalid job id")
        }
        let fm = FileManager.default
        let jobDir = jobsDir.appendingPathComponent(jobID).path
        let jobTmp = jobDir + "/tmp"
        do {
            try Self.makeDir(jobsDir.path)
            try Self.makeDir(jobDir)
            try Self.makeDir(jobTmp)
        } catch {
            onEvent(.finished(.failed))
            return HarnessJobResult(status: .failed, summary: "cannot create job dir: \(error.localizedDescription)")
        }
        let sink = EventSink(path: jobDir + "/events.jsonl", now: now)

        func conclude(_ r: HarnessJobResult, workspace: Workspace?) -> HarnessJobResult {
            var r = r
            r.summary = String(Redactor.redact(r.summary).prefix(1500))
            sink.close()
            Self.writeResult(r, jobDir: jobDir, workspace: workspace.flatMap { keepWorkspace ? $0 : nil }, finishedAt: now())
            // The agent can chmod 000 / flag trees under tmp; make them deletable first.
            GitWorktreeIsolation.makeRemovable(jobTmp, under: jobDir)
            try? fm.removeItem(atPath: jobTmp)
            return r
        }

        // Validate cwd.
        let cwd: String
        switch Self.validateCwd(spec.cwd) {
        case let .success(p): cwd = p
        case let .failure(e):
            sink.handle(.finished(.failed)); onEvent(.finished(.failed))
            return conclude(HarnessJobResult(status: .failed, summary: "invalid cwd: \(e.message)"), workspace: nil)
        }

        // Prepare workspace (always isolated, also for read access).
        let ws: Workspace
        do {
            ws = try await isolation.prepare(cwd: cwd, access: spec.access, files: spec.files)
        } catch {
            let st: HarnessStatus = Task.isCancelled ? .cancelled : .failed
            sink.handle(.finished(st)); onEvent(.finished(st))
            return conclude(HarnessJobResult(status: st, summary: "workspace preparation failed: \(error)"), workspace: nil)
        }

        let asm = await assemble(spec: spec, ws: ws, cwd: cwd, jobTmp: jobTmp, priority: priority, requireFinish: true)
        let scanRoot = asm.scanRoot, depsBefore = asm.depsBefore, bashRunner = asm.bashRunner
        let loop = asm.loop, loopSpec = asm.loopSpec

        var result = await loop.run(spec: loopSpec, workspace: ws) { e in
            sink.handle(e)
            onEvent(e)
        }

        // Patch first: it is the exact tree the agent produced, so verify side effects (build output) never
        // reach it, and its touched paths tell us whether `verified` can be trusted.
        var patch: String?
        var integrity: WorkspaceIntegrity?
        if spec.access == .write, result.status != .cancelled, result.status != .declined, !Task.isCancelled {
            do {
                let p = try await isolation.collectPatch(ws)
                if !p.isEmpty { patch = p }
                if spec.verify != nil {
                    do { integrity = try await isolation.integrityScan(ws) } catch {
                        integrity = WorkspaceIntegrity(suspicious: true)  // fail closed
                    }
                }
            } catch {
                result.status = .failed
                result.summary += " [patch collection failed: \(error)]"
            }
        }

        // Verify: the harness runs the caller's command itself (same sandbox, fresh HOME/TMPDIR), after the agent
        // is done. Commands of the agent never outlive their `bash` call (the runner kills the whole sandbox tag
        // set when each command ends), so no agent process is left running while verify executes.
        // The agent never sees or edits the command it will be judged by.
        if let cmd = spec.verify, !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           result.status == .done || result.status == .limit, !Task.isCancelled {
            // Regenerable caches are deleted so a planted .pyc cannot execute; new or changed dependency dirs downgrade.
            let purge = WorkspaceScan.purgeCaches(root: scanRoot)
            var deps = depsBefore.map { WorkspaceScan.dependencyChanges(before: $0, after: WorkspaceScan.dependencySnapshot(root: scanRoot)) } ?? []
            if !purge.complete { deps.append("unverifiable:cache scan limit") }
            let touched = Self.touchedSensitive(integrity: integrity, patch: patch ?? "", verifyCommand: cmd, dependencyChanges: deps)
            var v = await Self.runVerify(cmd, root: ws.root, jobTmp: jobTmp, runner: bashRunner, timeout: verifyTimeout)
            v.touchedSensitive = touched
            if v.status == .verified, !touched.isEmpty { v.status = .verifiedModifiedTests }
            if Task.isCancelled {
                result.status = .cancelled
                result.summary = "cancelled"
                patch = nil
            } else {
                result.verify = v
            }
        }

        if let patch, !Task.isCancelled {
            do {
                let path = jobDir + "/patch.diff"
                try Self.writeFile(path, Data(patch.utf8))
                result.patchPath = path
                result.patch = patch.utf8.count <= Self.maxInlinePatchBytes ? patch : nil
                result.filesChanged = GitWorktreeIsolation.fileChanges(in: patch)
            } catch {
                result.status = .failed
                result.summary += " [patch write failed: \(error)]"
            }
        }

        // Cleanup runs on every path, shielded from cancellation of this task.
        if keepWorkspace { kept[jobID] = ws } else { await Self.shielded { await self.isolation.cleanup(ws) } }
        return conclude(result, workspace: ws)
    }

    // MARK: assemble

    /// Everything a run needs besides the workspace: prompt context, the one tool set and the one sandbox runner.
    /// Shared by `run` (delegated jobs) and `openSession` (chat), so the two paths cannot drift apart.
    struct Assembled {
        var scanRoot: String
        var depsBefore: WorkspaceScan.DependencySnapshot?
        var bashRunner: CommandRunner
        var loop: AgentLoop
        var loopSpec: HarnessJobSpec
    }

    func assemble(spec: HarnessJobSpec, ws: Workspace, cwd: String, jobTmp: String, priority: Priority,
                  requireFinish: Bool = false) async -> Assembled {
        // Dependency/build dirs that exist before the agent runs are the only ones exempt from the ignored-file
        // downgrade. Scan the whole worktree (the job root may be a subdirectory of it).
        var scanRoot = ws.root
        if let git = isolation as? GitWorktreeIsolation, let top = await git.worktreeTop(for: ws) { scanRoot = top }
        let wantsIntegrity = spec.access == .write && spec.verify != nil
        let depsBefore = wantsIntegrity ? WorkspaceScan.dependencySnapshot(root: scanRoot) : nil

        // Prompt + tools.
        let pack = PackLoader.builtin()
        let project = PackLoader.projectContext(root: URL(fileURLWithPath: ws.root))
        var ctxParts: [String] = []
        let block = project.untrustedBlock
        if !block.isEmpty { ctxParts.append(block) }
        let lim = spec.limits
        var envLines = ["# Environment"]
        if let b = Self.currentBranch(cwd) { envLines.append("branch: \(b)") }
        envLines.append("limits: \(lim.maxTurns) turns, \(Int(lim.maxSeconds)) s, \(lim.maxGeneratedTokens) generated tokens")
        if let v = spec.verify?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            envLines.append("verify (Strim runs this after you finish; exit 0 = verified): \(Redactor.redact(v))")
        }
        ctxParts.append(envLines.joined(separator: "\n"))
        if let c = spec.context, !c.isEmpty { ctxParts.append(c) }
        var loopSpec = spec
        loopSpec.context = ctxParts.joined(separator: "\n\n")

        var gitWritable: [String] = [], gitControl: [String] = []
        if let git = isolation as? GitWorktreeIsolation {
            let p = await git.sandboxGitPaths(for: ws)
            gitWritable = p.writable; gitControl = p.control
        }
        let bashRunner = BashTool.makeRunner(workspaceRoot: ws.root, access: spec.access, jobTmp: jobTmp,
                                             gitWritable: gitWritable, gitControlDirs: gitControl,
                                             sandboxed: sandboxed)
        let loop = AgentLoop(engine: engine, tools: ToolCatalog.all(runner: bashRunner), systemPrompt: pack.systemPrompt,
                             limits: lim, date: Self.dateString(now()), clock: now, priority: priority, requireFinish: requireFinish,
                             knobs: knobsOverride ?? PackLoader.builtinKnobs())
        return Assembled(scanRoot: scanRoot, depsBefore: depsBefore, bashRunner: bashRunner, loop: loop, loopSpec: loopSpec)
    }

    // MARK: verify

    static func runVerify(_ command: String, root: String, jobTmp: String, runner: CommandRunner,
                          timeout: TimeInterval) async -> VerifyResult {
        // Fresh HOME and TMPDIR under an unpredictable subdir of the job tmp, never used by agent commands, so
        // caches and dotfiles the agent planted in its own HOME/TMPDIR are not picked up.
        let base = jobTmp + "/verify-" + UUID().uuidString
        var env = ["HOME": base + "/home", "TMPDIR": base + "/tmp"]
        // Toolchain caches too (npm, cargo target dir, ...): nothing the agent left in the shared job tmp is reused.
        env.merge(Toolchains.cacheEnv(scratch: base)) { a, _ in a }
        do {
            for d in [base, env["HOME"]!, env["TMPDIR"]!] { try makeDir(d) }
        } catch {
            return VerifyResult(status: .unverified, exitCode: nil, outputTail: "could not prepare verify environment")
        }
        let out: CommandOutput
        do {
            out = try await runner.run(command, cwd: root, env: env, timeout: timeout, outputCap: BashTool.outputCap)
        } catch {
            return VerifyResult(status: .unverified, exitCode: nil,
                                outputTail: tail(Redactor.redact("could not run verify: \(error)")))
        }
        var text = Redactor.redact(out.output).trimmingCharacters(in: .whitespacesAndNewlines)
        if out.timedOut { text += (text.isEmpty ? "" : "\n") + "[verify timed out after \(Int(timeout))s]" }
        let ok = out.exitCode == 0 && !out.timedOut
        return VerifyResult(status: ok ? .verified : .failed, exitCode: out.exitCode, outputTail: tail(text))
    }

    /// Integrity-sensitive paths a patch touches (old and new side), at most `maxTouchedPaths`, sorted:
    /// test dirs/files, build and test config, CI, scripts, and any path the verify command mentions.
    static func sensitivePaths(in patch: String, verifyCommand: String) -> [String] {
        var paths = [String]()
        for line in patch.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("diff --git ") {
            let spec = line.dropFirst("diff --git ".count)
            if let r = spec.range(of: " b/", options: .backwards) {
                paths.append(String(spec[r.upperBound...]))
                let a = spec[..<r.lowerBound]
                paths.append(a.hasPrefix("a/") ? String(a.dropFirst(2)) : String(a))
            }
        }
        return sensitive(among: paths, verifyCommand: verifyCommand)
    }

    /// Fallback parser, only for isolations that cannot scan the workspace (`integrity == nil`); the git-backed
    /// path never reads patch text. Order: unverifiable marker, sensitive changed paths, ignored files; max 5.
    static func touchedSensitive(integrity: WorkspaceIntegrity?, patch: String, verifyCommand: String,
                                 dependencyChanges: [String] = []) -> [String] {
        guard let integrity else { return Array((sensitivePaths(in: patch, verifyCommand: verifyCommand) + dependencyChanges).prefix(VerifyResult.maxTouchedPaths)) }
        var out: [String] = []
        if integrity.suspicious { out.append("unverifiable:odd or unreadable path list") }
        out += sensitive(among: integrity.changedPaths.filter { !GitWorktreeIsolation.isOddPath($0) }, verifyCommand: verifyCommand)
        out += dependencyChanges
        out += integrity.ignoredPaths.filter { !GitWorktreeIsolation.isOddPath($0) && !isAllowedCache($0) }.sorted()
            .map { "ignored:" + $0 }
        return Array(out.prefix(VerifyResult.maxTouchedPaths))
    }

    /// Build and cache dirs a normal test run creates and gitignores; anything else ignored is suspicious.
    static let allowedCacheDirs: Set<String> = [
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".build", ".swiftpm", "node_modules", "target", ".DS_Store",
    ]

    static func isAllowedCache(_ path: String) -> Bool {
        path.split(separator: "/").contains { allowedCacheDirs.contains(String($0)) }
    }

    private static func sensitive(among paths: [String], verifyCommand: String) -> [String] {
        let tokens = verifyCommand.split(whereSeparator: { " \t\n;&|()<>'\"=".contains($0) }).map { t -> String in
            var s = String(t)
            while s.hasPrefix("./") { s.removeFirst(2) }
            return s
        }.filter { !$0.isEmpty }
        let hits = Set(paths).filter { isSensitive($0) || mentioned($0, in: verifyCommand, tokens: tokens) }
        return Array(hits.sorted().prefix(VerifyResult.maxTouchedPaths))
    }

    private static let sensitiveNames: Set<String> = [
        "makefile", "gnumakefile", "package.json", "package.swift", "pytest.ini", "setup.cfg", "pyproject.toml",
        "tox.ini", "conftest.py", ".gitignore", ".gitattributes", ".gitmodules", ".npmrc",
    ]

    static func isSensitive(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map { String($0) }
        guard let name = parts.last?.lowercased() else { return false }
        if sensitiveNames.contains(name) || name.hasPrefix(".env") { return true }
        if name.hasPrefix("test_") || name.contains("_test.") || name.contains(".test.") || name.contains(".spec.")
            || name.hasSuffix("tests.swift") || name.hasSuffix("test.swift") { return true }
        for d in parts.dropLast().map({ $0.lowercased() }) {
            if d == "tests" || d == "test" || d == "spec" || d == "specs" || d == "scripts" || d == ".github"
                || d.hasPrefix("test_") || d.contains("tests") { return true }
        }
        return false
    }

    private static func mentioned(_ path: String, in command: String, tokens: [String]) -> Bool {
        if command.contains(path) { return true }
        return tokens.contains { $0 == path || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Last `maxTailChars` chars, control characters dropped. Input is already redacted (redact before clipping).
    static func tail(_ s: String) -> String {
        let clean = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            $0.value == 0x0A || $0.value == 0x09 || ($0.value >= 0x20 && $0.value != 0x7F)
        }))
        return String(clean.suffix(VerifyResult.maxTailChars))
    }

    // MARK: validation

    struct CwdError: Error { let message: String }

    static func validJobID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Absolute, existing directory, not `/`, `$HOME` or an ancestor of `$HOME`. Returns the resolved path.
    static func validateCwd(_ cwd: String, home homeOverride: String? = nil) -> Result<String, CwdError> {
        guard cwd.hasPrefix("/"), !cwd.contains("\0") else { return .failure(CwdError(message: "must be an absolute path")) }
        guard let real = realpath(cwd, nil) else { return .failure(CwdError(message: "does not exist")) }
        defer { free(real) }
        let path = String(cString: real)
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return .failure(CwdError(message: "not a directory"))
        }
        let homeDir = homeOverride ?? NSHomeDirectory()
        var homes = [homeDir]
        if let h = realpath(homeDir, nil) { homes.append(String(cString: h)); free(h) }
        for h in homes {
            let home = h.count > 1 && h.hasSuffix("/") ? String(h.dropLast()) : h
            if path == "/" || path == home || home.hasPrefix(path + "/") {
                return .failure(CwdError(message: "refusing the filesystem root, the home directory or an ancestor of it"))
            }
        }
        for h in homes {
            if let why = SensitiveDirs.refuse(realCwd: path, home: h) { return .failure(CwdError(message: why)) }
        }
        return .success(path)
    }

    // MARK: helpers

    static func shielded(_ body: @escaping @Sendable () async -> Void) async {
        await Task.detached { await body() }.value
    }

    static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func makeDir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(path, 0o700)
    }

    static func writeFile(_ path: String, _ data: Data) throws {
        unlink(path)
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CwdError(message: "cannot write \(path)")
        }
        chmod(path, 0o600)
    }

    /// Branch name from `.git/HEAD` (no process spawned); nil outside git, "(detached)" for a detached HEAD.
    static func currentBranch(_ cwd: String) -> String? {
        var dir = cwd
        for _ in 0..<64 {
            let g = dir + "/.git"
            var st = stat()
            if lstat(g, &st) == 0 {
                var gitDir = g
                if (st.st_mode & S_IFMT) == S_IFREG {
                    guard let t = try? String(contentsOfFile: g, encoding: .utf8),
                          let line = t.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                    gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    if !gitDir.hasPrefix("/") { gitDir = dir + "/" + gitDir }
                }
                guard let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return nil }
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if h.hasPrefix("ref: refs/heads/") { return Redactor.redact(String(h.dropFirst("ref: refs/heads/".count)).prefix(200).description) }
                return "(detached)"
            }
            if dir == "/" || dir.isEmpty { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func verifyDict(_ v: VerifyResult) -> [String: Any] {
        var d: [String: Any] = ["status": v.status.rawValue, "output_tail": Redactor.redact(v.outputTail),
                                "touched_sensitive": v.touchedSensitive.map { Redactor.redact($0) }]
        if let c = v.exitCode { d["exit_code"] = Int(c) }
        return d
    }

    static func writeResult(_ r: HarnessJobResult, jobDir: String, workspace: Workspace?, finishedAt: Date) {
        var d: [String: Any] = [
            "status": r.status.rawValue,
            "summary": r.summary,
            "files_changed": r.filesChanged.map { ["path": $0.path, "added": $0.added, "removed": $0.removed] as [String: Any] },
            "commands": r.commands.map { ["cmd": Redactor.redact($0.cmd), "exit": Int($0.exit)] as [String: Any] },
            "usage": ["prompt_tokens": r.usage.promptTokens, "cached_tokens": r.usage.cachedTokens,
                      "completion_tokens": r.usage.completionTokens, "turns": r.usage.turns, "seconds": r.usage.seconds] as [String: Any],
            "verify": verifyDict(r.verify),
            "finished_at": ISO8601DateFormatter().string(from: finishedAt),
        ]
        if let b = r.base { d["base"] = b }
        if let p = r.patchPath { d["patch_path"] = p }
        if let w = workspace { d["workspace"] = w.root }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
        try? writeFile(jobDir + "/result.json", data)
    }
}

/// Appends redacted event lines to `events.jsonl` (0600). Consecutive text/reasoning deltas are coalesced so a
/// secret split across deltas is still redacted.
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    private let now: @Sendable () -> Date
    private var pendingKind: String?
    private var pendingText = ""
    private var closed = false

    init(path: String, now: @escaping @Sendable () -> Date) {
        self.now = now
        unlink(path)
        if FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) {
            chmod(path, 0o600)
            handle = FileHandle(forWritingAtPath: path)
        } else {
            handle = nil
        }
    }

    func handle(_ e: HarnessEvent) {
        lock.withLock {
            guard !closed else { return }
            switch e {
            case let .textDelta(t): append("text", t)
            case let .reasoningDelta(t): append("reasoning", t)
            default:
                flush()
                switch e {
                case let .turn(n): emit(["type": "turn", "n": n])
                case let .toolCall(name, args): emit(["type": "tool_call", "name": name, "args": args])
                case let .toolResult(name, out, err): emit(["type": "tool_result", "name": name, "output": out, "is_error": err])
                case let .approval(cmd): emit(["type": "approval", "command": cmd])
                case let .usage(u): emit(["type": "usage", "prompt": u.promptTokens, "cached": u.cachedTokens, "completion": u.completionTokens])
                case let .finished(s): emit(["type": "finished", "status": s.rawValue])
                default: break
                }
            }
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            flush()
            closed = true
            try? handle?.close()
        }
    }

    private func append(_ kind: String, _ t: String) {
        if pendingKind != kind { flush(); pendingKind = kind }
        pendingText += t
    }

    private func flush() {
        guard let k = pendingKind else { return }
        emit(["type": k, "text": pendingText])
        pendingKind = nil
        pendingText = ""
    }

    private func emit(_ fields: [String: Any]) {
        var d = fields
        d["ts"] = now().timeIntervalSince1970
        for (k, v) in d { if let s = v as? String { d[k] = Redactor.redact(s) } }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
        try? handle?.write(contentsOf: data + Data("\n".utf8))
    }
}
