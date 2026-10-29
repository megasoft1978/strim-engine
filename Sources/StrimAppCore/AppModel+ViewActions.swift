import Foundation
import StrimAPI

// Model entry points for view controls: everything a button, menu item, shortcut or toggle does beyond one model call.
// Each is covered by Tests/StrimAppCoreTests/ControlInventoryTests.swift.

extension AppModel {
    // MARK: window shortcuts

    /// ⌘1 / ⌘2 / ⌘3 / ⌘N / ⇧⌘O / ⌘[ / ⌘]. `section` is the one on screen now.
    public func perform(_ command: WindowCommand, from section: AppSection) -> WindowOutcome {
        switch command {
        case .status: return .show(.status)
        case .jobs: return .show(.jobs)
        case .lastChat:
            if let id = lastThreadID { selectThread(id) }
            return .show(.chat)
        case .newChat: return newThread() != nil ? .show(.chat) : .stay
        case .openFolder: return .chooseFolder
        case .previousChat: return step(-1, from: section)
        case .nextChat: return step(1, from: section)
        }
    }

    private func step(_ by: Int, from section: AppSection) -> WindowOutcome {
        guard let id = adjacentThread(from: section == .chat ? selectedThreadID : nil, step: by) else { return .stay }
        selectThread(id)
        return .show(.chat)
    }

    // MARK: server

    /// A server process is up and a model is (being) served (same rule as `serverIsUp` in the app target).
    public var isServerRunning: Bool { connection.isConnected && status?.state != .stopped }

    /// Start or Stop, whichever the server needs now.
    public func toggleServer() async {
        if isServerRunning { await stopServer() } else { await startServer() }
    }
    public var serverToggleTitle: String { isServerRunning ? "Stop server" : "Start server" }
    public var serverToggleAvailability: Availability { isServerRunning ? serverStopAvailability : serverStartAvailability }
    /// Stopping with jobs running asks first.
    public var serverStopNeedsConfirmation: Bool { isServerRunning && (status?.activeJobs ?? 0) > 0 }
    /// The popover shows Pause only while there is something to pause or resume.
    public var showsPauseInPopover: Bool { (status?.activeJobs ?? 0) > 0 || jobsPaused }
    public var pauseMenuEnabled: Bool { pauseAvailability.enabled && isServerRunning }

    public func copyText(_ text: String) { clipboard.copy(text) }

    // MARK: sidebar and chat

    /// Row tap: opens the chat and shows the chat section.
    public func openThread(_ id: String) -> AppSection {
        selectThread(id)
        return .chat
    }
    /// "New Chat" in a project. True when the chat section should show.
    public func startChat(inProject id: String) -> Bool { newThread(projectID: id) != nil }
    public func duplicate(thread id: String) -> Bool { duplicateThread(id) != nil }

    /// Rename field commit: ignores a blank or unchanged title.
    public func commitRename(_ id: String, draft: String) {
        guard let t = thread(id), !draft.trimmingCharacters(in: .whitespaces).isEmpty, draft != t.title else { return }
        renameThread(id, to: draft)
    }

    /// Folder to reveal for a chat; nil when its folder is missing.
    public func revealPath(for t: ChatThread) -> String? {
        folderProblem(for: t.id) == nil ? cwd(for: t) : nil
    }

    public func projectMenuState(for p: ChatProject, missing: Bool) -> ProjectMenuState {
        ProjectMenuState(newChatEnabled: !missing, revealEnabled: !missing, showsLocate: missing,
                         showsRevokeAccess: folderAccessRoot(p) != nil,
                         removeTitle: p.isScratch ? "Delete Scratch Chats…" : "Remove Project…")
    }

    public func removalPlan(for p: ChatProject) -> ProjectRemovalPlan {
        ProjectRemovalPlan(title: "Remove “\(p.name)”?",
                           message: "Deletes its \(threads(in: p.id).count) chats from this Mac. The folder itself is not touched.",
                           offersRevoke: folderAccessRoot(p) != nil)
    }

    /// Composer Send / Return. Nil when nothing was sent (blank draft, unavailable chat, a message already waiting); otherwise
    /// the caller clears the draft and the returned task is the send itself.
    @discardableResult
    public func submitDraft(_ draft: String, in tid: String, available: Bool) -> Task<Void, Never>? {
        guard Self.canSend(draft: draft, queued: queuedText(for: tid) != nil, available: available) else { return nil }
        return Task { @MainActor [weak self] in await self?.send(draft, in: tid) }
    }
    public static func canSend(draft: String, queued: Bool, available: Bool) -> Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && !queued && available
    }

    // MARK: projects

    /// Adds each folder; opens a chat in the first one that works and reports the first failure.
    public func addFolders(_ paths: [String],
                           isDirectory: (String) -> Bool = { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }) -> AddFoldersResult {
        var result = AddFoldersResult(opened: false, failure: nil, needsConsent: false)
        for path in paths {
            guard isDirectory(path) else {
                result.failure = result.failure ?? "“\((path as NSString).lastPathComponent)” is not a folder."
                continue
            }
            switch requestProject(path) {
            case .added(let p):
                if !result.opened { _ = newThread(projectID: p.id); result.opened = true }
            case .needsConsent: result.needsConsent = true
            case .failed(let e): result.failure = result.failure ?? e.message
            }
        }
        return result
    }

    /// Allow in the consent sheet. True when the sheet was adding a project and the folder was added.
    public func allowPendingConsent() async -> Bool {
        let wasAdd = pendingConsent.map { c -> Bool in if case .add = c.kind { return true } else { return false } } ?? false
        return await confirmConsent() != nil && wasAdd
    }

    /// Locate…: repoints the project; the failure message when it cannot.
    public func locateProject(_ id: String, to path: String) async -> String? {
        if case .failed(let e) = await requestRelocate(id, path: path) { return e.message }
        return nil
    }

    // MARK: jobs

    public var jobListFooter: JobListFooter? {
        let v = jobListView
        guard v.total > 0 else { return nil }
        let title: String? = showAllJobs ? "Recent only" : (v.hidden > 0 ? "Show all (+\(v.hidden))" : nil)
        return JobListFooter(countText: showAllJobs ? "\(v.total) jobs" : "\(v.shown.count) of \(v.total) jobs", toggleTitle: title)
    }
    public func toggleShowAllJobs() { showAllJobs.toggle() }

    /// The detail pane's Cancel button: only for a job that can be cancelled and is still going.
    public func showsCancelButton(for d: JobDetail) -> Bool {
        cancelJobAvailability(for: d.summary).enabled && (d.summary.status == .running || d.summary.status == .queued)
    }

    // MARK: settings

    public func setStartServerWhenOpens(_ on: Bool) { var s = settings; s.startServerWhenOpens = on; update(settings: s) }
    public func setShowSpeedInMenuBar(_ on: Bool) { var s = settings; s.showSpeedInMenuBar = on; update(settings: s) }
    public func setStrimBinary(_ value: String) { var s = settings; s.strimBinary = value.isEmpty ? nil : value; update(settings: s) }
    public func setModelPath(_ path: String) { var s = settings; s.modelPath = path; update(settings: s) }
    public func setMTPPath(_ path: String) { var s = settings; s.mtpPath = path; s.mtpDisabled = false; update(settings: s) }
    /// "None" in the MTP picker: no head is passed to the server until one is chosen again.
    public func disableMTP() { var s = settings; s.mtpPath = nil; s.mtpDisabled = true; update(settings: s); notice = "MTP head off. It applies at the next Load." }
    /// "Default thinking" in Settings: saved, and used for chats started from now on.
    public func setDefaultThinking(_ on: Bool) { thinkingEnabled = on; var s = settings; s.thinkingEnabled = on; update(settings: s) }

    /// Port field commit: applies a valid port to the host URL; returns the text the field should show.
    public func applyPort(_ text: String) -> String {
        guard let n = Int(text), (1...65535).contains(n), var c = URLComponents(string: settings.hostURL) else {
            return SettingsText.port(settings.hostURL)
        }
        c.port = n
        var s = settings
        s.hostURL = c.string ?? s.hostURL
        update(settings: s)
        return text
    }

    public var localModels: [LocalModel] { availableModels.filter { $0.kind == "model" } }
    public var mtpHeads: [LocalModel] { availableModels.filter { $0.kind == "mtp" } }

    /// The explicit choice, else the loaded model matched by name, else the only model on disk.
    public var effectiveModelPath: String? {
        if let p = settings.modelPath, !p.isEmpty { return p }
        if let n = status?.model, let m = localModels.first(where: { $0.name == n }) { return m.path }
        return localModels.count == 1 ? localModels[0].path : nil
    }
    public var effectiveMTPPath: String? {
        if settings.mtpDisabled { return nil }
        if let p = settings.mtpPath, !p.isEmpty { return p }
        if let n = status?.mtp, let m = mtpHeads.first(where: { $0.name == n }) { return m.path }
        return mtpHeads.count == 1 ? mtpHeads[0].path : nil
    }

    /// Model picker selection (a path that is not in the list is ignored).
    public func pickModel(path: String?) {
        if let m = localModels.first(where: { $0.path == path }) { selectModel(m) }
    }
    /// MTP picker selection. "None" (nil) turns the head off; a path that is not in the list is ignored.
    public func pickMTP(path: String?) {
        guard let path else { disableMTP(); return }
        if let m = mtpHeads.first(where: { $0.path == path }) { setMTPPath(m.path); notice = "MTP head set to \(m.name). It applies at the next Load." }
    }
}
