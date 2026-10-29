import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

/// Menu-bar popover, 320 pt wide: header, model + memory, three numbers, endpoint, server action, menu rows.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).frame(height: 36)
            if model.modelDownloadState.isBlockingFirstRun {
                setupSection
            } else if let s = model.status, s.state != .stopped, s.state != .error {
                Divider()
                modelSection(s).padding(.horizontal, 14).padding(.vertical, 12)
                Divider()
                metrics(s).padding(.horizontal, 14).padding(.vertical, 12)
                Divider()
                endpoint.padding(.horizontal, 14).padding(.vertical, 10)
            } else if let e = model.status?.lastCrash ?? model.lastError, OrbState(model.connection) == .error {
                Divider()
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Strim.C.danger)
                    .lineLimit(3).padding(.horizontal, 14).padding(.vertical, 12)
            }
            Divider()
            if !model.modelDownloadState.isBlockingFirstRun {
                HStack(spacing: 8) {
                    ServerToggleButton(model: model, fullWidth: true)
                    if model.showsPauseInPopover {
                        Button { Task { await model.togglePause() } } label: { Text(model.pauseButtonTitle).frame(maxWidth: .infinity) }
                            .buttonStyle(StrimButtonStyle(.secondary))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                Divider()
            }
            VStack(spacing: 0) {
                MenuRow(title: MenuCommand.openMain.title, shortcut: MenuCommand.openMain.shortcut) { run(.openMain) }.keyboardShortcut("o")
                MenuRow(title: MenuCommand.settings.title, shortcut: MenuCommand.settings.shortcut) { run(.settings) }.keyboardShortcut(",")
                MenuRow(title: MenuCommand.quit.title, shortcut: MenuCommand.quit.shortcut) { run(.quit) }.keyboardShortcut("q")
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
        }
        .frame(width: 320)
        .background(Strim.C.bg)
        .foregroundStyle(Strim.C.text)
        .animation(.easeOut(duration: 0.18), value: model.modelDownloadState)
    }

    private func run(_ command: MenuCommand) {
        switch command.route {
        case .openWindow(let id): openWindow(id: id); NSApp.activate()
        case .openSettings: NSApp.activate(); openSettings()
        case .terminate: NSApp.terminate(nil)
        }
    }

    private var stateWord: String {
        switch model.modelDownloadState {
        case .downloading(let p): return "Downloading \(Int(p.fraction * 100))%"
        case .verifying: return "Verifying"
        case .startingServer: return "Starting"
        case .needsDownload(_, _, let r): return r ? "Download paused" : "Model needed"
        case .confirming: return "Model needed"
        case .failed: return "Download stopped"
        default: return OrbState(model.connection).word
        }
    }

    private var header: some View {
        let orb = OrbState(model.connection)
        return HStack(spacing: 8) {
            Image(nsImage: MenuBarGlyph.image(points: 20)).renderingMode(.template).foregroundStyle(Strim.C.text)
            Text("Strim").font(.system(size: 13, weight: .semibold))
            Text(stateWord).font(.system(size: 12)).foregroundStyle(Strim.C.muted).lineLimit(1)
            Spacer(minLength: 4)
            if orb == .busy, let s = model.status {
                Text(String(format: "%.1f tok/s", s.decodeTPS)).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Strim.C.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func modelSection(_ s: HostStatus) -> some View {
        let m = s.memory
        let total = m.weightsGB + m.prefixTrieGB + m.mlxCacheGB + m.headroomGB
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.modelLabel.replacingOccurrences(of: " + MTP", with: " · MTP")).font(.system(size: 12)).lineLimit(1)
                Spacer()
                Text("\(String(format: "%.1f", total - m.headroomGB)) of \(StatsFormat.gb(total))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Strim.C.muted)
            }
            MemoryBar(memory: m, height: 4, showLegend: false)
        }
    }

    private func metrics(_ s: HostStatus) -> some View {
        HStack(alignment: .top, spacing: 0) {
            metric("Active / queued", "\(s.activeJobs) / \(s.queuedJobs)")
            metric("MTP", StatsFormat.percent(s.mtpAcceptance))
            metric("Uptime", StatsFormat.duration(s.uptimeSeconds))
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(.system(size: 11)).foregroundStyle(Strim.C.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var endpoint: some View { EndpointRow(url: model.endpointURL, copy: { model.copyText($0) }) }

    /// First-run: progress row (when downloading) and a hint; all actions live in the window.
    @ViewBuilder private var setupSection: some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            switch model.modelDownloadState {
            case .downloading(let p):
                StrimProgressBar(value: p.fraction)
                let left = p.etaSec.map { " · \(FirstRunView.eta($0)) left" } ?? ""
                Text("\(String(format: "%.1f", Double(p.doneBytes) / 1e9)) of \(ModelDisk.gb(p.totalBytes))\(left)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Strim.C.muted)
            case .verifying, .startingServer:
                StrimProgressBar(value: nil)
            case .failed(let m, _):
                Text(m).font(.system(size: 12)).foregroundStyle(Strim.C.muted).lineLimit(3)
            default:
                Text("Download the \(ModelDisk.gb(ModelDownloader.modelBytes)) model to start the server.")
                    .font(.system(size: 12)).foregroundStyle(Strim.C.muted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        Divider().padding(.bottom, 0)
    }
}

struct EndpointRow: View {
    let url: String
    let copy: (String) -> Void
    @State private var copied = false
    var body: some View {
        HStack(spacing: 6) {
            Text(url).font(.system(size: 12, design: .monospaced)).foregroundStyle(Strim.C.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                copy(url)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(copied ? Strim.C.text : Strim.C.muted)
            }
            .buttonStyle(.borderless).help("Copy endpoint").accessibilityLabel("Copy endpoint")
        }
    }
}

/// 24 pt menu-style row with hover highlight.
struct MenuRow: View {
    let title: String
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 12)).foregroundStyle(Strim.C.tertiary) }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(hover ? Strim.C.surface2 : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
