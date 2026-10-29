import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, model, server, chat, about
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .model: "cpu"
        case .server: "network"
        case .chat: "bubble.left"
        case .about: "info.circle"
        }
    }
}

/// Separate Settings scene (⌘,). Grouped forms; every change applies immediately.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State var pane: SettingsPane = .general

    var body: some View {
        TabView(selection: $pane) {
            ForEach(SettingsPane.allCases) { p in
                Group {
                    switch p {
                    case .general: GeneralPane(model: model)
                    case .model: ModelPane(model: model)
                    case .server: ServerPane(model: model)
                    case .chat: ChatPane(model: model)
                    case .about: AboutPane(model: model)
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label(p.title, systemImage: p.icon) }
                .tag(p)
            }
        }
        .frame(width: 520)
        .frame(minHeight: 340)
        .tint(Strim.C.accent)
        .task { await model.refreshModels(); await model.refreshPack() }
    }
}

private func binding<T>(_ model: AppModel, _ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(get: { model.settings[keyPath: kp] }, set: { v in var s = model.settings; s[keyPath: kp] = v; model.update(settings: s) })
}

struct GeneralPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Toggle("Start server when Strim opens", isOn: binding(model, \.startServerWhenOpens))
            Toggle("Show speed in menu bar", isOn: binding(model, \.showSpeedInMenuBar))
        }
    }
}

struct ModelPane: View {
    @ObservedObject var model: AppModel
    private var models: [LocalModel] { model.availableModels.filter { $0.kind == "model" } }
    private var mtps: [LocalModel] { model.availableModels.filter { $0.kind == "mtp" } }

    /// The explicit choice, else the loaded model matched by name, else the only model on disk.
    private var effectiveModelPath: String? {
        if let p = model.settings.modelPath, !p.isEmpty { return p }
        if let n = model.status?.model, let m = models.first(where: { $0.name == n }) { return m.path }
        return models.count == 1 ? models[0].path : nil
    }
    private var effectiveMTPPath: String? {
        if let p = model.settings.mtpPath, !p.isEmpty { return p }
        if let n = model.status?.mtp, let m = mtps.first(where: { $0.name == n }) { return m.path }
        return mtps.count == 1 ? mtps[0].path : nil
    }

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: Binding<String?>(get: { effectiveModelPath }, set: { p in
                    if let m = models.first(where: { $0.path == p }) { model.selectModel(m) }
                })) {
                    if effectiveModelPath == nil { Text("Choose a model").tag(String?.none) }
                    ForEach(models) { m in Text(m.name + (m.sizeGB.map { String(format: " (%.1f GB)", $0) } ?? "")).tag(Optional(m.path)) }
                    if let p = effectiveModelPath, !models.contains(where: { $0.path == p }) { Text((p as NSString).lastPathComponent).tag(Optional(p)) }
                }
                Picker("MTP head", selection: Binding<String?>(get: { effectiveMTPPath }, set: { p in
                    if let m = mtps.first(where: { $0.path == p }) { model.selectModel(m) }
                })) {
                    Text("None").tag(String?.none)
                    ForEach(mtps) { m in Text(m.name).tag(Optional(m.path)) }
                    if let p = effectiveMTPPath, !mtps.contains(where: { $0.path == p }) { Text((p as NSString).lastPathComponent).tag(Optional(p)) }
                }
            }
            Section("Paths") {
                pathRow("Model", effectiveModelPath) { choose { p in var s = model.settings; s.modelPath = p; model.update(settings: s) } }
                pathRow("MTP head", effectiveMTPPath) { choose { p in var s = model.settings; s.mtpPath = p; model.update(settings: s) } }
            }
            Section {
                HStack {
                    let load = model.loadAvailability
                    Button("Start with selected model") { Task { await model.loadModel() } }.disabled(!load.enabled)
                    Button("Refresh") { Task { await model.refreshModels() } }
                    Spacer()
                    if let r = load.reason { Text(r).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                if let n = model.modelListNote { Text(n).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
    }

    private func pathRow(_ label: String, _ path: String?, choose: @escaping () -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not set")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                Button("Choose…", action: choose)
            }
        }
    }
    private func choose(_ apply: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.strim/models")
        if panel.runModal() == .OK, let url = panel.url { apply(url.path) }
    }
}

struct ServerPane: View {
    @ObservedObject var model: AppModel
    @State private var portText = ""
    @State private var reveal = false
    var body: some View {
        Form {
            Section {
                LabeledContent("Host URL") { Text(model.settings.hostURL).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                LabeledContent("Port") {
                    TextField("", text: $portText).multilineTextAlignment(.trailing).frame(width: 80)
                        .font(.system(size: 12, design: .monospaced)).onSubmit(applyPort)
                }
                if let p = model.settings.hostURLProblem {
                    Label(p, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Strim.C.danger)
                }
                Toggle("Loopback only (127.0.0.1)", isOn: .constant(true)).disabled(true)
            }
            Section("Control token") {
                LabeledContent("File") {
                    HStack {
                        Text(reveal ? model.settings.controlTokenPath : Self.mask(model.settings.controlTokenPath))
                            .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless).help(reveal ? "Hide path" : "Show path").accessibilityLabel(reveal ? "Hide token path" : "Show token path")
                    }
                }
                Text("Read-only. The MCP token is never used by this app.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Advanced") {
                LabeledContent("Strim binary") {
                    TextField("Strim binary", text: Binding(get: { model.settings.strimBinary ?? "" }, set: { v in
                        var s = model.settings; s.strimBinary = v.isEmpty ? nil : v; model.update(settings: s) }),
                        prompt: Text("auto: ~/.strim/bin, /opt/homebrew/bin"))
                        .labelsHidden().font(.system(size: 12, design: .monospaced)).multilineTextAlignment(.trailing)
                }
            }
        }
        .onAppear { portText = Self.port(model.settings.hostURL) }
    }
    private func applyPort() {
        guard let n = Int(portText), (1...65535).contains(n), var c = URLComponents(string: model.settings.hostURL) else { portText = Self.port(model.settings.hostURL); return }
        c.port = n
        var s = model.settings; s.hostURL = c.string ?? s.hostURL; model.update(settings: s)
    }
    static func port(_ url: String) -> String { URL(string: url)?.port.map(String.init) ?? "" }
    static func mask(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let dir = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        return dir + "/" + String(repeating: "•", count: max(6, min(name.count, 14)))
    }
}

struct ChatPane: View {
    @ObservedObject var model: AppModel
    @State private var confirmDelete = false
    var body: some View {
        Form {
            Section {
                Toggle("Default thinking", isOn: $model.thinkingEnabled)
                Text("Applies to new chats. A chat keeps the setting it started with.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Scratch chats") {
                LabeledContent("Folder") {
                    HStack {
                        Text(PathDisplay.tilde(AppModel.scratchDefault)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Reveal") { Finder.reveal(AppModel.scratchDefault) }
                    }
                }
                Text("Chats without a project work in their own folder here.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Folder access") {
                if model.grantedFolders.isEmpty {
                    Text("Only your home folder. Opening a project elsewhere asks first.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(model.grantedFolders, id: \.self) { f in
                    HStack {
                        Image(systemName: "lock.open").foregroundStyle(.secondary).font(.system(size: 11))
                        Text(PathDisplay.tilde(f)).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button("Revoke") { Task { await model.revokeFolder(f) } }
                    }
                }
                if !model.grantedFolders.isEmpty {
                    Text("Strim can read, change files and run commands in these folders, working in an isolated copy. Every change comes back as a patch you review.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("History") {
                Button("Delete all chat history…", role: .destructive) { confirmDelete = true }
                    .disabled(model.projects.isEmpty && model.threads.isEmpty)
            }
        }
        .confirmationDialog("Delete all chat history?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete All Chats", role: .destructive) { Task { await model.deleteAllChatHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Removes every chat and project from this list and ends open chat sessions. Your folders are not touched.") }
    }
}

struct AboutPane: View {
    @ObservedObject var model: AppModel
    private var version: String {
        let i = Bundle.main.infoDictionary
        return (i?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
    private var build: String { (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "–" }
    var body: some View {
        Form {
            Section {
                row("Version", version); row("Build", build)
            }
            Section {
                Text("Chats stay on this Mac in ~/.strim/chats and go only to your local Strim host.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Pack") {
                if let p = model.packInfo {
                    row("Active pack", p.activeFingerprint.map { String($0.prefix(8)) } ?? "built-in defaults")
                    row("Packs on disk", "\(p.packCount)")
                    if let e = p.lastEvolve {
                        row("Last evolve", Self.evolveDate(e.createdAt) + (e.dryRun ? " (dry run)" : ""))
                        if let g = e.valGainPP { row("Validation gain", String(format: "%+.1f pp", g)) }
                    } else { Text("No evolve run recorded yet.").font(.system(size: 11)).foregroundStyle(.secondary) }
                } else {
                    Text(model.connection.isConnected ? "Pack info is not available from this server." : "Server offline.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let s = model.status {
                Section("Fingerprint") {
                    row("Weights hash", StatusView.shortHash(s.quantFingerprint, 0))
                    row("MTP hash", StatusView.shortHash(s.quantFingerprint, 1))
                }
            }
        }
    }
    static func evolveDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) ?? { f.formatOptions.insert(.withFractionalSeconds); return f.date(from: iso) }() else { return iso }
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened))
    }
    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
    }
}
