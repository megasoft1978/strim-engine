import Foundation
import Combine
import Testing
import StrimAPI
@testable import StrimAppCore

@MainActor
private func resilienceModel(_ client: StrimControlClient, clock: AppClock = RecordingClock(),
                             launcher: HostLauncher = MockLauncher(.needsModel),
                             running: @escaping @Sendable (Int32) -> Bool = { _ in true },
                             terminate: @escaping @Sendable (Int32) -> Void = { _ in },
                             failure: @escaping @Sendable () -> String? = { nil },
                             loadNotice: String? = nil) -> AppModel {
    AppModel(settings: AppSettings(modelPath: "/models/q", startServerWhenOpens: false), loadNotice: loadNotice,
             makeClient: { _ in client },
             clock: clock, launcher: launcher, mcp: MockMcp(), loginItem: MockLogin(), clipboard: MockClipboard(),
             persist: { _ in }, pollInterval: nil, testMode: true, tokenStatus: { _ in .ok }, modelScan: { [] },
             modelDownloader: ModelDownloader(modelExists: { true }), discoverHostProcess: false,
             hostProcessRunning: running, terminateHostProcess: terminate, hostFailureDetail: failure)
}

/// Quit goes through LifecycleCoordinator, as QuitHandler does; fakes keep ~/.strim and real pids untouched.
@MainActor
@discardableResult
private func quitThroughCoordinator(_ model: AppModel, table: FakeProcessTable = FakeProcessTable()) async -> FakeProcessTable {
    var timing = LifecycleTiming(); timing.total = 1; timing.prepareCap = 0.5; timing.termWait = 0.2; timing.killWait = 0.1; timing.poll = 0.01
    await LifecycleCoordinator(target: model, table: table, store: FakeStore(), expectedBinary: { "/models/strim" }, timing: timing).runQuit()
    return table
}

@MainActor
private func subscribed(_ model: AppModel, _ fake: FakeControlClient) async -> Bool {
    await fake.emit(.status(await fake.statusValue))
    return await waitFor { model.lastEventTime != nil }
}

/// Deliberately ignores cancellation, like a transport completing an already dispatched request.
private actor StatusGate {
    var pending: CheckedContinuation<HostStatus, Never>?
    func get() async -> HostStatus { await withCheckedContinuation { pending = $0 } }
    func release() { pending?.resume(returning: FakeControlClient.sampleStatus); pending = nil }
    var waiting: Bool { pending != nil }
}

private struct GatedClient: StrimControlClient {
    let fake = FakeControlClient()
    let gate: StatusGate
    func status() async throws -> HostStatus { await gate.get() }
    func events() -> AsyncThrowingStream<StrimEvent, Error> { fake.events() }
    func load(_ r: LoadRequest) async throws { try await fake.load(r) }
    func unload() async throws { try await fake.unload() }
    func jobs() async throws -> [JobSummary] { try await fake.jobs() }
    func job(id: String) async throws -> JobDetail { try await fake.job(id: id) }
    func approve(_ a: PatchApproval) async throws { try await fake.approve(a) }
    func chatOpen(_ r: ChatOpenRequest) async throws -> ChatSession { try await fake.chatOpen(r) }
    func chatAppend(_ r: ChatAppendRequest) async throws { try await fake.chatAppend(r) }
    func chatCancel(_ r: ChatCancelRequest) async throws { try await fake.chatCancel(r) }
}

private final class ResilienceProtocol: URLProtocol, @unchecked Sendable {
    static let handler = Locked<(@Sendable (URLRequest) -> (Int, Data, Bool))?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let respond = Self.handler.value else { return }
        let (code, data, stream) = respond(request)
        let headers = stream ? ["Content-Type": "text/event-stream"] : ["Content-Type": "application/json"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        if !stream { client?.urlProtocolDidFinishLoading(self) }
    }
}

/// The main-actor tick releases this launcher. The timeout lets the regression fail without hanging.
private final class SlowResilienceLauncher: HostLauncher {
    let entered = Locked(false)
    let calls = Locked(0)
    let releasedDuringLaunch = Locked(false)
    let release = DispatchSemaphore(value: 0)
    let result: HostLaunchResult
    init(_ result: HostLaunchResult = .failed("finished slow launch")) { self.result = result }
    func start(settings: AppSettings) -> HostLaunchResult {
        calls.with { $0 += 1 }; entered.with { $0 = true }
        let released = release.wait(timeout: .now() + 1) == .success
        releasedDuringLaunch.with { $0 = released }
        return result
    }
}

@Suite @MainActor struct AppModelResilienceTests {
    @Test func slowLauncherAllowsMainActorTickAndStillGuardsDuplicateStarts() async {
        let launcher = SlowResilienceLauncher()
        let model = resilienceModel(FakeControlClient(), launcher: launcher)
        let tick = Task { @MainActor in
            while !launcher.entered.value { await Task.yield() }
            model.startHost()
            await model.startServer()
            launcher.release.signal()
        }
        model.startHost()
        await tick.value
        #expect(await waitFor { model.lastError?.contains("finished slow launch") == true })
        #expect(launcher.releasedDuringLaunch.value)
        #expect(launcher.calls.value == 1)
        model.stop()
    }

    @Test func stopDuringStartupGraceWaitsForPIDAndStopsExactlyThatChild() async {
        let launcher = SlowResilienceLauncher(.started(pid: 12345))
        let alive = Locked(true)
        let signals = Locked<[Int32]>([])
        let model = resilienceModel(FakeControlClient(), launcher: launcher, running: { _ in alive.value },
                                    terminate: { pid in signals.with { $0.append(pid) }; alive.with { $0 = false } })
        model.startHost()
        #expect(await waitFor { launcher.entered.value })
        let stopping = Task { await model.stopServer() }
        for _ in 0..<10 { await Task.yield() }
        #expect(!model.serverStartAvailability.enabled)
        launcher.release.signal()
        await stopping.value
        #expect(signals.value == [12345])
        #expect(model.ownedHostPID == nil && model.hostProcessPID == nil)
        #expect(launcher.calls.value == 1)
        model.stop()
    }

    @Test func corruptSettingsNoticeAppearsOnceAtStartup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hard1-s2-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app.json")
        try Data("{{{".utf8).write(to: file)
        let report = AppSettings.loadReport(path: file.path)
        let model = resilienceModel(FakeControlClient(), loadNotice: report.notice)
        #expect(model.notice?.contains("Settings file was unreadable") == true)
        #expect(model.notice?.contains(file.path + ".bad-") == true)
        model.dismissNotice()
        model.start(); model.stop(); model.start(); model.stop()
        #expect(model.notice == nil)
        #expect(resilienceModel(FakeControlClient()).notice == nil)
    }

    @Test func corruptLoadElsewhereNeverNoticesInAnotherModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hard1-s2-isolated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app.json")
        try Data("{{{".utf8).write(to: file)
        let corrupt = AppSettings.loadReport(path: file.path)
        #expect(corrupt.notice != nil)
        // Another model, built in parallel with no load notice of its own, must stay silent.
        #expect(resilienceModel(FakeControlClient()).notice == nil)
        #expect(resilienceModel(FakeControlClient(), loadNotice: nil).notice == nil)
        #expect(resilienceModel(FakeControlClient(), loadNotice: corrupt.notice).notice == corrupt.notice)
    }

    @Test func newLauncherFailureDetailsArePreservedInVisibleStartError() async {
        for reason in ["model not found at /models/missing. Choose a model in Settings or let Strim download one.",
                       "/tmp/fake-strim is not executable",
                       "strim exited with status 3 right after starting.\nstrim: bad weights\nport 49151 in use"] {
            let model = resilienceModel(FakeControlClient(), launcher: MockLauncher(.failed(reason)))
            model.startHost()
            #expect(await waitFor { model.lastError != nil })
            #expect(model.lastError == "Start server: \(reason)")
            #expect(model.serverStartAvailability.enabled)
            model.stop()
        }
    }

    @Test func repeatedStartsWhileHostBootsLaunchOnlyOnce() async {
        let launcher = MockLauncher(.started(pid: 2_000_000_000))
        let model = resilienceModel(FailingClient(error: ControlClientError.hostUnreachable("refused")), launcher: launcher)
        model.startHost()
        #expect(await waitFor { model.reconnectAttempts == 1 })
        model.startHost()
        await model.startServer()
        #expect(launcher.calls.value == 1)
        #expect(!model.serverStartAvailability.enabled)
        #expect(model.menuTitle.contains("loading"))
        model.stop()
    }

    @Test func startServerHonorsReadyAndLoadingGuards() async {
        let fake = FakeControlClient()
        let launcher = MockLauncher(.started(pid: 2_000_000_000))
        let model = resilienceModel(fake, launcher: launcher)
        model.start()
        #expect(await waitFor { model.connection.isConnected })
        #expect(await subscribed(model, fake))
        await model.startServer()
        await fake.emit(.status(status(.loading, progress: 0.1)))
        #expect(await waitFor { model.status?.state == .loading })
        await model.startServer()
        model.startHost()
        #expect(launcher.calls.value == 0)
        #expect(model.menuTitle == "Strim: loading 10%")
        model.stop()
    }

    @Test func crashEndsTurnWithErrorAndInvalidatesHostSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hard1-s2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeControlClient()
        let clock = RecordingClock()
        let launcher = MockLauncher(.needsModel)
        let model = resilienceModel(fake, clock: clock, launcher: launcher)
        model.start()
        #expect(await waitFor { model.connection.isConnected })
        #expect(await subscribed(model, fake))
        let project = try model.addProject(root.path).get()
        let thread = try #require(model.newThread(projectID: project.id))
        await model.send("hello", in: thread.id)
        #expect(model.generatingThreadID == thread.id)
        #expect(model.liveSessions[thread.id] != nil)
        await fake.finishEvents(throwing: ControlClientError.hostUnreachable("connection reset"))
        #expect(await waitFor { model.offlineBanner != nil })
        #expect(model.generatingThreadID == nil)
        #expect(model.lastError?.contains("connection reset") == true)
        #expect(model.messages[thread.id]?.last?.text.contains("offline") == true)
        #expect(model.liveSessions.isEmpty)
        clock.release()
        #expect(await waitFor { model.connection.isConnected })
        #expect(model.lastError == nil)
        #expect(launcher.calls.value == 0)
        await model.send("after recovery", in: thread.id)
        #expect(await fake.calls.filter { $0.hasPrefix("chat_open:") }.count == 2)
        model.stop()
    }

    @Test func disconnectEndsOnlyTheInFlightTurnAndClearsSessions() async throws {
        let roots = try (0..<2).map { _ -> URL in
            let r = FileManager.default.temporaryDirectory.appendingPathComponent("hard1-s2-disc-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
            return r
        }
        defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }
        let fake = FakeControlClient()
        let model = resilienceModel(fake)
        model.start()
        #expect(await waitFor { model.connection.isConnected })
        #expect(await subscribed(model, fake))
        // Separate projects: a new thread reuses an empty draft within the same project.
        let idleProject = try model.addProject(roots[0].path).get()
        let busyProject = try model.addProject(roots[1].path).get()
        let idle = try #require(model.newThread(projectID: idleProject.id))
        model.selectThread(idle.id)
        await model.probeChat()
        #expect(model.liveSessions[idle.id] != nil && model.generatingThreadID == nil)
        let busy = try #require(model.newThread(projectID: busyProject.id))
        await model.send("hello", in: busy.id)
        #expect(model.generatingThreadID == busy.id && model.liveSessions[busy.id] != nil)
        let idleBefore = model.messages[idle.id]?.count ?? 0
        await fake.finishEvents(throwing: ControlClientError.hostUnreachable("connection reset"))
        #expect(await waitFor { model.offlineBanner != nil })
        let endings = (model.messages[busy.id] ?? []).filter { $0.text.hasPrefix("Turn ended: host went offline") }
        #expect(endings.count == 1 && endings.first?.role == .assistant)
        #expect(model.messages[idle.id]?.count ?? 0 == idleBefore)
        #expect(!(model.messages[idle.id] ?? []).contains { $0.text.contains("went offline") })
        #expect(model.generatingThreadID == nil)
        #expect(model.liveSessions.isEmpty && model.liveOrder.isEmpty)
        model.stop()
    }

    @Test func cleanStreamEndHasVisibleError() async {
        let fake = FakeControlClient()
        let model = resilienceModel(fake)
        model.start()
        #expect(await waitFor { model.connection.isConnected })
        #expect(await subscribed(model, fake))
        await fake.finishEvents()
        #expect(await waitFor { model.offlineBanner != nil })
        #expect(model.lastError?.contains("Event stream closed") == true)
        model.stop()
    }

    @Test func duplicateStatusDoesNotRepublishConnection() async {
        let fake = FakeControlClient()
        let model = resilienceModel(fake)
        model.start()
        #expect(await waitFor { model.connection.isConnected })
        #expect(await subscribed(model, fake))
        let changes = Locked(0)
        let observation = model.$connection.dropFirst().sink { _ in changes.with { $0 += 1 } }
        let original = await fake.statusValue
        for _ in 0..<3 { await fake.emit(.status(original)) }
        await fake.emit(.error(APIError(code: "barrier", message: "received")))
        #expect(await waitFor { model.lastError?.contains("barrier") == true })
        #expect(changes.value == 0)
        withExtendedLifetime(observation) {}
        model.stop()
    }

    @Test func launchFailuresRemainVisibleAndRetryable() async {
        for result in [HostLaunchResult.failed("port already in use"), .failed("host lock held"),
                       .failed("process exited: missing model"), .binaryMissing(command: "strim serve model"), .needsModel] {
            let launcher = MockLauncher(result)
            let signals = Locked<[Int32]>([])
            let model = resilienceModel(FakeControlClient(), launcher: launcher, terminate: { pid in signals.with { $0.append(pid) } })
            model.startHost()
            #expect(await waitFor { model.lastError != nil || model.notice != nil })
            if case .failed(let reason) = result { #expect(model.lastError == "Start server: \(reason)") }
            #expect(model.hostProcessPID == nil)
            #expect(model.serverStartAvailability.enabled)
            let table = await quitThroughCoordinator(model)
            #expect(signals.value.isEmpty && table.s.value.termed.isEmpty)
            model.stop()
        }
    }

    @Test func exitedChildReportsStderrAndClearsOwnership() async {
        for detail in ["address already in use", "host lock held", "model directory missing"] {
            let model = resilienceModel(FailingClient(error: ControlClientError.hostUnreachable("refused")),
                                        launcher: MockLauncher(.started(pid: 12345)), running: { _ in false }, failure: { detail })
            model.startHost()
            #expect(await waitFor { model.lastError?.contains(detail) == true })
            #expect(model.hostProcessPID == nil)
            #expect(model.ownedHostPID == nil)
            #expect(model.serverStartAvailability.enabled)
            model.stop()
        }
    }

    @Test func stopWhileLoadingClearsOwnedPIDAndNeverSignalsForeignPID() async {
        let alive = Locked(true)
        let signals = Locked<[Int32]>([])
        let model = resilienceModel(FailingClient(error: ControlClientError.hostUnreachable("refused")),
                                    launcher: MockLauncher(.started(pid: 12345)), running: { _ in alive.value },
                                    terminate: { pid in signals.with { $0.append(pid) }; alive.with { $0 = false } })
        model.startHost()
        #expect(model.serverStopAvailability.enabled)
        await model.stopServer()
        #expect(signals.value == [12345])
        #expect(model.hostProcessPID == nil)
        #expect(model.ownedHostPID == nil)
        model.stop()
    }

    @Test func startWhileStoppingIsIgnoredAndRapidTogglesKeepOwnershipConsistent() async {
        let clock = RecordingClock()
        let alive = Locked(true)
        let signals = Locked<[Int32]>([])
        let launcher = MockLauncher(.started(pid: 12345))
        let model = resilienceModel(FailingClient(error: ControlClientError.hostUnreachable("refused")), clock: clock,
                                    launcher: launcher, running: { _ in alive.value },
                                    terminate: { pid in signals.with { $0.append(pid) } })
        model.startHost()
        let stopping = Task { await model.stopServer() }
        #expect(await waitFor { !signals.value.isEmpty })
        for _ in 0..<8 { model.startHost(); await model.startServer() }
        #expect(launcher.calls.value == 1)
        #expect(!model.serverStartAvailability.enabled)
        alive.with { $0 = false }; clock.release()
        await stopping.value
        #expect(model.ownedHostPID == nil)
        #expect(model.hostProcessPID == nil)
        model.stop()
        for _ in 0..<5 {
            alive.with { $0 = true }
            model.startHost()
            #expect(await waitFor { model.ownedHostPID == 12345 })
            alive.with { $0 = false }
            await model.stopServer()
            #expect(model.ownedHostPID == nil)
            #expect(model.hostProcessPID == nil)
            model.stop()
        }
        #expect(launcher.calls.value == 6)
    }

    @Test func quitClearsAlreadyExitedOwnedPIDWithoutSignallingIt() async {
        let signals = Locked<[Int32]>([])
        let model = resilienceModel(FakeControlClient(), launcher: MockLauncher(.started(pid: 12345)),
                                    running: { _ in false }, terminate: { pid in signals.with { $0.append(pid) } })
        model.startHost()
        let table = await quitThroughCoordinator(model)
        #expect(model.ownedHostPID == nil)
        #expect(model.hostProcessPID == nil)
        #expect(signals.value.isEmpty && table.s.value.termed.isEmpty)
        model.stop()
    }

    @Test func stoppedLoopCannotPublishLateTransportSuccess() async {
        let gate = StatusGate()
        let model = resilienceModel(GatedClient(gate: gate))
        model.start()
        while !(await gate.waiting) { await Task.yield() }
        model.stop()
        let changes = Locked(0)
        let observation = model.$connection.dropFirst().sink { _ in changes.with { $0 += 1 } }
        await gate.release()
        // Drain the resumed MainActor task without a wall-clock sleep.
        for _ in 0..<30 { await Task.yield() }
        #expect(changes.value == 0)
        #expect(!model.connection.isConnected)
        withExtendedLifetime(observation) {}
    }

    @Test func offlineRecoveryRefreshesHostSnapshotWithoutDuplicateConnectionEvents() async {
        let fake = FakeControlClient()
        let clock = RecordingClock()
        let model = resilienceModel(fake, clock: clock)
        let job = JobSummary(id: "old", source: .mcp, status: .running, started: 1)
        await fake.setJobs([job])
        model.start()
        #expect(await waitFor { model.jobs.count == 1 && model.packInfo != nil && model.hostFolders != nil })
        #expect(await subscribed(model, fake))
        let changes = Locked<[ConnectionState]>([])
        let observation = model.$connection.dropFirst().sink { value in changes.with { $0.append(value) } }
        await fake.finishEvents(throwing: ControlClientError.hostUnreachable("crash"))
        #expect(await waitFor { model.offlineBanner != nil })
        #expect(model.jobs.isEmpty && model.packInfo == nil && model.hostFolders == nil)
        #expect(model.lastEventTime == nil && model.status == nil)
        #expect(model.menuSymbol == "bolt.slash" && model.lastError != nil)
        var recovered = status(.ready, model: "replacement"); recovered.decodeTPS = 99
        await fake.setStatus(recovered)
        await fake.setJobs([])
        clock.release()
        #expect(await waitFor { model.status == recovered && model.packInfo != nil && model.hostFolders != nil })
        #expect(model.offlineBanner == nil && model.lastError == nil && model.reconnectAttempts == 0)
        #expect(model.menuTitle == "Strim: ready" && model.menuSymbol == "bolt.circle.fill")
        #expect(changes.value.count == 3)
        #expect(changes.value.last == .connected(recovered))
        withExtendedLifetime(observation) {}
        model.stop()
    }

    @Test func compatibleExistingHostConnectsWithoutLaunchOrSignal() async {
        let fake = FakeControlClient()
        let launcher = MockLauncher(.failed("must not launch"))
        let signals = Locked<[Int32]>([])
        let model = resilienceModel(fake, launcher: launcher, terminate: { pid in signals.with { $0.append(pid) } })
        model.start()
        #expect(await waitFor { model.connection.isConnected })
        model.startHost(); await model.startServer()
        let table = await quitThroughCoordinator(model)
        #expect(launcher.calls.value == 0 && signals.value.isEmpty && table.s.value.termed.isEmpty)
        #expect(model.ownedHostPID == nil)
    }

    @Test func tokenRotationDuringUnauthorizedRetryUsesNewToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hard1-s2-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = root.appendingPathComponent("control-token")
        try Data("old".utf8).write(to: token)
        let reader = TokenReader(path: token.path, home: root.path)
        let session = HTTPControlClient.hardenedSession(extraProtocols: [ResilienceProtocol.self])
        defer { session.invalidateAndCancel(); ResilienceProtocol.handler.with { $0 = nil } }
        let authorizations = Locked<[String]>([])
        let ready = try JSONEncoder().encode(FakeControlClient.sampleStatus)
        let event = try JSONEncoder().encode(StrimEvent.status(FakeControlClient.sampleStatus))
        let frame = Data(("data: " + String(decoding: event, as: UTF8.self) + "\n\n").utf8)
        ResilienceProtocol.handler.with { handler in handler = { request in
            let path = request.url?.path ?? ""
            if path == StrimRoutes.status {
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                authorizations.with { $0.append(auth) }
                if auth == "Bearer old" {
                    try? Data("rotated".utf8).write(to: token, options: .atomic)
                    return (401, Data(), false)
                }
                return (200, ready, false)
            }
            if path == StrimRoutes.events { return (200, frame, true) }
            if path == StrimRoutes.jobs { return (200, Data("[]".utf8), false) }
            return (501, Data(), false)
        } }
        let clock = RecordingClock()
        let client = HTTPControlClient(baseURL: URL(string: "http://127.0.0.1:49151")!, token: reader, session: session)
        let model = resilienceModel(client, clock: clock)
        model.start()
        #expect(await waitFor { model.offlineBanner?.contains("401") == true })
        clock.release()
        #expect(await waitFor { model.connection.isConnected && model.lastEventTime != nil })
        #expect(authorizations.value == ["Bearer old", "Bearer rotated"])
        #expect(model.lastError == nil && model.reconnectAttempts == 0)
        #expect(!model.eventLog.contains { $0.contains("rotated") || $0.contains("Bearer") })
        model.stop()
    }
}
