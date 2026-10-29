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
        let result = model.addFolders(paths)
        if result.needsConsent { afterConsent = then }   // the consent sheet is up; Allow adds the project, Cancel adds nothing
        if let failure = result.failure { fail(failure) } else { error = nil }
        if result.opened { then() }
        return result.opened
    }
}

extension ProjectsFlow {
    /// Allow in the consent sheet.
    func allow(_ model: AppModel) {
        let then = afterConsent
        Task { if await model.allowPendingConsent() { then?() } }
    }
}

enum Finder {
    /// Shows the folder in Finder; a folder that does not exist yet (lazy scratch) falls back to its parent.
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: FinderTarget.revealPath(path))])
    }
}

/// Repoints a project whose folder moved.
@MainActor func locateProject(_ model: AppModel, _ projectID: String, flow: ProjectsFlow) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    panel.prompt = "Locate"; panel.message = "Choose the folder this project moved to."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { if let failure = await model.locateProject(projectID, to: url.path) { flow.fail(failure) } }
}
