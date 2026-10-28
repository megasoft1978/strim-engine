import SwiftUI
import StrimAPI
import StrimAppCore

struct ChatTab: View {
    @ObservedObject var model: AppModel
    /// Screenshots only: show every tool card and reasoning block open.
    var expandAll = false
    @State private var draft = ""
    @State private var expanded = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.chat {
            case .unknown:
                Text("Chat has not been opened.").foregroundStyle(.secondary)
                Button("Open chat session") { Task { await model.probeChat() } }
                    .disabled(!model.connection.isConnected)
            case .unavailable(let why):
                Label(why, systemImage: "bubble.left.and.exclamationmark.bubble.right").foregroundStyle(.secondary)
                Button("Retry") { Task { await model.probeChat() } }
            case .ready(let s):
                ChatHeader(model: model, cwd: s.cwd)
                ChatTranscriptView(model: model, expanded: $expanded, expandAll: expandAll)
                ChatComposer(model: model, draft: $draft)
            }
            if case .unknown = model.chat {} else { Spacer(minLength: 0) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { if model.chat == .unknown, model.connection.isConnected { await model.probeChat() } }
    }
}

struct ChatHeader: View {
    @ObservedObject var model: AppModel
    let cwd: String
    var body: some View {
        HStack {
            Label((cwd as NSString).abbreviatingWithTildeInPath, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
            Spacer()
            Toggle("Thinking", isOn: $model.thinkingEnabled).toggleStyle(.switch).controlSize(.small)
                .help("Let the model reason before answering. Applies to the next message.")
        }
    }
}

struct ChatTranscriptView: View {
    @ObservedObject var model: AppModel
    @Binding var expanded: Set<UUID>
    var expandAll = false
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.chatMessages) { m in
                        MessageRow(message: m, isOpen: binding(m.id), copy: { model.copyMessage(m.id) })
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack {
            TextField("Message", text: $draft).onSubmit(send).disabled(model.chatGenerating)
            if model.chatGenerating {
                Button { Task { await model.cancelChat() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .tint(.red).keyboardShortcut(".", modifiers: .command).help("Stop generating (Cmd-.)")
            } else {
                Button("Send", action: send).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
    private func send() { let t = draft; draft = ""; Task { await model.sendChat(t) } }
}

/// One transcript entry. Tool calls and reasoning are collapsed disclosure groups; the last message of a turn carries
/// the token ledger.
struct MessageRow: View {
    let message: ChatMessage
    @Binding var isOpen: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch message.role {
            case .user:
                HStack {
                    Spacer(minLength: 40)
                    Text(message.text).textSelection(.enabled).padding(8)
                        .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
            case .assistant:
                Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            case .reasoning:
                DisclosureGroup(isExpanded: $isOpen) {
                    Text(message.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
                } label: {
                    Label("Reasoning", systemImage: "brain").font(.callout).foregroundStyle(.secondary)
                }
            case .tool:
                ToolCardView(card: message.tool ?? ToolCard(name: "tool", args: message.text), isOpen: $isOpen)
            }
            HStack(spacing: 8) {
                if let l = message.ledger { Text(l.summary).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
                Spacer()
                if message.role != .user {
                    Button(action: copy) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain)
                        .foregroundStyle(.secondary).help("Copy message")
                }
            }
        }
    }
}

struct ToolCardView: View {
    let card: ToolCard
    @Binding var isOpen: Bool
    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            VStack(alignment: .leading, spacing: 4) {
                if !card.args.isEmpty { Text("args: " + card.args).font(.system(.caption, design: .monospaced)) }
                Text(card.result ?? "running...").font(.system(.caption, design: .monospaced))
                    .foregroundStyle(card.isError ? Color.red : Color.primary)
            }
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: card.finished ? (card.isError ? "xmark.octagon.fill" : "checkmark.circle.fill") : "gearshape.2")
                    .foregroundStyle(card.finished ? (card.isError ? Color.red : Color.green) : Color.secondary)
                Text(card.name).font(.callout.bold())
                Text(card.args).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(8)
        .background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
