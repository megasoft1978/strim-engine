import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

/// Adding projects (Open Folder…, drag and drop, Recent) with the failure shown inline in the sidebar.
@MainActor
final class ProjectsFlow: ObservableObject {
    @Published var error: String?
    private var clearTask: Task<Void, Never>?
    /// Runs after the user allows a folder that needed consent (e.g. switch to the chat section).
    private var afterConsent: (() -> Void)?

    func fail(_ message: String) {
        error = message
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.error = nil }
        }
    }

    func openFolderPanel(_ model: AppModel, then: @escaping () -> Void = {}) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = "Open"; panel.message = "Choose project folders to chat with."
        guard panel.runModal() == .OK else { return }
        add(panel.urls.map(\.path), model, then: then)
    }

    /// Adds each folder; selects a chat in the first one that works, shows the first failure.
    @discardableResult
    func add(_ paths: [String], _ model: AppModel, then: @escaping () -> Void = {}) -> Bool {
        var opened = false, failure: String?
        for path in paths {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                failure = failure ?? "“\((path as NSString).lastPathComponent)” is not a folder."
                continue
            }
            switch model.requestProject(path) {
            case .added(let p):
                if !opened { _ = model.newThread(projectID: p.id); opened = true }
            case .needsConsent: afterConsent = then   // the consent sheet is up; Allow adds the project, Cancel adds nothing
            case .failed(let e): failure = failure ?? e.message
            }
        }
        if let failure { fail(failure) } else { error = nil }
        if opened { then() }
        return opened
    }
}

extension ProjectsFlow {
    /// Allow in the consent sheet.
    func allow(_ model: AppModel) {
        let then = afterConsent
        Task {
            let wasAdd = model.pendingConsent.map { c -> Bool in if case .add = c.kind { return true } else { return false } } ?? false
            if await model.confirmConsent() != nil, wasAdd { then?() }
        }
    }
}

enum Finder {
    /// Shows the folder in Finder; a folder that does not exist yet (lazy scratch) falls back to its parent.
    static func reveal(_ path: String) {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Repoints a project whose folder moved.
@MainActor func locateProject(_ model: AppModel, _ projectID: String, flow: ProjectsFlow) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    panel.prompt = "Locate"; panel.message = "Choose the folder this project moved to."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { if case .failed(let e) = await model.requestRelocate(projectID, path: url.path) { flow.fail(e.message) } }
}
