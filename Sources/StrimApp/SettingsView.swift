import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var draft = AppSettings()
    var body: some View {
        Form {
            TextField("Host URL", text: $draft.hostURL)
            TextField("strim binary", text: Binding(get: { draft.strimBinary ?? "" }, set: { draft.strimBinary = $0.isEmpty ? nil : $0 }),
                      prompt: Text("absolute path; auto: ~/.strim/bin, /opt/homebrew/bin, /usr/local/bin"))
            ModelPickerSection(model: model, draft: $draft)
            ProjectPickerSection(model: model, draft: $draft)
            LabeledContent("Control token file", value: draft.controlTokenPath)
            HStack {
                Button("Save") { model.update(settings: draft) }.disabled(draft == model.settings)
                Button("Revert") { draft = model.settings }.disabled(draft == model.settings)
                Text("Stored in ~/.strim/app.json").font(.caption).foregroundStyle(.secondary)
            }
            PackSection(model: model)
        }
        .padding()
        .onAppear { draft = model.settings }
        .onChange(of: model.settings) { _, new in draft = new }
    }
}

/// Picking a model only records the choice; the host loads it on the explicit Load action (Status tab).
struct ModelPickerSection: View {
    @ObservedObject var model: AppModel
    @Binding var draft: AppSettings
    var body: some View {
        Section("Model") {
            HStack {
                Picker("Local models", selection: Binding(get: { model.settings.modelPath ?? "" },
                                                           set: { path in if let m = model.availableModels.first(where: { $0.path == path }) { model.selectModel(m) } })) {
                    Text("Choose a model").tag("")
                    ForEach(model.availableModels.filter { $0.kind == "model" }) { m in
                        Text(m.name + (m.sizeGB.map { String(format: " (%.1f GB)", $0) } ?? "")).tag(m.path)
                    }
                    if let p = model.settings.modelPath, !model.availableModels.contains(where: { $0.path == p }) {
                        Text((p as NSString).lastPathComponent).tag(p)
                    }
                }
                Button { Task { await model.refreshModels() } } label: { Image(systemName: "arrow.clockwise") }.help("Rescan models")
            }
            Picker("MTP head", selection: Binding(get: { model.settings.mtpPath ?? "" },
                                                  set: { path in if let m = model.availableModels.first(where: { $0.path == path }) { model.selectModel(m) } })) {
                Text("None").tag("")
                ForEach(model.availableModels.filter { $0.kind == "mtp" }) { m in Text(m.name).tag(m.path) }
            }
            TextField("Model path", text: Binding(get: { draft.modelPath ?? "" }, set: { draft.modelPath = $0.isEmpty ? nil : $0 }))
            TextField("MTP head path", text: Binding(get: { draft.mtpPath ?? "" }, set: { draft.mtpPath = $0.isEmpty ? nil : $0 }))
            if let n = model.modelSelectionNote { Text(n).font(.caption).foregroundStyle(.secondary) }
            if let n = model.modelListNote { Text(n).font(.caption).foregroundStyle(.secondary) }
            HStack {
                let load = model.loadAvailability
                Button("Load selected model") { Task { await model.loadModel() } }.disabled(!load.enabled).help(load.reason ?? "")
                if let r = load.reason { Text(r).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task { await model.refreshModels() }
    }
}

struct ProjectPickerSection: View {
    @ObservedObject var model: AppModel
    @Binding var draft: AppSettings
    var body: some View {
        Section("Project folder (chat)") {
            HStack {
                Text(model.settings.projectPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None chosen")
                    .foregroundStyle(model.settings.projectPath == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                Spacer()
                Button("Choose...") { choose() }
                Menu("Recent") {
                    let recents = model.validRecentProjects
                    if recents.isEmpty { Text("No recent projects") }
                    ForEach(recents, id: \.self) { p in
                        Button((p as NSString).abbreviatingWithTildeInPath) { model.setProject(p) }
                    }
                }.fixedSize()
            }
            Text("Never your home folder. Changing it starts a new chat.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"; panel.message = "Choose the project folder chats work in."
        if panel.runModal() == .OK, let url = panel.url { model.setProject(url.path) }
    }
}

/// Read-only: the adopted pack fingerprint and the newest `strim evolve` record from `~/.strim/packs`.
struct PackSection: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Section("About") {
            if let p = model.packInfo {
                LabeledContent("Active pack", value: p.activeFingerprint ?? "none (built-in defaults)").textSelection(.enabled)
                LabeledContent("Packs on disk", value: "\(p.packCount)")
                if let e = p.lastEvolve {
                    LabeledContent("Last evolve", value: e.createdAt + (e.dryRun ? " (dry run)" : ""))
                    LabeledContent("Candidate", value: e.fingerprint).textSelection(.enabled)
                    if let g = e.valGainPP { LabeledContent("Validation gain", value: String(format: "%+.1f pp", g)) }
                    if let r = e.round { LabeledContent("Round", value: "\(r)") }
                } else {
                    Text("No evolve run recorded yet.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(model.connection.isConnected ? "Pack info is not available from this host." : "Host offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Refresh") { Task { await model.refreshPack() } }.disabled(!model.connection.isConnected)
        }
    }
}
