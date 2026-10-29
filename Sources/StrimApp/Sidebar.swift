import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

enum SidebarItem: Hashable {
    case section(AppSection)
    case thread(String)
}

/// Status, Jobs, then the Projects section: one disclosure row per folder with its chats underneath.
struct Sidebar: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject var flow: ProjectsFlow
    @Binding var section: AppSection
    @State private var collapsed = Set<String>()
    @State private var showAll = Set<String>()
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var dropTargeted = false
    @State private var deleteThread: ChatThread?
    @State private var removeProject: ChatProject?

    static let collapsedLimit = 5
    private let rowInsets = EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

    private func select(_ item: SidebarItem) {
        switch item {
        case .section(let s): section = s
        case .thread(let id): model.selectThread(id); section = .chat
        }
    }

    var body: some View {
        let now = Date().timeIntervalSince1970
        let missing = Set(model.projects.filter { model.folderMissing($0.id) }.map(\.id))
        // No List selection: the system's emphasised (blue) highlight cannot be themed, so rows draw the accent pill themselves.
        List {
            ForEach(AppSection.sidebar) { s in
                Label(s.title, systemImage: s.icon)
                    .badge(s == .jobs ? activeJobs : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { select(.section(s)) }
                    .accessibilityAddTraits(section == s ? [.isButton, .isSelected] : .isButton)
                    .listRowBackground(SelectedRowBackground(selected: section == s, hoverable: false))
            }
            Section {
                if let e = flow.error { errorRow(e) }
                ForEach(model.sidebarProjects) { p in projectGroup(p, missing: missing.contains(p.id), now: now) }
                if model.projects.isEmpty {
                    Text("No projects yet").font(.system(size: 12)).foregroundStyle(Strim.C.tertiary)
                        .frame(height: 26)
                }
            } header: { ProjectsHeader(model: model, section: $section) }
        }
        .toolbar(removing: model.modelDownloadState.isBlockingFirstRun ? .sidebarToggle : nil)
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 24)
        .safeAreaInset(edge: .top, spacing: 0) { stateRow }
        .dropDestination(for: URL.self) { urls, _ in
            flow.add(urls.map(\.path), model) { section = .chat }
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Strim.C.muted.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(Strim.C.surface2.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay { Label("Drop a folder to add it", systemImage: "folder.badge.plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Strim.C.text) }
                    .padding(8).allowsHitTesting(false)
            }
        }
        .confirmationDialog(deleteThread.map { "Delete “\($0.title)”?" } ?? "Delete chat?", isPresented: Binding(get: { deleteThread != nil }, set: { if !$0 { deleteThread = nil } }),
                            titleVisibility: .visible, presenting: deleteThread) { t in
            Button("Delete Chat", role: .destructive) { Task { await model.deleteThread(t.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("This chat is deleted from this Mac. It cannot be undone.") }
        .confirmationDialog(removeProject.map { "Remove “\($0.name)”?" } ?? "Remove project?", isPresented: Binding(get: { removeProject != nil }, set: { if !$0 { removeProject = nil } }),
                            titleVisibility: .visible, presenting: removeProject) { p in
            Button("Remove Project", role: .destructive) { Task { await model.removeProject(p.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { p in Text("Deletes its \(model.threads(in: p.id).count) chats from this Mac. The folder itself is not touched.") }
    }

    private var activeJobs: Int { model.status?.activeJobs ?? 0 }

    // MARK: projects

    @ViewBuilder
    private func projectGroup(_ p: ChatProject, missing: Bool, now: Double) -> some View {
        let all = model.threads(in: p.id)
        let (visible, hidden) = Self.visible(all, selected: model.selectedThreadID, showAll: showAll.contains(p.id))
        let open = !collapsed.contains(p.id)
        ProjectRow(project: p, missing: missing, open: open)
            .contentShape(Rectangle())
            .onTapGesture { if open { collapsed.insert(p.id) } else { collapsed.remove(p.id) } }
            .contextMenu { projectMenu(p, missing: missing) }
            .listRowInsets(rowInsets)
        if open {
            ForEach(visible) { t in
                ThreadRow(thread: t, badge: model.threadBadge(t.id), selected: section == .chat && model.selectedThreadID == t.id, now: now,
                          renaming: $renaming, renameText: $renameText, commit: { model.renameThread(t.id, to: $0) })
                    .contentShape(Rectangle())
                    .onTapGesture { select(.thread(t.id)) }
                    .accessibilityAddTraits(section == .chat && model.selectedThreadID == t.id ? [.isButton, .isSelected] : .isButton)
                    .contextMenu { threadMenu(t) }
                    .listRowBackground(SelectedRowBackground(selected: section == .chat && model.selectedThreadID == t.id, hoverable: false))
                    .listRowInsets(rowInsets)
            }
            if hidden > 0 || (showAll.contains(p.id) && all.count > Self.collapsedLimit) {
                Button { if showAll.contains(p.id) { showAll.remove(p.id) } else { showAll.insert(p.id) } } label: {
                    Text(showAll.contains(p.id) ? "Show less" : "Show \(hidden) more").font(.system(size: 11)).foregroundStyle(Strim.C.tertiary)
                        .padding(.leading, 16)
                }
                .buttonStyle(.plain).frame(height: 24).listRowInsets(rowInsets)
                .accessibilityLabel(showAll.contains(p.id) ? "Show fewer chats in \(p.name)" : "Show \(hidden) more chats in \(p.name)")
            }
            if all.isEmpty {
                Button { startChat(in: p) } label: {
                    Label("New chat", systemImage: "square.and.pencil").font(.system(size: 12)).foregroundStyle(Strim.C.muted).padding(.leading, 16)
                }
                .buttonStyle(.plain).frame(height: 26).listRowInsets(rowInsets)
            }
        }
    }

    /// The first five chats (plus the selected one when it is further down), and how many stay hidden.
    static func visible(_ all: [ChatThread], selected: String?, showAll: Bool) -> ([ChatThread], Int) {
        guard !showAll, all.count > collapsedLimit else { return (all, 0) }
        var out = Array(all.prefix(collapsedLimit))
        if let selected, !out.contains(where: { $0.id == selected }), let t = all.first(where: { $0.id == selected }) { out.append(t) }
        return (out, all.count - out.count)
    }

    private func startChat(in p: ChatProject) {
        collapsed.remove(p.id)
        if model.newThread(projectID: p.id) != nil { section = .chat }
    }

    @ViewBuilder private func projectMenu(_ p: ChatProject, missing: Bool) -> some View {
        Button("New Chat") { startChat(in: p) }.disabled(missing)
        Divider()
        Button("Reveal in Finder") { Finder.reveal(p.path) }.disabled(missing)
        Button("Copy Path") { Finder.copy(p.path) }
        if missing { Button("Locate…") { locateProject(model, p.id, flow: flow) } }
        Divider()
        Button(p.isScratch ? "Delete Scratch Chats…" : "Remove Project…", role: .destructive) { removeProject = p }
    }

    @ViewBuilder private func threadMenu(_ t: ChatThread) -> some View {
        Button("Rename") { renameText = t.title; renaming = t.id }
        Button("Duplicate") { if model.duplicateThread(t.id) != nil { section = .chat } }
        Button("Reveal Folder in Finder") { if let dir = model.cwd(for: t) { Finder.reveal(dir) } }
            .disabled(model.folderProblem(for: t.id) != nil)
        Divider()
        Button("Delete…", role: .destructive) { deleteThread = t }
    }

    private func errorRow(_ message: String) -> some View {
        Button { flow.error = nil } label: {
            Label { Text(message).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading) } icon: { Image(systemName: "exclamationmark.circle") }
                .font(.system(size: 11)).foregroundStyle(Strim.C.danger)
        }
        .buttonStyle(.plain).help("Dismiss")
        .accessibilityLabel("Could not add folder: \(message)")
    }

    private var stateRow: some View {
        let orb = OrbState(model.connection)
        return HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: MenuBarGlyph.image()).renderingMode(.template).foregroundStyle(Strim.C.text)
                StateBadge(state: orb).offset(x: 3, y: 3)
            }.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(orb.word).font(.system(size: 13, weight: .semibold))
                if orb == .busy, let s = model.status {
                    Text(String(format: "%.1f tok/s", s.decodeTPS)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Strim.C.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Server \(orb.word)")
    }
}

/// The accent selection pill every selectable sidebar row shares (the accent budget's one "selected item"), plus hover.
struct SelectedRowBackground: View {
    let selected: Bool
    var hover = false
    var hoverable = true
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Strim.C.accent.opacity(0.22) : (hover && hoverable ? Strim.C.surface2.opacity(0.6) : .clear))
            .padding(.horizontal, 6)
    }
}

// MARK: header

struct ProjectsHeader: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject var flow: ProjectsFlow
    @Binding var section: AppSection
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            Text("Projects").font(.system(size: 11, weight: .semibold)).foregroundStyle(Strim.C.tertiary).textCase(nil)
            Spacer(minLength: 4)
            Menu {
                Button("Open Folder…") { flow.openFolderPanel(model) { section = .chat } }
                Menu("Recent") {
                    let open = Set(model.projects.map(\.path))
                    let recents = model.validRecentProjects.filter { !open.contains($0) }
                    if recents.isEmpty { Text("No recent folders") }
                    ForEach(recents, id: \.self) { p in
                        Button(PathDisplay.tilde(p)) { flow.add([p], model) { section = .chat } }
                    }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Strim.C.muted)
                    .frame(width: 22, height: 22)
                    .background(hover ? Strim.C.surface2 : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .onHover { hover = $0 }
            .help("Open a project folder")
            .accessibilityLabel("Add project")
        }
        .frame(height: 28)
    }
}

// MARK: rows

struct ProjectRow: View {
    let project: ChatProject
    let missing: Bool
    var open = true
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Strim.C.tertiary).frame(width: 10)
            Image(systemName: project.isScratch ? "tray" : (missing ? "folder.badge.questionmark" : "folder"))
                .font(.system(size: 13)).foregroundStyle(Strim.C.muted).frame(width: 16)
            Text(project.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Strim.C.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .opacity(missing ? 0.5 : 1)
        .help(missing ? "Folder not found" : PathDisplay.tilde(project.path))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(missing ? "\(project.name), folder not found" : project.name)
    }
}

struct ThreadRow: View {
    let thread: ChatThread
    let badge: ThreadBadge
    let selected: Bool
    let now: Double
    @Binding var renaming: String?
    @Binding var renameText: String
    let commit: (String) -> Void
    @State private var hover = false
    @FocusState private var focused: Bool

    private var unread: Bool { badge == .unread }

    var body: some View {
        HStack(spacing: 6) {
            if renaming == thread.id {
                TextField("Chat title", text: $renameText)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                    .onSubmit(finish)
                    .onExitCommand { renaming = nil }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, now in if !now, renaming == thread.id { finish() } }
            } else {
                Text(thread.title).font(.system(size: 12, weight: unread ? .semibold : .regular)).foregroundStyle(Strim.C.text)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            trailing
        }
        .frame(height: 26)
        .onHover { hover = $0 }
        .padding(.leading, 4).padding(.trailing, 2)
        .background(hover && !selected ? Strim.C.surface2.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func finish() {
        let t = renameText
        renaming = nil
        if !t.trimmingCharacters(in: .whitespaces).isEmpty, t != thread.title { commit(t) }
    }

    @ViewBuilder private var trailing: some View {
        switch badge {
        case .generating: PulseDot()
        case .queued:
            Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(Strim.C.tertiary)
        case .error:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Strim.C.danger)
                time
            }
        case .unread:
            HStack(spacing: 5) {
                Circle().fill(Strim.C.text).frame(width: 6, height: 6)
                time
            }
        case .none: time
        }
    }

    private var time: some View {
        Text(RelativeTime.short(thread.lastActivity, now: now)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Strim.C.tertiary)
    }

    private var accessibilityText: String {
        let status: String
        switch badge {
        case .generating: status = ", generating"
        case .queued: status = ", waiting to send"
        case .error: status = ", could not start"
        case .unread: status = ", unread reply"
        case .none: status = ""
        }
        return "\(thread.title)\(status), \(RelativeTime.short(thread.lastActivity, now: now))"
    }
}

/// 6 pt accent dot for a live turn. It pulses unless Reduce Motion is on.
struct PulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        Circle().fill(Strim.C.accent).frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1 : (on ? 1 : 0.35))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}
