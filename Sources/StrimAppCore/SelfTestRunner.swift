import Foundation
import Darwin
import StrimAPI

public struct SelfTestCheck: Codable, Equatable, Sendable {
    public var name: String
    public var ok: Bool
    public var ms: Double
    public var detail: String
    public var skipped: Bool

    public init(name: String, ok: Bool, ms: Double, detail: String, skipped: Bool = false) {
        self.name = name; self.ok = ok; self.ms = ms; self.detail = detail; self.skipped = skipped
    }
    public static func skip(_ name: String, reason: String) -> Self {
        Self(name: name, ok: false, ms: 0, detail: reason, skipped: true)
    }
    /// A render probe that timed out or died on a signal is a failure, never a skip.
    public static func renderChildFailure(_ name: String, reason: String) -> Self {
        Self(name: "render-" + name, ok: false, ms: 0, detail: reason)
    }
}

public struct SelfTestReport: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var version: String
    public var windows: Int
    public var checks: [SelfTestCheck]

    public init(version: String = StrimVersion.current, windows: Int, checks: [SelfTestCheck]) {
        self.version = version; self.windows = windows; self.checks = checks
    }
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", version, windows, checks }
    public var exitCode: Int32 {
        windows == 0 && !checks.isEmpty && checks.allSatisfy { $0.skipped || $0.ok } ? 0 : 1
    }
    public var summary: String {
        let passed = checks.filter { !$0.skipped && $0.ok }.count
        let failed = checks.filter { !$0.skipped && !$0.ok }.count
        let skipped = checks.filter(\.skipped).count
        return "Strim selftest: \(passed) passed, \(failed) failed, \(skipped) skipped; windows=\(windows); exit=\(exitCode)"
    }
    public func write(to directory: URL) throws {
        let safe = try SelfTestIsolation.directory(directory.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try SecureFS.writeAtomically(try encoder.encode(self), to: safe.appendingPathComponent("selftest.json").path)
    }
}

public enum SelfTestIsolation {
    /// Resolve before creating anything, including a not-yet-existing descendant of a symlink.
    public static func directory(_ path: String, home: String = NSHomeDirectory()) throws -> URL {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SecureFSError(message: "selftest requires an output directory")
        }
        let url = try resolve(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        // A overridden $HOME must not unprotect the account's real ~/.strim (passwd home).
        var homes = [home]
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { homes.append(String(cString: dir)) }
        for h in homes {
            let protected = try resolve(URL(fileURLWithPath: h).appendingPathComponent(".strim")).path
            guard url.path != protected, !url.path.hasPrefix(protected + "/") else {
                throw SecureFSError(message: "refusing selftest state under ~/.strim: \(url.path)")
            }
        }
        return url
    }

    private static func resolve(_ url: URL) throws -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        var st = stat()
        while lstat(ancestor.path, &st) != 0 {
            guard errno == ENOENT, ancestor.path != "/" else {
                throw SecureFSError(message: "cannot resolve selftest directory: \(url.path)")
            }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        guard let canonical = realpath(ancestor.path, nil) else {
            throw SecureFSError(message: "cannot resolve selftest directory: \(url.path)")
        }
        defer { free(canonical) }
        var result = URL(fileURLWithPath: String(cString: canonical))
        for component in suffix.reversed() { result.appendPathComponent(component) }
        return result
    }
}

/// Stops the server this run started when the run is interrupted or overruns. Only the recorded pid, only while it
/// still runs our binary (pid reuse), TERM then KILL after the grace period.
public final class SelfTestGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    private var cleaned = false
    private let binary: String
    private let table: HostProcessTable
    private let grace: Double
    private let exitProcess: @Sendable (Int32) -> Void
    private var sources: [DispatchSourceSignal] = []
    private var watchdog: DispatchSourceTimer?

    public init(binary: String, table: HostProcessTable = SystemProcessTable(), grace: Double = 3,
                exit: @escaping @Sendable (Int32) -> Void = { Darwin.exit($0) }) {
        self.binary = binary; self.table = table; self.grace = grace; self.exitProcess = exit
    }

    public func hostStarted(_ pid: Int32) { lock.lock(); self.pid = pid; cleaned = false; lock.unlock() }

    private func stillOurs(_ pid: Int32) -> Bool {
        func canon(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().standardized.path }
        guard let exe = table.executablePath(of: pid) else { return false }
        return canon(exe) == canon(binary)
    }

    /// Synchronous; safe from any queue. Idempotent per recorded pid.
    public func cleanup() {
        lock.lock(); let target = pid; let already = cleaned; cleaned = true; lock.unlock()
        guard let target, !already, target > 1, target != getpid(), table.isAlive(target), stillOurs(target) else { return }
        table.terminate(target)
        let end = DispatchTime.now() + grace
        while table.isAlive(target), DispatchTime.now() < end { usleep(20_000) }
        if table.isAlive(target), stillOurs(target) { table.kill(target) }
    }

    /// Replace default handlers (they would orphan the server) and clean up on each signal. A no-op handler rather than
    /// SIG_IGN: caught signals reset to default across exec, so the server child does not inherit an ignored SIGTERM.
    public func installSignals(_ signals: [Int32] = [SIGINT, SIGTERM, SIGHUP], exitCode: Int32 = 130) {
        for sig in signals {
            Darwin.signal(sig) { _ in }
            let s = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue(label: "strim.selftest.signal.\(sig)"))
            s.setEventHandler { [self] in cleanup(); exitProcess(exitCode) }
            s.resume()
            sources.append(s)
        }
    }

    /// Overall deadline: clean up and exit(1).
    public func armWatchdog(seconds: Double) {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "strim.selftest.watchdog"))
        t.schedule(deadline: .now() + seconds)
        t.setEventHandler { [self] in cleanup(); exitProcess(1) }
        t.resume()
        watchdog = t
    }

    public func disarm() { watchdog?.cancel(); watchdog = nil; sources.forEach { $0.cancel() }; sources = [] }
}

private struct SelfTestLogin: LoginItemControlling {
    var isEnabled: Bool { false }
    func setEnabled(_ on: Bool) throws {}
}
private struct SelfTestClipboard: ClipboardWriting { func copy(_ text: String) {} }
private struct SelfTestMCP: McpCommandProvider { func commands(settings: AppSettings) async -> String { "" } }

private final class SelfTestLaunchProbe: HostLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: AppSettings?
    var settings: AppSettings? { lock.lock(); defer { lock.unlock() }; return captured }
    func start(settings: AppSettings) -> HostLaunchResult {
        lock.lock(); captured = settings; lock.unlock()
        return .failed("selftest: captured default paths without launching a model")
    }
}

/// The real model/client/lifecycle path with every writable dependency explicitly rooted in the run directory.
@MainActor
public enum SelfTestRunner {
    public static func run(directory: URL, modelPath: String?, noModel: Bool, binary: String,
                           bundleVersion: String?, onHostStarted: @escaping (pid_t) -> Void = { _ in },
                           windows: @MainActor () -> Int,
                           render: @MainActor (AppModel, URL) -> [SelfTestCheck]) async -> SelfTestReport {
        var checks: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String, since: UInt64 = DispatchTime.now().uptimeNanoseconds) {
            checks.append(SelfTestCheck(name: name, ok: ok,
                ms: Double(DispatchTime.now().uptimeNanoseconds - since) / 1_000_000, detail: detail))
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let root: URL
        do {
            root = try SelfTestIsolation.directory(directory.path)
            try SecureFS.ensureDir(root.path)
        } catch {
            check("isolation", false, error.localizedDescription, since: start)
            return SelfTestReport(windows: windows(), checks: checks)
        }
        // A fresh child prevents previous runs' tokens, config, symlinks, or ownership records from being reused.
        let run = root.appendingPathComponent("run-" + UUID().uuidString)
        let state = run.appendingPathComponent("state")
        let settingsPath = run.appendingPathComponent("app.json").path
        var model: AppModel?
        var coordinator: LifecycleCoordinator?
        var port: UInt16 = 0
        do {
            try SecureFS.ensureDir(state.path)
            let allowed = run.appendingPathComponent("allowed-base").path
            try SecureFS.ensureDir(allowed)
            let config = try JSONSerialization.data(withJSONObject: ["mcp": ["allowedRoots": [allowed]]])
            try SecureFS.writeAtomically(config, to: state.appendingPathComponent("config.json").path)
            port = try freePort()
            check("isolation", port != 8203, "state=\(state.path); port=\(port)", since: start)
            let t = DispatchTime.now().uptimeNanoseconds
            if let bundleVersion {
                check("bundle-version", bundleVersion == StrimVersion.current,
                      "bundle=\(bundleVersion); compiled=\(StrimVersion.current)", since: t)
            } else {
                checks.append(.skip("bundle-version", reason: "SwiftPM executable has no app bundle metadata; run the packaged Contents/MacOS binary to gate the release"))
            }
            if let why = BinaryValidator.validate(binary) { throw SecureFSError(message: "selftest CLI: \(binary): \(why)") }
            let cliVersion = try await command(binary, ["--version"], in: run)
            check("cli-version", cliVersion.trimmingCharacters(in: .whitespacesAndNewlines) == "strim " + StrimVersion.current,
                  "CLI=\(cliVersion.trimmingCharacters(in: .whitespacesAndNewlines)); compiled=\(StrimVersion.current)", since: t)
            checks.append(.skip("binary-identity", reason: "This build embeds the release version only; no compile-time git SHA/build timestamp is available. Matching versions cannot detect a stale same-version UI."))

            // Load the actual blank setting, then observe the real AppModel launch arguments without loading weights.
            var settings = AppSettings(hostURL: "http://127.0.0.1:\(port)", strimBinary: binary,
                modelPath: "", controlTokenPath: state.appendingPathComponent("control-token").path,
                startServerWhenOpens: false, thinkingEnabled: false)
            try settings.save(path: settingsPath)
            settings = AppSettings.load(path: settingsPath)
            let probe = SelfTestLaunchProbe()
            let blank = makeModel(settings, run: run, launcher: probe, settingsPath: settingsPath)
            let blankStart = DispatchTime.now().uptimeNanoseconds
            await blank.startServer()
            let expected = AppPaths.home + "/.strim/models/qwen38-4bit"
            check("blank-model-default", settings.modelPath == nil && probe.settings?.modelPath == expected,
                  "blank model_path -> \(probe.settings?.modelPath ?? "no launch attempted")", since: blankStart)
            blank.stop()

            // Explicit model selection is read-only; no scanner, downloader, or default settings file is consulted.
            if !noModel {
                settings.modelPath = HostCommand.expandPath(modelPath ?? expected)
                let parent = (settings.modelPath! as NSString).deletingLastPathComponent
                settings.mtpPath = parent + "/qwen38-mtp-4bit"
            }
            try settings.save(path: settingsPath)
            let app = makeModel(settings, run: run,
                launcher: ProcessHostLauncher(stateDir: state.path, binaryCandidates: [binary]), settingsPath: settingsPath)
            model = app
            let lifecycle = LifecycleCoordinator(target: app,
                table: SystemProcessTable(lockPath: state.appendingPathComponent("host.lock").path),
                store: FileOwnedHostStore(path: state.appendingPathComponent("app-host.json").path), expectedBinary: { binary })
            coordinator = lifecycle
            if noModel {
                for name in ["app-start-ready", "health-version", "status-fields", "folder-refusal", "folder-grant-chat", "streamed-turn", "tool-round-trip", "quit-owned-server"] {
                    checks.append(.skip(name, reason: "Inference disabled (--no-model or no explicit --model path); serve requires a loaded model"))
                }
            } else {
                let readyStart = DispatchTime.now().uptimeNanoseconds
                // The pid is published while startServer is still awaiting: report it as soon as it exists so a
                // signal during launch can already stop the server.
                let watcher = Task { @MainActor in
                    while !Task.isCancelled {
                        if let pid = app.ownedHostPID { onHostStarted(pid); return }
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                }
                defer { watcher.cancel() }
                await app.startServer()
                if let pid = app.ownedHostPID { onHostStarted(pid) }
                // Launch failure must never cause the self-test to connect to a pre-existing listener.
                if app.ownedHostPID != nil { app.start() }
                let remaining = max(0, 120 - Double(DispatchTime.now().uptimeNanoseconds - readyStart) / 1_000_000_000)
                let ready = await wait(seconds: remaining) {
                    app.status?.state == .ready || (app.ownedHostPID == nil && !app.hostLaunchInFlight)
                }
                let withinDeadline = DispatchTime.now().uptimeNanoseconds - readyStart <= 120_000_000_000
                let running = ready && withinDeadline && app.status?.state == .ready && app.ownedHostPID != nil
                check("app-start-ready", running, running ? "Running/Ready; pid=\(app.ownedHostPID!)" : (app.lastError ?? app.offlineBanner ?? "not Ready within 120 seconds"), since: readyStart)
                if running {
                    let client = HTTPControlClient(baseURL: settings.url, token: TokenReader(path: settings.controlTokenPath, home: run.path))
                    let healthStart = DispatchTime.now().uptimeNanoseconds
                    let session = HTTPControlClient.hardenedSession()
                    defer { session.invalidateAndCancel() }
                    var req = URLRequest(url: settings.url.appendingPathComponent("health")); req.timeoutInterval = 8
                    let (data, response) = try await session.data(for: req)
                    let health = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    check("health-version", (response as? HTTPURLResponse)?.statusCode == 200 && health?["version"] as? String == StrimVersion.current,
                          "health version=\(health?["version"] as? String ?? "missing")", since: healthStart)
                    let status = try await client.status()
                    check("status-fields", status.model?.isEmpty == false && status.memory.weightsGB > 0 && status.uptimeSeconds >= 0 && status.quantFingerprint?.isEmpty == false,
                          "model=\(status.model ?? "nil"); weights=\(status.memory.weightsGB) GiB; quant=\(status.quantFingerprint ?? "nil")")
                    try await chat(app, client: client, run: run, checks: &checks)
                } else {
                    for name in ["health-version", "status-fields", "folder-refusal", "folder-grant-chat", "streamed-turn", "tool-round-trip"] {
                        checks.append(.skip(name, reason: "Prerequisite app-start-ready failed"))
                    }
                }
            }
            // ImageRenderer lives in the app target so this core never depends on the SwiftUI application entry point.
            checks += render(app, run)
        } catch {
            check("selftest-error", false, error.localizedDescription)
        }
        if let model, let log = try? JSONEncoder().encode(model.eventLog) {
            try? SecureFS.writeAtomically(log, to: run.appendingPathComponent("app-events.json").path)
        }
        // Also run on every error path: the coordinator knows only the PID launched by this run, never adopts.
        if let coordinator, let model, !noModel {
            let pid = model.ownedHostPID
            let quitStart = DispatchTime.now().uptimeNanoseconds
            await coordinator.runQuit()
            let gone = pid.map { Darwin.kill($0, 0) != 0 && errno == ESRCH } ?? true
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - quitStart) / 1_000_000
            check("quit-owned-server", gone && portIsFree(port) && elapsed <= 4000,
                  "pid=\(pid.map(String.init) ?? "none"); gone=\(gone); port=\(port); elapsed=\(Int(elapsed))ms", since: quitStart)
        }
        let count = windows()
        check("no-windows", count == 0, "NSApp?.windows.count=\(count)")
        return SelfTestReport(windows: count, checks: checks)
    }

    private static func makeModel(_ settings: AppSettings, run: URL, launcher: HostLauncher, settingsPath: String) -> AppModel {
        let home = run.path
        return AppModel(settings: settings, makeClient: { s in
            HTTPControlClient(baseURL: s.url, token: TokenReader(path: s.controlTokenPath, home: home))
        }, launcher: launcher, mcp: SelfTestMCP(), loginItem: SelfTestLogin(), clipboard: SelfTestClipboard(),
           persist: { try $0.save(path: settingsPath) }, pollInterval: 0.5, testMode: false,
           tokenStatus: { TokenReader(path: $0.controlTokenPath, home: home).inspect() }, modelScan: { [] },
           modelDownloader: ModelDownloader(directory: run.appendingPathComponent("downloads").path,
                                            binary: { nil }, modelExists: { true }, initialState: .done),
           discoverHostProcess: false, chatStore: FileChatStore(root: run.appendingPathComponent("chats").path),
           scratchRoot: run.appendingPathComponent("scratch").path)
    }

    private static func wait(seconds: Double, until done: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(seconds)
        while !done(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(100)) }
        return done()
    }

    private static func chat(_ app: AppModel, client: HTTPControlClient, run: URL, checks: inout [SelfTestCheck]) async throws {
        func record(_ name: String, _ ok: Bool, _ detail: String, _ start: UInt64) {
            checks.append(.init(name: name, ok: ok, ms: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, detail: detail))
        }
        // A restricted base inside this run makes the refusal deterministic even when the output is below HOME.
        let denied = run.appendingPathComponent("ungranted").path
        try SecureFS.ensureDir(denied)
        let refusalStart = DispatchTime.now().uptimeNanoseconds
        do {
            let session = try await client.chatOpen(ChatOpenRequest(cwd: denied, enableThinking: false))
            try await client.chatClose(sessionID: session.sessionID)
            record("folder-refusal", false, "ungranted folder was accepted", refusalStart)
        } catch {
            record("folder-refusal", error.localizedDescription.contains("outside the allowed roots"), error.localizedDescription, refusalStart)
        }
        let project = run.appendingPathComponent("project")
        try SecureFS.ensureDir(project.path)
        _ = try await command("/usr/bin/git", ["init", "--quiet", project.path], in: run)
        try SecureFS.writeAtomically(Data("selftest sentinel\n".utf8), to: project.appendingPathComponent("sentinel.txt").path)
        _ = try await command("/usr/bin/git", ["-C", project.path, "add", "sentinel.txt"], in: run)
        _ = try await command("/usr/bin/git", ["-C", project.path, "-c", "user.name=Strim Selftest", "-c", "user.email=selftest@localhost", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "selftest fixture"], in: run)
        let openStart = DispatchTime.now().uptimeNanoseconds
        _ = try await client.grantFolder(path: project.path)
        let p = try app.addProject(project.path).get()
        guard let thread = app.newThread(projectID: p.id) else { throw SecureFSError(message: "cannot create selftest chat") }
        await app.probeChat()
        record("folder-grant-chat", app.hasLiveSession(thread.id), "folder granted via API; session=\(app.hasLiveSession(thread.id))", openStart)
        let turnStart = DispatchTime.now().uptimeNanoseconds
        await app.sendChat("Reply with just the word hello. Do not use tools.")
        let done = await wait(seconds: 60) { !app.chatGenerating }
        let text = app.chatMessages.filter { $0.role == .assistant }.map(\.text).joined()
        record("streamed-turn", done && app.lastError == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               "streamed assistant characters=\(text.count); completed=\(done); roles=\(app.chatMessages.map { $0.role.rawValue }); error=\(app.lastError ?? "none"); transcript=\(run.appendingPathComponent("chats").path)", turnStart)
        if done && app.lastError == nil && app.hasLiveSession(thread.id) {
            let toolStart = DispatchTime.now().uptimeNanoseconds
            let before = app.chatMessages.count
            await app.sendChat("Use a file-reading tool to read sentinel.txt and tell me its contents. Do not change any files.")
            let finished = await wait(seconds: 45) { !app.chatGenerating }
            let tools = app.chatMessages.dropFirst(before).compactMap(\.tool)
            record("tool-round-trip", finished && tools.contains { $0.name != "finish" && $0.finished && !$0.isError },
                   "finished=\(finished); completed tools=\(tools.filter(\.finished).map(\.name))", toolStart)
        } else {
            checks.append(.skip("tool-round-trip", reason: "First turn did not complete with a usable chat session"))
        }
    }

    private static func socketBound(to port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }
    private static func freePort() throws -> UInt16 {
        for _ in 0..<20 {
            guard let fd = socketBound(to: 0) else { break }
            var address = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
            }
            close(fd)
            let port = UInt16(bigEndian: address.sin_port)
            if result == 0, port > 1024, port != 8203 { return port }
        }
        throw SecureFSError(message: "could not allocate an isolated random port")
    }
    private static func portIsFree(_ port: UInt16) -> Bool {
        guard port != 0, port != 8203, let fd = socketBound(to: port) else { return false }
        close(fd); return true
    }

    private static func command(_ binary: String, _ args: [String], in directory: URL) async throws -> String {
        try await Task.detached { try commandSync(binary, args, in: directory) }.value
    }

    private nonisolated static func commandSync(_ binary: String, _ args: [String], in directory: URL) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: binary); p.arguments = args
        p.currentDirectoryURL = directory
        // No personal git config, hooks, credential helpers, or signing programs in the fixture repository.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_TEMPLATE_DIR"] = directory.appendingPathComponent("git-template").path
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0); p.terminationHandler = { _ in done.signal() }
        try p.run()
        guard done.wait(timeout: .now() + 10) == .success else {
            p.terminate()
            if done.wait(timeout: .now() + 0.5) != .success { Darwin.kill(p.processIdentifier, SIGKILL) }
            throw SecureFSError(message: "selftest command timed out: \(binary)")
        }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw SecureFSError(message: "selftest command failed: \(binary): \(text)") }
        return text
    }
}
