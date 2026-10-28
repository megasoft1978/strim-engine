import SwiftUI
import AppKit
import StrimAppCore

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.menuTitle, systemImage: model.menuSymbol).font(.headline)
            OfflineBannerView(model: model)
            TokenWarningView(model: model)
            NoticeView(model: model)
            StatsView(model: model)
            if model.connection.isConnected {
                ControlButtons(model: model)
            }
            if let e = model.lastError {
                Text("Error: \(e)").font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Divider()
            Button("Copy MCP registration commands") { Task { await model.copyMCPCommands() } }
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            HStack {
                Button("Open Window") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}
