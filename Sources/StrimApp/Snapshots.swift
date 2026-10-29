import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

/// `StrimApp --snapshots <dir>` (or `STRIM_APP_SNAPSHOT_DIR=<dir>`) renders the real views from fixtures (a scripted
/// `FakeControlClient`: no host, no network, no model) into PNGs inside a drawn macOS window frame and exits.
/// Deterministic: fixed sample data, fixed sizes, scale 2. Used for docs/img/app.
enum SnapshotMode {
    static var directory: String? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshots"), i + 1 < args.count { return args[i + 1] }
        let d = ProcessInfo.processInfo.environment["STRIM_APP_SNAPSHOT_DIR"]
        return (d?.isEmpty ?? true) ? nil : d
    }

    static let now = Date().timeIntervalSince1970

    @MainActor
    static func run(into dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.regular)
        if let tr = SnapshotMode.value("--from-transcript") { await runTranscript((tr as NSString).expandingTildeInPath, into: dir); exit(0) }
        if CommandLine.arguments.contains("--offline-menu") { await runOfflineMenu(into: dir); exit(0) }
        if let live = LiveOptions.parse() { await runLive(live, into: dir); exit(0) }
        if CommandLine.arguments.contains("--projects") { await runProjects(into: dir); exit(0) }
        if CommandLine.arguments.contains("--grants") { await runGrants(into: dir); exit(0) }

        let icon = SnapshotMode.value("--icon") ?? "packaging/app/icon/icon-1024.png"
        if let img = NSImage(contentsOfFile: icon) { NSApp.applicationIconImage = img }
        let history: [Double] = (0..<60).map { (i: Int) -> Double in let x = Double(i); return 62 + 9 * sin(x / 5) + 3 * cos(x / 2.3) }
        let running = await scenario(status: runningStatus(), jobs: sampleJobs(), history: history)
        let idle = await scenario(status: runningStatus(state: .ready, decode: 0), jobs: [], history: history)
        let stoppedStatus = HostStatus(state: .stopped, memory: MemoryStats(weightsGB: 0, prefixTrieGB: 0, mlxCacheGB: 0, headroomGB: 64), uptimeSeconds: 0, jobsPaused: false)
        let stopped = await scenario(status: stoppedStatus)
        let errored = await scenario(status: HostStatus(state: .error, memory: MemoryStats(weightsGB: 0, prefixTrieGB: 0, mlxCacheGB: 0, headroomGB: 64),
                                                          uptimeSeconds: 0, lastCrash: "Metal command buffer failed: out of memory while loading model-00017-of-00032.safetensors", jobsPaused: false))
        let jobs = await scenario(status: runningStatus(), jobs: sampleJobs(), details: sampleDetails(), select: "j_bcdefghi34")
        let chat = await scenario(status: runningStatus(), chat: true)
        let settings = await scenario(status: runningStatus())
        func dl(_ s: ModelDownloadState, free: Int64 = 24_800_000_000, paused: Double? = nil) async -> AppModel {
            await scenario(status: stoppedStatus, downloadState: s, free: free, pausedFraction: paused)
        }
        let needsDownload = await dl(.needsDownload(sizeBytes: 15_200_000_000, freeBytes: 24_800_000_000, resumable: false))
        let lowDisk = await dl(.needsDownload(sizeBytes: 15_200_000_000, freeBytes: 19_000_000_000, resumable: false), free: 19_000_000_000)
        let downloading = await dl(.downloading(.init(file: "qwen38-4bit/model-00017-of-00032.safetensors", doneBytes: 6_384_000_000, totalBytes: 15_200_000_000, bytesPerSec: 28_400_000, etaSec: 310)))
        let paused = await dl(.needsDownload(sizeBytes: 15_200_000_000, freeBytes: 24_800_000_000, resumable: true), paused: 0.42)
        let verifying = await dl(.verifying(file: "qwen38-4bit/model-00017-of-00032.safetensors"))
        let startingServer = await dl(.startingServer)
        let failedDownload = await dl(.failed(message: "The network connection was lost while downloading model-00017-of-00032.safetensors. Downloaded parts are kept.", resumable: true))
        let loading = await scenario(status: HostStatus(state: .loading, loadProgress: 0.42, memory: MemoryStats(weightsGB: 6.4, prefixTrieGB: 0, mlxCacheGB: 0, headroomGB: 26.1), uptimeSeconds: 4, jobsPaused: false))

        if let sizes = Self.parseSizes(SnapshotMode.value("--sizes")) {
            // Responsive matrix: the same real views at each window size, both schemes. `<view>-<w>x<h>-<scheme>.png`.
            let jobsList = await scenario(status: runningStatus(), jobs: sampleJobs(), details: sampleDetails())
            for (w, h) in sizes {
                for scheme in [ColorScheme.dark, .light] {
                    let s = scheme == .dark ? "dark" : "light", z = "\(Int(w))x\(Int(h))"
                    shoot(MainWindow(model: running, section: .status), "status-\(z)-\(s)", w, h, scheme, dir)
                    shoot(MainWindow(model: stopped, section: .status), "status-stopped-\(z)-\(s)", w, h, scheme, dir)
                    shoot(MainWindow(model: jobsList, section: .jobs), "jobs-list-\(z)-\(s)", w, h, scheme, dir)
                    shoot(MainWindow(model: jobs, section: .jobs), "jobs-\(z)-\(s)", w, h, scheme, dir)
                    shoot(MainWindow(model: chat, section: .chat, expandChat: true), "chat-\(z)-\(s)", w, h, scheme, dir)
                    shoot(MainWindow(model: downloading), "fixture-downloading-42-\(z)-\(s)", w, h, scheme, dir)
                }
            }
            exit(0)
        }

        let W: CGFloat = 1040, H: CGFloat = 560
        for scheme in [ColorScheme.dark, .light] {
            let s = scheme == .dark ? "dark" : "light"
            shoot(MainWindow(model: running, section: .status), "status-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: idle, section: .status), "status-idle-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: stopped, section: .status), "status-stopped-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: errored, section: .status), "status-error-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: loading, section: .status), "status-loading-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: jobs, section: .jobs), "jobs-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: chat, section: .chat, expandChat: true), "chat-\(s)", W, H, scheme, dir)
            for p in SettingsPane.allCases {
                shootSettings(SettingsView(model: settings, pane: p), "settings-\(p.rawValue)-\(s)", scheme, dir)
            }
            shootSettings(SettingsView(model: settings, pane: .general), "settings-\(s)", scheme, dir)
            shoot(MainWindow(model: needsDownload), "fixture-needs-download-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: lowDisk), "fixture-low-disk-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: downloading), "fixture-downloading-42-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: paused), "fixture-paused-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: verifying), "fixture-verifying-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: startingServer), "fixture-starting-server-\(s)", W, H, scheme, dir)
            shoot(MainWindow(model: failedDownload), "fixture-failed-\(s)", W, H, scheme, dir)
            shootPopover(MenuContent(model: running), "menu-\(s)", scheme, dir)
            shootPopover(MenuContent(model: stopped), "menu-stopped-\(s)", scheme, dir)
            shootPopover(MenuContent(model: downloading), "menu-downloading-\(s)", scheme, dir)
        }
        glyphs(dir)
        hero(dir)
        exit(0)
    }

    // MARK: fixtures

    static func runningStatus(state: HostState = .busy, decode: Double = 70.2) -> HostStatus {
        HostStatus(state: state, model: "qwen38-4bit", mtp: "qwen38-mtp-4bit",
                   memory: MemoryStats(weightsGB: 15.2, prefixTrieGB: 1.6, mlxCacheGB: 0.8, headroomGB: 14.9),
                   decodeTPS: decode, prefillTPS: 807, mtpAcceptance: 0.85, mtpDepth: 3.5, prefixHitRate: 0.76,
                   savedPrefillSeconds: 16.4, activeJobs: decode > 0 ? 1 : 0, queuedJobs: 0, tokensToday: 760, localTokensGenerated: 520,
                   uptimeSeconds: 26, parentTokensSavedEstimate: nil, jobsPaused: false,
                   quantFingerprint: "3f9a1c07d2b84e65/9be41d20a7c35f18")
    }

    static func sampleJobs() -> [JobSummary] {
        [JobSummary(id: "j_abcdefgh23", source: .mcp, status: .running, started: now - 90, title: "Fix failing ParseTests"),
         JobSummary(id: "j_bcdefghi34", source: .mcp, status: .awaitingApproval, verify: .verified, started: now - 240, title: "Rename Config.timeout to requestTimeout"),
         JobSummary(id: "j_cdefghij45", source: .chat, status: .done, verify: .verified, started: now - 3600, title: "Chat: strim-engine")]
    }

    static func sampleDetails() -> [JobDetail] {
        let patch = """
        diff --git a/Sources/App/Config.swift b/Sources/App/Config.swift
        --- a/Sources/App/Config.swift
        +++ b/Sources/App/Config.swift
        @@ -10,4 +10,4 @@ struct Config {
             var host: String
        -    var timeout: Double = 30
        +    var requestTimeout: Double = 30
             var retries = 3
         }
        @@ -42,2 +42,2 @@ extension Config {
        -    func deadline() -> Date { Date().addingTimeInterval(timeout) }
        +    func deadline() -> Date { Date().addingTimeInterval(requestTimeout) }
         }

        """
        let jobs = sampleJobs()
        return [
            JobDetail(summary: jobs[0], resultSummary: nil, turns: 6, localTokens: 4_820),
            JobDetail(summary: jobs[1], resultSummary: "Renamed `timeout` to `requestTimeout` in Config.swift and updated the one call site. Build and 41 tests pass.",
                      patch: patch, turns: 9, localTokens: 12_460, verifyOutput: "swift build: ok\nswift test: 41 passed, 0 failed"),
            JobDetail(summary: jobs[2], resultSummary: "Answered 3 questions about the cache layout.", turns: 3, localTokens: 2_100),
        ]
    }

    @MainActor
    static func scenario(status: HostStatus, jobs: [JobSummary] = [], details: [JobDetail] = [], chat: Bool = false,
                         select: String? = nil, downloadState: ModelDownloadState? = nil, free: Int64 = 24_800_000_000,
                         pausedFraction: Double? = nil, history: [Double] = []) async -> AppModel {
        let fake = FakeControlClient(status: status)
        await fake.setJobs(jobs)
        for d in details { await fake.setDetail(d) }
        await fake.setModels([
            LocalModel(name: "qwen38-4bit", path: "/Users/me/.strim/models/qwen38-4bit", sizeGB: 15.2),
            LocalModel(name: "qwen38-mtp-4bit", path: "/Users/me/.strim/models/qwen38-mtp-4bit", sizeGB: 0.9, kind: "mtp"),
        ])
        await fake.setPack(PackInfo(activeFingerprint: "c41e7a92d0b3586f", packCount: 3,
                                    lastEvolve: EvolveSummary(fingerprint: "c41e7a92d0b3586f", parent: "a1b2c3d4e5f60718", round: 4,
                                                              valGainPP: 3.5, dryRun: false, createdAt: "2026-10-27T18:42:10Z")))
        let project = "/tmp/strim-engine"     // sample folder (resolves to /private/tmp/...); no real paths in screenshots
        try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        var settings = AppSettings(modelPath: "/Users/me/.strim/models/qwen38-4bit", mtpPath: "/Users/me/.strim/models/qwen38-mtp-4bit",
                                   controlTokenPath: "/Users/me/.strim/control-token", projectPath: project, startServerWhenOpens: false)
        settings.recentProjects = [project]
        let downloader = ModelDownloader(freeSpace: { _ in free }, modelExists: { false }, initialState: downloadState ?? .done, pausedFraction: pausedFraction)
        let model = AppModel(client: fake, settings: settings, persist: { _ in }, pollInterval: nil,
                             tokenStatus: { _ in .ok }, modelScan: { [] }, modelDownloader: downloader)
        model.start()
        for _ in 0..<200 where !(model.connection.isConnected && model.packInfo != nil) { try? await Task.sleep(for: .milliseconds(10)) }
        await model.refreshJobs(); await model.refreshModels()
        if !history.isEmpty { model.seedDecodeHistory(history) }
        if let select { await model.selectJob(select) }
        guard chat else { return model }
        await model.probeChat()
        guard case .ready(let s) = model.chat else { FileHandle.standardError.write(Data("snapshot: chat not ready\n".utf8)); exit(1) }
        await model.sendChat("Why does ParseTests.testTrailingComma fail?")
        func d(_ k: ChatDeltaKind, _ t: String) async { await fake.emit(.chatDelta(ChatDelta(sessionID: s.sessionID, kind: k, text: t))) }
        await d(.reasoning, "The test builds `[1, 2,]` and expects 2 elements. Let me read the parser before guessing.")
        await d(.toolCall, "read_file Sources/Parser.swift")
        await d(.toolResult, "read_file: public struct Parser {\n    public let title: String\n    var tokens: [Token]\n    mutating func parseList() -> [Int] {\n        var out: [Int] = []\n        while let t = next() {\n            out.append(t.value)\n            if peek() == .close { break }\n        }\n        return out\n    }\n}")
        await d(.toolCall, "bash swift test --filter ParseTests")
        await d(.toolResult, "bash ERROR: 1 failure: testTrailingComma expected 2, got 3")
        await d(.text, "`parseList` appends an empty element after a trailing comma. In `Parser.swift` line 41 the loop adds the token before checking for `]`. ")
        await d(.text, "Checking for the closing bracket first fixes it; the change is a three-line reorder.")
        await fake.emit(.harnessEvent(HarnessEvent(jobID: s.sessionID, kind: "usage", text: "2310/1980/164")))
        await fake.emit(.harnessEvent(HarnessEvent(jobID: s.sessionID, kind: "usage", text: "2870/2400/96")))
        await d(.done, "ok")
        for _ in 0..<300 where model.chatGenerating { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(150))
        return model
    }

    // MARK: rendering

    /// Real titled window (sidebar, unified toolbar, traffic lights) captured by the window server: `screencapture -l`.
    @MainActor
    static func shoot<V: View>(_ content: V, _ name: String, _ w: CGFloat, _ h: CGFloat, _ scheme: ColorScheme, _ dir: String, title: String = "Strim") {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 900)
        if isOversize(w, h, visible: visible.size) {
            // A real window cannot exceed the screen: render the content offscreen (no window chrome) instead.
            FileHandle.standardError.write(Data("snapshot: \(name) oversize: plain render\n".utf8))
            shootPlain(content, name, CGSize(width: w, height: h), scheme, dir)
            return
        }
        let height = min(h, visible.height - 40)
        let hc = NSHostingController(rootView: content)
        hc.sizingOptions = []   // the requested window size wins over the content's ideal size (long chats, sidebars)
        capture(hc, CGSize(width: w, height: height), titled: true, title: title, name, scheme, dir)
    }

    /// The window frame is placed at x 80 / 30 pt below the top and titled (about 28 pt of chrome).
    static func isOversize(_ w: CGFloat, _ h: CGFloat, visible: CGSize) -> Bool {
        w > visible.width - 120 || h > visible.height - 40
    }

    /// `--sizes 640x460,800x560`: ignores malformed entries; nil when the flag is absent or yields nothing.
    static func parseSizes(_ raw: String?) -> [(CGFloat, CGFloat)]? {
        guard let raw else { return nil }
        let out: [(CGFloat, CGFloat)] = raw.split(separator: ",").compactMap { part in
            let p = part.lowercased().split(separator: "x")
            guard p.count == 2, let w = Double(p[0]), let h = Double(p[1]), w >= 320, h >= 240 else { return nil }
            return (CGFloat(w), CGFloat(h))
        }
        return out.isEmpty ? nil : out
    }

    /// Settings scene content in its own window (title "Settings", width 520).
    @MainActor
    static func shootSettings(_ content: SettingsView, _ name: String, _ scheme: ColorScheme, _ dir: String) {
        capture(NSHostingController(rootView: content), CGSize(width: 520, height: 520), titled: true, title: "Settings", name, scheme, dir)
    }

    /// Popover as the menu-bar extra draws it: rounded, hairline, shadow. Height follows the content.
    @MainActor
    static func shootPopover<V: View>(_ content: V, _ name: String, _ scheme: ColorScheme, _ dir: String) {
        let styled = content.fixedSize().clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Strim.C.hairline))
            .padding(20)
        let hc = NSHostingController(rootView: styled)
        let size = hc.sizeThatFits(in: CGSize(width: 400, height: 900))
        capture(hc, size, titled: false, title: "", name, scheme, dir)
    }

    /// Spin the run loop while dispatching AppKit events, so activation and window-server notifications are processed.
    @MainActor
    static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    @MainActor
    static func scrollToBottom(in view: NSView?) {
        guard let view else { return }
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            let y = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for child in view.subviews { scrollToBottom(in: child) }
    }

    @MainActor
    static func capture(_ vc: NSViewController, _ size: CGSize, titled: Bool, title: String, _ name: String, _ scheme: ColorScheme, _ dir: String) {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let screenFrame = NSScreen.main?.frame ?? NSRect(origin: .zero, size: size)
        let backdrop = NSWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        let gray = scheme == .dark ? CGFloat(58) / 255 : CGFloat(232) / 255
        let blue = scheme == .dark ? CGFloat(60) / 255 : CGFloat(234) / 255
        backdrop.isOpaque = true
        backdrop.backgroundColor = NSColor(srgbRed: gray, green: gray, blue: blue, alpha: 1)
        backdrop.hasShadow = false
        backdrop.ignoresMouseEvents = true
        backdrop.level = .normal
        backdrop.orderFrontRegardless()
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        win.appearance = appearance
        win.title = title
        win.hasShadow = false
        if !titled { win.isOpaque = false; win.backgroundColor = .clear }
        win.contentViewController = vc
        win.setContentSize(size)
        win.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 30))
        // Cooperative activation (macOS 14+): ask, then wait up to 2 s until the app is really active so the capture
        // shows an active window (coloured traffic lights, active title bar).
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        for _ in 0..<40 where !NSApp.isActive || !win.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
            pump(0.05)
        }
        if titled { FileHandle.standardError.write(Data("snapshot: \(name) active=\(NSApp.isActive) key=\(win.isKeyWindow) main=\(win.isMainWindow) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\n".utf8)) }
        if titled && !(NSApp.isActive && win.isKeyWindow) { FileHandle.standardError.write(Data("snapshot: \(name) captured while inactive\n".utf8)) }
        pump(1.4)
        if name.hasPrefix("chat-live-") { scrollToBottom(in: win.contentView); pump(0.2) }
        let out = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png").path
        // A capture race can leave an opaque margin around the window (black backdrop). The corner of a titled
        // capture must be transparent; if not, re-shoot (up to twice).
        for attempt in 0..<3 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-l\(win.windowNumber)", "-o", "-x", out]
            try? p.run(); p.waitUntilExit()
            if !titled || cornerIsTransparent(out) { break }
            FileHandle.standardError.write(Data("snapshot: \(name) opaque corner, re-shoot \(attempt + 1)\n".utf8))
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }
        win.orderOut(nil)
        win.contentViewController = nil
        backdrop.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func cornerIsTransparent(_ path: String) -> Bool {
        guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()),
              let c = rep.colorAt(x: 0, y: 0) else { return true }
        return c.alphaComponent < 0.1
    }

    @MainActor
    static func shootPlain<V: View>(_ view: V, _ name: String, _ size: CGSize, _ scheme: ColorScheme, _ dir: String) {
        guard let rep = bitmap(view, size, scheme, scale: 2), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    /// Offline menu rendered through the same AppModel and HTTP client after the host has stopped.
    @MainActor
    static func runOfflineMenu(into dir: String) async {
        let args = CommandLine.arguments
        func value(_ flag: String, _ fallback: String) -> String {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? fallback
        }
        let host = value("--live", "http://127.0.0.1:8231")
        let token = (value("--token-file", "~/.strim/control-token") as NSString).expandingTildeInPath
        let settings = AppSettings(hostURL: host, strimBinary: nil, controlTokenPath: token)
        let model = AppModel(settings: settings, makeClient: { HTTPControlClient.make(settings: $0) },
                             persist: { _ in }, pollInterval: nil)
        model.start()
        for _ in 0..<200 where model.offlineBanner == nil { try? await Task.sleep(for: .milliseconds(10)) }
        guard model.offlineBanner != nil else {
            FileHandle.standardError.write(Data("snapshot --offline-menu: host still reachable at \(host)\n".utf8))
            model.stop()
            exit(1)
        }
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            shootPopover(MenuContent(model: model), "menu-live-offline-\(suffix)", scheme, dir)
        }
        model.stop()
    }

    @MainActor
    static func bitmap<V: View>(_ view: V, _ size: CGSize, _ scheme: ColorScheme, scale: CGFloat) -> NSBitmapImageRep? {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.appearance = appearance
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Menu-bar glyph variants (template, 18 pt) at 4x on light and dark bars.
    @MainActor
    static func glyphs(_ dir: String) {
        for scheme in [ColorScheme.dark, .light] {
            let row = HStack(spacing: 18) {
                ForEach([MenuBarGlyph.Badge.none, .dot, .ring, .diamond], id: \.self) { b in
                    Image(nsImage: MenuBarGlyph.image(badge: b)).renderingMode(.template).resizable().frame(width: 72, height: 72)
                }
            }
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .padding(24).background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.93))
            shootPlain(row, "menubar-glyph-\(scheme == .dark ? "dark" : "light")", CGSize(width: 420, height: 120), scheme, dir)
        }
    }

    /// 1600x1000 composition: chat window behind, status window in front, on a flat backdrop.
    @MainActor
    static func hero(_ dir: String, live: Bool = false) {
        let sfx = live ? "-live" : ""
        func img(_ n: String) -> NSImage? { NSImage(contentsOfFile: dir + "/" + n + ".png") }
        guard let status = img("status\(sfx)-dark"), let chat = img("chat\(sfx)-dark") else { return }
        let view = ZStack {
            StrimBackground()
            Image(nsImage: chat).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: live ? 900 : 960)
                .offset(x: live ? 350 : 290, y: live ? 0 : -125)
            Image(nsImage: status).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: live ? 780 : 1020)
                .offset(x: live ? -410 : -230, y: live ? 120 : 85)
        }
        .frame(width: 1600, height: 1000)
        if let rep = bitmap(view, CGSize(width: 1600, height: 1000), .dark, scale: 1), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("app-hero\(sfx).png"))
        }
    }
}

struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(Strim.C.muted.opacity(0.72)).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
            }
        }
    }
}

// MARK: live mode

/// `--live <controlURL> --token-file <path>`: same views, real `HTTPControlClient` against a running `strim serve`.
/// No fixtures: status numbers, jobs, models and the chat transcript all come from the host. Extra options:
/// `--project <dir>` (chat/job folder, shown in Settings), `--model-path`, `--mtp-path` (shown in Settings),
/// `--select-job <title substring>` (job shown in the detail pane), `--chat-prompt <text>` (repeatable; sent through the real chat backend and rendered), `--chat-timeout <s>`.
struct LiveOptions {
    var url: String
    var tokenFile: String
    var project: String?
    var modelPath: String?
    var mtpPath: String?
    var chatPrompts: [String] = []
    var chatProjects: [String] = []
    var chatTurns: [(project: Int, prompt: String)] = []
    var chatStorePath: String?
    var chatTimeout: Double = 600
    var selectJob: String?
    var jobsOnly = false

    static func parse(_ args: [String] = CommandLine.arguments) -> LiveOptions? {
        func value(_ f: String) -> String? { args.firstIndex(of: f).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let url = value("--live") else { return nil }
        guard let tok = value("--token-file") else {
            FileHandle.standardError.write(Data("snapshot: --live needs --token-file <path>\n".utf8)); exit(2)
        }
        var o = LiveOptions(url: url, tokenFile: (tok as NSString).expandingTildeInPath)
        o.project = value("--project").map { ($0 as NSString).expandingTildeInPath }
        o.modelPath = value("--model-path").map { ($0 as NSString).expandingTildeInPath }
        o.mtpPath = value("--mtp-path").map { ($0 as NSString).expandingTildeInPath }
        o.selectJob = value("--select-job")
        o.jobsOnly = args.contains("--jobs-only")
        o.chatTimeout = value("--chat-timeout").flatMap(Double.init) ?? 600
        for (i, a) in args.enumerated() where a == "--chat-prompt" && i + 1 < args.count { o.chatPrompts.append(args[i + 1]) }
        for (i, a) in args.enumerated() where a == "--chat-project" && i + 1 < args.count {
            o.chatProjects.append((args[i + 1] as NSString).expandingTildeInPath)
        }
        for (i, a) in args.enumerated() where a == "--chat-turn" && i + 1 < args.count {
            let raw = args[i + 1]
            guard let split = raw.firstIndex(of: ":"), let project = Int(raw[..<split]), project > 0 else {
                FileHandle.standardError.write(Data("snapshot: --chat-turn must be <project-number>:<prompt>\n".utf8)); exit(2)
            }
            o.chatTurns.append((project, String(raw[raw.index(after: split)...])))
        }
        o.chatStorePath = value("--chat-store").map { ($0 as NSString).expandingTildeInPath }
        return o
    }
}

/// On-disk form of a chat transcript (the model's `ChatMessage`s are not Codable).
struct TranscriptFile: Codable {
    struct Msg: Codable {
        var role: String, text: String
        var toolName: String?, toolArgs: String?, toolResult: String?, toolIsError: Bool?
        var prompt: Int?, cached: Int?, completion: Int?, seconds: Double?
    }
    var host: String
    var capturedAt: String
    var messages: [Msg]
}

extension SnapshotMode {
    @MainActor
    static func runLive(_ o: LiveOptions, into dir: String) async {
        func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("snapshot --live: \(m)\n".utf8)); exit(1) }
        var settings = AppSettings(hostURL: o.url, strimBinary: nil, modelPath: o.modelPath, mtpPath: o.mtpPath,
                                   controlTokenPath: o.tokenFile, projectPath: o.project)
        settings.recentProjects = o.project.map { [$0] } ?? o.chatProjects
        let storePath = o.chatStorePath ?? NSTemporaryDirectory() + "strim-snapshot-chats-\(UUID().uuidString)"
        let homeChats = (AppPaths.home + "/.strim/chats")
        guard (storePath as NSString).standardizingPath != (homeChats as NSString).standardizingPath else {
            fail("--chat-store must point to a temporary store, not ~/.strim/chats")
        }
        let store = FileChatStore(root: storePath)
        let model = AppModel(settings: settings, makeClient: { HTTPControlClient.make(settings: $0) }, persist: { _ in }, pollInterval: 1,
                             chatStore: store)
        model.start()
        for _ in 0..<1500 where !model.connection.isConnected { try? await Task.sleep(for: .milliseconds(10)) }
        guard model.connection.isConnected else { fail("could not connect to \(o.url): \(model.offlineBanner ?? "no answer")") }
        await model.refreshJobs(); await model.refreshModels()

        // Real turns share the app's project/thread model and persist only under the temporary snapshot chat store.
        var threadsByProject: [Int: String] = [:]
        var liveStatusCaptured = false
        if !o.chatProjects.isEmpty {
            for (offset, raw) in o.chatProjects.enumerated() {
                guard case .success(let path) = ProjectFolder.resolve(raw) else { fail("invalid chat project folder: \(raw)") }
                var project = model.projects.first(where: { $0.path == path })
                if project == nil, case .success(let added) = model.addProject(path) { project = added }
                guard let project else { fail("could not add project folder: \(raw)") }
                if !o.jobsOnly {
                    guard let thread = model.newThread(projectID: project.id) else { fail("could not create chat for project \(raw)") }
                    threadsByProject[offset + 1] = thread.id
                }
            }
            for turn in o.chatTurns {
                guard let tid = threadsByProject[turn.project] else { fail("chat turn refers to missing project \(turn.project)") }
                model.selectThread(tid)
                let messageCountBefore = model.thread(tid)?.messageCount ?? 0
                let task = Task { await model.send(turn.prompt, in: tid) }
                let deadline = Date().addingTimeInterval(o.chatTimeout)
                while Date() < deadline {
                    if !o.jobsOnly, !liveStatusCaptured, model.generatingThreadID == tid,
                       let status = model.status, status.activeJobs > 0, status.decodeTPS > 0 {
                        for scheme in [ColorScheme.dark, .light] {
                            let suffix = scheme == .dark ? "dark" : "light"
                            shoot(MainWindow(model: model, section: .status), "status-live-\(suffix)", 1040, 560, scheme, dir)
                        }
                        liveStatusCaptured = true
                    }
                    if model.generatingThreadID != tid, (model.thread(tid)?.messageCount ?? 0) > messageCountBefore { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if model.generatingThreadID == tid { await model.cancel(tid) }
                await task.value
            }
            if let first = threadsByProject[1] { model.selectThread(first) }
        }

        // Legacy single-project prompt path, also sent through the live app model and host chat endpoint.
        if !o.chatPrompts.isEmpty {
            await model.probeChat()
            guard case .ready = model.chat else { fail("chat not ready: \(model.chat)") }
            for p in o.chatPrompts {
                await model.sendChat(p)
                for _ in 0..<100 {
                    if let status = model.status, status.activeJobs > 0 && status.decodeTPS > 0 { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let status = model.status, status.activeJobs > 0 && status.decodeTPS > 0 {
                    for scheme in [ColorScheme.dark, .light] {
                        let suffix = scheme == .dark ? "dark" : "light"
                        shoot(MainWindow(model: model, section: .status), "status-live-\(suffix)", 1040, 560, scheme, dir)
                    }
                }
                let deadline = Date().addingTimeInterval(o.chatTimeout)
                while model.chatGenerating, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
                if model.chatGenerating { await model.cancelChat(); FileHandle.standardError.write(Data("snapshot: chat turn cut after \(Int(o.chatTimeout)) s\n".utf8)) }
            }
            try? await Task.sleep(for: .milliseconds(300))
            let msgs = model.chatMessages.map { m in
                TranscriptFile.Msg(role: m.role.rawValue, text: m.text, toolName: m.tool?.name, toolArgs: m.tool?.args,
                                   toolResult: m.tool?.result, toolIsError: m.tool?.isError,
                                   prompt: m.ledger?.prompt, cached: m.ledger?.cached, completion: m.ledger?.completion, seconds: m.ledger?.seconds)
            }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(TranscriptFile(host: o.url, capturedAt: ISO8601DateFormatter().string(from: Date()), messages: msgs)) {
                try? d.write(to: URL(fileURLWithPath: dir).appendingPathComponent("chat-transcript.json"))
            }
        }

        // Let a status poll land after the traffic, then pick the newest job for the detail pane.
        try? await Task.sleep(for: .milliseconds(1500))
        await model.refreshJobs()
        let candidates = model.jobs.filter { $0.status == .done && $0.verify == .verified && !($0.title ?? "").isEmpty }
        var selectedRealPatch = false
        for job in candidates {
            await model.selectJob(job.id)
            guard let detail = model.selectedJob else { continue }
            let content = [detail.summary.cwd ?? "", detail.resultSummary ?? "", detail.patch ?? "", detail.verifyOutput ?? ""].joined(separator: "\n")
            let tempPath = content.localizedCaseInsensitiveContains("/T/strim-agentbench-") || content.localizedCaseInsensitiveContains("strim-agentbench-")
            if detail.summary.status == .done && detail.summary.verify == .verified &&
                !(detail.patch ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !tempPath {
                selectedRealPatch = true
                break
            }
        }
        if !selectedRealPatch, let fallback = o.selectJob.flatMap({ s in model.jobs.first(where: { ($0.title ?? "").contains(s) }) }) ?? candidates.first ?? model.jobs.first {
            await model.selectJob(fallback.id)
        }
        if !o.jobsOnly, let s = model.status, let d = try? JSONEncoder().encode(s) {
            try? d.write(to: URL(fileURLWithPath: dir).appendingPathComponent("live-status.json"))
        }
        let hasLiveGeneration = model.status.map { $0.state == .busy && $0.activeJobs > 0 && $0.decodeTPS > 0 } ?? false
        if var summary = model.selectedJob?.summary {
            summary.cwd = Self.captureProjectAlias(summary.cwd)
            if let data = try? JSONEncoder().encode([summary]) {
                try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("live-jobs.json"))
            }
        }

        if o.jobsOnly {
            let renderClient = FakeControlClient(status: model.status ?? FakeControlClient.sampleStatus)
            let summaries = model.jobs.map { job -> JobSummary in
                var summary = job
                summary.cwd = Self.captureProjectAlias(summary.cwd)
                return summary
            }
            await renderClient.setJobs(summaries)
            if var detail = model.selectedJob {
                detail.summary.cwd = Self.captureProjectAlias(detail.summary.cwd)
                await renderClient.setDetail(detail)
            }
            let renderSettings = AppSettings(hostURL: o.url, strimBinary: nil, modelPath: o.modelPath, mtpPath: o.mtpPath,
                                             controlTokenPath: o.tokenFile, startServerWhenOpens: false)
            let renderDownloader = ModelDownloader(freeSpace: { _ in 32_000_000_000 }, modelExists: { true }, initialState: .done)
            let rendered = AppModel(client: renderClient, settings: renderSettings, persist: { _ in }, pollInterval: nil, testMode: true,
                                    tokenStatus: { _ in .ok }, modelScan: { [] }, modelDownloader: renderDownloader,
                                    discoverHostProcess: false)
            rendered.start()
            await rendered.refreshJobs()
            if let id = model.selectedJob?.id { await rendered.selectJob(id) }
            for scheme in [ColorScheme.dark, .light] {
                let suffix = scheme == .dark ? "dark" : "light"
                shoot(MainWindow(model: rendered, section: .jobs), "jobs-live-\(suffix)", 1040, 560, scheme, dir)
            }
            rendered.stop()
            model.stop()
            return
        }

        var chatRenderModel: AppModel?
        if !o.chatTurns.isEmpty {
            let index = store.load()
            let memory = MemoryChatStore(index: ChatIndex(projects: index.projects, threads: index.threads))
            for thread in index.threads {
                let messages = store.loadThread(thread.id).messages.map { message -> StoredMessage in
                    guard message.role == "tool", message.tool?.name == "finish",
                          let summary = Self.finishSummary(message.tool?.args), !summary.isEmpty else { return message }
                    var assistant = message
                    assistant.role = "assistant"
                    assistant.text = summary
                    assistant.tool = nil
                    return assistant
                }
                memory.seed(thread.id, messages)
            }
            var renderSettings = AppSettings(hostURL: o.url, strimBinary: nil, modelPath: o.modelPath, mtpPath: o.mtpPath,
                                             controlTokenPath: o.tokenFile, startServerWhenOpens: false)
            renderSettings.recentProjects = o.chatProjects
            let renderClient = FakeControlClient(status: model.status ?? FakeControlClient.sampleStatus)
            await renderClient.setJobs(model.jobs)
            await renderClient.setModels(model.availableModels)
            let renderDownloader = ModelDownloader(freeSpace: { _ in 32_000_000_000 }, modelExists: { true }, initialState: .done)
            let rendered = AppModel(client: renderClient, settings: renderSettings, persist: { _ in }, pollInterval: nil, testMode: true,
                                    tokenStatus: { _ in .ok }, modelScan: { [] }, modelDownloader: renderDownloader,
                                    discoverHostProcess: false, chatStore: memory)
            rendered.start()
            for _ in 0..<100 where rendered.connection.isConnected == false { try? await Task.sleep(for: .milliseconds(10)) }
            await rendered.refreshJobs(); await rendered.refreshModels()
            if let id = threadsByProject[1] { rendered.selectThread(id) }
            rendered.seedDecodeHistory(model.decodeHistory)
            chatRenderModel = rendered
            if !o.jobsOnly, let id = threadsByProject[1] {
                let transcript = store.loadThread(id).messages.compactMap(\.chatMessage).map { message in
                    TranscriptFile.Msg(role: message.role.rawValue, text: message.text, toolName: message.tool?.name,
                                       toolArgs: message.tool?.args, toolResult: message.tool?.result, toolIsError: message.tool?.isError,
                                       prompt: message.ledger?.prompt, cached: message.ledger?.cached,
                                       completion: message.ledger?.completion, seconds: message.ledger?.seconds)
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(TranscriptFile(host: o.url, capturedAt: ISO8601DateFormatter().string(from: Date()), messages: transcript)) {
                    try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("chat-transcript.json"))
                }
            }
        }

        if CommandLine.arguments.contains("--menu-only") {
            for scheme in [ColorScheme.dark, .light] {
                let s = scheme == .dark ? "dark" : "light"
                shootPopover(MenuContent(model: model), "menu-live-\(s)", scheme, dir)
            }
            model.stop()
            return
        }

        let W: CGFloat = 1040
        for scheme in [ColorScheme.dark, .light] {
            let s = scheme == .dark ? "dark" : "light"
            if (hasLiveGeneration && !liveStatusCaptured) || !FileManager.default.fileExists(atPath: dir + "/status-live-\(s).png") {
                shoot(MainWindow(model: model, section: .status), "status-live-\(s)", W, 560, scheme, dir)
            }
            shoot(MainWindow(model: model, section: .jobs), "jobs-live-\(s)", W, 560, scheme, dir)
            shoot(MainWindow(model: chatRenderModel ?? model, section: .chat, expandChat: false), "chat-live-\(s)", W, 560, scheme, dir)
            shoot(MainWindow(model: chatRenderModel ?? model, section: .chat, expandChat: true), "chat-live-expanded-\(s)", W, 760, scheme, dir)
            shootPopover(MenuContent(model: model), "menu-live-\(s)", scheme, dir)
            shootSettings(SettingsView(model: model, pane: .general), "settings-live-\(s)", scheme, dir)
            shootSettings(SettingsView(model: model, pane: .model), "settings-live-model-\(s)", scheme, dir)
            shootSettings(SettingsView(model: model, pane: .server), "settings-live-server-\(s)", scheme, dir)
            shootSettings(SettingsView(model: model, pane: .chat), "settings-live-chat-\(s)", scheme, dir)
            shootSettings(SettingsView(model: model, pane: .about), "settings-live-about-\(s)", scheme, dir)
        }
        hero(dir, live: true)
        model.stop()
    }

    static func finishSummary(_ raw: String?) -> String? {
        guard let raw, let brace = raw.firstIndex(of: "{"),
              let data = String(raw[brace...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["summary"] as? String
    }

    static func captureProjectAlias(_ path: String?) -> String? {
        guard let path else { return nil }
        let name = (path as NSString).lastPathComponent
        return ["WeatherStation", "VectorNotes"].contains(name) ? "~/Projects/\(name)" : path
    }
}

// MARK: transcript replay

extension SnapshotMode {
    static func value(_ flag: String, _ args: [String] = CommandLine.arguments) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    /// `--snapshots <dir> --from-transcript <chat-transcript.json>`: re-renders only the Chat view from a saved live
    /// transcript, replayed as chat deltas through a fake client (no host, no GPU). Writes chat-live-{dark,light}
    /// (and the expanded variants), then recomposes app-hero-live from the status/chat PNGs already in `dir`.
    @MainActor
    static func runTranscript(_ path: String, into dir: String) async {
        func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("snapshot --from-transcript: \(m)\n".utf8)); exit(1) }
        guard let data = FileManager.default.contents(atPath: path), let t = try? JSONDecoder().decode(TranscriptFile.self, from: data) else { fail("cannot read \(path)") }
        let status: HostStatus = (FileManager.default.contents(atPath: dir + "/live-status.json").flatMap { try? JSONDecoder().decode(HostStatus.self, from: $0) }) ?? runningStatus()
        let fake = FakeControlClient(status: status)
        let project = value("--project").map { ($0 as NSString).expandingTildeInPath } ?? "/tmp/strim-engine"
        try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        var settings = AppSettings(modelPath: value("--model-path"), mtpPath: value("--mtp-path"),
                                   controlTokenPath: "/Users/me/.strim/control-token", projectPath: project)
        settings.recentProjects = [project]
        let clock = ReplayClock()
        let model = AppModel(client: fake, settings: settings, clock: clock, persist: { _ in }, pollInterval: nil, tokenStatus: { _ in .ok }, modelScan: { [] })
        model.start()
        for _ in 0..<200 where !model.connection.isConnected { try? await Task.sleep(for: .milliseconds(10)) }
        await model.probeChat()
        guard case .ready(let s) = model.chat else { fail("chat not ready") }
        func d(_ k: ChatDeltaKind, _ x: String) async { await fake.emit(.chatDelta(ChatDelta(sessionID: s.sessionID, kind: k, text: x))) }
        var i = 0
        let msgs = t.messages
        while i < msgs.count {
            let m = msgs[i]
            if m.role == "user" {
                clock.t = Date(timeIntervalSince1970: 1_800_000_000)
                await model.sendChat(m.text); i += 1
                // Replay this turn: everything up to the next user message.
                while i < msgs.count, msgs[i].role != "user" {
                    let x = msgs[i]
                    switch x.role {
                    case "reasoning": await d(.reasoning, x.text)
                    case "assistant":  // re-chunked mid-token to exercise the same path the stream takes
                        let mid = x.text.index(x.text.startIndex, offsetBy: x.text.count / 2)
                        await d(.text, String(x.text[..<mid])); await d(.text, String(x.text[mid...]))
                    case "tool":
                        let finishArgs = x.toolArgs.map { raw in
                            raw.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? raw
                        }
                        if x.toolName == "finish", let raw = finishArgs,
                           let json = raw.data(using: .utf8),
                           let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                           let summary = object["summary"] as? String, !summary.isEmpty {
                            await d(.text, summary)
                        } else {
                            await d(.toolCall, x.toolArgs ?? x.text)
                            await d(.toolResult, "\(x.toolName ?? "tool")\(x.toolIsError == true ? " ERROR" : ""): \(x.toolResult ?? "")")
                        }
                    default: break
                    }
                    i += 1
                }
                // Usage of the turn sits on its last message that carries a ledger.
                let turn = msgs[0..<i].reversed().prefix { $0.role != "user" }
                if let l = turn.first(where: { $0.prompt != nil }) {
                    await fake.emit(.harnessEvent(HarnessEvent(jobID: s.sessionID, kind: "usage", text: "\(l.prompt ?? 0)/\(l.cached ?? 0)/\(l.completion ?? 0)")))
                }
                clock.t = clock.t.addingTimeInterval(turn.compactMap(\.seconds).first ?? 0)   // server-measured turn time
                await d(.done, "ok")
                for _ in 0..<300 where model.chatGenerating { try? await Task.sleep(for: .milliseconds(10)) }
            } else { i += 1 }
        }
        try? await Task.sleep(for: .milliseconds(200))
        let W: CGFloat = 1040
        for scheme in [ColorScheme.dark, .light] {
            let sfx = scheme == .dark ? "dark" : "light"
            shoot(MainWindow(model: model, section: .chat, expandChat: false), "chat-live-\(sfx)", W, 560, scheme, dir)
            shoot(MainWindow(model: model, section: .chat, expandChat: true), "chat-live-expanded-\(sfx)", W, 760, scheme, dir)
        }
        hero(dir, live: true)
        model.stop()
    }
}

/// Settable clock so a replayed turn reports the server-measured duration, not the replay's wall time.
final class ReplayClock: AppClock, @unchecked Sendable {
    var t = Date()
    func now() -> Date { t }
    func sleep(seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9)) }
}
