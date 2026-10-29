import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

/// `StrimApp --snapshots <dir> --projects [--sizes 800x560,1440x900,640x460]`: the Projects sidebar and chat states from
/// fixtures on `MemoryChatStore` (nothing is written to ~/.strim). Names: `projects-<state>-<w>x<h>-<scheme>.png`.
extension SnapshotMode {
    static let fxRoot = "/tmp/strim-fx"

    static func chatMsg(_ role: ChatMessage.Role, _ text: String, tool: ToolCard? = nil, ledger: TokenLedger? = nil, marker: ChatMarker? = nil) -> ChatMessage {
        ChatMessage(role: role, text: text, tool: tool, ledger: ledger, marker: marker)
    }

    @MainActor
    static func runProjects(into dir: String) async {
        let sizes = parseSizes(value("--sizes")) ?? [(800, 560), (1440, 900), (640, 460)]
        let full = await projectsModel()
        let empty = await projectsModel(empty: true)
        // Rows of (state name, model, chat to select, expanded transcript).
        let states: [(String, AppModel, String?)] = [
            ("generating", full, "t-a1"), ("queued", full, "t-a2"), ("missing", full, "t-c1"),
            ("divider", full, "t-a4"), ("error", full, "t-b1"), ("scratch", full, "t-s1"), ("empty", empty, nil),
        ]
        for (w, h) in sizes {
            for scheme in [ColorScheme.dark, .light] {
                let s = scheme == .dark ? "dark" : "light", z = "\(Int(w))x\(Int(h))"
                for (name, model, tid) in states {
                    if let tid { model.selectThread(tid) }
                    shoot(MainWindow(model: model, section: .chat, expandChat: false, sidebarOpen: w < 1000), "projects-\(name)-\(z)-\(s)", w, h, scheme, dir)
                }
                if w < 700 {
                    full.selectThread("t-a1")
                    shoot(MainWindow(model: full, section: .chat, sidebarOpen: true), "projects-sidebar-open-\(z)-\(s)", w, h, scheme, dir)
                }
            }
        }
        for scheme in [ColorScheme.dark, .light] {
            let s = scheme == .dark ? "dark" : "light"
            shootSettings(SettingsView(model: full, pane: .chat), "projects-settings-chat-\(s)", scheme, dir)
            shootSettings(SettingsView(model: full, pane: .about), "projects-settings-about-\(s)", scheme, dir)
        }
        full.stop(); empty.stop()
    }

    @MainActor
    static func projectsModel(empty: Bool = false, grants: Bool = false) async -> AppModel {
        PathDisplay.displayMap = (fxRoot, "~/Projects")
        let fm = FileManager.default
        for d in ["strim-engine", "notes-app"] { try? fm.createDirectory(atPath: "\(fxRoot)/\(d)", withIntermediateDirectories: true) }
        try? fm.removeItem(atPath: "\(fxRoot)/old-service")
        let fake = FakeControlClient(status: runningStatus(state: .ready, decode: 0))
        await fake.setUniqueSessions(true)
        if grants {
            // Host home is /Users/me; only strim-engine is granted (resolved path, as the host reports it). notes-app is refused.
            let real = URL(fileURLWithPath: fxRoot).resolvingSymlinksInPath().path
            await fake.setFolders(home: "/Users/me", roots: ["/Users/me", real + "/strim-engine"], enforce: true)
        }
        await fake.setModels([LocalModel(name: "qwen38-4bit", path: "/Users/me/.strim/models/qwen38-4bit", sizeGB: 15.2)])
        let t = now
        func at(_ ago: Double) -> Double { t - ago }
        var idx = ChatIndex()
        var transcripts: [String: [ChatMessage]] = [:]
        if !empty {
            idx.projects = [
                ChatProject(id: "p-a", path: "\(fxRoot)/strim-engine", name: "strim-engine", addedAt: at(900_000), lastActivity: at(60),
                            folderConsent: grants ? at(800_000) : nil),
                ChatProject(id: "p-b", path: "\(fxRoot)/notes-app", name: "notes-app", addedAt: at(800_000), lastActivity: at(14_400)),
                ChatProject(id: "p-c", path: "\(fxRoot)/old-service", name: "old-service", addedAt: at(700_000), lastActivity: at(259_200)),
                ChatProject(id: "p-s", path: "\(fxRoot)-scratch/Strim Scratch", name: "Scratch", addedAt: at(600_000), lastActivity: at(1_200), isScratch: true),
            ]
            func th(_ id: String, _ p: String, _ title: String, _ ago: Double, unread: Bool = false, n: Int = 2) -> ChatThread {
                ChatThread(id: id, projectId: p, title: title, titleIsUser: false, createdAt: at(ago + 600), lastActivity: at(ago), thinking: true, unread: unread, messageCount: n)
            }
            idx.threads = [
                ChatThread(id: "t-a1", projectId: "p-a", createdAt: at(120), lastActivity: at(120), thinking: true),
                th("t-a2", "p-a", "Rename Config.timeout to requestTimeout", 600),
                th("t-a3", "p-a", "Fix flaky cache eviction test", 10_800, unread: true),
                th("t-a4", "p-a", "Explain the MTP acceptance loop", 172_800, n: 5),
                th("t-a5", "p-a", "Profile prefill on long prompts", 432_000),
                th("t-a6", "p-a", "Draft release notes for 0.9", 777_600),
                th("t-a7", "p-a", "Audit the tool call parser", 1_209_600),
                th("t-b1", "p-b", "Add a dark mode toggle to settings", 14_400),
                th("t-b2", "p-b", "Why is the build slow?", 86_400),
                th("t-c1", "p-c", "Trace the retry storm in the gateway", 259_200),
                th("t-s1", "p-s", "Convert this CSV to JSON", 1_200),
            ]
            let ledger = TokenLedger(prompt: 2310, cached: 1980, completion: 164, seconds: 3.8)
            func qa(_ q: String, _ a: String) -> [ChatMessage] { [chatMsg(.user, q), chatMsg(.assistant, a, ledger: ledger)] }
            transcripts["t-a2"] = qa("Rename Config.timeout to requestTimeout and update the call sites.", "Renamed the property in `Config.swift` and fixed the one call site in `Client.swift`. The patch is in Jobs.")
            transcripts["t-a3"] = qa("Why is CacheEvictionTests flaky?", "The test sleeps for 50 ms and asserts eviction already happened. Use the injected clock instead.")
            transcripts["t-a4"] = qa("Explain the MTP acceptance loop", "The drafter proposes up to `depth` tokens; the verifier accepts the longest matching prefix.")
                + [chatMsg(.assistant, "", marker: .sessionBreak)]
                + qa("And what does acceptance look like on code?", "On code the head accepts about 0.85 of drafts, because identifiers repeat.")
            transcripts["t-a5"] = qa("Where does prefill spend its time on 8k prompts?", "Mostly in attention; the MLP is under a third of it.")
            transcripts["t-a6"] = qa("Draft release notes for 0.9", "Highlights: faster prefill, MTP on by default, chat history.")
            transcripts["t-a7"] = qa("Audit the tool call parser", "Two issues: unterminated JSON is dropped silently, and nested braces confuse the splitter.")
            transcripts["t-b1"] = qa("Add a dark mode toggle to settings", "Added a `Toggle` bound to `@AppStorage(\"dark\")` in `SettingsView.swift`.")
            transcripts["t-b2"] = qa("Why is the build slow?", "Most of the time is the generated protobuf target; it rebuilds on every change.")
            transcripts["t-c1"] = qa("Trace the retry storm in the gateway", "Retries multiply across three layers; cap them at the edge.")
            transcripts["t-s1"] = qa("Convert this CSV to JSON", "Done: `data.json` is in the scratch folder with 128 records.")
        }
        let store = MemoryChatStore(index: empty ? nil : idx)
        for (id, ms) in transcripts { store.seed(id, ms.map { StoredMessage($0, ts: t) }) }
        let settings = AppSettings(modelPath: "/Users/me/.strim/models/qwen38-4bit", controlTokenPath: "/Users/me/.strim/control-token", startServerWhenOpens: false)
        let model = AppModel(client: fake, settings: settings, persist: { _ in }, pollInterval: nil, tokenStatus: { _ in .ok }, modelScan: { [] },
                             modelDownloader: ModelDownloader(modelExists: { true }), chatStore: store, scratchRoot: "\(fxRoot)-scratch/Strim Scratch")
        model.start()
        for _ in 0..<200 where !model.connection.isConnected { try? await Task.sleep(for: .milliseconds(10)) }
        await model.refreshModels()
        if empty { return model }
        try? fm.createDirectory(atPath: "\(fxRoot)-scratch/Strim Scratch", withIntermediateDirectories: true)

        // Error: the host refuses to open a session for notes-app.
        model.selectThread("t-b1")
        if !grants { await fake.setFailNext(APIError(code: "load_failed", message: "The model is still loading")) }
        await model.send("Try the toggle again", in: "t-b1")
        // Generating: a1 streams; a2 then waits in the queue.
        model.selectThread("t-a1")
        await model.send("Why does ParseTests.testTrailingComma fail?", in: "t-a1")
        guard let sid = model.liveSessions["t-a1"]?.sessionID else { FileHandle.standardError.write(Data("snapshot: no session\n".utf8)); exit(1) }
        func d(_ k: ChatDeltaKind, _ x: String) async { await fake.emit(.chatDelta(ChatDelta(sessionID: sid, kind: k, text: x))) }
        await d(.reasoning, "The test builds `[1, 2,]` and expects 2 elements. Let me read the parser before guessing.")
        await d(.toolCall, "read_file Sources/Parser.swift")
        await d(.toolResult, "read_file: 84 lines")
        await d(.text, "`parseList` appends an empty element after a trailing comma. In `Parser.swift` line 41 the loop adds the token before checking for `]`")
        try? await Task.sleep(for: .milliseconds(200))
        await model.send("Also rename Config.timeout to requestTimeout when you are done.", in: "t-a2")
        try? await Task.sleep(for: .milliseconds(200))
        return model
    }
}
