import Foundation
import Testing
import StrimAPI
@testable import StrimAppCore

// Every interactive control in the main views, as a data table. A guard test counts the controls in the view sources and
// fails when the count differs from the table, so a new control has to be added here with a test that drives its logic.

// MARK: - rig

@MainActor
final class CtlRig {
    let fake: FakeControlClient
    let model: AppModel
    let clip: MockClipboard
    let login: MockLogin
    let saved: Locked<[AppSettings]>
    let signals: Locked<[Int32]>
    let home: String

    /// `owned`: the app launched the server itself (pid 4242), so Stop can terminate it.
    init(status: HostStatus? = nil, owned: Bool = false, connect: Bool = true) async {
        let fake = FakeControlClient()
        let home = tempDir("home")
        await fake.setFolders(home: home, enforce: false)
        await fake.setUniqueSessions(true)
        if let status { await fake.setStatus(status) }
        let clip = MockClipboard(), login = MockLogin()
        let saved = Locked<[AppSettings]>([]), signals = Locked<[Int32]>([])
        let alive = Locked(true)
        let launcher = MockLauncher(owned ? .started(pid: 4242) : .needsModel)
        self.fake = fake; self.clip = clip; self.login = login; self.saved = saved; self.signals = signals; self.home = home
        model = AppModel(settings: AppSettings(modelPath: "/models/q", startServerWhenOpens: false),
                         makeClient: { _ in fake }, clock: RecordingClock(auto: 100_000), launcher: launcher, mcp: MockMcp(),
                         loginItem: login, clipboard: clip, persist: { s in saved.with { $0.append(s) } }, pollInterval: nil,
                         testMode: false, tokenStatus: { _ in .ok }, modelScan: { [] },
                         modelDownloader: ModelDownloader(modelExists: { true }), discoverHostProcess: false,
                         chatStore: MemoryChatStore(), scratchRoot: tempDir("scratch") + "/Strim Scratch",
                         hostProcessRunning: { _ in alive.value },
                         terminateHostProcess: { pid in signals.with { $0.append(pid) }; alive.with { $0 = false } })
        if owned {   // launched while the host is still offline (Start is refused once a server answers)
            model.startHost()
            _ = await waitFor { self.model.ownedHostPID == 4242 }
        }
        if connect {
            model.start()
            _ = await waitFor { self.model.connection.isConnected && self.model.hostFolders != nil }
        }
    }

    /// A folder inside the (fake) host's home.
    func folder(_ name: String = "proj") -> String {
        let p = home + "/" + name + "-" + UUID().uuidString.prefix(6)
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }
    /// A folder outside the host's home (needs consent).
    func outside() -> String { tempDir("outside") }

    @discardableResult
    func project(_ name: String = "proj") -> ChatProject {
        guard case .success(let p) = model.addProject(folder(name)) else { fatalError("addProject failed") }
        return p
    }
    /// A new chat in `p` with a live host session.
    func readyChat(in p: ChatProject? = nil) async -> ChatThread {
        let p = p ?? project()
        let t = model.newThread(projectID: p.id)!
        await model.probeChat()
        return t
    }
    func calls() async -> [String] { await fake.calls }
}

// MARK: - table

typealias Drive = @MainActor @Sendable (CtlRig) async throws -> Void

struct ControlRow: Sendable {
    var id: String
    var file: String
    var kind: String
    var label: String
    var shortcut: String?
    var entry: String
    /// nil: the closure only changes view state (a sheet, a toggle of a `@State`); `entry` says which.
    var drive: Drive?
}

enum Controls {
    static let rows: [ControlRow] = build()

    static func row(_ id: String) -> ControlRow? { rows.first { $0.id == id } }

    private static func build() -> [ControlRow] {
        var r: [ControlRow] = []
        func add(_ id: String, _ file: String, _ kind: String, _ label: String, key: String? = nil, _ entry: String, _ drive: Drive? = nil) {
            r.append(ControlRow(id: id, file: file, kind: kind, label: label, shortcut: key, entry: entry, drive: drive))
        }
        let chat = "ChatView.swift", menu = "MenuContent.swift", settings = "SettingsView.swift", jobs = "JobsView.swift"
        let window = "MainWindow.swift", side = "Sidebar.swift"

        // MARK: ChatView
        let removeConfirm: Drive = { r in
            let p = r.project(); _ = r.model.newThread(projectID: p.id)
            let plan = r.model.removalPlan(for: p)
            #expect(plan.title == "Remove “\(p.name)”?")
            #expect(plan.message == "Deletes its 1 chats from this Mac. The folder itself is not touched.")
            #expect(!plan.offersRevoke)
            await r.model.removeProject(p.id)
            #expect(r.model.projects.isEmpty && r.model.threads.isEmpty)
            #expect(FileManager.default.fileExists(atPath: p.path), "the folder itself is not touched")
        }
        let removeRevoke: Drive = { r in
            let dir = r.outside()
            #expect(r.model.requestProject(dir) == .needsConsent)
            #expect(await r.model.allowPendingConsent())
            guard let p = r.model.projects.first else { Issue.record("project not added"); return }
            #expect(r.model.grantedFolders.contains { $0.hasSuffix((dir as NSString).lastPathComponent) })
            #expect(r.model.removalPlan(for: p).offersRevoke)
            await r.model.removeProject(p.id, revokeAccess: true)
            #expect(await r.calls().contains { $0.hasPrefix("revoke:") })
            #expect(r.model.projects.isEmpty && r.model.grantedFolders.isEmpty)
        }
        add("chat.remove.confirm", chat, "Button", "Remove Project", "AppModel.removeProject(_:)", removeConfirm)
        add("chat.remove.revoke", chat, "Button", "Remove and Revoke Access", "AppModel.removeProject(_:revokeAccess:)", removeRevoke)
        add("chat.remove.cancel", chat, "Button", "Cancel", "view: closes the confirmation dialog")
        add("chat.notice.dismiss", chat, "Button", "Dismiss notice (xmark)", "view: hides the store notice (@State dismissedNotice)")
        add("chat.grant", chat, "Button", "Grant access…", "AppModel.requestGrant(forThread:)") { r in
            let t = await r.readyChat()
            r.model.requestGrant(forThread: t.id)
            #expect(r.model.pendingConsent?.kind == .retry(threadID: t.id))
            #expect(r.model.pendingConsent?.title.hasPrefix("Allow Strim to read, change files and run commands in ") == true)
        }
        let openFolder: Drive = { r in
            let dir = r.folder()
            #expect(r.model.addFolders([dir]) == AddFoldersResult(opened: true, failure: nil, needsConsent: false))
            #expect(r.model.selectedProject?.path == dir && r.model.projects.count == 1)
            let missing = r.model.addFolders([dir + "/nope"])
            #expect(!missing.opened && missing.failure == "“nope” is not a folder.")
            let out = r.model.addFolders([r.outside()])
            #expect(out.needsConsent && !out.opened && r.model.pendingConsent != nil)
        }
        add("chat.empty.openFolder", chat, "Button", "Open Folder… (no projects)", "AppModel.addFolders(_:)", openFolder)
        let scratch: Drive = { r in
            let t = r.model.newThread()
            #expect(t != nil && r.model.selectedThreadID == t?.id)
            #expect(r.model.selectedProject?.isScratch == true)
        }
        add("chat.empty.scratch", chat, "Button", "or start a scratch chat", "AppModel.newThread()", scratch)
        add("chat.empty.newChat", chat, "Button", "New Chat", "AppModel.newThread()") { r in
            let p = r.project(); _ = r.model.newThread(projectID: p.id)
            r.model.selectedThreadID = nil
            let t = r.model.newThread()
            #expect(t != nil, "a chat exists after New Chat")
            #expect(r.model.selectedThreadID == t?.id)
        }
        add("chat.empty.openFolder2", chat, "Button", "Open Folder… (with projects)", "AppModel.addFolders(_:)", openFolder)
        add("chat.missing.locate", chat, "Button", "Locate…", "AppModel.locateProject(_:to:)") { r in
            let p = r.project()
            try FileManager.default.removeItem(atPath: p.path)
            #expect(r.model.folderMissing(p.id))
            let moved = r.folder("moved")
            #expect(await r.model.locateProject(p.id, to: moved) == nil)
            #expect(r.model.project(p.id)?.path == moved && !r.model.folderMissing(p.id))
            #expect(await r.model.locateProject(p.id, to: moved + "/nope") != nil, "a bad folder reports its message")
        }
        add("chat.missing.remove", chat, "Button", "Remove", "AppModel.projectMenuState / removalPlan -> removeProject") { r in
            let p = r.project(); _ = r.model.newThread(projectID: p.id)
            try FileManager.default.removeItem(atPath: p.path)
            #expect(r.model.projectMenuState(for: p, missing: true).showsLocate)
            await r.model.removeProject(p.id)
            #expect(r.model.projects.isEmpty)
        }
        add("chat.model.select", chat, "Button", "Model menu item", "AppModel.selectModel(_:)") { r in
            let m = LocalModel(name: "q38", path: "/models/q38", sizeGB: 15.2)
            #expect(m.menuLabel == "q38 (15.2 GB)" && LocalModel(name: "x", path: "/x").menuLabel == "x")
            r.model.selectModel(m)
            #expect(r.model.settings.modelPath == "/models/q38" && r.saved.value.last?.modelPath == "/models/q38")
        }
        add("chat.queued.cancel", chat, "Button", "Cancel (queued message)", "AppModel.cancel(_:)") { r in
            let a = await r.readyChat(), b = await r.readyChat(in: r.project("other"))
            await r.model.send("first", in: a.id)
            #expect(r.model.generatingThreadID == a.id)
            await r.model.send("second", in: b.id)
            #expect(r.model.queuedText(for: b.id) == "second")
            await r.model.cancel(b.id)
            #expect(r.model.queuedText(for: b.id) == nil && r.model.generatingThreadID == a.id)
            #expect(await !r.calls().contains { $0.hasPrefix("chat_cancel:") }, "cancelling a queued message never touches the host")
        }
        add("chat.thinking", chat, "Toggle", "Thinking", "AppModel.thinkingEnabled (new chats; not saved, Settings > Default thinking is the saved default)") { r in
            r.model.thinkingEnabled = false
            let p = r.project()
            #expect(r.model.newThread(projectID: p.id)?.thinking == false)
            r.model.thinkingEnabled = true
            let q = r.project("second")
            #expect(r.model.newThread(projectID: q.id)?.thinking == true)
        }
        add("chat.modelMenu", chat, "Menu", "Model menu", "AppModel.localModels") { r in
            await r.fake.setModels([LocalModel(name: "q", path: "/m/q"), LocalModel(name: "h", path: "/m/h", kind: "mtp")])
            await r.model.refreshModels()
            #expect(r.model.localModels.map(\.name) == ["q"] && r.model.mtpHeads.map(\.name) == ["h"])
        }
        add("chat.composer.field", chat, "TextField", "Message", "AppModel.canSend(draft:queued:available:)") { _ in
            #expect(!AppModel.canSend(draft: "  ", queued: false, available: true))
            #expect(!AppModel.canSend(draft: "hi", queued: true, available: true))
            #expect(!AppModel.canSend(draft: "hi", queued: false, available: false))
            #expect(AppModel.canSend(draft: "hi", queued: false, available: true))
        }
        let submit: Drive = { r in
            let t = await r.readyChat()
            #expect(r.model.submitDraft("   ", in: t.id, available: true) == nil)
            #expect(r.model.submitDraft("hi", in: t.id, available: false) == nil)
            let sent = r.model.submitDraft("hello there", in: t.id, available: true)
            #expect(sent != nil)
            await sent?.value
            #expect(await r.fake.appends.map(\.text) == ["hello there"])
            #expect(r.model.chatMessages.first?.text == "hello there")
            // the next message waits for the running turn instead of reaching the host
            let other = await r.readyChat(in: r.project("other"))
            await r.model.submitDraft("second", in: other.id, available: true)?.value
            #expect(r.model.queuedText(for: other.id) == "second")
            #expect(r.model.submitDraft("third", in: other.id, available: true) == nil, "one waiting message per chat")
        }
        add("chat.composer.submit", chat, "onSubmit", "Return in the message field", "AppModel.submitDraft(_:in:available:)", submit)
        add("chat.stop", chat, "Button", "Stop generating", key: nil, "AppModel.cancel(_:)") { r in
            let t = await r.readyChat()
            await r.model.send("work", in: t.id)
            #expect(r.model.chatGenerating)
            await r.model.cancel(t.id)
            #expect(await r.calls().contains { $0.hasPrefix("chat_cancel:") })
            #expect(!r.model.chatGenerating && r.model.generatingThreadID == nil)
        }
        add("chat.stop.shortcut", chat, "Shortcut", "Stop generating", key: "⌘.", "AppModel.cancelChat()") { r in
            let t = await r.readyChat()
            await r.model.send("work", in: t.id)
            await r.model.cancelChat()
            #expect(!r.model.chatGenerating && r.model.selectedThreadID == t.id)
        }
        add("chat.send", chat, "Button", "Send", "AppModel.submitDraft(_:in:available:)", submit)
        add("chat.copy", chat, "Button", "Copy message", "AppModel.copyMessage(_:)") { r in
            let t = await r.readyChat()
            await r.model.send("copy me", in: t.id)
            guard let m = r.model.chatMessages.first else { Issue.record("no message"); return }
            r.model.copyMessage(m.id)
            #expect(r.clip.copied.value == ["copy me"] && r.model.notice == "Message copied.")
        }
        add("chat.tool.more", chat, "Button", "N more lines", "view: expands the tool result (@State showAll)")
        add("chat.tool.less", chat, "Button", "Show less", "view: collapses the tool result (@State showAll)")

        // MARK: MenuContent
        let toggleServerStart: Drive = { r in
            #expect(r.model.serverToggleTitle == "Start server" && !r.model.isServerRunning)
            #expect(r.model.serverToggleAvailability.enabled)
            await r.model.toggleServer()
            #expect(await r.calls().contains { $0.hasPrefix("load:") })
            #expect(r.model.isServerRunning && r.model.serverToggleTitle == "Stop server")
        }
        let toggleServerStop: Drive = { r in
            #expect(r.model.isServerRunning && r.model.serverToggleAvailability.enabled)
            await r.model.toggleServer()
            #expect(r.signals.value == [4242], "Stop terminates the server this app started")
            #expect(r.model.ownedHostPID == nil)
        }
        add("menu.server", menu, "ServerToggleButton", "Start server / Stop server", "AppModel.toggleServer()") { r in
            try await toggleServerStart(await CtlRig(status: status(.stopped)))
            try await toggleServerStop(await CtlRig(status: status(.ready), owned: true))
            let busy = await CtlRig(status: status(.busy, active: 2))
            #expect(busy.model.serverStopNeedsConfirmation, "stopping with running jobs asks first")
            #expect(await !CtlRig(status: status(.ready)).model.serverStopNeedsConfirmation)
        }
        add("menu.pause", menu, "Button", "Pause jobs / Resume jobs", "AppModel.togglePause() + showsPauseInPopover") { r in
            #expect(!r.model.showsPauseInPopover, "nothing to pause")
            await r.model.togglePause()
            #expect(await r.calls().contains("pause:false") && r.model.jobsPaused)
            #expect(r.model.showsPauseInPopover && r.model.pauseButtonTitle == "Resume jobs")
            await r.model.togglePause()
            #expect(await r.calls().last == "resume" && !r.model.jobsPaused)
            let busy = await CtlRig(status: status(.busy, active: 1))
            #expect(busy.model.showsPauseInPopover)
        }
        let menuRoute: (MenuCommand, MenuCommand.Route, String, String) -> Drive = { c, route, title, glyph in
            { _ in
                #expect(c.route == route && c.title == title && c.shortcut == glyph)
                #expect(MenuCommand.allCases.filter { $0.route == route }.count == 1)
            }
        }
        add("menu.row.openMain", menu, "MenuRow", "Open Strim", "MenuCommand.openMain.route", menuRoute(.openMain, .openWindow(id: "main"), "Open Strim", "⌘O"))
        add("menu.row.settings", menu, "MenuRow", "Settings…", "MenuCommand.settings.route", menuRoute(.settings, .openSettings, "Settings…", "⌘,"))
        add("menu.row.quit", menu, "MenuRow", "Quit Strim", "MenuCommand.quit.route", menuRoute(.quit, .terminate, "Quit Strim", "⌘Q"))
        add("menu.shortcut.openMain", menu, "Shortcut", "Open Strim", key: "⌘O", "MenuCommand.openMain.shortcut", menuRoute(.openMain, .openWindow(id: "main"), "Open Strim", "⌘O"))
        add("menu.shortcut.settings", menu, "Shortcut", "Settings…", key: "⌘,", "MenuCommand.settings.shortcut", menuRoute(.settings, .openSettings, "Settings…", "⌘,"))
        add("menu.shortcut.quit", menu, "Shortcut", "Quit Strim", key: "⌘Q", "MenuCommand.quit.shortcut", menuRoute(.quit, .terminate, "Quit Strim", "⌘Q"))
        add("menu.copyEndpoint", menu, "Button", "Copy endpoint", "AppModel.copyText(_:)") { r in
            r.model.copyText("http://127.0.0.1:8203/v1")
            #expect(r.clip.copied.value == ["http://127.0.0.1:8203/v1"])
        }
        add("menu.row.base", menu, "Button", "MenuRow's button", "view: calls the row's closure (the three MenuRow rows above)")

        // MARK: SettingsView
        add("settings.launchAtLogin", settings, "Toggle", "Launch at login", "AppModel.setLaunchAtLogin(_:)") { r in
            r.model.setLaunchAtLogin(true)
            #expect(r.login.isEnabled && r.model.launchAtLogin)
            r.model.setLaunchAtLogin(false)
            #expect(!r.login.isEnabled && !r.model.launchAtLogin)
            r.login.failure.with { $0 = NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "denied"]) }
            r.model.setLaunchAtLogin(true)
            #expect(!r.model.launchAtLogin && r.model.lastError == "Launch at login: denied")
        }
        add("settings.startServerWhenOpens", settings, "Toggle", "Start server when Strim opens", "AppModel.setStartServerWhenOpens(_:)") { r in
            r.model.setStartServerWhenOpens(true)
            #expect(r.model.settings.startServerWhenOpens && r.saved.value.last?.startServerWhenOpens == true)
            r.model.setStartServerWhenOpens(false)
            #expect(r.saved.value.last?.startServerWhenOpens == false)
        }
        add("settings.showSpeed", settings, "Toggle", "Show speed in menu bar", "AppModel.setShowSpeedInMenuBar(_:)") { r in
            r.model.setShowSpeedInMenuBar(false)
            #expect(!r.model.settings.showSpeedInMenuBar && r.saved.value.last?.showSpeedInMenuBar == false)
            r.model.setShowSpeedInMenuBar(true)
            #expect(r.saved.value.last?.showSpeedInMenuBar == true)
        }
        add("settings.loopback", settings, "Toggle", "Loopback only", "view: constant, disabled (the host binds 127.0.0.1)")
        add("settings.defaultThinking", settings, "Toggle", "Default thinking", "AppModel.setDefaultThinking(_:) (saved as thinking_enabled)") { r in
            r.model.setDefaultThinking(false)
            #expect(r.model.thinkingEnabled == false && r.saved.value.last?.thinkingEnabled == false, "the default is saved")
            let p = r.project()
            #expect(r.model.newThread(projectID: p.id)?.thinking == false)
            r.model.setDefaultThinking(true)
            #expect(r.saved.value.last?.thinkingEnabled == true)
            #expect(r.model.newThread(projectID: r.project("second").id)?.thinking == true)
        }
        let models = [LocalModel(name: "q38", path: "/m/q38", sizeGB: 15.2), LocalModel(name: "q27", path: "/m/q27"),
                      LocalModel(name: "mtp-a", path: "/m/mtp-a", kind: "mtp"), LocalModel(name: "mtp-b", path: "/m/mtp-b", kind: "mtp")]
        add("settings.pickModel", settings, "Picker", "Model", "AppModel.pickModel(path:)") { r in
            await r.fake.setModels(models); await r.model.refreshModels()
            r.model.pickModel(path: "/m/q27")
            #expect(r.model.settings.modelPath == "/m/q27" && r.saved.value.last?.modelPath == "/m/q27")
            r.model.pickModel(path: "/m/unknown")
            #expect(r.model.settings.modelPath == "/m/q27", "a path outside the list changes nothing")
            #expect(r.model.effectiveModelPath == "/m/q27")
        }
        add("settings.pickMTP", settings, "Picker", "MTP head", "AppModel.pickMTP(path:) (nil = None: saved as mtp_disabled)") { r in
            await r.fake.setModels(models); await r.model.refreshModels()
            r.model.pickMTP(path: "/m/mtp-b")
            #expect(r.model.settings.mtpPath == "/m/mtp-b" && r.saved.value.last?.mtpPath == "/m/mtp-b" && r.model.effectiveMTPPath == "/m/mtp-b")
            #expect(r.model.settings.modelPath == "/models/q", "the head does not touch the model")
            r.model.pickMTP(path: nil)
            #expect(r.model.settings.mtpDisabled && r.model.settings.mtpPath == nil, "None clears the head")
            #expect(r.saved.value.last?.mtpDisabled == true && r.saved.value.last?.mtpPath == nil, "the choice is saved")
            #expect(r.model.effectiveMTPPath == nil)
            #expect(HostCommand.arguments(settings: r.model.settings) == ["serve", "/models/q", "--port", String(r.model.settings.port)], "the launcher omits the head")
            r.model.pickMTP(path: "/m/mtp-a")
            #expect(!r.model.settings.mtpDisabled && r.saved.value.last?.mtpDisabled == false && r.model.effectiveMTPPath == "/m/mtp-a")
        }
        add("settings.load", settings, "Button", "Start with selected model", "AppModel.loadModel()") { r in
            #expect(!r.model.loadAvailability.enabled && r.model.loadAvailability.reason == "Model already loaded")
            let idle = await CtlRig(status: status(.stopped, model: nil))
            #expect(idle.model.loadAvailability.enabled)
            await idle.model.loadModel()
            #expect(await idle.calls().contains("load:/models/q"))
        }
        add("settings.refresh", settings, "Button", "Refresh", "AppModel.refreshModels()") { r in
            await r.fake.setModels(models)
            await r.model.refreshModels()
            #expect(r.model.availableModels.count == 4 && r.model.localModels.count == 2 && r.model.mtpHeads.count == 2)
        }
        add("settings.choose", settings, "Button", "Choose…", "AppModel.setModelPath / setMTPPath") { r in
            r.model.setModelPath("/picked/model"); r.model.setMTPPath("/picked/mtp")
            #expect(r.saved.value.last?.modelPath == "/picked/model" && r.saved.value.last?.mtpPath == "/picked/mtp")
            #expect(r.model.effectiveModelPath == "/picked/model" && r.model.effectiveMTPPath == "/picked/mtp")
        }
        add("settings.revealToken", settings, "Button", "Show/Hide token path", "view: toggles @State reveal; the path is masked by SettingsText.mask") { _ in }
        add("settings.revealScratch", settings, "Button", "Reveal", "FinderTarget.revealPath(_:)") { _ in
            #expect(FinderTarget.revealPath("/a/b/c", exists: { $0 == "/a" }) == "/a", "a folder that does not exist yet falls back to its parent")
            #expect(FinderTarget.revealPath("/a/b/c", exists: { $0 == "/a/b/c" }) == "/a/b/c")
            #expect(FinderTarget.revealPath("/x/y", exists: { _ in false }) == "/")
        }
        add("settings.revokeFolder", settings, "Button", "Revoke", "AppModel.revokeFolder(_:)") { r in
            let dir = r.outside()
            _ = r.model.requestProject(dir)
            #expect(await r.model.allowPendingConsent())
            guard let root = r.model.grantedFolders.first else { Issue.record("no grant"); return }
            await r.model.revokeFolder(root)
            #expect(await r.calls().contains("revoke:\(root)") && r.model.grantedFolders.isEmpty)
            #expect(r.model.projects.allSatisfy { $0.folderConsent == nil })
        }
        add("settings.deleteAll.open", settings, "Button", "Delete all chat history…", "view: shows the confirmation (@State confirmDelete)")
        add("settings.deleteAll.confirm", settings, "Button", "Delete All Chats", "AppModel.deleteAllChatHistory()") { r in
            let t = await r.readyChat()
            await r.model.send("x", in: t.id)
            await r.model.deleteAllChatHistory()
            #expect(r.model.projects.isEmpty && r.model.threads.isEmpty && r.model.selectedThreadID == nil)
        }
        add("settings.deleteAll.cancel", settings, "Button", "Cancel", "view: closes the confirmation dialog")
        add("settings.port.field", settings, "TextField", "Port", "AppModel.applyPort(_:)") { r in
            #expect(SettingsText.port("http://127.0.0.1:8203") == "8203" && SettingsText.port("nonsense") == "")
            #expect(r.model.applyPort("9001") == "9001")
            #expect(r.model.settings.hostURL == "http://127.0.0.1:9001" && r.saved.value.last?.hostURL == "http://127.0.0.1:9001")
            let before = r.saved.value.count
            for bad in ["0", "65536", "abc", "", "-5", "80.5"] {
                #expect(r.model.applyPort(bad) == "9001", "\(bad) is refused and the field shows the current port")
            }
            #expect(r.saved.value.count == before)
            r.model.stop()
        }
        add("settings.port.submit", settings, "onSubmit", "Return in the port field", "AppModel.applyPort(_:)") { r in
            #expect(r.model.applyPort("8300") == "8300" && SettingsText.port(r.model.settings.hostURL) == "8300")
            r.model.stop()
        }
        add("settings.binary", settings, "TextField", "Strim binary", "AppModel.setStrimBinary(_:)") { r in
            r.model.setStrimBinary("/opt/homebrew/bin/strim")
            #expect(r.saved.value.last?.strimBinary == "/opt/homebrew/bin/strim")
            r.model.setStrimBinary("")
            #expect(r.model.settings.strimBinary == nil && r.saved.value.last?.strimBinary == nil, "empty means auto")
        }

        // MARK: JobsView
        func jobsRig() async -> CtlRig {
            let patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
            let rig = await CtlRig(status: status(.ready))
            let run = JobSummary(id: "run", source: .mcp, status: .running, started: 999_990, title: "running")
            let wait = JobSummary(id: "wait", source: .mcp, status: .awaitingApproval, started: 999_900, title: "awaiting")
            let old = JobSummary(id: "old", source: .cli, status: .done, started: 1, finished: 2, title: "old")
            await rig.fake.setJobs([run, wait, old])
            await rig.fake.setDetail(JobDetail(summary: run))
            await rig.fake.setDetail(JobDetail(summary: wait, patch: patch))
            await rig.model.refreshJobs()
            return rig
        }
        add("jobs.back", jobs, "Button", "Jobs (back)", "view: clears the selection (@State selection)") { r in
            let rig = await jobsRig()
            await rig.model.selectJob("wait")
            #expect(rig.model.selectedJob?.id == "wait")
            await rig.model.selectJob(nil)
            #expect(rig.model.selectedJob == nil && rig.model.selectedAnalysis == nil && !rig.model.patchConfirmed)
        }
        add("jobs.list.contextMenu", jobs, "contextMenu", "Job row menu", "AppModel.cancelJobAvailability(for:)") { _ in
            let rig = await jobsRig()
            let byID = Dictionary(uniqueKeysWithValues: rig.model.jobs.map { ($0.id, $0) })
            #expect(rig.model.cancelJobAvailability(for: byID["run"]).enabled)
            #expect(!rig.model.cancelJobAvailability(for: byID["old"]).enabled)
        }
        add("jobs.list.cancel", jobs, "Button", "Cancel job (row menu)", "AppModel.cancelJob(_:)") { _ in
            let rig = await jobsRig()
            await rig.model.cancelJob("run")
            #expect(await rig.calls().contains("cancel_job:run"))
            #expect(rig.model.jobs.first { $0.id == "run" }?.status == .cancelled)
            await rig.model.cancelJob("old")
            #expect(await !rig.calls().contains("cancel_job:old"), "a finished job is never cancelled")
        }
        add("jobs.showAll", jobs, "Button", "Show all / Recent only", "AppModel.toggleShowAllJobs() + jobListFooter") { _ in
            let rig = await jobsRig()
            #expect(rig.model.jobListFooter == JobListFooter(countText: "2 of 3 jobs", toggleTitle: "Show all (+1)"))
            rig.model.toggleShowAllJobs()
            #expect(rig.model.jobListFooter == JobListFooter(countText: "3 jobs", toggleTitle: "Recent only"))
            rig.model.toggleShowAllJobs()
            #expect(rig.model.jobListFooter?.toggleTitle == "Show all (+1)")
            let empty = await CtlRig()
            #expect(empty.model.jobListFooter == nil)
        }
        add("jobs.detail.cancel", jobs, "Button", "Cancel job", "AppModel.showsCancelButton(for:) -> cancelJob(_:)") { _ in
            let rig = await jobsRig()
            await rig.model.selectJob("run")
            guard let d = rig.model.selectedJob else { Issue.record("no job"); return }
            #expect(rig.model.showsCancelButton(for: d))
            await rig.model.cancelJob(d.id)
            #expect(await rig.calls().contains("cancel_job:run"))
            await rig.model.selectJob("old")
            #expect(rig.model.selectedJob.map { !rig.model.showsCancelButton(for: $0) } == true)
            await rig.model.selectJob("wait")
            #expect(rig.model.selectedJob.map { !rig.model.showsCancelButton(for: $0) } == true, "awaiting approval: Apply/Reject, not Cancel")
        }
        add("jobs.ack", jobs, "Button", "I have reviewed the updated patch", "AppModel.acknowledgeUpdatedPatch()") { _ in
            let rig = await jobsRig()
            await rig.model.selectJob("wait")
            #expect(!rig.model.patchChangedSinceReview)
            let changed = JobDetail(summary: rig.model.selectedJob!.summary, patch: "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+c\n")
            await rig.fake.setDetail(changed)
            await rig.model.refreshSelectedJob()
            #expect(rig.model.patchChangedSinceReview && !rig.model.applyAvailability(for: rig.model.selectedJob).enabled)
            rig.model.acknowledgeUpdatedPatch()
            #expect(!rig.model.patchChangedSinceReview && rig.model.applyAvailability(for: rig.model.selectedJob).enabled)
        }
        add("jobs.confirm", jobs, "Toggle", "I have reviewed it and want to apply it", "AppModel.setPatchConfirmed(_:)") { _ in
            let rig = await jobsRig()
            let link = "diff --git a/l b/l\nnew file mode 120000\n--- /dev/null\n+++ b/l\n@@ -0,0 +1 @@\n+t\n"
            let wait = JobSummary(id: "wait", source: .mcp, status: .awaitingApproval, started: 999_900, title: "awaiting")
            await rig.fake.setDetail(JobDetail(summary: wait, patch: link))
            await rig.model.selectJob("wait")
            #expect(!rig.model.applyAvailability(for: rig.model.selectedJob).enabled)
            rig.model.setPatchConfirmed(true)
            #expect(rig.model.patchConfirmed && rig.model.applyAvailability(for: rig.model.selectedJob).enabled)
            rig.model.setPatchConfirmed(false)
            #expect(!rig.model.patchConfirmed && !rig.model.applyAvailability(for: rig.model.selectedJob).enabled)
        }
        add("jobs.apply", jobs, "Button", "Apply", "AppModel.approve(.apply)") { _ in
            let rig = await jobsRig()
            await rig.model.selectJob("wait")
            #expect(rig.model.applyAvailability(for: rig.model.selectedJob).enabled)
            await rig.model.approve(.apply)
            #expect(await rig.calls().contains("approve:wait:apply"))
            #expect(await rig.fake.approvals.first?.patchSHA256 == rig.model.reviewedDigest, "the approval is bound to the reviewed bytes")
        }
        add("jobs.reject", jobs, "Button", "Reject", "AppModel.approve(.reject)") { _ in
            let rig = await jobsRig()
            await rig.model.selectJob("wait")
            #expect(rig.model.approveAvailability(for: rig.model.selectedJob).enabled)
            await rig.model.approve(.reject)
            #expect(await rig.calls().contains("approve:wait:reject"))
            await rig.model.selectJob("run")
            #expect(!rig.model.approveAvailability(for: rig.model.selectedJob).enabled)
        }
        add("jobs.copyPatch", jobs, "Button", "Copy patch path", "AppModel.copyPatchPath()") { _ in
            let rig = await jobsRig()
            rig.model.patchDirectory = tempDir("patches")
            await rig.model.selectJob("wait")
            rig.model.copyPatchPath()
            guard let path = rig.clip.copied.value.last else { Issue.record("nothing copied"); return }
            #expect(path == rig.model.patchDirectory + "/wait.patch")
            #expect((try? String(contentsOfFile: path, encoding: .utf8))?.hasPrefix("diff --git") == true)
        }

        // MARK: MainWindow
        let cmd: (WindowCommand, String) -> Drive = { command, glyph in
            { r in
                #expect(command.shortcut == glyph)
                switch command {
                case .status: #expect(r.model.perform(.status, from: .chat) == .show(.status))
                case .jobs: #expect(r.model.perform(.jobs, from: .chat) == .show(.jobs))
                case .lastChat:
                    #expect(r.model.perform(.lastChat, from: .status) == .show(.chat), "with no chats it still shows the chat section")
                    let p = r.project()
                    let a = r.model.newThread(projectID: p.id)!, b = r.model.newThread(projectID: r.project("two").id)!
                    r.model.selectThread(a.id)
                    r.model.selectedThreadID = nil
                    let expected = r.model.lastThreadID!
                    #expect([a.id, b.id].contains(expected))
                    #expect(r.model.perform(.lastChat, from: .jobs) == .show(.chat) && r.model.selectedThreadID == expected)
                case .newChat:
                    #expect(r.model.perform(.newChat, from: .status) == .show(.chat) && r.model.selectedThread != nil)
                case .openFolder:
                    #expect(r.model.perform(.openFolder, from: .status) == .chooseFolder && r.model.projects.isEmpty)
                case .previousChat, .nextChat:
                    let p = r.project()
                    let a = r.model.newThread(projectID: p.id)!
                    await r.model.send("one", in: a.id)
                    let b = r.model.newThread(projectID: p.id)!
                    #expect(a.id != b.id)
                    let order = r.model.sidebarThreadOrder
                    #expect(order.count == 2)
                    let first = order[0], last = order[1]
                    r.model.selectThread(first)
                    if command == .nextChat {
                        #expect(r.model.perform(.nextChat, from: .chat) == .show(.chat) && r.model.selectedThreadID == last)
                        #expect(r.model.perform(.nextChat, from: .chat) == .stay && r.model.selectedThreadID == last, "no wrap at the end")
                        #expect(r.model.perform(.nextChat, from: .status) == .show(.chat) && r.model.selectedThreadID == first, "from another section: the first chat")
                    } else {
                        r.model.selectThread(last)
                        #expect(r.model.perform(.previousChat, from: .chat) == .show(.chat) && r.model.selectedThreadID == first)
                        #expect(r.model.perform(.previousChat, from: .chat) == .stay && r.model.selectedThreadID == first, "no wrap at the start")
                        #expect(r.model.perform(.previousChat, from: .jobs) == .show(.chat) && r.model.selectedThreadID == last, "from another section: the last chat")
                    }
                }
            }
        }
        let wc: [(WindowCommand, String)] = [(.status, "⌘1"), (.jobs, "⌘2"), (.lastChat, "⌘3"), (.newChat, "⌘N"),
                                             (.openFolder, "⇧⌘O"), (.previousChat, "⌘["), (.nextChat, "⌘]")]
        for (c, g) in wc {
            add("window.button.\(c.rawValue)", window, "Button", c.title, key: nil, "AppModel.perform(.\(c.rawValue), from:)", cmd(c, g))
        }
        for (c, g) in wc {
            add("window.shortcut.\(c.rawValue)", window, "Shortcut", c.title, key: g, "AppModel.perform(.\(c.rawValue), from:)", cmd(c, g))
        }
        add("window.overflow.server", window, "Button", "Start server / Stop server (overflow menu)", "AppModel.toggleServer(); running jobs ask first (OverflowMenu dialog)") { _ in
            try await toggleServerStart(await CtlRig(status: status(.stopped)))
            try await toggleServerStop(await CtlRig(status: status(.ready), owned: true))
            let offline = await CtlRig(connect: false)
            #expect(offline.model.serverToggleTitle == "Start server" && !offline.model.isServerRunning)
            #expect(await CtlRig(status: status(.busy, active: 1)).model.serverStopNeedsConfirmation, "stop with jobs running asks first")
            #expect(await !CtlRig(status: status(.ready)).model.serverStopNeedsConfirmation, "idle stop goes straight through")
            // The confirmation dialog lives in one place (stopServerDialog in Components.swift); its Stop button calls stopServer().
            let busy = await CtlRig(status: status(.busy, active: 2), owned: true)
            await busy.model.stopServer()
            #expect(busy.signals.value == [4242] && busy.model.ownedHostPID == nil)
        }
        add("window.overflow.pause", window, "Button", "Pause jobs / Resume jobs (overflow menu)", "AppModel.togglePause() + pauseMenuEnabled") { r in
            let offline = await CtlRig(connect: false)
            #expect(!offline.model.pauseMenuEnabled)
            #expect(r.model.pauseMenuEnabled)
            await r.model.togglePause()
            #expect(await r.calls().contains("pause:false") && r.model.pauseButtonTitle == "Resume jobs" && r.model.pauseMenuEnabled)
            let stopped = await CtlRig(status: status(.stopped))
            #expect(!stopped.model.pauseMenuEnabled, "no server, nothing to pause")
        }
        add("window.overflow.copyEndpoint", window, "Button", "Copy endpoint", "AppModel.copyText(_:)") { r in
            r.model.copyText("http://127.0.0.1:8203/v1")
            #expect(r.clip.copied.value == ["http://127.0.0.1:8203/v1"])
        }
        add("window.overflow.copyMCP", window, "Button", "Copy MCP registration commands", "AppModel.copyMCPCommands()") { r in
            await r.model.copyMCPCommands()
            #expect(r.clip.copied.value == [McpTemplate.render(port: r.model.settings.port)])
            #expect(r.model.notice?.hasPrefix("MCP registration commands copied") == true)
        }
        add("window.overflow.menu", window, "Menu", "More actions", "AppModel.serverToggleAvailability / pauseMenuEnabled") { r in
            #expect(r.model.serverToggleAvailability.enabled || r.model.isServerRunning)
        }
        add("window.toolbar.server", window, "ServerToggleButton", "Start server / Stop server (toolbar)", "AppModel.toggleServer()") { _ in
            try await toggleServerStart(await CtlRig(status: status(.stopped)))
        }

        // MARK: Sidebar
        add("sidebar.section.tap", side, "onTapGesture", "Status / Jobs row", "view: sets the section; rows come from AppSection.sidebar") { _ in
            #expect(AppSection.sidebar == [.status, .jobs])
            #expect(AppSection.allCases.map(\.title) == ["Status", "Chat", "Jobs"])
        }
        add("sidebar.project.tap", side, "onTapGesture", "Project row (collapse / expand)", "Set.flip(_:)") { _ in
            var s = Set<String>()
            s.flip("a"); #expect(s == ["a"])
            s.flip("b"); #expect(s == ["a", "b"])
            s.flip("a"); #expect(s == ["b"])
        }
        add("sidebar.thread.tap", side, "onTapGesture", "Chat row", "AppModel.openThread(_:)") { r in
            let p = r.project()
            let a = r.model.newThread(projectID: p.id)!
            await r.model.send("x", in: a.id)
            let b = r.model.newThread(projectID: p.id)!
            #expect(r.model.selectedThreadID == b.id)
            #expect(r.model.openThread(a.id) == .chat && r.model.selectedThreadID == a.id)
            #expect(r.model.thread(a.id)?.unread == false)
        }
        add("sidebar.project.contextMenu", side, "contextMenu", "Project menu", "AppModel.projectMenuState(for:missing:)") { r in
            let p = r.project()
            let ok = r.model.projectMenuState(for: p, missing: false)
            #expect(ok == ProjectMenuState(newChatEnabled: true, revealEnabled: true, showsLocate: false, showsRevokeAccess: false, removeTitle: "Remove Project…"))
            let gone = r.model.projectMenuState(for: p, missing: true)
            #expect(!gone.newChatEnabled && !gone.revealEnabled && gone.showsLocate)
            _ = r.model.newThread()
            let scratch = r.model.projects.first { $0.isScratch }!
            #expect(r.model.projectMenuState(for: scratch, missing: false).removeTitle == "Delete Scratch Chats…")
        }
        add("sidebar.thread.contextMenu", side, "contextMenu", "Chat menu", "AppModel.revealPath(for:)") { r in
            let p = r.project()
            let t = r.model.newThread(projectID: p.id)!
            #expect(r.model.revealPath(for: t) == p.path)
            try FileManager.default.removeItem(atPath: p.path)
            #expect(r.model.revealPath(for: t) == nil, "a chat whose folder is gone cannot reveal it")
            r.model.selectedThreadID = nil
            let s = r.model.newThread()!
            #expect(r.model.revealPath(for: s) == r.model.cwd(for: s), "scratch folders are created lazily and always reveal")
        }
        add("sidebar.delete.confirm", side, "Button", "Delete Chat", "AppModel.deleteThread(_:)") { r in
            let p = r.project()
            let a = r.model.newThread(projectID: p.id)!
            await r.model.send("x", in: a.id)
            let b = r.model.newThread(projectID: p.id)!
            await r.model.deleteThread(b.id)
            #expect(r.model.thread(b.id) == nil && r.model.thread(a.id) != nil)
            await r.model.deleteThread("missing")
            #expect(r.model.threads.count == 1)
        }
        add("sidebar.delete.cancel", side, "Button", "Cancel (delete chat)", "view: closes the confirmation dialog")
        add("sidebar.remove.confirm", side, "Button", "Remove Project", "AppModel.removeProject(_:)", removeConfirm)
        add("sidebar.remove.revoke", side, "Button", "Remove and Revoke Access", "AppModel.removeProject(_:revokeAccess:)", removeRevoke)
        add("sidebar.remove.cancel", side, "Button", "Cancel (remove project)", "view: closes the confirmation dialog")
        add("sidebar.showMore", side, "Button", "Show N more / Show less", "Set.flip + ThreadListWindow.visible") { r in
            let p = r.project()
            let threads = (0..<8).map { i in ChatThread(projectId: p.id, title: "t\(i)") }
            let (shown, hidden) = ThreadListWindow.visible(threads, selected: nil, showAll: false)
            #expect(shown.count == 5 && hidden == 3)
            let (withSel, hidden2) = ThreadListWindow.visible(threads, selected: threads[7].id, showAll: false)
            #expect(withSel.count == 6 && withSel.last?.id == threads[7].id && hidden2 == 2)
            #expect(ThreadListWindow.visible(threads, selected: nil, showAll: true).hidden == 0)
            #expect(ThreadListWindow.visible(Array(threads.prefix(5)), selected: nil, showAll: false).hidden == 0)
        }
        add("sidebar.emptyNewChat", side, "Button", "New chat (empty project)", "AppModel.startChat(inProject:)") { r in
            let p = r.project()
            #expect(r.model.startChat(inProject: p.id) && r.model.selectedProject?.id == p.id)
            #expect(!r.model.startChat(inProject: "nope"))
        }
        add("sidebar.menu.newChat", side, "Button", "New Chat", "AppModel.startChat(inProject:)") { r in
            let p = r.project()
            let t = r.model.newThread(projectID: p.id)
            await r.model.send("x", in: t!.id)
            #expect(r.model.startChat(inProject: p.id) && r.model.threads(in: p.id).count == 2)
        }
        add("sidebar.menu.reveal", side, "Button", "Reveal in Finder", "FinderTarget.revealPath(_:)") { r in
            #expect(FinderTarget.revealPath(r.home) == r.home)
            #expect(FinderTarget.revealPath(r.home + "/not/there/yet") == r.home)
        }
        add("sidebar.menu.copyPath", side, "Button", "Copy Path", "AppModel.copyText(_:)") { r in
            let p = r.project()
            r.model.copyText(p.path)
            #expect(r.clip.copied.value == [p.path])
        }
        add("sidebar.menu.locate", side, "Button", "Locate…", "AppModel.locateProject(_:to:)") { r in
            let p = r.project()
            try FileManager.default.removeItem(atPath: p.path)
            let t = r.model.newThread(projectID: p.id)
            #expect(r.model.folderProblem(for: t!.id) == "Folder moved or deleted")
            let moved = r.folder("moved")
            #expect(await r.model.locateProject(p.id, to: moved) == nil)
            #expect(r.model.folderProblem(for: t!.id) == nil && r.model.project(p.id)?.name == (moved as NSString).lastPathComponent)
            let outside = r.outside()
            #expect(await r.model.locateProject(p.id, to: outside) == nil, "an outside folder asks for consent instead of failing")
            #expect(r.model.pendingConsent?.kind == .relocate(projectID: p.id))
        }
        add("sidebar.menu.revokeAccess", side, "Button", "Revoke Folder Access", "AppModel.revokeFolderAccess(projectID:)") { r in
            _ = r.model.requestProject(r.outside())
            #expect(await r.model.allowPendingConsent())
            guard let p = r.model.projects.first else { Issue.record("no project"); return }
            #expect(r.model.projectMenuState(for: p, missing: false).showsRevokeAccess)
            await r.model.revokeFolderAccess(projectID: p.id)
            #expect(await r.calls().contains { $0.hasPrefix("revoke:") })
            let after = r.model.project(p.id)!
            #expect(!r.model.projectMenuState(for: after, missing: false).showsRevokeAccess && after.folderConsent == nil)
        }
        add("sidebar.menu.remove", side, "Button", "Remove Project… / Delete Scratch Chats…", "ProjectMenuState.removeTitle -> removalPlan(for:)") { r in
            let t = r.model.newThread()!
            let scratch = r.model.project(t.projectId)!
            #expect(r.model.removalPlan(for: scratch).message == "Deletes its 1 chats from this Mac. The folder itself is not touched.")
            await r.model.removeProject(scratch.id)
            #expect(r.model.threads.isEmpty && r.model.selectedThreadID == nil)
        }
        add("sidebar.thread.rename", side, "Button", "Rename", "AppModel.commitRename(_:draft:)") { r in
            let p = r.project()
            let t = r.model.newThread(projectID: p.id)!
            r.model.commitRename(t.id, draft: "  ")
            #expect(r.model.thread(t.id)?.title == ChatThread.defaultTitle, "blank is ignored")
            r.model.commitRename(t.id, draft: ChatThread.defaultTitle)
            #expect(r.model.thread(t.id)?.titleIsUser == false, "unchanged is ignored")
            r.model.commitRename(t.id, draft: "  Plan the release  ")
            #expect(r.model.thread(t.id)?.title == "Plan the release" && r.model.thread(t.id)?.titleIsUser == true)
            r.model.commitRename("missing", draft: "x")
            #expect(r.model.threads.count == 1)
        }
        add("sidebar.thread.duplicate", side, "Button", "Duplicate", "AppModel.duplicate(thread:)") { r in
            let p = r.project()
            let t = r.model.newThread(projectID: p.id)!
            await r.model.send("hello", in: t.id)
            #expect(r.model.duplicate(thread: t.id))
            #expect(r.model.threads(in: p.id).count == 2 && r.model.selectedThread?.title.hasSuffix(" copy") == true)
            #expect(r.model.chatMessages.first?.text == "hello")
            #expect(!r.model.duplicate(thread: "missing"))
        }
        add("sidebar.thread.reveal", side, "Button", "Reveal Folder in Finder", "AppModel.revealPath(for:)") { r in
            let p = r.project()
            let t = r.model.newThread(projectID: p.id)!
            #expect(r.model.revealPath(for: t) == p.path)
        }
        add("sidebar.thread.delete", side, "Button", "Delete…", "view: shows the confirmation (@State deleteThread)")
        add("sidebar.errorRow", side, "Button", "Dismiss folder error", "view: clears ProjectsFlow.error") { r in
            let res = r.model.addFolders(["/definitely/not/here"])
            #expect(res.failure == "“here” is not a folder." && !res.opened)
        }
        add("sidebar.header.openFolder", side, "Button", "Open Folder…", "AppModel.addFolders(_:)", openFolder)
        add("sidebar.header.recent", side, "Button", "Recent folder", "AppModel.addFolders(_:)") { r in
            let a = r.folder("a"), b = r.folder("b")
            let res = r.model.addFolders([a, b])
            #expect(res.opened && r.model.projects.count == 2, "every folder is added")
            #expect(r.model.selectedProject?.path == a, "the chat opens in the first folder")
            #expect(r.model.addFolders([a]).opened, "an existing project opens a chat again")
            #expect(r.model.projects.count == 2)
            #expect(r.model.addFolders([b, "/nope/gone"]).failure == "“gone” is not a folder.")
        }
        add("sidebar.header.recentMenu", side, "Menu", "Recent", "AppModel.validRecentProjects") { r in
            let dir = r.folder()
            r.model.setProject(dir)
            #expect(r.model.validRecentProjects.contains(dir))
        }
        add("sidebar.header.menu", side, "Menu", "Add project (+)", "AppModel.addFolders(_:)", openFolder)
        add("sidebar.drop", side, "dropDestination", "Drop folders", "AppModel.addFolders(_:)") { r in
            let dir = r.folder()
            let file = r.home + "/file.txt"
            try "x".write(toFile: file, atomically: true, encoding: .utf8)
            let res = r.model.addFolders([file, dir])
            #expect(res.opened && res.failure == "“file.txt” is not a folder.", "a dropped file is reported, the folder still opens")
            #expect(r.model.projects.map(\.path) == [dir])
        }
        add("sidebar.rename.field", side, "TextField", "Chat title", "AppModel.commitRename(_:draft:)") { r in
            let t = r.model.newThread(projectID: r.project().id)!
            r.model.commitRename(t.id, draft: String(repeating: "x", count: 300))
            #expect(r.model.thread(t.id)?.title.count == 100)
        }
        add("sidebar.rename.submit", side, "onSubmit", "Return in the title field", "AppModel.commitRename(_:draft:)") { r in
            let t = r.model.newThread(projectID: r.project().id)!
            r.model.commitRename(t.id, draft: "Done")
            #expect(r.model.thread(t.id)?.title == "Done")
        }

        // ProjectsFlow.swift has no controls: it is the folder panel and the glue to AddFoldersResult / allowPendingConsent.
        add("flow.allow", "ProjectsFlow.swift", "none", "Allow (consent sheet)", "AppModel.allowPendingConsent()") { r in
            #expect(await !r.model.allowPendingConsent(), "no sheet: nothing to allow")
            _ = r.model.requestProject(r.outside())
            #expect(await r.model.allowPendingConsent() && r.model.pendingConsent == nil && r.model.projects.count == 1)
            let t = r.model.threads.first
            r.model.requestGrant(forThread: t!.id)
            #expect(await !r.model.allowPendingConsent(), "a retry consent does not report an added project")
        }
        return r
    }
}

// MARK: - scanning

private enum Scan {
    static let files = ["ChatView.swift", "MenuContent.swift", "SettingsView.swift", "JobsView.swift", "MainWindow.swift",
                        "Sidebar.swift", "ProjectsFlow.swift"]
    /// kind -> regex over comment-free source.
    static let kinds: [(String, String)] = [
        ("Button", #"\bButton\s*[({]"#), ("Toggle", #"\bToggle\s*[({]"#), ("Picker", #"\bPicker\s*[({]"#),
        ("Menu", #"\bMenu\s*[({]"#), ("MenuRow", #"\bMenuRow\s*\("#), ("ServerToggleButton", #"\bServerToggleButton\s*\("#),
        ("Shortcut", #"\.keyboardShortcut\("#), ("onSubmit", #"\.onSubmit\b"#), ("dropDestination", #"\.(dropDestination|onDrop)\b"#),
        ("onTapGesture", #"\.onTapGesture\b"#), ("contextMenu", #"\.contextMenu\b"#), ("TextField", #"\b(TextField|SecureField)\s*\("#),
        ("Stepper", #"\b(Stepper|Slider|DatePicker|ColorPicker)\s*\("#), ("Link", #"\b(Link|NavigationLink|DisclosureGroup)\s*[({]"#),
    ]
    static func counts(_ file: String) -> [String: Int] {
        let src = ViewSources.code(file)
        var out: [String: Int] = [:]
        for (kind, pattern) in kinds {
            let n = try! NSRegularExpression(pattern: pattern).numberOfMatches(in: src, range: NSRange(src.startIndex..., in: src))
            if n > 0 { out[kind] = n }
        }
        return out
    }

    /// `.keyboardShortcut("1", modifiers: .command)` -> "⌘1" in source order.
    static func shortcuts(_ file: String) -> [String] {
        let src = ViewSources.code(file)
        let re = try! NSRegularExpression(pattern: #"\.keyboardShortcut\(\s*"(.)"\s*(?:,\s*modifiers:\s*(\[[^\]]*\]|\.\w+))?\s*\)"#)
        let ns = src as NSString
        return re.matches(in: src, range: NSRange(location: 0, length: ns.length)).map { m in
            let key = ns.substring(with: m.range(at: 1)).uppercased()
            let mods = m.range(at: 2).location == NSNotFound ? ".command" : ns.substring(with: m.range(at: 2))
            var glyphs = ""
            for (name, g) in [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")] where mods.contains("." + name) { glyphs += g }
            return glyphs + key
        }
    }
}

@MainActor
@Suite struct ControlInventoryTests {
    @Test func tableIdsAreUnique() {
        let ids = Controls.rows.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate ids: \(Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
    }

    /// New controls must be added to the table (with a test): the control count per file and kind has to match the sources.
    @Test func controlCountsMatchTheViewSources() {
        var problems: [String] = []
        for file in Scan.files {
            #expect(!ViewSources.raw(file).isEmpty, "cannot read \(file) (\(ViewSources.dir.path))")
            let found = Scan.counts(file)
            var table: [String: Int] = [:]
            for r in Controls.rows where r.file == file && r.kind != "none" { table[r.kind, default: 0] += 1 }
            for kind in Set(found.keys).union(table.keys).sorted() where found[kind, default: 0] != table[kind, default: 0] {
                problems.append("\(file) \(kind): source has \(found[kind, default: 0]), table has \(table[kind, default: 0])")
            }
        }
        #expect(problems.isEmpty, Comment(rawValue: "Add or remove rows in ControlInventoryTests.swift:\n" + problems.joined(separator: "\n")))
    }

    @Test func tableShortcutsMatchTheKeyboardShortcutsInTheSources() {
        for file in Scan.files {
            let fromTable = Controls.rows.filter { $0.file == file && $0.kind == "Shortcut" }.map { $0.shortcut ?? "?" }
            #expect(Scan.shortcuts(file) == fromTable, "\(file)")
        }
    }

    @Test func windowShortcutsAreBoundToTheirCommands() {
        // MainWindow wires `Button(WindowCommand.x.title) { run(.x) }.keyboardShortcut(...)` in WindowCommand order.
        let src = ViewSources.code("MainWindow.swift")
        let wired = try! NSRegularExpression(pattern: #"Button\(WindowCommand\.(\w+)\.title\) \{ run\(\.(\w+)\) \}\.keyboardShortcut"#)
            .matches(in: src, range: NSRange(src.startIndex..., in: src))
            .map { (String(src[Range($0.range(at: 1), in: src)!]), String(src[Range($0.range(at: 2), in: src)!])) }
        #expect(wired.map(\.0) == wired.map(\.1), "each shortcut button runs its own command")
        #expect(wired.map(\.0) == WindowCommand.allCases.map(\.rawValue))
        #expect(Scan.shortcuts("MainWindow.swift") == WindowCommand.allCases.map(\.shortcut))
        // The popover rows: `MenuRow(title: MenuCommand.x.title, ...) { run(.x) }.keyboardShortcut(...)`.
        let m = ViewSources.code("MenuContent.swift")
        let rows = try! NSRegularExpression(pattern: #"MenuRow\(title: MenuCommand\.(\w+)\.title, shortcut: MenuCommand\.(\w+)\.shortcut\) \{ run\(\.(\w+)\) \}"#)
            .matches(in: m, range: NSRange(m.startIndex..., in: m))
            .map { x in (1...3).map { String(m[Range(x.range(at: $0), in: m)!]) } }
        #expect(rows.allSatisfy { Set($0).count == 1 })
        #expect(rows.map { $0[0] } == MenuCommand.allCases.map(\.rawValue))
        #expect(Scan.shortcuts("MenuContent.swift") == MenuCommand.allCases.map(\.shortcut))
    }

    /// Cmd+R used to be declared on a hidden button and never fired. It is gone everywhere; nothing may bring back a dead shortcut.
    @Test func commandRIsGoneConsistently() {
        for file in ViewSources.allFiles() {
            let src = ViewSources.raw(file)
            #expect(!src.contains(#"keyboardShortcut("r""#), "\(file) binds Cmd+R again")
            #expect(!src.contains("⌘R"), "\(file) documents Cmd+R")
        }
        #expect(!WindowCommand.allCases.map(\.shortcut).contains("⌘R") && !MenuCommand.allCases.map(\.shortcut).contains("⌘R"))
    }

    /// Stop server has three entry points: the toolbar item and the popover button (both ServerToggleButton in Components.swift)
    /// and the overflow item (MainWindow.swift). All three must ask the same question and show the same dialog.
    @Test func stopServerConfirmationIsTheSameAtEveryEntryPoint() {
        let component = ViewSources.code("Components.swift"), overflow = ViewSources.code("MainWindow.swift")
        // One dialog definition, used by the toolbar/popover button and the overflow item.
        #expect(component.contains(#"confirmationDialog("Stop the Strim server?""#))
        #expect(component.contains(#"Text("Active jobs will be interrupted.")"#))
        #expect(component.components(separatedBy: "confirmationDialog(\"Stop the Strim server?\"").count == 2, "exactly one definition")
        #expect(!overflow.contains("confirmationDialog(\"Stop the Strim server?\""), "no private copy in the overflow menu")
        #expect(component.contains(".stopServerDialog(") && overflow.contains(".stopServerDialog("))
        #expect(component.contains("serverStopNeedsConfirmation"), "the button asks through the model rule")
        #expect(overflow.contains("serverStopNeedsConfirmation"), "the overflow item asks through the model rule")
    }

    /// The empty-chat composer toggle is labelled as the default for new chats, so it saves like Settings does.
    @Test func composerThinkingToggleSavesTheDefault() {
        #expect(ViewSources.code("ChatView.swift").contains("model.setDefaultThinking("))
    }

    @Test func everyRowNamesItsEntryPointAndViewOnlyRowsSayWhy() {
        for r in Controls.rows {
            #expect(!r.entry.isEmpty && !r.label.isEmpty, "\(r.id)")
            if r.drive == nil { #expect(r.entry.hasPrefix("view:"), "\(r.id): a row without a test must be view-state only") }
        }
        let driven = Controls.rows.filter { $0.drive != nil }.count
        #expect(driven >= 100, "driven rows: \(driven)")
    }

    @Test(arguments: Controls.rows.filter { $0.drive != nil }.map(\.id))
    func controlDrivesItsEntryPoint(id: String) async throws {
        let row = try #require(Controls.row(id))
        let rig = await CtlRig(status: status(.ready))
        defer { rig.model.stop() }
        try await row.drive?(rig)
    }
}
