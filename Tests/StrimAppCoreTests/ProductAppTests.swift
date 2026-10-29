import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

@MainActor
private func make(_ client: StrimControlClient, clip: MockClipboard = MockClipboard(),
                  settings: AppSettings = AppSettings(modelPath: "/models/q", projectPath: "/tmp", startServerWhenOpens: false),
                  persisted: Locked<[AppSettings]> = Locked([]),
                  scan: @escaping @Sendable () -> [LocalModel] = { [] }) -> AppModel {
    AppModel(client: client, settings: settings, clock: RecordingClock(auto: 100), launcher: MockLauncher(.needsModel), mcp: MockMcp(),
             loginItem: MockLogin(), clipboard: clip, persist: { s in persisted.with { $0.append(s) } }, pollInterval: nil,
             modelScan: scan, modelDownloader: ModelDownloader(modelExists: { true }))
}

/// Connected, connect-time fetches done and the event stream subscribed (so `setFailNext` hits the next real call).
@MainActor
private func settled(_ m: AppModel, _ fake: FakeControlClient) async -> Bool {
    m.start()
    let up = await waitFor { m.connection.isConnected && m.packInfo != nil }
    guard up else { return false }
    await fake.emit(.status(FakeControlClient.sampleStatus))
    return await waitFor { m.lastEventTime != nil }
}

@MainActor
private func chatReady(_ fake: FakeControlClient, _ m: AppModel) async -> String? {
    guard await settled(m, fake) else { return nil }
    await m.probeChat()
    guard case .ready(let s) = m.chat else { return nil }
    return s.sessionID
}

private func delta(_ sid: String, _ k: ChatDeltaKind, _ t: String) -> StrimEvent { .chatDelta(ChatDelta(sessionID: sid, kind: k, text: t)) }

@MainActor
@Suite struct PauseAndCancelTests {
    @Test func pauseButtonIsRealAndToggles() async {
        let fake = FakeControlClient()
        let m = make(fake)
        #expect(m.pauseAvailability == .no("Host offline"))
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        #expect(m.pauseAvailability.enabled && m.pauseButtonTitle == "Pause jobs" && !m.jobsPaused)
        await m.togglePause()
        #expect(await fake.calls.contains("pause:false"))
        #expect(m.jobsPaused && m.pauseButtonTitle == "Resume jobs")
        await m.togglePause()
        #expect(await fake.calls.last == "resume")
        #expect(!m.jobsPaused)
        m.stop()
    }

    @Test func pauseFailureShowsError() async {
        let fake = FakeControlClient()
        let m = make(fake)
        #expect(await settled(m, fake))
        await fake.setFailNext(APIError(code: "boom", message: "nope"))
        await m.pauseJobs()
        #expect(m.lastError?.contains("Pause jobs") == true)
        #expect(!m.jobsPaused)
        m.stop()
    }

    @Test func cancelJobAvailabilityPerState() async {
        let fake = FakeControlClient()
        let m = make(fake)
        func sum(_ s: JobStatusDTO) -> JobSummary { JobSummary(id: "j_\(s.rawValue)", source: .mcp, status: s, started: 1) }
        #expect(m.cancelJobAvailability(for: sum(.running)) == .no("Host offline"))
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        for s in JobStatusDTO.allCases {
            let av = m.cancelJobAvailability(for: sum(s))
            let finished: [JobStatusDTO] = [.done, .failed, .cancelled, .limit]
            #expect(av.enabled == !finished.contains(s), "\(s)")
        }
        #expect(m.cancelJobAvailability(for: nil) == .no("Select a job"))
        m.stop()
    }

    @Test func cancelJobCallsHostAndRefreshes() async {
        let fake = FakeControlClient()
        await fake.setJobs([JobSummary(id: "j_abcdefgh23", source: .mcp, status: .running, started: 1)])
        let m = make(fake)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        await m.refreshJobs()
        await m.cancelJob("j_abcdefgh23")
        #expect(await fake.calls.contains("cancel_job:j_abcdefgh23"))
        #expect(m.jobs.first?.status == .cancelled)
        let before = await fake.calls.count
        await m.cancelJob("j_abcdefgh23")      // already cancelled: no second call
        #expect(await fake.calls.count == before)
        m.stop()
    }
}

@MainActor
@Suite struct ChatControlsTests {
    @Test func toolCardsPairCallAndResult() async {
        let fake = FakeControlClient()
        let m = make(fake)
        guard let sid = await chatReady(fake, m) else { Issue.record("no chat"); return }
        await fake.emit(delta(sid, .toolCall, "read_file path=a.txt"))
        await fake.emit(delta(sid, .toolCall, "bash ls"))
        await fake.emit(delta(sid, .toolResult, "read_file: 3 lines"))
        await fake.emit(delta(sid, .toolResult, "bash ERROR: exit 2"))
        #expect(await waitFor { m.chatMessages.count == 2 && m.chatMessages.allSatisfy { $0.tool?.finished == true } })
        let a = m.chatMessages[0].tool!, b = m.chatMessages[1].tool!
        #expect(a == ToolCard(name: "read_file", args: "path=a.txt", result: "3 lines", isError: false))
        #expect(b.name == "bash" && b.isError && b.result == "exit 2")
        m.stop()
    }

    @Test func reasoningIsSeparateFromAnswer() async {
        let fake = FakeControlClient()
        let m = make(fake)
        guard let sid = await chatReady(fake, m) else { Issue.record("no chat"); return }
        await fake.emit(delta(sid, .reasoning, "think "))
        await fake.emit(delta(sid, .reasoning, "hard"))
        await fake.emit(delta(sid, .text, "42"))
        #expect(await waitFor { m.chatMessages.last?.text == "42" })
        #expect(m.chatMessages.map(\.role) == [.reasoning, .assistant])
        #expect(m.chatMessages[0].text == "think hard")
        m.stop()
    }

    @Test func manyDeltasCoalesceIntoOneMessage() async {
        let fake = FakeControlClient()
        let m = make(fake)
        guard let sid = await chatReady(fake, m) else { Issue.record("no chat"); return }
        for i in 0..<200 { await fake.emit(delta(sid, .text, "\(i % 10)")) }
        await fake.emit(delta(sid, .done, "ok"))
        #expect(await waitFor { m.chatMessages.last?.text.count == 200 })
        #expect(m.chatMessages.count == 1)
        m.stop()
    }

    @Test func turnLedgerFromUsageFrames() async {
        let fake = FakeControlClient()
        let m = make(fake)
        guard let sid = await chatReady(fake, m) else { Issue.record("no chat"); return }
        await m.sendChat("go")
        #expect(m.chatGenerating)
        await fake.emit(.harnessEvent(HarnessEvent(jobID: sid, kind: "usage", text: "100/40/20")))
        await fake.emit(delta(sid, .toolCall, "ls"))
        await fake.emit(.harnessEvent(HarnessEvent(jobID: sid, kind: "usage", text: "150/100/30")))
        await fake.emit(.harnessEvent(HarnessEvent(jobID: "other", kind: "usage", text: "9999/0/9999")))
        await fake.emit(delta(sid, .text, "done"))
        await fake.emit(delta(sid, .done, "ok"))
        #expect(await waitFor { !m.chatGenerating })
        let l = m.chatMessages.last?.ledger
        #expect(l?.prompt == 250 && l?.cached == 140 && l?.completion == 50 && l?.local == 50)
        #expect(l?.seconds == 0)       // the test clock does not advance
        #expect(l?.summary.contains("local 50") == true)
        m.stop()
    }

    @Test func stopCancelsAndAllowsNextTurn() async {
        let fake = FakeControlClient()
        let m = make(fake)
        guard let sid = await chatReady(fake, m) else { Issue.record("no chat"); return }
        await m.sendChat("first")
        #expect(m.chatGenerating)
        await m.sendChat("second")           // ignored while a turn runs
        #expect(await fake.appends.count == 1)
        await m.cancelChat()
        #expect(await fake.calls.contains("chat_cancel:\(sid)"))
        #expect(!m.chatGenerating)
        await m.sendChat("third")
        #expect(await fake.appends.count == 2)
        m.stop()
    }

    @Test func stopIsInertWhenIdle() async {
        let fake = FakeControlClient()
        let m = make(fake)
        guard await chatReady(fake, m) != nil else { Issue.record("no chat"); return }
        await m.cancelChat()
        #expect(await !fake.calls.contains { $0.hasPrefix("chat_cancel") })
        m.stop()
    }

    @Test func thinkingToggleIsSentWithOpenAndAppend() async {
        let fake = FakeControlClient()
        let m = make(fake)
        m.thinkingEnabled = false
        guard let sid = await chatReady(fake, m) else { Issue.record("no chat"); return }
        await m.sendChat("hi")
        #expect(await fake.appends.last == ChatAppendRequest(sessionID: sid, text: "hi", enableThinking: false))
        await fake.emit(delta(sid, .done, "ok"))
        #expect(await waitFor { !m.chatGenerating })
        m.thinkingEnabled = true
        await m.sendChat("again")
        #expect(await fake.appends.last?.enableThinking == true)
        m.stop()
    }

    @Test func failedSendReleasesTheTurn() async {
        let fake = FakeControlClient()
        let m = make(fake)
        guard await chatReady(fake, m) != nil else { Issue.record("no chat"); return }
        await fake.setFailNext(APIError(code: "turn_in_progress", message: "busy"))
        await m.sendChat("x")
        #expect(!m.chatGenerating)
        #expect(m.lastError?.hasPrefix("Chat:") == true)
        m.stop()
    }

    @Test func copyMessageUsesClipboard() async {
        let fake = FakeControlClient()
        let clip = MockClipboard()
        let m = make(fake, clip: clip)
        guard let sid = await chatReady(fake, m) else { Issue.record("no chat"); return }
        await fake.emit(delta(sid, .text, "hello"))
        await fake.emit(delta(sid, .toolCall, "ls -la"))
        await fake.emit(delta(sid, .toolResult, "ls: ok"))
        #expect(await waitFor { m.chatMessages.count == 2 && m.chatMessages[1].tool?.finished == true })
        m.copyMessage(m.chatMessages[0].id)
        m.copyMessage(m.chatMessages[1].id)
        #expect(clip.copied.value == ["hello", "ls -la\nok"])
        m.stop()
    }

    @Test func parsers() {
        #expect(TokenLedger.parse("1/2/3")! == (1, 2, 3))
        #expect(TokenLedger.parse("1/2") == nil && TokenLedger.parse("a/b/c") == nil)
        let r = ToolCard.parseResult("read_file ERROR: no such file: x")
        #expect(r.name == "read_file" && r.isError && r.summary == "no such file: x")
        #expect(ToolCard.call("solo").args == "" && ToolCard.call("").name == "tool")
        var l = TokenLedger(prompt: 10, cached: 0, completion: 100, seconds: 2)
        #expect(l.tokensPerSecond == 50 && l.summary.contains("50.0 tok/s"))
        l.seconds = 0
        #expect(l.tokensPerSecond == nil)
    }
}

@MainActor
@Suite struct PickerTests {
    private func tmp() -> String {
        let d = NSTemporaryDirectory() + "strim-proj-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return URL(fileURLWithPath: d).resolvingSymlinksInPath().path
    }

    @Test func modelListFromHostAndSelectionNeedsLoad() async {
        let fake = FakeControlClient(status: HostStatus(state: .stopped, memory: MemoryStats(weightsGB: 0, prefixTrieGB: 0, mlxCacheGB: 0, headroomGB: 0)))
        await fake.setModels([LocalModel(name: "Qwen-27B", path: "/models/Qwen-27B", sizeGB: 15), LocalModel(name: "mtp-head", path: "/models/mtp-head", kind: "mtp")])
        let saved = Locked<[AppSettings]>([])
        let m = make(fake, settings: AppSettings(), persisted: saved)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        await m.refreshModels()
        #expect(m.availableModels.count == 2)
        #expect(m.loadAvailability == .yes, "no saved model path falls back to the default model, no manual step")
        m.selectModel(m.availableModels[0])
        #expect(m.settings.modelPath == "/models/Qwen-27B")
        #expect(saved.value.last?.modelPath == "/models/Qwen-27B")
        #expect(await fake.calls.isEmpty, "selecting never loads")
        #expect(m.modelSelectionNote?.contains("Press Load") == true)
        #expect(m.loadAvailability.enabled)
        m.selectModel(m.availableModels[1])
        #expect(m.settings.mtpPath == "/models/mtp-head" && m.settings.modelPath == "/models/Qwen-27B")
        await m.loadModel()
        #expect(await fake.calls == ["load:/models/Qwen-27B"])
        m.stop()
    }

    @Test func selectingWhileLoadedAsksForUnloadFirst() async {
        let fake = FakeControlClient()   // ready with Qwen3.8-27B
        let m = make(fake, settings: AppSettings(modelPath: "/models/Other"))
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        #expect(m.modelSelectionNote?.contains("Unload, then Load") == true)
        #expect(!m.loadAvailability.enabled)
        m.stop()
    }

    @Test func modelListFallsBackToLocalScan() async {
        let fake = FakeControlClient()
        let m = make(fake, scan: { [LocalModel(name: "Local", path: "/home/x/.strim/models/Local")] })
        #expect(await settled(m, fake))
        await fake.setFailNext(ControlClientError.notImplemented)
        await m.refreshModels()
        #expect(m.availableModels.map(\.name) == ["Local"])
        #expect(m.modelListNote?.contains("Scanned locally") == true)
        m.stop()
    }

    @Test func localScannerFindsConfigDirs() throws {
        let root = tmp()
        for n in ["A", "mtp-b", "none"] { try FileManager.default.createDirectory(atPath: root + "/" + n, withIntermediateDirectories: true) }
        for n in ["A", "mtp-b"] { try Data("{}".utf8).write(to: URL(fileURLWithPath: root + "/" + n + "/config.json")) }
        let found = LocalModelScanner.scan(roots: [root, root + "/missing"])
        #expect(found.map(\.name) == ["A", "mtp-b"] && found[1].kind == "mtp")
    }

    @Test func projectPickerValidatesAndKeepsRecents() async {
        let fake = FakeControlClient()
        let saved = Locked<[AppSettings]>([])
        let m = make(fake, settings: AppSettings(), persisted: saved)
        m.start()
        #expect(await waitFor { m.connection.isConnected })
        let a = tmp(), b = tmp()
        #expect(m.setProject(a))
        #expect(m.settings.projectPath == a && m.settings.recentProjects == [a])
        #expect(m.setProject(b))
        #expect(m.setProject(a))
        #expect(m.settings.recentProjects == [a, b], "newest first, no duplicates")
        #expect(saved.value.last?.recentProjects == [a, b])
        // Rejections leave settings alone.
        let before = m.settings
        #expect(!m.setProject(NSHomeDirectory()))
        #expect(m.lastError?.contains("home folder") == true)
        #expect(!m.setProject("/definitely/not/here"))
        #expect(!m.setProject("relative/dir"))
        #expect(m.settings == before)
        m.stop()
    }

    @Test func recentsAreCappedAndStaleOnesHidden() {
        let fake = FakeControlClient()
        let dirs = (0..<10).map { _ in tmp() }
        let m = make(fake, settings: AppSettings())
        for d in dirs { m.setProject(d) }
        #expect(m.settings.recentProjects.count == AppSettings.maxRecents)
        #expect(m.settings.recentProjects.first == dirs.last)
        try? FileManager.default.removeItem(atPath: dirs.last!)
        #expect(m.validRecentProjects.count == AppSettings.maxRecents - 1)
    }

    @Test func changingProjectStartsANewChat() async {
        let fake = FakeControlClient()
        let m = make(fake)
        guard await chatReady(fake, m) != nil else { Issue.record("no chat"); return }
        await m.sendChat("hi")
        #expect(!m.chatMessages.isEmpty)
        #expect(m.setProject(tmp()))
        #expect(m.chat == .unknown && m.chatMessages.isEmpty && !m.chatGenerating)
        m.stop()
    }

    @Test func recentProjectsRoundTripInSettingsFile() throws {
        let path = NSTemporaryDirectory() + "strim-app-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var s = AppSettings(); s.recentProjects = ["/a", "/b"]
        try s.save(path: path)
        #expect(AppSettings.load(path: path).recentProjects == ["/a", "/b"])
        try Data(#"{"model_path":"/m"}"#.utf8).write(to: URL(fileURLWithPath: path))
        #expect(AppSettings.load(path: path).recentProjects.isEmpty)
    }
}

@MainActor
@Suite struct PackInfoTests {
    @Test func packLoadsOnConnectAndRefresh() async {
        let fake = FakeControlClient()
        let e = EvolveSummary(fingerprint: "bbbbbbbbbbbbbbbb", round: 2, valGainPP: 1.5, createdAt: "2026-10-22T10:00:00Z")
        await fake.setPack(PackInfo(activeFingerprint: "aaaaaaaaaaaaaaaa", packCount: 2, lastEvolve: e))
        let m = make(fake)
        #expect(m.packInfo == nil)
        m.start()
        #expect(await waitFor { m.packInfo != nil })
        #expect(m.packInfo?.activeFingerprint == "aaaaaaaaaaaaaaaa" && m.packInfo?.lastEvolve == e)
        await fake.setPack(PackInfo())
        await m.refreshPack()
        #expect(m.packInfo?.activeFingerprint == nil && m.packInfo?.lastEvolve == nil)
        m.stop()
    }

    @Test func oldHostWithoutPackRouteLeavesItEmpty() async {
        let fake = FakeControlClient()
        let m = make(fake)
        #expect(await settled(m, fake))
        await fake.setFailNext(ControlClientError.notImplemented)
        await m.refreshPack()
        #expect(m.packInfo == PackInfo(), "the last known value stays")
        m.stop()
    }
}

@Suite struct BlankModelPathTests {
    @Test func blankPathsInAppJsonDecodeAsUnset() throws {
        let json = #"{"model_path": "", "mtp_path": "  "}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(s.modelPath == nil && s.mtpPath == nil)
    }
    @Test func realPathsSurvive() throws {
        let json = #"{"model_path": " /m/qwen "}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(s.modelPath == "/m/qwen")
    }
}
