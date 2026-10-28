import SwiftUI
import StrimAppCore

@main
struct StrimMenuApp: App {
    @StateObject private var model: AppModel

    init() {
        if let dir = SnapshotMode.directory {
            _model = StateObject(wrappedValue: AppModel(makeClient: { s in HTTPControlClient.make(settings: s) }))
            Task { @MainActor in await SnapshotMode.run(into: dir) }
            return
        }
        let m = AppModel(makeClient: { s in HTTPControlClient.make(settings: s) })
        _model = StateObject(wrappedValue: m)
        m.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Strim", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 720, minHeight: 520)
        }
    }
}

/// Always shows an SF Symbol plus short text so the item can never silently disappear.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Label(model.menuTitle, systemImage: model.menuSymbol)
            .labelStyle(.titleAndIcon)
            .task {
                if model.testMode {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
