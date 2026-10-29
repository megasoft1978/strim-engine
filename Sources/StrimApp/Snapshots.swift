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
        NSApp.setActivationPolicy(.accessory)
        if let tr = SnapshotMode.value("--from-transcript") { await runTranscript((tr as NSString).expandingTildeInPath, into: dir); exit(0) }
        if let live = LiveOptions.parse() { await runLive(live, into: dir); exit(0) }

        let running = await scenario(status: runningStatus(), jobs: sampleJobs())
        let stopped = await scenario(status: HostStatus(state: .stopped, memory: MemoryStats(weightsGB: 0, prefixTrieGB: 0, mlxCacheGB: 0, headroomGB: 64), uptimeSeconds: 0, jobsPaused: false))
        let jobs = await scenario(status: runningStatus(), jobs: sampleJobs(), details: sampleDetails(), select: "j_bcdefghi34")
        let chat = await scenario(status: runningStatus(), chat: true)
        let settings = await scenario(status: runningStatus())

        let W: CGFloat = 940
        for scheme in [ColorScheme.dark, .light] {
            let s = scheme == .dark ? "dark" : "light"
            shoot(MainWindow(model: running, tab: .status), "status-\(s)", W, 812, scheme, dir)
            shoot(MainWindow(model: stopped, tab: .status), "status-stopped-\(s)", W, 690, scheme, dir)
            shoot(MainWindow(model: jobs, tab: .jobs), "jobs-\(s)", W, 640, scheme, dir)
            shoot(MainWindow(model: chat, tab: .chat, expandChat: true), "chat-\(s)", W, 700, scheme, dir)
            shoot(MainWindow(model: settings, tab: .settings), "settings-\(s)", W, 730, scheme, dir)
            shootPlain(MenuContent(model: running).fixedSize().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Strim.C.hairline))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12).padding(40).frame(maxHeight: .infinity, alignment: .top),
                       "menu-\(s)", CGSize(width: 440, height: 600), scheme, dir)
        }
        glyphs(dir)
        hero(dir)
        exit(0)
    }

    // MARK: fixtures

    static func runningStatus() -> HostStatus {
        HostStatus(state: .ready, model: "Qwen3.8-27B-4bit", mtp: "Qwen3.8-27B-mtp",
                   memory: MemoryStats(weightsGB: 15.2, prefixTrieGB: 2.4, mlxCacheGB: 1.1, headroomGB: 21),
                   decodeTPS: 68.3, prefillTPS: 1180, mtpAcceptance: 0.71, mtpDepth: 2.3, prefixHitRate: 0.86,
                   savedPrefillSeconds: 412, activeJobs: 2, queuedJobs: 0, tokensToday: 183_400, localTokensGenerated: 52_100,
                   uptimeSeconds: 7260, parentTokensSavedEstimate: 96_000, jobsPaused: false,
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
    static func scenario(status: HostStatus, jobs: [JobSummary] = [], details: [JobDetail] = [], chat: Bool = false, select: String? = nil) async -> AppModel {
        let fake = FakeControlClient(status: status)
        await fake.setJobs(jobs)
        for d in details { await fake.setDetail(d) }
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
        if let select { await model.selectJob(select) }
        guard chat else { return model }
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
        return model
    }

    // MARK: rendering

    /// Window content inside a drawn macOS window: rounded corners, hairline, traffic lights, soft shadow, transparent backdrop.
    @MainActor
    static func shoot<V: View>(_ content: V, _ name: String, _ w: CGFloat, _ h: CGFloat, _ scheme: ColorScheme, _ dir: String) {
        let framed = windowFrame(content, w, h, scheme).padding(.horizontal, 64).padding(.top, 48).padding(.bottom, 84)
        shootPlain(framed, name, CGSize(width: w + 128, height: h + 132), scheme, dir)
    }

    static func windowFrame<V: View>(_ content: V, _ w: CGFloat, _ h: CGFloat, _ scheme: ColorScheme) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 28) }.frame(width: w, height: h)
            .overlay(alignment: .topLeading) { TrafficLights().padding(.leading, 10).padding(.top, 8) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(scheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.22), radius: 36, y: 22)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }

    @MainActor
    static func shootPlain<V: View>(_ view: V, _ name: String, _ size: CGSize, _ scheme: ColorScheme, _ dir: String) {
        guard let rep = bitmap(view, size, scheme, scale: 2), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
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

    /// 1600x1000 composition: chat window behind, status window in front, on an aurora backdrop.
    @MainActor
    static func hero(_ dir: String, live: Bool = false) {
        let sfx = live ? "-live" : ""
        func img(_ n: String) -> NSImage? { NSImage(contentsOfFile: dir + "/" + n + ".png") }
        guard let status = img("status\(sfx)-dark"), let chat = img("chat\(sfx)-dark") else { return }
        let view = ZStack {
            StrimBackground()
            RadialGradient(colors: [Strim.C.violet.opacity(0.30), .clear], center: UnitPoint(x: 0.5, y: 0.95), startRadius: 0, endRadius: 700)
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
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { c in
                Circle().fill(Strim.hex(UInt32(c))).frame(width: 12, height: 12)
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
    var chatTimeout: Double = 600
    var selectJob: String?

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
        o.chatTimeout = value("--chat-timeout").flatMap(Double.init) ?? 600
        for (i, a) in args.enumerated() where a == "--chat-prompt" && i + 1 < args.count { o.chatPrompts.append(args[i + 1]) }
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
        if let p = o.project { settings.recentProjects = [p] }
        let model = AppModel(settings: settings, makeClient: { HTTPControlClient.make(settings: $0) }, persist: { _ in }, pollInterval: 1)
        model.start()
        for _ in 0..<1500 where !model.connection.isConnected { try? await Task.sleep(for: .milliseconds(10)) }
        guard model.connection.isConnected else { fail("could not connect to \(o.url): \(model.offlineBanner ?? "no answer")") }
        await model.refreshJobs(); await model.refreshModels()

        // Real chat through the app's own chat backend (control API chat/open + chat/append, SSE deltas).
        if !o.chatPrompts.isEmpty {
            await model.probeChat()
            guard case .ready = model.chat else { fail("chat not ready: \(model.chat)") }
            for p in o.chatPrompts {
                await model.sendChat(p)
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
        if let j = o.selectJob.flatMap({ s in model.jobs.first(where: { ($0.title ?? "").contains(s) }) }) ?? model.jobs.first(where: { $0.source == .mcp }) ?? model.jobs.first { await model.selectJob(j.id) }
        if let s = model.status, let d = try? JSONEncoder().encode(s) {
            try? d.write(to: URL(fileURLWithPath: dir).appendingPathComponent("live-status.json"))
        }
        if let d = try? JSONEncoder().encode(model.jobs) { try? d.write(to: URL(fileURLWithPath: dir).appendingPathComponent("live-jobs.json")) }

        let W: CGFloat = 940
        for scheme in [ColorScheme.dark, .light] {
            let s = scheme == .dark ? "dark" : "light"
            shoot(MainWindow(model: model, tab: .status), "status-live-\(s)", W, 812, scheme, dir)
            shoot(MainWindow(model: model, tab: .jobs), "jobs-live-\(s)", W, 780, scheme, dir)
            shoot(MainWindow(model: model, tab: .chat, expandChat: false), "chat-live-\(s)", W, 1000, scheme, dir)
            shoot(MainWindow(model: model, tab: .chat, expandChat: true), "chat-live-expanded-\(s)", W, 1700, scheme, dir)
            if scheme == .dark { shoot(MainWindow(model: model, tab: .settings), "settings-live-dark", W, 730, scheme, dir) }
            shootPlain(MenuContent(model: model).fixedSize().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Strim.C.hairline))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12).padding(40).frame(maxHeight: .infinity, alignment: .top),
                       "menu-live-\(s)", CGSize(width: 440, height: 600), scheme, dir)
        }
        hero(dir, live: true)
        model.stop()
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
                        await d(.toolCall, x.toolArgs ?? x.text)
                        await d(.toolResult, "\(x.toolName ?? "tool")\(x.toolIsError == true ? " ERROR" : ""): \(x.toolResult ?? "")")
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
        let W: CGFloat = 940
        for scheme in [ColorScheme.dark, .light] {
            let sfx = scheme == .dark ? "dark" : "light"
            shoot(MainWindow(model: model, tab: .chat, expandChat: false), "chat-live-\(sfx)", W, 1000, scheme, dir)
            shoot(MainWindow(model: model, tab: .chat, expandChat: true), "chat-live-expanded-\(sfx)", W, 1700, scheme, dir)
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
