import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

/// Grouped glass sections. The control token file path is masked until revealed; the token itself is never read here.
struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var draft = AppSettings()
    @State private var revealToken = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Strim.S.lg) {
              HStack(alignment: .top, spacing: Strim.S.lg) {
                VStack(alignment: .leading, spacing: Strim.S.lg) {
                ModelPickerSection(model: model, draft: $draft)
                PackSection(model: model)
                }.frame(maxWidth: .infinity, alignment: .top)
                VStack(alignment: .leading, spacing: Strim.S.lg) {
                SettingsGroup("Connection", icon: "network") {
                    SettingsField("Host URL", text: $draft.hostURL, prompt: "http://127.0.0.1:8765")
                    HStack(spacing: 6) {
                        SectionLabel("Port")
                        StrimPill(Self.port(draft.hostURL), icon: "number")
                        Text("loopback only").font(Strim.F.mono(.caption2)).foregroundStyle(Strim.C.muted)
                    }
                    if let p = draft.hostURLProblem { Label(p, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Strim.C.coral) }
                }
                SettingsGroup("Server", icon: "power") {
                    Toggle("Start server when Strim opens", isOn: $draft.startServerWhenOpens)
                        .toggleStyle(StrimToggleStyle())
                    Text("The server starts after the model is available.").font(.caption).foregroundStyle(Strim.C.muted)
                }
                ProjectPickerSection(model: model, draft: $draft)
                SettingsGroup("Paths and tokens", icon: "key") {
                    SettingsField("strim binary", text: Binding(get: { draft.strimBinary ?? "" }, set: { draft.strimBinary = $0.isEmpty ? nil : $0 }),
                                  prompt: "auto: ~/.strim/bin, /opt/homebrew/bin, /usr/local/bin")
                    VStack(alignment: .leading, spacing: 5) {
                        SectionLabel("Control token file")
                        HStack {
                            Text(revealToken ? draft.controlTokenPath : Self.mask(draft.controlTokenPath))
                                .font(Strim.F.mono(.callout)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Button { revealToken.toggle() } label: {
                                Image(systemName: revealToken ? "eye.slash" : "eye").frame(width: 24, height: 20)
                            }
                            .buttonStyle(.plain).foregroundStyle(Strim.C.accentText)
                            .help(revealToken ? "Hide path" : "Show path").accessibilityLabel(revealToken ? "Hide token path" : "Show token path")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Strim.C.field, in: RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous))
                        Text("Read-only. The MCP token is never used by this app.").font(.caption).foregroundStyle(Strim.C.muted)
                    }
                }
                }.frame(maxWidth: .infinity, alignment: .top)
              }
                HStack(spacing: 8) {
                    Button("Save") { model.update(settings: draft) }.buttonStyle(StrimButtonStyle(.primary)).disabled(draft == model.settings)
                    Button("Revert") { draft = model.settings }.buttonStyle(StrimButtonStyle(.secondary)).disabled(draft == model.settings)
                    Text("stored in ~/.strim/app.json").font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
                }
            }
            .padding(Strim.S.xl)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { draft = model.settings }
        .onChange(of: model.settings) { _, new in draft = new }
    }

    static func port(_ url: String) -> String { URL(string: url)?.port.map(String.init) ?? "?" }
    static func mask(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let dir = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        return dir + "/" + String(repeating: "•", count: max(6, min(name.count, 14)))
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String, icon: String
    @ViewBuilder var content: () -> Content
    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.icon = icon; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: Strim.S.md) {
            Label { SectionLabel(title) } icon: { Image(systemName: icon).foregroundStyle(Strim.C.accentText) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct SettingsField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    init(_ label: String, text: Binding<String>, prompt: String = "") { self.label = label; _text = text; self.prompt = prompt }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(Strim.C.muted)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Strim.C.muted.opacity(0.8)))
                .textFieldStyle(.plain).font(Strim.F.mono(.callout)).autocorrectionDisabled()
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Strim.C.field, in: RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
        }
    }
}

/// A menu styled as a field (label, current value, chevron).
struct MenuField<Items: View>: View {
    let label: String, value: String
    @ViewBuilder var items: () -> Items
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(Strim.C.muted)
            Menu(content: items) {
                HStack {
                    Text(value).font(Strim.F.mono(.callout)).lineLimit(1).truncationMode(.middle).foregroundStyle(Strim.C.text)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Strim.C.muted)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Strim.C.field, in: RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous).strokeBorder(Strim.C.hairline, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
    }
}

/// Picking a model only records the choice; the host loads it on the explicit Start action (Status tab).
struct ModelPickerSection: View {
    @ObservedObject var model: AppModel
    @Binding var draft: AppSettings
    var body: some View {
        let models = model.availableModels.filter { $0.kind == "model" }
        let mtps = model.availableModels.filter { $0.kind == "mtp" }
        SettingsGroup("Model", icon: "cpu") {
            HStack(alignment: .bottom, spacing: 8) {
                MenuField(label: "Local models", value: Self.name(model.settings.modelPath, models: models, none: "Choose a model")) {
                    ForEach(models) { m in
                        Button(m.name + (m.sizeGB.map { String(format: " (%.1f GB)", $0) } ?? "")) { model.selectModel(m) }
                    }
                }
                Button { Task { await model.refreshModels() } } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 20) }
                    .buttonStyle(StrimButtonStyle(.secondary)).help("Rescan models").accessibilityLabel("Rescan models")
            }
            MenuField(label: "MTP head", value: Self.name(model.settings.mtpPath, models: mtps, none: "None")) {
                ForEach(mtps) { m in Button(m.name) { model.selectModel(m) } }
            }
            SettingsField("Model path", text: Binding(get: { draft.modelPath ?? "" }, set: { draft.modelPath = $0.isEmpty ? nil : $0 }))
            SettingsField("MTP head path", text: Binding(get: { draft.mtpPath ?? "" }, set: { draft.mtpPath = $0.isEmpty ? nil : $0 }))
            if let n = model.modelSelectionNote { Text(n).font(.caption).foregroundStyle(Strim.C.muted) }
            if let n = model.modelListNote { Text(n).font(.caption).foregroundStyle(Strim.C.muted) }
            HStack {
                let load = model.loadAvailability
                Button { Task { await model.loadModel() } } label: { Label("Start with selected model", systemImage: "play.fill") }
                    .buttonStyle(StrimButtonStyle(.primary)).disabled(!load.enabled).help(load.reason ?? "")
                if let r = load.reason { Text(r).font(.caption).foregroundStyle(Strim.C.muted) }
            }
        }
        .task { await model.refreshModels() }
    }
    static func name(_ path: String?, models: [LocalModel], none: String) -> String {
        guard let path, !path.isEmpty else { return none }
        return models.first(where: { $0.path == path })?.name ?? (path as NSString).lastPathComponent
    }
}

struct ProjectPickerSection: View {
    @ObservedObject var model: AppModel
    @Binding var draft: AppSettings
    var body: some View {
        SettingsGroup("Project folder (chat)", icon: "folder") {
            HStack(spacing: 8) {
                Text(model.settings.projectPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None chosen")
                    .font(Strim.F.mono(.callout))
                    .foregroundStyle(model.settings.projectPath == nil ? Strim.C.muted : Strim.C.text)
                    .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Strim.C.field, in: RoundedRectangle(cornerRadius: Strim.R.control, style: .continuous))
                Button("Choose...") { chooseProject(model) }.buttonStyle(StrimButtonStyle(.secondary))
                Menu {
                    let recents = model.validRecentProjects
                    if recents.isEmpty { Text("No recent projects") }
                    ForEach(recents, id: \.self) { p in
                        Button((p as NSString).abbreviatingWithTildeInPath) { _ = model.setProject(p) }
                    }
                } label: { Text("Recent") }.menuStyle(.button).buttonStyle(StrimButtonStyle(.secondary)).menuIndicator(.visible).fixedSize()
            }
            Text("Never your home folder. Changing it starts a new chat.").font(.caption).foregroundStyle(Strim.C.muted)
        }
    }
}

/// Read-only: the adopted pack fingerprint and the newest `strim evolve` record from `~/.strim/packs`.
struct PackSection: View {
    @ObservedObject var model: AppModel
    var body: some View {
        SettingsGroup("About", icon: "info.circle") {
            if let p = model.packInfo {
                row("Active pack", p.activeFingerprint ?? "none (built-in defaults)")
                row("Packs on disk", "\(p.packCount)")
                if let e = p.lastEvolve {
                    row("Last evolve", e.createdAt + (e.dryRun ? " (dry run)" : ""))
                    row("Candidate", e.fingerprint)
                    if let g = e.valGainPP { row("Validation gain", String(format: "%+.1f pp", g)) }
                    if let r = e.round { row("Round", "\(r)") }
                } else {
                    Text("No evolve run recorded yet.").font(.caption).foregroundStyle(Strim.C.muted)
                }
            } else {
                Text(model.connection.isConnected ? "Pack info is not available from this host." : "Engine offline.")
                    .font(.caption).foregroundStyle(Strim.C.muted)
            }
            Button("Refresh") { Task { await model.refreshPack() } }.buttonStyle(StrimButtonStyle(.secondary)).disabled(!model.connection.isConnected)
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.callout).foregroundStyle(Strim.C.muted)
            Spacer()
            Text(v).font(Strim.F.mono(.callout, weight: .medium)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }
}
