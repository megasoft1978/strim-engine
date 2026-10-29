import SwiftUI
import AppKit
import StrimAppCore

@main
struct StrimMenuApp: App {
    @NSApplicationDelegateAdaptor(QuitHandler.self) private var quitHandler
    @StateObject private var model: AppModel

    init() {
        if let dir = SnapshotMode.directory {
            // Snapshots keep the in-memory chat store: they must never write ~/.strim.
            _model = StateObject(wrappedValue: AppModel(makeClient: { s in HTTPControlClient.make(settings: s) }))
            Task { @MainActor in await SnapshotMode.run(into: dir) }
            return
        }
        let m = AppModel(makeClient: { s in HTTPControlClient.make(settings: s) }, chatStore: FileChatStore())
        _model = StateObject(wrappedValue: m)
        QuitHandler.model = m
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
                .frame(minWidth: 640, minHeight: 460)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1040, height: 700)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Template glyph alone; the decode speed joins it only while generating (General setting "Show speed in menu bar").
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarGlyph.image(badge: MenuBarGlyph.badge(for: model.connection)))
            if model.settings.showSpeedInMenuBar, OrbState(model.connection) == .busy, let s = model.status {
                Text("\(Int(s.decodeTPS.rounded())) tok/s").monospacedDigit()
            }
        }
        .accessibilityLabel(model.menuTitle.replacingOccurrences(of: "busy", with: "generating"))
        .task {
            if model.testMode {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// On quit: ends open chat sessions and stops the server this app started (best effort, at most 4 s).
final class QuitHandler: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { g in
                g.addTask { await model.stopOwnedServerOnQuit() }
                g.addTask { try? await Task.sleep(for: .seconds(4)) }
                _ = await g.next()
                g.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
