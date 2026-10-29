import SwiftUI
import AppKit
import StrimAppCore

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let orb = OrbState(model.connection)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StrimOrb(orb, size: 46).padding(4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.menuTitle).font(.headline).foregroundStyle(Strim.C.text)
                    if let s = model.status, orb.isLive {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.1f", s.decodeTPS)).font(.system(.title2, design: .rounded, weight: .bold).monospacedDigit()).gradientFill()
                            Text("tok/s").font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
                        }.fixedSize()
                    } else {
                        Text(orb.word).font(Strim.F.mono(.caption)).foregroundStyle(Strim.C.muted)
                    }
                }
                Spacer()
            }
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
        .padding(16)
        .frame(width: 360)
        .background(StrimBackground())
        .foregroundStyle(Strim.C.text)
    }
}
