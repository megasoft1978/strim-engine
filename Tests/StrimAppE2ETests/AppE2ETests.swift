import Foundation
import Darwin
import Testing
import StrimAppCore
import StrimAPI

private struct SmokeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor private enum LiveSmoke {
    static var task: Task<[String: String], Never>?
    static func result(_ name: String) async -> String {
        if task == nil { task = Task { await run() } }
        return (await task!.value)[name] ?? "not reached"
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SmokeError(message) }
    }
    static func wait(_ seconds: Double, _ predicate: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }
    static func freePort() throws -> UInt16 {
        for _ in 0..<20 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SmokeError("socket failed") }
            var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET); a.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
            let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let got = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            close(fd)
            let p = UInt16(bigEndian: a.sin_port)
            if ok == 0 && got == 0 && p != 8203 { return p }
        }
        throw SmokeError("could not choose a free port")
    }
    static func portIsFree(_ port: UInt16) -> Bool {
        // A bare bind can fail on TIME_WAIT even after the listener has exited.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let output = Pipe(), errors = Pipe(); p.standardOutput = output; p.standardError = errors
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 1 && output.fileHandleForReading.readDataToEndOfFile().isEmpty && errors.fileHandleForReading.readDataToEndOfFile().isEmpty
    }
    /// Same path as QuitHandler.applicationShouldTerminate: requestQuit, then wait for the reply.
    static func quit(_ coordinator: LifecycleCoordinator) async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            if coordinator.requestQuit(reply: { k.resume() }) == .now { k.resume() }
        }
    }
    static func git(_ args: [String], cwd: String) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd); p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); try check(p.terminationStatus == 0, "git \(args.first ?? "") failed")
    }
    static func run() async -> [String: String] {
        var report = Dictionary(uniqueKeysWithValues: (1...8).map { ("S\($0)", "not run after earlier failure") })
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("strim-e2e-" + UUID().uuidString).path
        let outside = base + "-outside", state = base + "/state", project = base + "/project", chats = base + "/chats"
        var model: AppModel?; var quitCoordinator: LifecycleCoordinator?; var pid: Int32?; var port: UInt16 = 0; var stage = "S1"
        defer {
            if let pid, kill(pid, 0) == 0 { _ = kill(pid, SIGTERM) }
            try? FileManager.default.removeItem(atPath: base)
            try? FileManager.default.removeItem(atPath: outside)
        }
        do {
            guard let binary = ProcessInfo.processInfo.environment["STRIM_BIN"], !binary.isEmpty else { throw SmokeError("STRIM_BIN is required") }
            try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
            try Data("let value = 1\n".utf8).write(to: URL(fileURLWithPath: project + "/source.swift"))
            try git(["init", "-q"], cwd: project); try git(["add", "source.swift"], cwd: project)
            try git(["-c", "user.name=Smoke", "-c", "user.email=smoke@example.invalid", "commit", "-qm", "initial"], cwd: project)
            let cfg = try JSONSerialization.data(withJSONObject: ["mcp": ["allowedRoots": [base]]])
            try cfg.write(to: URL(fileURLWithPath: state + "/config.json"))
            port = try freePort()
            var settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"model_path":" ","mtp_path":""}"#.utf8))
            try check(settings.modelPath == nil && settings.mtpPath == nil, "blank paths did not decode as defaults")
            settings.hostURL = "http://127.0.0.1:\(port)"; settings.strimBinary = binary
            settings.controlTokenPath = state + "/control-token"; settings.startServerWhenOpens = false
            let client = HTTPControlClient(baseURL: settings.url, token: TokenReader(path: settings.controlTokenPath, home: base))
            let downloader = ModelDownloader(modelExists: { true }, initialState: .done)
            let m = AppModel(client: client, settings: settings, launcher: ProcessHostLauncher(stateDir: state), persist: { _ in },
                             pollInterval: 0.2, testMode: true, modelDownloader: downloader, discoverHostProcess: false,
                             chatStore: FileChatStore(root: chats), scratchRoot: base + "/scratch")
            model = m; m.thinkingEnabled = false
            // Same wiring as StrimApp.init, with the app-host record and host.lock kept in the temp state dir.
            quitCoordinator = LifecycleCoordinator(target: m, table: SystemProcessTable(lockPath: state + "/host.lock"),
                                                   store: FileOwnedHostStore(path: state + "/app-host.json"), expectedBinary: { binary })
            await m.startServer(); pid = m.hostProcessPID
            try check(pid != nil, "startServer did not launch: \(m.lastError ?? m.notice ?? "no reason")")
            let ready = await wait(60) { m.status?.state == .ready && m.status?.model == "qwen38-4bit" }
            try check(ready, "ready qwen38-4bit not observed: \(m.offlineBanner ?? m.lastError ?? "timeout")")
            report[stage] = "PASS"
            stage = "S2"
            guard case .success(let p) = m.addProject(project), let a = m.newThread(projectID: p.id) else { throw SmokeError("project or thread creation failed") }
            try check(m.threads.contains { $0.id == a.id }, "new thread absent")
            report[stage] = "PASS"
            stage = "S3"
            await m.send("Reply with exactly one word: pong", in: a.id)
            let completed = await wait(60) { m.generatingThreadID == nil }
            try check(completed, "chat turn did not finish")
            let answer = (m.messages[a.id] ?? []).first { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            try check(answer != nil, "assistant message absent; roles=\((m.messages[a.id] ?? []).map { $0.role.rawValue }); error=\(m.lastError ?? m.chatUnavailable[a.id] ?? "none")")
            try check(m.lastError == nil && m.chatUnavailable[a.id] == nil, "chat error: \(m.lastError ?? m.chatUnavailable[a.id] ?? "")")
            let metricsReady = await wait(5) { (m.status?.decodeTPS ?? 0) > 0 }
            let liveStatus = m.status
            report[stage] = "PASS"
            stage = "S4"
            guard let b = m.newThread(projectID: p.id), b.id != a.id else { throw SmokeError("second thread absent") }
            let turn = Task { await m.send("Write a 300-word story about a lighthouse keeper.", in: a.id) }
            let started = await wait(10) { m.generatingThreadID == a.id }
            try check(started, "long turn never entered generating state")
            await m.send("Reply with one word.", in: b.id)
            try check(m.queuedText(for: b.id) != nil, "second thread was not queued")
            await m.cancel(b.id)
            try check(m.queuedText(for: b.id) == nil && m.generatingThreadID == a.id, "queue cancellation disturbed active turn")
            await turn.value
            let finished = await wait(60) { m.generatingThreadID == nil }
            try check(finished, "active turn did not finish")
            report[stage] = "PASS"
            stage = "S5"
            guard case .success(let op) = m.addProject(outside), let ot = m.newThread(projectID: op.id) else { throw SmokeError("outside project creation failed") }
            await m.send("hello", in: ot.id)
            let reason = m.chatUnavailable[ot.id] ?? m.lastError ?? ""
            try check(reason.localizedCaseInsensitiveContains("outside the allowed roots") && !reason.localizedCaseInsensitiveContains("loopback only"), "missing host refusal reason: \(reason)")
            report[stage] = "PASS"
            stage = "S6"
            await m.closeAllSessions()
            let m2 = AppModel(client: client, settings: settings, persist: { _ in }, pollInterval: nil, testMode: true,
                              modelDownloader: ModelDownloader(modelExists: { true }, initialState: .done),
                              chatStore: FileChatStore(root: chats), scratchRoot: base + "/scratch")
            m2.selectThread(a.id)
            try check(m2.projects.contains { $0.id == p.id } && m2.threads.contains { $0.id == a.id }, "projects or threads not restored")
            try check((m2.messages[a.id] ?? []).contains { $0.role == .assistant && !$0.text.isEmpty }, "assistant message not restored")
            try check((m2.messages[a.id] ?? []).contains { $0.marker == .sessionBreak }, "session-break marker not restored")
            report[stage] = "PASS"
            stage = "S8"
            try check(liveStatus?.state == .ready || liveStatus?.state == .busy, "missing status state")
            try check(metricsReady && liveStatus?.model == "qwen38-4bit" && (liveStatus?.uptimeSeconds ?? 0) > 0 && (liveStatus?.decodeTPS ?? 0) > 0, "missing model, uptime or decode speed: \(String(describing: liveStatus))")
            report[stage] = "PASS"
        } catch { report[stage] = "FAIL: \(error)" }
        if let quitCoordinator {
            let quitStarted = Date()
            await quit(quitCoordinator)
            let quitSeconds = Date().timeIntervalSince(quitStarted)
            let exited = await wait(2) { pid.map { kill($0, 0) != 0 } ?? false }
            let free = portIsFree(port)
            let quickly = quitSeconds <= 4
            report["S7"] = exited && free && quickly ? "PASS" : "FAIL: pid=\(pid.map(String.init) ?? "nil"), exited=\(exited), port=\(port), free=\(free), quit=\(String(format: "%.2f", quitSeconds))s (limit 4s)"
            if exited { pid = nil }
            else if let child = pid {
                _ = kill(child, SIGKILL)
                if await wait(2, { kill(child, 0) != 0 }) { pid = nil }
            }
        }
        return report
    }
}

@Suite("Live app smoke", .enabled(if: ProcessInfo.processInfo.environment["STRIM_E2E"] == "1", "set STRIM_E2E=1 to run live smoke"))
struct AppE2ETests {
    @MainActor private func check(_ name: String) async { let result = await LiveSmoke.result(name); #expect(result == "PASS", "\(name): \(result)") }
    @Test("S1 start") @MainActor func start() async { await check("S1") }
    @Test("S2 projects and threads") @MainActor func projects() async { await check("S2") }
    @Test("S3 chat") @MainActor func chat() async { await check("S3") }
    @Test("S4 queue") @MainActor func queue() async { await check("S4") }
    @Test("S5 refusal") @MainActor func refusal() async { await check("S5") }
    @Test("S6 persistence") @MainActor func persistence() async { await check("S6") }
    @Test("S7 quit") @MainActor func quit() async { await check("S7") }
    @Test("S8 status") @MainActor func status() async { await check("S8") }
}
