import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

/// The selected chat: transcript, queued message, composer and the safety line. With no chat selected, the empty state.
struct ChatTab: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject var flow: ProjectsFlow
    /// Screenshots only: show every tool card and reasoning block open.
    var expandAll = false
    @State private var drafts: [String: String] = [:]
    @State private var expanded = Set<UUID>()
    @State private var removeProject: ChatProject?
    @State private var dismissedNotice: String?
    @Environment(\.layoutClass) private var layout

    var body: some View {
        VStack(alignment: .leading, spacing: Strim.S.md) {
            if let t = model.selectedThread {
                notices(t)
                ChatTranscriptView(model: model, expanded: $expanded, expandAll: expandAll, emptyHint: emptyHint(t))
                composerArea(t)
            } else {
                ChatEmptyState(model: model)
            }
        }
        // One readable column shared by transcript and composer: centred 760 pt in regular and wide.
        .frame(maxWidth: layout == .compact ? .infinity : 760, maxHeight: .infinity, alignment: .topLeading)
        .padding(layout == .compact ? 16 : Strim.S.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Strim.C.bg)
        .confirmationDialog(removeProject.map { model.removalPlan(for: $0).title } ?? "Remove project?", isPresented: Binding(get: { removeProject != nil }, set: { if !$0 { removeProject = nil } }),
                            titleVisibility: .visible, presenting: removeProject) { p in
            Button("Remove Project", role: .destructive) { Task { await model.removeProject(p.id) } }
            if model.removalPlan(for: p).offersRevoke {
                Button("Remove and Revoke Access", role: .destructive) { Task { await model.removeProject(p.id, revokeAccess: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { p in Text(model.removalPlan(for: p).message) }
    }

    private func emptyHint(_ t: ChatThread) -> String {
        guard let p = model.project(t.projectId) else { return "" }
        return p.isScratch ? "Files the model creates land in \(PathDisplay.tilde(p.path))" : "Ask anything about \(p.name)."
    }

    @ViewBuilder private func notices(_ t: ChatThread) -> some View {
        if let n = model.chatStoreNotice, n != dismissedNotice {
            infoCard(n) { dismissedNotice = n }
        }
        if let k = model.unreadableMessages[t.id], k > 0 {
            infoCard("\(k) message\(k == 1 ? "" : "s") could not be read.", dismiss: nil)
        }
    }

    private func infoCard(_ text: String, dismiss: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Strim.C.muted)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Strim.C.muted).help("Dismiss").accessibilityLabel("Dismiss notice")
            }
        }
        .padding(Strim.S.md).card(padding: 0)
    }

    @ViewBuilder private func composerArea(_ t: ChatThread) -> some View {
        if model.folderProblem(for: t.id) != nil, let p = model.project(t.projectId) {
            MissingFolderBar(project: p, locate: { locateProject(model, p.id, flow: flow) }, remove: { removeProject = p })
        } else {
            let avail = model.sendAvailability(for: t.id)
            VStack(alignment: .leading, spacing: 6) {
                if let why = model.chatUnavailable[t.id] {
                    Label(why, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Strim.C.danger)
                        .textSelection(.enabled)
                    if model.folderRefused.contains(t.id) {
                        Button("Grant access…") { model.requestGrant(forThread: t.id) }.buttonStyle(StrimButtonStyle(.secondary))
                            .help("Ask to let Strim work in this folder")
                    }
                } else if let why = avail.reason {
                    Label(why, systemImage: "lock").font(.system(size: 12)).foregroundStyle(Strim.C.muted)
                }
                ChatComposer(model: model, thread: t, draft: draftBinding(t.id), available: avail.enabled)
                Text(safetyLine(t)).font(.system(size: 11)).foregroundStyle(Strim.C.tertiary)
                    .accessibilityLabel(safetyLine(t))
            }
        }
    }

    private func safetyLine(_ t: ChatThread) -> String {
        let name = model.project(t.projectId).map { $0.isScratch ? "this scratch folder" : $0.name } ?? "the folder"
        return "Works in an isolated copy of \(name). Changes come back as a patch for review in Jobs."
    }

    private func draftBinding(_ id: String) -> Binding<String> {
        Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 })
    }
}

/// No chat selected: open a folder (primary) or start a scratch chat.
struct ChatEmptyState: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject var flow: ProjectsFlow
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: model.projects.isEmpty ? "folder.badge.plus" : "bubble.left.and.bubble.right").font(.system(size: 26)).foregroundStyle(Strim.C.tertiary)
            Text(model.projects.isEmpty ? "Open a project folder to chat with your code." : "Pick a chat in the sidebar, or start a new one.")
                .font(.system(size: 13)).foregroundStyle(Strim.C.muted).multilineTextAlignment(.center)
            if model.projects.isEmpty {
                Button("Open Folder…") { flow.openFolderPanel(model) }.buttonStyle(StrimButtonStyle(.primary, large: true))
                Button("or start a scratch chat") { _ = model.newThread() }
                    .buttonStyle(.link).font(.system(size: 12)).foregroundStyle(Strim.C.accent)
            } else {
                Button("New Chat") { _ = model.newThread() }.buttonStyle(StrimButtonStyle(.primary, large: true))
                Button("Open Folder…") { flow.openFolderPanel(model) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Strim.C.muted)
            }
            if let e = flow.error {
                Label(e, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Strim.C.danger).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Replaces the composer when the project folder is gone.
struct MissingFolderBar: View {
    let project: ChatProject
    let locate: () -> Void
    let remove: () -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { info; Spacer(minLength: 8); buttons }
            VStack(alignment: .leading, spacing: 10) { info; buttons }
        }
        .padding(Strim.S.md)
        .background(Strim.C.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
    private var info: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark").font(.system(size: 16)).foregroundStyle(Strim.C.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Folder moved or deleted").font(.system(size: 13, weight: .medium))
                Text(PathDisplay.tilde(project.path)).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Strim.C.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Locate…", action: locate).buttonStyle(StrimButtonStyle(.secondary))
            Button("Remove", action: remove).buttonStyle(StrimButtonStyle(.secondary))
        }
    }
}

/// Toolbar model picker: `cpu` plus the model name (icon only when compact).
struct ModelMenu: View {
    @ObservedObject var model: AppModel
    var iconOnly = false
    var body: some View {
        Menu {
            let models = model.availableModels.filter { $0.kind == "model" }
            if models.isEmpty { Text("No local models found") }
            ForEach(models) { m in
                Button(m.menuLabel) { model.selectModel(m) }
            }
        } label: {
            if iconOnly {
                Image(systemName: "cpu")
            } else {
                Label { Text(name).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle) } icon: { Image(systemName: "cpu") }
            }
        }
        .menuIndicator(.visible)
        .help("Model: \(name) (takes effect on the next Start)")
        .accessibilityLabel("Model \(name)")
    }
    private var name: String {
        model.status?.model ?? model.settings.modelPath.map { ($0 as NSString).lastPathComponent } ?? "no model"
    }
}

struct ChatTranscriptView: View {
    @ObservedObject var model: AppModel
    @Binding var expanded: Set<UUID>
    var expandAll = false
    var emptyHint = ""

    enum Item: Identifiable {
        case message(ChatMessage)
        case tools([ChatMessage])
        case divider(ChatMessage)
        var id: UUID { switch self { case .message(let m), .divider(let m): m.id; case .tools(let t): t[0].id } }
    }
    /// Consecutive tool calls share one bordered container; markers become divider rows.
    static func items(_ messages: [ChatMessage]) -> [Item] {
        var out: [Item] = []
        for m in messages {
            if m.marker != nil { out.append(.divider(m)) }
            else if m.role == .tool, case .tools(let g)? = out.last { out[out.count - 1] = .tools(g + [m]) }
            else if m.role == .tool { out.append(.tools([m])) }
            else { out.append(.message(m)) }
        }
        return out
    }

    var body: some View {
        let queued = model.selectedThreadID.flatMap { model.queuedText(for: $0) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.chatMessages.isEmpty, queued == nil, !emptyHint.isEmpty {
                        Text(emptyHint).font(.system(size: 13)).foregroundStyle(Strim.C.tertiary)
                            .frame(maxWidth: .infinity).padding(.top, 48).multilineTextAlignment(.center)
                    }
                    ForEach(Self.items(model.chatMessages)) { item in
                        switch item {
                        case .message(let m): MessageRow(message: m, isOpen: binding(m.id), copy: { model.copyMessage(m.id) })
                        case .tools(let g): ToolGroupView(messages: g, expanded: $expanded, expandAll: expandAll).padding(.leading, 30)
                        case .divider(let m): SessionBreakRow(text: m.text)
                        }
                    }
                    if let q = queued, let tid = model.selectedThreadID {
                        QueuedBubble(text: q, waitingFor: model.generatingThreadID.flatMap { model.thread($0)?.title } ?? "another chat",
                                     cancel: { Task { await model.cancel(tid) } })
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            // Instant scroll, no animation: deltas are coalesced upstream (~30 Hz), so this stays smooth.
            .onChange(of: model.chatMessages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.chatMessages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.selectedThreadID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expandAll || expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}

/// "Session ended" / "Earlier messages trimmed": hairline with centred 11 pt text, 16 pt above and below.
struct SessionBreakRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Strim.C.hairline).frame(height: 1)
            Text(text).font(.system(size: 11)).foregroundStyle(Strim.C.tertiary).multilineTextAlignment(.center)
                .layoutPriority(1).frame(maxWidth: 420)
            Rectangle().fill(Strim.C.hairline).frame(height: 1)
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// A message sent while another chat is generating: dimmed user bubble and what it waits for.
struct QueuedBubble: View {
    let text: String
    let waitingFor: String
    let cancel: () -> Void
    @Environment(\.layoutClass) private var layout
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: layout == .compact ? 40 : 80)
                Text(text).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Strim.C.surface2, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous))
                    .opacity(0.6)
            }
            HStack(spacing: 4) {
                Text("Waiting for “\(waitingFor)” to finish ·").lineLimit(1).truncationMode(.middle)
                Button("Cancel", action: cancel).buttonStyle(.plain).underline().accessibilityLabel("Cancel queued message")
            }
            .font(.system(size: 11)).foregroundStyle(Strim.C.muted)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }
}

struct ChatComposer: View {
    @ObservedObject var model: AppModel
    let thread: ChatThread
    @Binding var draft: String
    var available = true

    /// Before the first message the toggle edits the default; afterwards it shows what the chat uses (the host reads it once).
    private var thinking: Binding<Bool> {
        thread.messageCount == 0 ? Binding(get: { model.thinkingEnabled }, set: { model.setDefaultThinking($0) }) : .constant(thread.thinking)
    }

    var body: some View {
        let queued = model.queuedText(for: thread.id) != nil
        let locked = thread.messageCount > 0
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "brain").font(.system(size: 11)).foregroundStyle(Strim.C.muted)
                Toggle("Thinking", isOn: thinking).labelsHidden()
                    .toggleStyle(.switch).controlSize(.small).fixedSize().disabled(locked)
            }
            .padding(.leading, 6)
            .help(locked ? "Applies to new chats" : "Let the model reason before answering. Fixed once the chat has started.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Thinking")
            .accessibilityValue(thinking.wrappedValue ? "on" : "off")
            .accessibilityHint(locked ? "Applies to new chats" : "")
            TextField(queued ? "One message is waiting" : "Message", text: $draft).textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit(send).disabled(model.chatGenerating || queued || !available)
            if model.chatGenerating {
                Button { Task { await model.cancel(thread.id) } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Strim.C.text)
                        .frame(width: 26, height: 26).background(Strim.C.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain).keyboardShortcut(".", modifiers: .command).help("Stop generating (Cmd-.)").accessibilityLabel("Stop generating")
            } else {
                let off = !AppModel.canSend(draft: draft, queued: queued, available: available)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(off ? Strim.C.tertiary : Strim.C.onAccent)
                        .frame(width: 26, height: 26)
                        .background(off ? Strim.C.surface2 : Strim.C.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain).disabled(off).accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 6).frame(minHeight: 36)
        .background(Strim.C.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
        .opacity(available ? 1 : 0.6)
    }
    private func send() {
        let t = draft
        guard model.submitDraft(t, in: thread.id, available: available) != nil else { return }
        draft = ""
    }
}

/// One transcript entry. Tool calls and reasoning are collapsed by default; the last message of a turn carries the
/// token ledger.
struct MessageRow: View {
    let message: ChatMessage
    @Binding var isOpen: Bool
    let copy: () -> Void
    @Environment(\.layoutClass) private var layout

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            switch message.role {
            case .user:
                HStack {
                    Spacer(minLength: layout == .compact ? 40 : 80)
                    Text(markdown(message.text)).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(
                            Strim.C.surface2,
                            in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous))
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous)
                            .strokeBorder(Strim.C.hairline, lineWidth: 1))
                }
            case .assistant:
                HStack(alignment: .top, spacing: 8) {
                    Image(nsImage: MenuBarGlyph.image()).renderingMode(.template).foregroundStyle(Strim.C.muted).frame(width: 22, height: 22).padding(.top, 2)
                    AssistantBody(text: message.text)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Strim.C.surface, in: UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous))
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous)
                            .strokeBorder(Strim.C.hairline, lineWidth: 1))
                }
            case .reasoning:
                StrimDisclosure(isOpen: $isOpen) {
                    Label { Text("Reasoning").font(.system(size: 12, weight: .medium)) } icon: { Image(systemName: "brain") }
                        .font(.system(size: 12)).foregroundStyle(Strim.C.muted)
                } content: {
                    Text(message.text).font(.callout).foregroundStyle(Strim.C.muted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Strim.C.hairline).frame(width: 2) }
                        .padding(.leading, 16)
                }
                .padding(.leading, 30)
            case .tool:
                EmptyView()   // rendered by ToolGroupView
            }
            HStack(spacing: 8) {
                if let l = message.ledger { Text(l.summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(Strim.C.tertiary) }
                if message.role == .assistant {
                    Button(action: copy) { Image(systemName: "doc.on.doc").font(.system(size: 10)) }.buttonStyle(.plain)
                        .foregroundStyle(Strim.C.muted).help("Copy message").accessibilityLabel("Copy message")
                }
            }
            .padding(.leading, message.role == .user ? 0 : 30)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Consecutive tool calls in one bordered container, 28 pt rows.
struct ToolGroupView: View {
    let messages: [ChatMessage]
    @Binding var expanded: Set<UUID>
    var expandAll: Bool
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Rectangle().fill(Strim.C.hairline).frame(height: 1) }
                ToolRowView(card: m.tool ?? ToolCard(name: "tool", args: m.text), isOpen: Binding(
                    get: { expandAll || expanded.contains(m.id) },
                    set: { if $0 { expanded.insert(m.id) } else { expanded.remove(m.id) } }))
            }
        }
        .background(Strim.C.surface, in: RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
    }
}

struct ToolRowView: View {
    let card: ToolCard
    @Binding var isOpen: Bool
    @State private var showAll = false
    private var args: String {
        let a = card.args.trimmingCharacters(in: .whitespaces)
        return a.hasPrefix(card.name + " ") ? String(a.dropFirst(card.name.count + 1)) : a
    }
    var body: some View {
        StrimDisclosure(isOpen: $isOpen, spacing: 0) {
            HStack(spacing: 8) {
                statusSymbol
                Text(card.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Strim.C.text)
                Text(args).font(.system(size: 12, design: .monospaced)).foregroundStyle(Strim.C.muted).lineLimit(1).truncationMode(.middle)
                if card.isError { Text("error").font(.system(size: 11)).foregroundStyle(Strim.C.danger) }
            }
            .frame(height: 28)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                // The header already shows short args; repeat them in the body only when the header truncates them.
                if args.count > 60 { codeBlock(card.args, Strim.C.muted) }
                resultBlock
            }
            .textSelection(.enabled)
            .padding(.horizontal, 10).padding(.bottom, 8).padding(.leading, 16)
        }
        .padding(.leading, 10)
    }

    @ViewBuilder private var resultBlock: some View {
        let color = card.isError ? Strim.C.danger : Strim.C.text
        if let r = card.result {
            let p = ToolResultPreview.split(r, maxLines: showAll ? .max : 8)
            VStack(alignment: .leading, spacing: 4) {
                codeBlock(p.shown, color)
                if p.hidden > 0 {
                    Button("\(p.hidden) more line\(p.hidden == 1 ? "" : "s")") { showAll = true }.buttonStyle(.link).font(.system(size: 11)).foregroundStyle(Strim.C.accent)
                } else if showAll, ToolResultPreview.split(r).hidden > 0 {
                    Button("Show less") { showAll = false }.buttonStyle(.link).font(.system(size: 11)).foregroundStyle(Strim.C.accent)
                }
            }
        } else { codeBlock("running...", color) }
    }

    @ViewBuilder private var statusSymbol: some View {
        if !card.finished { Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).foregroundStyle(Strim.C.tertiary) }
        else if card.isError { Image(systemName: "xmark.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Strim.C.danger) }
        else { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Strim.C.tertiary) }
    }

    private func codeBlock(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text).font(.system(size: 11, design: .monospaced)).foregroundStyle(color)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            .background(Strim.C.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Assistant markdown: prose as inline markdown, fenced code with preserved newlines in a monospace block that
/// scrolls sideways; diff fences colour added lines indigo and removed lines coral.
struct AssistantBody: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let p):
                    Text((try? AttributedString(markdown: p, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(p))
                        .lineSpacing(2)
                case .code(let lang, let code):
                    CodeBlockView(language: lang, code: code)
                }
            }
        }
        .textSelection(.enabled)
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    var body: some View {
        let isDiff = DiffLineKind.isDiffLanguage(language)
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language).font(Strim.F.label()).foregroundStyle(Strim.C.muted)
                    .padding(.horizontal, 10).padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        let kind: DiffLineKind = isDiff ? DiffLineKind.classify(line) : .context
                        Text(line.isEmpty ? " " : line)
                            .font(Strim.F.mono(.caption)).foregroundStyle(color(kind)).fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(fill(kind))
                    }
                }
                .padding(.vertical, 6)
                .frame(minWidth: 0, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Strim.C.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
    }

    private func color(_ k: DiffLineKind) -> Color {
        switch k {
        case .added: Strim.C.accent
        case .removed: Strim.C.danger
        case .hunk, .header: Strim.C.muted
        case .context: Strim.C.text
        }
    }
    private func fill(_ k: DiffLineKind) -> Color {
        switch k {
        case .added: Strim.C.accent.opacity(0.14)
        case .removed: Strim.C.danger.opacity(0.14)
        default: .clear
        }
    }
}
