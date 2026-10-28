import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

@MainActor
private func makeModel(_ client: StrimControlClient, clock: AppClock = RecordingClock(auto: 100), launcher: HostLauncher = MockLauncher(.needsModel),
                       clip: MockClipboard = MockClipboard(), login: MockLogin = MockLogin(), settings: AppSettings = AppSettings(modelPath: "/models/q", projectPath: "/tmp"),
                       poll: Double? = nil, testMode: Bool = false) -> AppModel {
    AppModel(client: client, settings: settings, clock: clock, launcher: launcher, mcp: MockMcp(), loginItem: login,
             clipboard: clip, persist: { _ in }, pollInterval: poll, testMode: testMode)
}

/// Emits a status event and waits until the model saw it: proves the SSE stream is subscribed.
@MainActor
private func awaitSubscribed(_ m: AppModel, _ fake: FakeControlClient) async -> Bool {
    await fake.emit(.status(FakeControlClient.sampleStatus))
    return await waitFor { m.lastEventTime != nil }
}

@Suite @MainActor struct AppModelTests {
    @Test func connectsAndShowsStatus() async {
        let fake = FakeControlClient()
        let m = makeModel(fake)
        #expect(m.connection == .connecting)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        #expect(m.menuTitle == "Strim: ready")
        #expect(m.offlineBanner == nil)
        m.stop()
    }

    @Test func offlineWhenHostNotRunningHasVisibleReason() async {
        let clock = RecordingClock(auto: 0)
        let m = makeModel(FailingClient(error: ControlClientError.hostUnreachable("Could not connect to the server.")), clock: clock)
        m.start()
        #expect(await waitFor { m.offlineBanner != nil })
        #expect(m.menuTitle == "Strim: offline")
        #expect(m.menuSymbol == "bolt.slash")
        #expect(m.offlineBanner == "Strim host is not running at http://127.0.0.1:8203: Could not connect to the server..")
        #expect(m.hostCanBeStarted)
        m.stop()
    }

    @Test func backoffDoublesAndCaps() async {
        let clock = RecordingClock(auto: 5)
        let m = makeModel(FailingClient(error: ControlClientError.hostUnreachable("refused")), clock: clock)
        m.start()
        #expect(await waitFor { clock.sleeps.count >= 6 })
        #expect(Array(clock.sleeps.prefix(6)) == [1, 2, 4, 8, 16, 30])
        m.stop()
    }

    @Test func backoffStruct() {
        var b = Backoff(base: 1, cap: 30)
        #expect((0..<7).map { _ in b.next() } == [1, 2, 4, 8, 16, 30, 30])
        b.reset()
        #expect(b.next() == 1)
    }

    @Test func hostDiesMidStreamThenRecovers() async {
        let fake = FakeControlClient()
        let clock = RecordingClock(auto: 0)
        let m = makeModel(fake, clock: clock)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        #expect(await awaitSubscribed(m, fake))
        await fake.finishEvents(throwing: ControlClientError.hostUnreachable("connection reset"))
        #expect(await waitFor { m.offlineBanner != nil })
        #expect(m.offlineBanner?.contains("not running") == true)
        #expect(await waitFor { clock.sleeps == [1] })
        clock.release()
        #expect(await waitFor { m.connection.isConnected })
        #expect(m.reconnectAttempts == 0)
        m.stop()
    }

    @Test func streamClosingCleanlyAlsoReconnects() async {
        let fake = FakeControlClient()
        let clock = RecordingClock(auto: 0)
        let m = makeModel(fake, clock: clock)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        #expect(await awaitSubscribed(m, fake))
        await fake.finishEvents()
        #expect(await waitFor { m.offlineBanner?.contains("Event stream closed") == true })
        m.stop()
    }

    @Test func statusEventUpdatesAndLoadingTitle() async {
        let fake = FakeControlClient()
        let m = makeModel(fake)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        await fake.emit(.status(status(.loading, progress: 0.42)))
        #expect(await waitFor { m.menuTitle == "Strim: loading 42%" })
        #expect(m.showTestBanner)
        #expect(m.lastEventTime != nil)
        await fake.emit(.status(status(.busy)))
        #expect(await waitFor { m.menuTitle == "Strim: busy" })
        await fake.emit(.status(status(.stopped, model: nil)))
        #expect(await waitFor { m.menuTitle == "Strim: stopped" })
        m.stop()
    }

    @Test func pollingRefreshesStatusAndDetectsDeath() async {
        let fake = FakeControlClient()
        let clock = RecordingClock(auto: 1000)
        let m = makeModel(fake, clock: clock, poll: 5)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        var s = status(.ready); s.decodeTPS = 77
        await fake.setStatus(s)
        #expect(await waitFor { m.status?.decodeTPS == 77 })
        await fake.setFailNext(ControlClientError.timeout)
        #expect(await waitFor { m.eventLog.contains { $0.contains("disconnected:") && $0.contains("timeout") } })
        m.stop()
    }

    @Test func testBannerRules() async {
        let fake = FakeControlClient()
        let off = makeModel(fake, testMode: true)
        #expect(off.showTestBanner)   // STRIM_APP_TEST
        let m = makeModel(fake)
        #expect(!m.showTestBanner)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        #expect(!m.showTestBanner)    // ready
        await fake.emit(.status(status(.error)))
        #expect(await waitFor { m.showTestBanner })
        #expect(m.rawState == "error")
        #expect(m.eventLogTail.last?.contains("status: error") == true)
        m.stop()
    }

    @Test func loadUnloadEnablement() async {
        let fake = FakeControlClient(status: status(.stopped, model: nil))
        let m = makeModel(fake)
        #expect(m.loadAvailability == .no("Host offline"))
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        #expect(m.loadAvailability.enabled)
        #expect(m.unloadAvailability == .no("No model loaded"))
        #expect(m.pauseAvailability.enabled == false)
        await m.loadModel()
        #expect(await fake.calls == ["load:/models/q"])
        #expect(m.status?.state == .ready)
        #expect(m.loadAvailability == .no("Model already loaded"))
        #expect(m.unloadAvailability.enabled)
        await fake.emit(.status(status(.loading, progress: 0.1)))
        #expect(await waitFor { m.status?.state == .loading })
        #expect(m.loadAvailability == .no("Model is loading"))
        #expect(m.unloadAvailability == .no("Model is loading"))
        await fake.emit(.status(status(.ready, active: 2)))
        #expect(await waitFor { m.status?.activeJobs == 2 })
        #expect(m.unloadAvailability == .no("Jobs are running"))
        m.stop()
    }

    @Test func loadDisabledWithoutModelPath() async {
        let fake = FakeControlClient(status: status(.stopped, model: nil))
        let m = makeModel(fake, settings: AppSettings())
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        #expect(m.loadAvailability.enabled == false)
        #expect(m.loadAvailability.reason?.contains("model_path") == true)
        m.stop()
    }

    @Test func applyAndRejectAreRecorded() async {
        let fake = FakeControlClient()
        let sum = JobSummary(id: "job-1", source: .mcp, status: .awaitingApproval, verify: .verified, started: 10, title: "fix")
        await fake.setJobs([sum])
        await fake.setDetail(JobDetail(summary: sum, patch: "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"))
        let m = makeModel(fake)
        m.start()
        #expect(await waitFor { m.jobs.count == 1 })
        #expect(m.approveAvailability(for: nil) == .no("Select a job"))
        await m.selectJob("job-1")
        #expect(m.approveAvailability(for: m.selectedJob).enabled)
        await m.approve(.apply)
        await m.approve(.reject)
        #expect(await fake.calls == ["approve:job-1:apply", "approve:job-1:reject"])
        m.stop()
    }

    @Test func approveDisabledWhenNoPatchOrWrongStatus() async {
        let fake = FakeControlClient()
        let done = JobSummary(id: "j", source: .cli, status: .done, started: 1)
        let m = makeModel(fake)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        #expect(m.approveAvailability(for: JobDetail(summary: done)) == .no("Job has no patch"))
        #expect(m.approveAvailability(for: JobDetail(summary: done, patch: "x")).reason == "Job is done, not awaiting approval")
        m.stop()
    }

    @Test func jobEventsUpdateListAndLog() async {
        let fake = FakeControlClient()
        let m = makeModel(fake)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        await fake.setJobs([JobSummary(id: "a", source: .mcp, status: .running, started: 1),
                            JobSummary(id: "b", source: .mcp, status: .queued, started: 2),
                            JobSummary(id: "c", source: .chat, status: .running, started: 3)])
        await fake.emit(.jobEvent(JobEvent(jobID: "a", status: .running)))
        #expect(await waitFor { m.jobs.count == 3 })
        let mcp = m.sourceCounts.first { $0.source == .mcp }
        #expect(mcp == SourceCount(source: .mcp, active: 1, queued: 1))
        #expect(m.sourceCounts.first { $0.source == .evolve } == SourceCount(source: .evolve, active: 0, queued: 0))
        #expect(m.eventLog.contains { $0.contains("job a: running") })
        m.stop()
    }

    @Test func chatFallsBackOn501() async {
        let m = makeModel(FakeControlClient())
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        // the fake's own error shape is also recognised
        let fake = FakeControlClient()
        let m3 = makeModel(fake)
        m3.start()
        #expect(await waitFor { m3.connection.isConnected })
        #expect(await awaitSubscribed(m3, fake))   // the event subscription must not consume failNext
        await fake.setFailNext(APIError(code: "not_implemented", message: "chat"))
        await m3.probeChat()
        #expect(m3.chat == .unavailable(ChatState.notAvailableYet))
        m.stop(); m3.stop()
        #expect(isNotImplemented(ControlClientError.notImplemented))
        #expect(isNotImplemented(ControlClientError.http(status: 501, api: nil)))
        #expect(!isNotImplemented(ControlClientError.timeout))
    }

    @Test func chatStreamsDeltasWhenAvailable() async {
        let fake = FakeControlClient()
        let m = makeModel(fake)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        await m.probeChat()
        guard case .ready(let s) = m.chat else { Issue.record("chat not ready"); return }
        await m.sendChat("hello")
        #expect(await fake.calls.contains("chat_append:\(s.sessionID):hello"))
        await fake.emit(.chatDelta(ChatDelta(sessionID: s.sessionID, kind: .text, text: "Hi ")))
        await fake.emit(.chatDelta(ChatDelta(sessionID: s.sessionID, kind: .text, text: "there")))
        #expect(await waitFor { m.chatMessages.last?.text == "Hi there" })
        #expect(m.chatMessages.map(\.role) == [.user, .assistant])
        m.stop()
    }

    @Test func startHostLaunchesAndReconnects() async {
        let launcher = MockLauncher(.started(pid: 4242))
        let m = makeModel(FailingClient(error: ControlClientError.hostUnreachable("refused")), clock: RecordingClock(auto: 0), launcher: launcher)
        m.start()
        #expect(await waitFor { m.offlineBanner != nil })
        m.startHost()
        #expect(launcher.calls.value == 1)
        #expect(m.notice?.contains("4242") == true)
        m.stop()
    }

    @Test func startHostWithMissingBinaryCopiesCommand() {
        let clip = MockClipboard()
        let m = makeModel(FakeControlClient(), launcher: MockLauncher(.binaryMissing(command: "strim serve /models/q --port 8203")), clip: clip)
        m.startHost()
        #expect(clip.copied.value == ["strim serve /models/q --port 8203"])
        #expect(m.notice?.contains("Terminal") == true)
    }

    @Test func startHostNeedsModel() {
        let m = makeModel(FakeControlClient(), launcher: MockLauncher(.needsModel))
        m.startHost()
        #expect(m.notice?.contains("model_path") == true)
    }

    @Test func mcpCommandsCopiedWithoutToken() async {
        let clip = MockClipboard()
        let m = makeModel(FakeControlClient(), clip: clip)
        await m.copyMCPCommands()
        let text = clip.copied.value.first ?? ""
        #expect(text.contains("claude mcp add"))
        #expect(text.contains("$(cat ~/.strim/token)"))
        #expect(text.contains("127.0.0.1:8203/mcp"))
        #expect(m.notice?.contains("not shown") == true)
    }

    @Test func launchAtLoginToggleAndFailure() {
        let login = MockLogin()
        let m = makeModel(FakeControlClient(), login: login)
        #expect(!m.launchAtLogin)
        m.setLaunchAtLogin(true)
        #expect(m.launchAtLogin)
        login.failure.with { $0 = URLError(.cancelled) }
        m.setLaunchAtLogin(false)
        #expect(m.launchAtLogin)   // unchanged on failure
        #expect(m.lastError?.contains("Launch at login") == true)
    }

    @Test func eventLogIsCapped() async {
        let fake = FakeControlClient()
        let m = makeModel(fake)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        for i in 0..<260 { m.log("line \(i)") }
        #expect(m.eventLog.count == 200)
        #expect(m.eventLog.last?.hasSuffix("line 259") == true)
        m.stop()
    }
}

@Suite @MainActor struct ApprovalGateTests {
    private func setup(patch: String, status: JobStatusDTO = .awaitingApproval) async -> (AppModel, FakeControlClient, MockClipboard) {
        let fake = FakeControlClient()
        let sum = JobSummary(id: "job/1", source: .mcp, status: status, started: 1)
        await fake.setJobs([sum])
        await fake.setDetail(JobDetail(summary: sum, patch: patch))
        let clip = MockClipboard()
        let m = AppModel(client: fake, clock: RecordingClock(auto: 100), launcher: MockLauncher(.needsModel), mcp: MockMcp(),
                         loginItem: MockLogin(), clipboard: clip, persist: { _ in }, pollInterval: nil)
        m.patchDirectory = NSTemporaryDirectory() + "patches-\(UUID().uuidString)"
        m.start()
        _ = await waitFor { m.connection.isConnected }
        await m.selectJob("job/1")
        return (m, fake, clip)
    }
    private let symlink = "diff --git a/l b/l\nnew file mode 120000\n--- /dev/null\n+++ b/l\n@@ -0,0 +1 @@\n+t\n"
    private let broken = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n a\n"

    @Test func specialPatchNeedsTickBeforeApply() async {
        let (m, fake, _) = await setup(patch: symlink)
        #expect(m.selectedAnalysis?.needsConfirmation == true)
        #expect(!m.applyAvailability(for: m.selectedJob).enabled)
        #expect(m.applyAvailability(for: m.selectedJob).reason?.contains("adds a symlink") == true)
        await m.approve(.apply)
        #expect(await fake.calls.isEmpty)
        m.setPatchConfirmed(true)
        #expect(m.applyAvailability(for: m.selectedJob).enabled)
        await m.approve(.apply)
        #expect(await fake.calls == ["approve:job/1:apply"])
        m.stop()
    }

    @Test func confirmationResetsWhenPatchChanges() async {
        let (m, fake, _) = await setup(patch: symlink)
        m.setPatchConfirmed(true)
        await m.selectJob("job/1")           // same patch: tick kept (e.g. a job event refresh)
        #expect(m.patchConfirmed)
        let sum = JobSummary(id: "job/1", source: .mcp, status: .awaitingApproval, started: 1)
        await fake.setDetail(JobDetail(summary: sum, patch: symlink + "diff --git a/m b/m\nold mode 100644\nnew mode 100755\n"))
        await m.selectJob("job/1")           // patch changed under the user: tick dropped
        #expect(!m.patchConfirmed)
        m.stop()
    }

    @Test func unparseablePatchCanOnlyBeRejected() async {
        let (m, fake, _) = await setup(patch: broken)
        #expect(m.selectedAnalysis?.blocked == true)
        m.setPatchConfirmed(true)
        #expect(!m.applyAvailability(for: m.selectedJob).enabled)
        #expect(m.approveAvailability(for: m.selectedJob).enabled)   // Reject stays available
        await m.approve(.apply)
        await m.approve(.reject)
        #expect(await fake.calls == ["approve:job/1:reject"])
        m.stop()
    }

    @Test func copyPatchPathWritesFileAndCopiesPath() async throws {
        let (m, _, clip) = await setup(patch: broken)
        m.copyPatchPath()
        let path = try #require(clip.copied.value.first)
        #expect(path.hasSuffix("/job_1.patch"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == broken)
        try? FileManager.default.removeItem(atPath: m.patchDirectory)
        m.stop()
    }
}

@Suite @MainActor struct PatchDigestTests {
    private let patchA = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
    private let patchB = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+EVIL\n"
    private func setup(_ patch: String) async -> (AppModel, FakeControlClient) {
        let fake = FakeControlClient()
        await fake.setJobs([JobSummary(id: "j", source: .mcp, status: .awaitingApproval, started: 1)])
        await fake.setDetail(JobDetail(summary: JobSummary(id: "j", source: .mcp, status: .awaitingApproval, started: 1), patch: patch))
        let m = AppModel(client: fake, clock: RecordingClock(auto: 100), launcher: MockLauncher(.needsModel), mcp: MockMcp(),
                         loginItem: MockLogin(), clipboard: MockClipboard(), persist: { _ in }, pollInterval: nil)
        m.start(); _ = await waitFor { m.connection.isConnected }
        await m.selectJob("j")
        return (m, fake)
    }
    private func change(_ fake: FakeControlClient, to patch: String) async {
        await fake.setDetail(JobDetail(summary: JobSummary(id: "j", source: .mcp, status: .awaitingApproval, started: 1), patch: patch))
    }

    @Test func sha256KnownVector() {
        #expect(PatchDigest.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(PatchDigest.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
    @Test func applySendsDigestOfReviewedBytes() async {
        let (m, fake) = await setup(patchA)
        #expect(m.reviewedDigest == PatchDigest.sha256(patchA))
        await m.approve(.apply)
        let sent = await fake.approvals
        #expect(sent.count == 1 && sent[0].patchSHA256 == PatchDigest.sha256(patchA) && sent[0].action == .apply)
        m.stop()
    }
    @Test func patchChangingAfterReviewDisablesApplyUntilReReviewed() async {
        let (m, fake) = await setup(patchA)
        #expect(m.applyAvailability(for: m.selectedJob).enabled)
        await change(fake, to: patchB)
        await m.refreshSelectedJob()                       // e.g. triggered by a job event
        #expect(m.selectedJob?.patch == patchB)            // the new patch is what is shown
        #expect(m.patchChangedSinceReview)
        let av = m.applyAvailability(for: m.selectedJob)
        #expect(!av.enabled && av.reason?.contains("changed") == true)
        #expect(m.approveAvailability(for: m.selectedJob).enabled)   // Reject stays possible
        await m.approve(.apply)
        #expect(await fake.approvals.isEmpty)
        m.acknowledgeUpdatedPatch()
        #expect(m.applyAvailability(for: m.selectedJob).enabled)
        await m.approve(.apply)
        #expect(await fake.approvals.map(\.patchSHA256) == [PatchDigest.sha256(patchB)])
        m.stop()
    }
    @Test func patchChangingBetweenLastRefreshAndApplyIsCaught() async {
        let (m, fake) = await setup(patchA)
        await change(fake, to: patchB)                     // no refresh happened: UI still shows A
        await m.approve(.apply)                            // pre-flight re-fetch must notice
        #expect(await fake.approvals.isEmpty)
        #expect(m.lastError?.contains("changed") == true)
        #expect(m.patchChangedSinceReview)
        m.stop()
    }
    @Test func changeInvalidatesConfirmationTicks() async {
        let sym = "diff --git a/l b/l\nnew file mode 120000\n--- /dev/null\n+++ b/l\n@@ -0,0 +1 @@\n+t\n"
        let (m, fake) = await setup(sym)
        m.setPatchConfirmed(true)
        #expect(m.applyAvailability(for: m.selectedJob).enabled)
        await change(fake, to: sym + "diff --git a/b.sh b/b.sh\nold mode 100644\nnew mode 100755\n")
        await m.refreshSelectedJob()
        #expect(!m.patchConfirmed)
        m.acknowledgeUpdatedPatch()
        #expect(!m.applyAvailability(for: m.selectedJob).enabled)   // still needs a fresh tick
        m.setPatchConfirmed(true)
        #expect(m.applyAvailability(for: m.selectedJob).enabled)
        m.stop()
    }
    @Test func rejectDoesNotNeedDigest() async {
        let (m, fake) = await setup(patchA)
        await m.approve(.reject)
        #expect(await fake.calls == ["approve:j:reject"])
        m.stop()
    }
}
