import SwiftUI
import AppKit
import StrimAppCore

@main
enum StrimEntry {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--selftest") {
            exit(await SelfTest.run())
        }
        StrimMenuApp.main()
    }
}

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
        let coordinator = LifecycleCoordinator(target: m, expectedBinary: {
            if case .found(let path) = HostCommand.resolveBinary(settings: m.settings) { return path }
            return nil
        })
        coordinator.adoptOnLaunch()   // before start(): a server left by the previous run is adopted, never duplicated
        QuitHandler.coordinator = coordinator
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

/// Quit / logout / shutdown / wake. All decisions live in `LifecycleCoordinator` (StrimAppCore, unit-tested).
final class QuitHandler: NSObject, NSApplicationDelegate {
    @MainActor static var coordinator: LifecycleCoordinator?

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.coordinator?.systemDidWake() }
        }
    }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = Self.coordinator else { return .terminateNow }
        switch c.requestQuit(reply: { NSApp.reply(toApplicationShouldTerminate: true) }) {
        case .now: return .terminateNow
        case .later: return .terminateLater
        }
    }
}
