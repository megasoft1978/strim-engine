import Foundation
import StrimAPI

// Logic the SwiftUI views used to carry in their closures, as plain types so it can be tested without a window.
// The model-driven actions live in AppModel+ViewActions.swift.

/// The three main-window sections.
public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case status, chat, jobs
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var icon: String {
        switch self {
        case .status: "gauge.with.dots.needle.33percent"
        case .chat: "bubble.left.and.bubble.right"
        case .jobs: "list.bullet.rectangle"
        }
    }
    /// Rows above the Projects section. Chat has no row of its own: its chats live under their projects.
    public static let sidebar: [AppSection] = [.status, .jobs]
}

/// The window's keyboard commands. `shortcut` is the glyph form; the views bind the same key to the same case.
public enum WindowCommand: String, CaseIterable, Sendable {
    case status, jobs, lastChat, newChat, openFolder, previousChat, nextChat

    public var title: String {
        switch self {
        case .status: "Status"
        case .jobs: "Jobs"
        case .lastChat: "Last chat"
        case .newChat: "New chat"
        case .openFolder: "Open folder"
        case .previousChat: "Previous chat"
        case .nextChat: "Next chat"
        }
    }
    public var shortcut: String {
        switch self {
        case .status: "⌘1"
        case .jobs: "⌘2"
        case .lastChat: "⌘3"
        case .newChat: "⌘N"
        case .openFolder: "⇧⌘O"
        case .previousChat: "⌘["
        case .nextChat: "⌘]"
        }
    }
}

/// What the window does after a `WindowCommand`.
public enum WindowOutcome: Equatable, Sendable {
    case show(AppSection)
    case stay
    /// The view runs the folder panel (a window concern); adding the chosen folders goes through `addFolders`.
    case chooseFolder
}

/// Menu-bar popover rows.
public enum MenuCommand: String, CaseIterable, Sendable {
    case openMain, settings, quit

    public enum Route: Equatable, Sendable {
        case openWindow(id: String)
        case openSettings
        case terminate
    }
    public var title: String {
        switch self {
        case .openMain: "Open Strim"
        case .settings: "Settings…"
        case .quit: "Quit Strim"
        }
    }
    public var shortcut: String {
        switch self {
        case .openMain: "⌘O"
        case .settings: "⌘,"
        case .quit: "⌘Q"
        }
    }
    public var route: Route {
        switch self {
        case .openMain: .openWindow(id: "main")
        case .settings: .openSettings
        case .quit: .terminate
        }
    }
}

public extension Set {
    /// Inserts `e` when absent, removes it when present (sidebar collapse / "show more" state).
    mutating func flip(_ e: Element) {
        if contains(e) { remove(e) } else { insert(e) }
    }
}

public extension LocalModel {
    /// "Qwen3.8-27B (15.2 GB)": the label in the toolbar model menu and the Settings picker.
    var menuLabel: String { name + (sizeGB.map { String(format: " (%.1f GB)", $0) } ?? "") }
}

/// Where "Reveal in Finder" goes: a folder that does not exist yet (lazy scratch) falls back to its nearest existing parent.
public enum FinderTarget {
    public static func revealPath(_ path: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        var url = URL(fileURLWithPath: path)
        while !exists(url.path), url.path != "/" { url.deleteLastPathComponent() }
        return url.path
    }
}

/// What the sidebar project context menu offers for one project.
public struct ProjectMenuState: Equatable, Sendable {
    public var newChatEnabled: Bool
    public var revealEnabled: Bool
    public var showsLocate: Bool
    public var showsRevokeAccess: Bool
    public var removeTitle: String
}

/// The "Remove project?" confirmation (shared by the sidebar menu and the missing-folder bar).
public struct ProjectRemovalPlan: Equatable, Sendable {
    public var title: String
    public var message: String
    public var offersRevoke: Bool
}

/// Footer of the Jobs list: the count and the optional "show all / recent only" switch.
public struct JobListFooter: Equatable, Sendable {
    public var countText: String
    public var toggleTitle: String?
}

/// Settings text helpers.
public enum SettingsText {
    public static func port(_ url: String) -> String { URL(string: url)?.port.map(String.init) ?? "" }
    public static func mask(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let dir = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        return dir + "/" + String(repeating: "•", count: max(6, min(name.count, 14)))
    }
}

/// Result of adding folders (Open Folder…, drop, Recent).
public struct AddFoldersResult: Equatable, Sendable {
    /// A chat was opened in at least one folder.
    public var opened: Bool
    /// The first failure, for the sidebar's inline error; nil when every folder worked or is waiting for consent.
    public var failure: String?
    /// The consent sheet is up for at least one folder.
    public var needsConsent: Bool
}

/// Sidebar chat list per project: the first five chats (plus the selected one when it is further down).
public enum ThreadListWindow {
    public static let collapsedLimit = 5

    /// The visible chats and how many stay hidden behind "Show N more".
    public static func visible(_ all: [ChatThread], selected: String?, showAll: Bool) -> (shown: [ChatThread], hidden: Int) {
        guard !showAll, all.count > collapsedLimit else { return (all, 0) }
        var out = Array(all.prefix(collapsedLimit))
        if let selected, !out.contains(where: { $0.id == selected }), let t = all.first(where: { $0.id == selected }) { out.append(t) }
        return (out, all.count - out.count)
    }
}
