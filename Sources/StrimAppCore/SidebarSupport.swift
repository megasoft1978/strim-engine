import Foundation

/// "4m" style age for sidebar rows.
public enum RelativeTime {
    public static func short(_ ts: Double, now: Double) -> String {
        let s = Int(max(0, now - ts))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3600)h"
        case ..<(86_400 * 7): return "\(s / 86_400)d"
        default: return "\(s / (86_400 * 7))w"
        }
    }
}

public enum PathDisplay {
    /// Screenshots only: show fixture paths under `from` as `to` (e.g. `~/Projects`).
    nonisolated(unsafe) public static var displayMap: (from: String, to: String)?
    /// `/Users/me/dev/app` as `~/dev/app`; over `maxLength` characters the middle becomes an ellipsis (keeps both ends).
    public static func tilde(_ path: String, home: String = NSHomeDirectory(), maxLength: Int = 56) -> String {
        var p = path
        if let m = displayMap, p == m.from || p.hasPrefix(m.from + "/") { p = m.to + p.dropFirst(m.from.count) }
        if p == home { p = "~" } else if p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
        guard p.count > maxLength, maxLength > 8 else { return p }
        let keep = maxLength - 1
        let head = keep / 3, tail = keep - head
        return String(p.prefix(head)) + "…" + String(p.suffix(tail))
    }
}

public extension AppModel {
    /// Sidebar order: projects by latest activity, Scratch last.
    var sidebarProjects: [ChatProject] {
        projects.filter { !$0.isScratch }.sorted { $0.lastActivity > $1.lastActivity } + projects.filter(\.isScratch)
    }
    /// Thread ids top to bottom in the sidebar (all threads, including ones behind "Show more").
    var sidebarThreadOrder: [String] { sidebarProjects.flatMap { threads(in: $0.id).map(\.id) } }

    /// The thread one step before (-1) or after (+1) `id` in sidebar order; nil at the ends or when there is none.
    func adjacentThread(from id: String?, step: Int) -> String? {
        let order = sidebarThreadOrder
        guard !order.isEmpty else { return nil }
        guard let id, let i = order.firstIndex(of: id) else { return step > 0 ? order.first : order.last }
        let j = i + step
        return order.indices.contains(j) ? order[j] : nil
    }

    /// The selected thread, else the most recently active one (target of Cmd-3).
    var lastThreadID: String? {
        selectedThreadID ?? threads.max { $0.lastActivity < $1.lastActivity }?.id
    }

    /// Dashboard glyph of a thread row. Highest priority first.
    func threadBadge(_ id: String) -> ThreadBadge {
        if generatingThreadID == id { return .generating }
        if queuedText(for: id) != nil { return .queued }
        if chatUnavailable[id] != nil { return .error }
        if thread(id)?.unread == true { return .unread }
        return .none
    }
}

public enum ThreadBadge: Sendable, Equatable { case none, generating, queued, unread, error }
