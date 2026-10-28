import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

/// `STRIM_APP_SNAPSHOT_DIR=<dir> StrimApp` renders the main views from sample data (a scripted `FakeControlClient`,
/// no host, no network) into PNG files and exits. Used for the docs screenshots.
enum SnapshotMode {
    static var directory: String? {
        let d = ProcessInfo.processInfo.environment["STRIM_APP_SNAPSHOT_DIR"]
        return (d?.isEmpty ?? true) ? nil : d
    }

    @MainActor
    static func run(into dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)
        let fake = FakeControlClient(status: sampleStatus())
        await fake.setJobs([
            JobSummary(id: "j_abcdefgh23", source: .mcp, status: .running, started: Date().timeIntervalSince1970 - 90, title: "Fix failing ParseTests"),
            JobSummary(id: "j_bcdefghi34", source: .mcp, status: .queued, started: Date().timeIntervalSince1970 - 30, title: "Rename Config.timeout"),
            JobSummary(id: "j_cdefghij45", source: .chat, status: .done, verify: .verified, started: Date().timeIntervalSince1970 - 600, title: "Chat: strim-engine"),
        ])
        await fake.setModels([
            LocalModel(name: "Qwen3.8-27B-4bit", path: "/Users/me/models/Qwen3.8-27B-4bit", sizeGB: 15.2),
            LocalModel(name: "Qwen3.8-27B-mtp", path: "/Users/me/models/Qwen3.8-27B-mtp", sizeGB: 0.9, kind: "mtp"),
        ])
        await fake.setPack(PackInfo(activeFingerprint: "3f9a1c07d2b84e65", packCount: 3,
                                    lastEvolve: EvolveSummary(fingerprint: "3f9a1c07d2b84e65", parent: "a1b2c3d4e5f60718", round: 4,
                                                              valGainPP: 3.5, dryRun: false, createdAt: "2026-10-27T18:42:10Z")))
        let project = "/tmp/strim-engine"     // sample folder (resolves to /private/tmp/...); no real paths in screenshots
        try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        var settings = AppSettings(modelPath: "/Users/me/models/Qwen3.8-27B-4bit", mtpPath: "/Users/me/models/Qwen3.8-27B-mtp",
                                   controlTokenPath: "/Users/me/.strim/control-token", projectPath: project)
        settings.recentProjects = [project]
        let model = AppModel(client: fake, settings: settings, persist: { _ in }, pollInterval: nil,
                             tokenStatus: { _ in .ok }, modelScan: { [] })
        model.start()
        for _ in 0..<200 where !(model.connection.isConnected && model.packInfo != nil) { try? await Task.sleep(for: .milliseconds(10)) }
        await model.refreshJobs(); await model.refreshModels()
        await model.probeChat()
        guard case .ready(let s) = model.chat else { FileHandle.standardError.write(Data("snapshot: chat not ready\n".utf8)); exit(1) }
        await model.sendChat("Why does ParseTests.testTrailingComma fail?")
        func d(_ k: ChatDeltaKind, _ t: String) async { await fake.emit(.chatDelta(ChatDelta(sessionID: s.sessionID, kind: k, text: t))) }
        await d(.reasoning, "The test builds `[1, 2,]` and expects 2 elements. Let me read the parser before guessing.")
        await d(.toolCall, "read_file Sources/Parser.swift")
        await d(.toolResult, "read_file: 84 lines")
        await d(.toolCall, "bash swift test --filter ParseTests")
        await d(.toolResult, "bash ERROR: 1 failure: testTrailingComma expected 2, got 3")
        await d(.text, "`parseList` appends an empty element after a trailing comma. In `Parser.swift` line 41 the loop adds the token before checking for `]`. ")
        await d(.text, "Checking for the closing bracket first fixes it; the change is a three-line reorder.")
        await fake.emit(.harnessEvent(HarnessEvent(jobID: s.sessionID, kind: "usage", text: "2310/1980/164")))
        await fake.emit(.harnessEvent(HarnessEvent(jobID: s.sessionID, kind: "usage", text: "2870/2400/96")))
        await d(.done, "ok")
        for _ in 0..<300 where model.chatGenerating { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(150))
        await model.pauseJobs()

        shoot(ChatTab(model: model), "app-chat.png", 760, 560, dir)
        shoot(ChatTab(model: model, expandAll: true), "app-chat-expanded.png", 760, 700, dir)
        shoot(StatusTab(model: model), "app-status.png", 640, 640, dir)
        shoot(SettingsTab(model: model), "app-settings.png", 760, 640, dir)
        exit(0)
    }

    private static func sampleStatus() -> HostStatus {
        HostStatus(state: .ready, model: "Qwen3.8-27B-4bit", mtp: "Qwen3.8-27B-mtp",
                   memory: MemoryStats(weightsGB: 15.2, prefixTrieGB: 2.4, mlxCacheGB: 1.1, headroomGB: 21),
                   decodeTPS: 41.2, prefillTPS: 1180, mtpAcceptance: 0.71, mtpDepth: 2.3, prefixHitRate: 0.86,
                   savedPrefillSeconds: 412, activeJobs: 1, queuedJobs: 1, tokensToday: 183_400, localTokensGenerated: 52_100,
                   uptimeSeconds: 7260, jobsPaused: false)
    }

    @MainActor
    private static func shoot<V: View>(_ view: V, _ name: String, _ w: CGFloat, _ h: CGFloat, _ dir: String) {
        let host = NSHostingView(rootView: view.frame(width: w, height: h).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}
