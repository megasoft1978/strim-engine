import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

enum AppSection: String, CaseIterable, Identifiable {
    case status, chat, jobs
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .status: "gauge.with.dots.needle.33percent"
        case .chat: "bubble.left.and.bubble.right"
        case .jobs: "list.bullet.rectangle"
        }
    }
    /// Rows above the Projects section. Chat has no row of its own: its chats live under their projects.
    static let sidebar: [AppSection] = [.status, .jobs]
}

/// Main window: sidebar (state row, Status, Jobs, Projects with their chats), unified toolbar (Start/Stop, overflow menu) and the
/// section content. First-run states collapse the sidebar and replace the content with the download flow.
struct MainWindow: View {
    @ObservedObject var model: AppModel
    @State private var section: AppSection
    @State private var visibility: NavigationSplitViewVisibility
    /// The visibility the app last set itself; a different value arriving later is the user's toolbar toggle.
    @State private var expectedVisibility: NavigationSplitViewVisibility
    @State private var userPinnedVisibility = false
    @State private var windowWidth: CGFloat = 1040
    @State private var detailWidth: CGFloat = 840
    @StateObject private var flow = ProjectsFlow()
    var expandChat = false

    /// `sidebarOpen`: start with the sidebar shown and pinned (snapshots of the narrow-window state the user opened by hand).
    init(model: AppModel, section: AppSection = .status, expandChat: Bool = false, sidebarOpen: Bool = false) {
        self.model = model; self.expandChat = expandChat
        _section = State(initialValue: section)
        let initial: NavigationSplitViewVisibility = model.modelDownloadState.isBlockingFirstRun ? .detailOnly : .all
        _visibility = State(initialValue: initial)
        _expectedVisibility = State(initialValue: initial)
        _userPinnedVisibility = State(initialValue: sidebarOpen)
    }

    private var layout: LayoutClass { LayoutClass.of(width: detailWidth) }
    /// From the window width alone (not the detail column): the detail width jumps when the sidebar collapses, and the
    /// toolbar item keeps its first measured size, so a width-class flip there would leave a clipped button.
    private var startStopStyle: ToolbarStartStopStyle { .of(windowWidth: windowWidth, layout: LayoutClass.of(width: windowWidth)) }

    private func setVisibility(_ v: NavigationSplitViewVisibility) {
        expectedVisibility = v
        visibility = v
    }

    /// Sidebar follows the window width unless the user toggled it by hand (see `SidebarVisibilityPolicy`).
    private func applyAutoVisibility(width: CGFloat) {
        guard !firstRun, width >= 300 else { return }   // width 1 is the hosting view before its first layout
        let collapsed = SidebarVisibilityPolicy.collapsed(windowWidth: width, currentlyCollapsed: visibility == .detailOnly,
                                                          userPinned: userPinnedVisibility)
        let target: NavigationSplitViewVisibility = collapsed ? .detailOnly : .all
        if target != visibility { setVisibility(target) }
    }

    private var firstRun: Bool { model.modelDownloadState.isBlockingFirstRun }

    /// Chat shows the chat's title with its folder as the subtitle; the other sections show their name.
    private var title: String {
        if firstRun { return "Strim" }
        guard section == .chat else { return section.title }
        return model.selectedThread?.title ?? "Chat"
    }
    private var subtitle: String {
        guard !firstRun, section == .chat, let t = model.selectedThread, let dir = model.cwd(for: t) else { return "" }
        return PathDisplay.tilde(model.project(t.projectId)?.isScratch == true ? (dir as NSString).deletingLastPathComponent : dir)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            Sidebar(model: model, section: $section)
                .environmentObject(flow)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                if firstRun { FirstRunView(model: model) }
                else {
                    switch section {
                    case .status: StatusView(model: model)
                    case .chat: ChatTab(model: model, expandAll: expandChat).environmentObject(flow)
                    case .jobs: JobsView(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Strim.C.bg)
            .environment(\.layoutClass, layout)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0 >= 300 { detailWidth = $0 } }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                if !firstRun {
                    if section == .chat, model.selectedThread != nil {
                        ToolbarItem(placement: .primaryAction) { ModelMenu(model: model, iconOnly: layout == .compact) }
                    }
                    // Separate items (not one group) so the toolbar re-measures each when the width class changes.
                    ToolbarItem(placement: .primaryAction) {
                        if startStopStyle != .inMenu { ServerToggleButton(model: model, toolbar: true, iconOnly: startStopStyle == .iconOnly) }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        OverflowMenu(model: model, includeServerToggle: startStopStyle == .inMenu)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            guard $0 >= 300 else { return }   // 1 pt is the hosting view before its first layout
            windowWidth = $0; applyAutoVisibility(width: $0)
        }
        .onChange(of: visibility) { _, new in
            if new != expectedVisibility { userPinnedVisibility = true; expectedVisibility = new }
        }
        .tint(Strim.C.accent)
        .foregroundStyle(Strim.C.text)
        .background { shortcuts }
        .onChange(of: firstRun) { _, now in
            if now { setVisibility(.detailOnly) } else { userPinnedVisibility = false; setVisibility(.all); applyAutoVisibility(width: windowWidth) }
        }
        .onAppear { model.checkModelAvailability() }
        .sheet(item: Binding(get: { model.pendingConsent }, set: { if $0 == nil, model.pendingConsent != nil { model.cancelConsent() } })) { c in
            ConsentSheet(consent: c, allow: { flow.allow(model) }, cancel: { model.cancelConsent() })
        }
    }

    /// ⌘1 Status, ⌘2 Jobs, ⌘3 last chat, ⌘N new chat, ⇧⌘O open folder, ⌘[ / ⌘] previous / next chat, ⌘R toggles the server.
    private var shortcuts: some View {
        Group {
            Button("Status") { section = .status }.keyboardShortcut("1", modifiers: .command)
            Button("Jobs") { section = .jobs }.keyboardShortcut("2", modifiers: .command)
            Button("Last chat") {
                if let id = model.lastThreadID { model.selectThread(id) }
                section = .chat
            }.keyboardShortcut("3", modifiers: .command)
            Button("New chat") { if model.newThread() != nil { section = .chat } }.keyboardShortcut("n", modifiers: .command)
            Button("Open folder") { flow.openFolderPanel(model) { section = .chat } }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Previous chat") { step(-1) }.keyboardShortcut("[", modifiers: .command)
            Button("Next chat") { step(1) }.keyboardShortcut("]", modifiers: .command)
            Button("Toggle server") {
                if model.serverIsUp { Task { await model.stopServer() } } else { Task { await model.startServer() } }
            }.keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private func step(_ by: Int) {
        guard let id = model.adjacentThread(from: section == .chat ? model.selectedThreadID : nil, step: by) else { return }
        model.selectThread(id); section = .chat
    }
}

/// Small shape badge on the glyph: the shape, not the colour, carries the state.
struct StateBadge: View {
    let state: OrbState
    var body: some View {
        Group {
            switch state {
            case .running, .busy: Circle().fill(Strim.C.accent)
            case .error: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(Strim.C.danger)
            case .loading: Circle().strokeBorder(Strim.C.muted, lineWidth: 1.5)
            case .stopped, .offline: Circle().strokeBorder(Strim.C.tertiary, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
    }
}

/// The toolbar "…" menu.
struct OverflowMenu: View {
    @ObservedObject var model: AppModel
    /// Narrow windows (< 700 pt) move Start/Stop here as the first item.
    var includeServerToggle = false
    var body: some View {
        Menu {
            if includeServerToggle {
                let up = model.serverIsUp
                Button(up ? "Stop server" : "Start server") {
                    if up { Task { await model.stopServer() } } else { Task { await model.startServer() } }
                }
                .disabled(!(up ? model.serverStopAvailability : model.serverStartAvailability).enabled)
                Divider()
            }
            Button(model.pauseButtonTitle) { Task { await model.togglePause() } }
                .disabled(!model.pauseAvailability.enabled || !model.serverIsUp)
            Divider()
            Button("Copy endpoint") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.endpointURL, forType: .string) }
            Button("Copy MCP registration commands") { Task { await model.copyMCPCommands() } }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuIndicator(.hidden)
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}
