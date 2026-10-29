import SwiftUI
import AppKit
import StrimAPI
import StrimAppCore

/// `StrimApp --snapshots <dir> --grants`: folder-access states (consent sheet, granted lock row, refused chat with
/// "Grant access", Settings list) from fixtures on `MemoryChatStore`. Rendered offscreen with no window shown, so the
/// desktop is not disturbed. Names: `grants-<state>-800x560-<scheme>.png`.
extension SnapshotMode {
    @MainActor
    static func runGrants(into dir: String) async {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: "\(fxRoot)/new-client", withIntermediateDirectories: true)
        let size = CGSize(width: 800, height: 560)
        let model = await projectsModel(grants: true)
        model.selectThread("t-b1")
        await model.send("Try the toggle again", in: "t-b1")          // refused: notes-app is not granted
        model.selectThread("t-a1")
        let refused = await projectsModel(grants: true)
        refused.selectThread("t-b1")
        await refused.send("Try the toggle again", in: "t-b1")

        model.requestProject("\(fxRoot)/new-client")                    // outside the host's folders: consent step
        let consent = model.pendingConsent
        var failing = consent
        failing?.error = "/System/Library is inside a protected system location (/System)"

        func sheet(_ c: FolderConsent) -> some View {
            ZStack {
                MainWindow(model: model, section: .chat, sidebarOpen: true).overlay(Color.black.opacity(0.4))
                ConsentSheet(consent: c, allow: {}, cancel: {})
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Strim.C.hairline))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            }
        }
        for scheme in [ColorScheme.dark, .light] {
            let s = scheme == .dark ? "dark" : "light"
            if let c = consent { shootPlain(sheet(c), "grants-consent-800x560-\(s)", size, scheme, dir) }
            if let f = failing { shootPlain(sheet(f), "grants-consent-error-800x560-\(s)", size, scheme, dir) }
            model.cancelConsent()
            model.selectThread("t-a1")
            shootPlain(MainWindow(model: model, section: .chat, sidebarOpen: true), "grants-lock-row-800x560-\(s)", size, scheme, dir)
            shootPlain(MainWindow(model: refused, section: .chat, sidebarOpen: true), "grants-refused-800x560-\(s)", size, scheme, dir)
            shootPlain(SettingsView(model: model, pane: .chat), "grants-settings-chat-\(s)", CGSize(width: 520, height: 520), scheme, dir)
            model.requestProject("\(fxRoot)/new-client")
        }
        model.stop(); refused.stop()
    }
}
