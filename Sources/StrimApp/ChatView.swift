import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

struct ChatTab: View {
    @ObservedObject var model: AppModel
    /// Screenshots only: show every tool card and reasoning block open.
    var expandAll = false
    @State private var draft = ""
    @State private var expanded = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: Strim.S.md) {
            switch model.chat {
            case .unknown:
                emptyState(icon: "bubble.left.and.bubble.right", text: "Chat has not been opened.") {
                    Button("Open chat session") { Task { await model.probeChat() } }
                        .buttonStyle(StrimButtonStyle(.primary)).disabled(!model.connection.isConnected)
                }
            case .unavailable(let why):
                emptyState(icon: "bubble.left.and.exclamationmark.bubble.right", text: why) {
                    Button("Retry") { Task { await model.probeChat() } }.buttonStyle(StrimButtonStyle(.secondary))
                }
            case .ready(let s):
                ChatHeader(model: model, cwd: s.cwd)
                ChatTranscriptView(model: model, expanded: $expanded, expandAll: expandAll)
                ChatComposer(model: model, draft: $draft)
            }
        }
        .padding(Strim.S.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { if model.chat == .unknown, model.connection.isConnected { await model.probeChat() } }
    }

    private func emptyState<A: View>(icon: String, text: String, @ViewBuilder action: () -> A) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(Strim.C.muted)
            Text(text).font(.callout).foregroundStyle(Strim.C.muted).multilineTextAlignment(.center)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).glassCard()
    }
}

struct ChatHeader: View {
    @ObservedObject var model: AppModel
    let cwd: String
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                let recents = model.validRecentProjects
                if recents.isEmpty { Text("No recent projects") }
                ForEach(recents, id: \.self) { p in
                    Button((p as NSString).abbreviatingWithTildeInPath) { _ = model.setProject(p) }
                }
                Divider()
                Button("Choose folder...") { chooseProject(model) }
            } label: {
                chip("folder", (cwd as NSString).abbreviatingWithTildeInPath, truncate: .head)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Project folder (starts a new chat when changed)")
            Menu {
                let models = model.availableModels.filter { $0.kind == "model" }
                if models.isEmpty { Text("No local models found") }
                ForEach(models) { m in
                    Button(m.name + (m.sizeGB.map { String(format: " (%.1f GB)", $0) } ?? "")) { model.selectModel(m) }
                }
            } label: {
                chip("cpu", model.status?.model ?? model.settings.modelPath.map { ($0 as NSString).lastPathComponent } ?? "no model", truncate: .middle)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Model (takes effect on the next Start)")
            Spacer()
            Toggle(isOn: $model.thinkingEnabled) { Label("Thinking", systemImage: "brain") }
                .toggleStyle(StrimToggleStyle())
                .help("Let the model reason before answering. Applies to the next message.")
        }
    }

    private func chip(_ icon: String, _ text: String, truncate: Text.TruncationMode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Strim.C.accentText)
            Text(text).font(Strim.F.mono(.caption, weight: .medium)).foregroundStyle(Strim.C.text).lineLimit(1).truncationMode(truncate)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Strim.C.muted)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: 260)
        .capsuleSurface(Strim.C.glass, stroke: Strim.C.hairline)
        .contentShape(Stadium())
    }
}

@MainActor func chooseProject(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    panel.prompt = "Use folder"; panel.message = "Choose the project folder chats work in."
    if panel.runModal() == .OK, let url = panel.url { _ = model.setProject(url.path) }
}

struct ChatTranscriptView: View {
    @ObservedObject var model: AppModel
    @Binding var expanded: Set<UUID>
    var expandAll = false
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.chatMessages) { m in
                        MessageRow(message: m, isOpen: binding(m.id), copy: { model.copyMessage(m.id) })
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            // Instant scroll, no animation: deltas are coalesced upstream (~30 Hz), so this stays smooth.
            .onChange(of: model.chatMessages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.chatMessages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expandAll || expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}

struct ChatComposer: View {
    @ObservedObject var model: AppModel
    @Binding var draft: String
    var body: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft).textFieldStyle(.plain).font(.body)
                .onSubmit(send).disabled(model.chatGenerating).padding(.leading, 6)
            if model.chatGenerating {
                Button { Task { await model.cancelChat() } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Strim.C.coral)
                        .frame(width: 30, height: 30).background(Strim.C.coralFill, in: Circle())
                        .overlay(Circle().strokeBorder(Strim.C.coral.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain).keyboardShortcut(".", modifiers: .command).help("Stop generating (Cmd-.)").accessibilityLabel("Stop generating")
            } else {
                let empty = draft.trimmingCharacters(in: .whitespaces).isEmpty
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Strim.ctaGradient, in: Circle())
                }
                .buttonStyle(.plain).disabled(empty).opacity(empty ? 0.4 : 1).accessibilityLabel("Send")
            }
        }
        .padding(6)
        .capsuleSurface(Strim.C.glassStrong, stroke: Strim.C.hairline)
    }
    private func send() { let t = draft; draft = ""; Task { await model.sendChat(t) } }
}

/// One transcript entry. Tool calls and reasoning are collapsed by default; the last message of a turn carries the
/// token ledger.
struct MessageRow: View {
    let message: ChatMessage
    @Binding var isOpen: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            switch message.role {
            case .user:
                HStack {
                    Spacer(minLength: 80)
                    Text(markdown(message.text)).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(
                            LinearGradient(colors: [Strim.C.indigo.opacity(0.30), Strim.C.violet.opacity(0.26)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous))
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous)
                            .strokeBorder(Strim.C.indigo.opacity(0.4), lineWidth: 1))
                }
            case .assistant:
                HStack(alignment: .top, spacing: 8) {
                    StrimMarkView(size: 22).padding(.top, 2)
                    AssistantBody(text: message.text)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Strim.C.glass, in: UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 16, style: .continuous))
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 16, style: .continuous)
                            .strokeBorder(Strim.C.hairline, lineWidth: 1))
                }
            case .reasoning:
                StrimDisclosure(isOpen: $isOpen) {
                    Label { Text("Reasoning").font(Strim.F.label()).tracking(1).textCase(.uppercase) } icon: { Image(systemName: "brain") }
                        .font(.caption).foregroundStyle(Strim.C.muted)
                } content: {
                    Text(message.text).font(.callout).foregroundStyle(Strim.C.muted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Strim.gradient).frame(width: 2).opacity(0.8) }
                        .padding(.leading, 16)
                }
                .padding(.leading, 30)
            case .tool:
                ToolCardView(card: message.tool ?? ToolCard(name: "tool", args: message.text), isOpen: $isOpen).padding(.leading, 30)
            }
            HStack(spacing: 8) {
                if let l = message.ledger { Text(l.summary).font(Strim.F.mono(.caption2)).foregroundStyle(Strim.C.muted) }
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

struct ToolCardView: View {
    let card: ToolCard
    @Binding var isOpen: Bool
    var body: some View {
        StrimDisclosure(isOpen: $isOpen) {
            HStack(spacing: 8) {
                statusIcon
                Text(card.name).font(Strim.F.mono(.callout, weight: .bold))
                Text(card.args).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted).lineLimit(1).truncationMode(.middle)
                if card.finished { StrimPill(card.isError ? "error" : "done", tone: card.isError ? .error : .accent) }
                else { StrimPill("running", icon: "ellipsis", tone: .neutral) }
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                if !card.args.isEmpty { codeBlock("args  " + card.args, Strim.C.muted) }
                codeBlock(card.result ?? "running...", card.isError ? Strim.C.coral : Strim.C.text)
            }
            .textSelection(.enabled)
        }
        .padding(Strim.S.md)
        .background(Strim.C.glass, in: RoundedRectangle(cornerRadius: Strim.R.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Strim.R.tile, style: .continuous)
            .strokeBorder(card.isError ? Strim.C.coral.opacity(0.45) : Strim.C.hairline, lineWidth: 1))
    }

    private var statusIcon: some View {
        let name = card.finished ? (card.isError ? "xmark" : "checkmark") : "gearshape.2"
        return Image(systemName: name).font(.system(size: 10, weight: .heavy))
            .foregroundStyle(card.finished ? (card.isError ? Strim.C.coral : Strim.C.accentText) : Strim.C.muted)
            .frame(width: 22, height: 22)
            .background(card.isError ? Strim.C.coralFill : Strim.C.indigo.opacity(0.16), in: Circle())
    }

    private func codeBlock(_ text: String, _ color: Color) -> some View {
        Text(text).font(Strim.F.mono(.caption)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            .background(Strim.C.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                Text(language).font(Strim.F.label()).tracking(1).textCase(.uppercase).foregroundStyle(Strim.C.muted)
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
        case .added: Strim.C.indigo
        case .removed: Strim.C.coral
        case .hunk, .header: Strim.C.muted
        case .context: Strim.C.text
        }
    }
    private func fill(_ k: DiffLineKind) -> Color {
        switch k {
        case .added: Strim.C.indigo.opacity(0.14)
        case .removed: Strim.C.coralFill
        default: .clear
        }
    }
}
