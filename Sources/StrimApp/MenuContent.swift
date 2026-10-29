import SwiftUI
import AppKit
import StrimAppCore

/// Compact native popover: status row, key metrics, actions. `.regularMaterial` is used only here.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let orb = OrbState(model.connection)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StrimOrb(orb, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.menuTitle).font(.headline).foregroundStyle(Strim.C.text)
                    if let s = model.status, orb.isLive {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.1f", s.decodeTPS)).font(Strim.F.mono(.title3, weight: .semibold)).foregroundStyle(Strim.C.accent)
                            Text("tok/s").font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
                        }.fixedSize()
                    } else if orb != .offline {
                        Text(orb.word).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
                    }
                }
                Spacer()
            }
            ModelDownloadCard(model: model, compact: true)
            OfflineBannerView(model: model)
            TokenWarningView(model: model)
            NoticeView(model: model)
            StatsView(model: model).font(.callout)
            if model.connection.isConnected {
                ControlButtons(model: model)
            }
            if model.connection.isConnected, let e = model.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Strim.C.coral).lineLimit(3)
            }
            Rectangle().fill(Strim.C.hairline).frame(height: 1)
            Button("Copy MCP registration commands") { Task { await model.copyMCPCommands() } }
                .buttonStyle(.plain).font(.callout).foregroundStyle(Strim.C.accentText)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(StrimToggleStyle())
            HStack {
                Button("Open Window") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }.buttonStyle(StrimButtonStyle(.primary))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q").buttonStyle(StrimButtonStyle(.secondary))
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial)
        .foregroundStyle(Strim.C.text)
    }
}
