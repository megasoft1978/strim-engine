import AppKit
import SwiftUI
import StrimAPI
import StrimAppCore

private struct SelfTestError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Entered before SwiftUI's App.main: no scenes, delegate adaptor, menu extras, or windows are constructed.
@MainActor
enum SelfTest {
    static func run() async -> Int32 {
        // Renders are windowless NSHostingViews (see image); this application can never activate.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = Array(CommandLine.arguments.dropFirst())
        var directory: URL?
        do {
            var output: String?
            var model: String?
            var noModel = false
            var renderOnly: String?
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--selftest", "--model", "--render-only":
                    guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                        throw SelfTestError(message: "\(args[i]) requires a path")
                    }
                    if args[i] == "--selftest" { output = args[i + 1] }
                    else if args[i] == "--model" { model = args[i + 1] }
                    else { renderOnly = args[i + 1] }
                    i += 2
                case "--no-model": noModel = true; i += 1
                default: throw SelfTestError(message: "unknown selftest argument: \(args[i])")
                }
            }
            guard let output else { throw SelfTestError(message: "usage: Strim --selftest <dir> [--model <path> | --no-model]") }
            let root = try SelfTestIsolation.directory(output)
            directory = root
            guard !(noModel && model != nil) else { throw SelfTestError(message: "--model and --no-model are mutually exclusive") }
            if let renderOnly, !["menu", "chat", "settings"].contains(renderOnly) {
                throw SelfTestError(message: "unknown render probe: \(renderOnly)")
            }
            try SecureFS.ensureDir(root.path)
            guard FileManager.default.changeCurrentDirectoryPath(root.path) else {
                throw SelfTestError(message: "cannot enter isolated selftest directory: \(root.path)")
            }
            let packaged = Bundle.main.bundleURL.pathExtension == "app"
            let binary: String
            if packaged {
                guard let resources = Bundle.main.resourceURL else { throw SelfTestError(message: "app bundle has no Resources directory") }
                binary = resources.appendingPathComponent("strim").path
            } else {
                guard let exe = Bundle.main.executableURL else { throw SelfTestError(message: "cannot locate selftest executable") }
                binary = exe.deletingLastPathComponent().appendingPathComponent("strim").path
            }
            let version = packaged ? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "missing") : nil
            // Default handlers would orphan the owned server: clean it up on SIGINT/SIGTERM/SIGHUP and on overrun.
            let guardian = SelfTestGuard(binary: binary)
            guardian.installSignals()
            guardian.armWatchdog(seconds: 480)
            defer { guardian.disarm() }
            let report = await SelfTestRunner.run(directory: root, modelPath: model, noModel: noModel || model == nil,
                binary: binary, bundleVersion: version, onHostStarted: { guardian.hostStarted($0) }, windows: { NSApp?.windows.count ?? 0 }, render: { app, dir in
                    if let renderOnly { return [render(app, name: renderOnly, directory: dir)] }
                    return ["menu", "chat", "settings"].map { renderChild(name: $0, directory: dir) }
                })
            try report.write(to: root)
            print(report.summary + "; report=\(root.appendingPathComponent("selftest.json").path)")
            return report.exitCode
        } catch {
            let report = SelfTestReport(windows: NSApp?.windows.count ?? 0,
                checks: [.init(name: "selftest-arguments", ok: false, ms: 0, detail: error.localizedDescription)])
            if let directory { try? report.write(to: directory) }
            print(report.summary + "; " + error.localizedDescription.replacingOccurrences(of: "\n", with: " "))
            return 1
        }
    }

    private static func render(_ model: AppModel, name: String, directory: URL) -> SelfTestCheck {
        switch name {
        case "menu": image(MenuContent(model: model), name: name, width: 320, height: 560, directory: directory)
        case "chat": image(ChatTab(model: model).environmentObject(ProjectsFlow()), name: name, width: 1000, height: 700, directory: directory)
        // The TabView strip is AppKit-backed and not renderable windowless: render the General pane as the snapshot test does.
        default: image(GeneralPane(model: model).formStyle(.grouped).tint(Strim.C.accent).background(Strim.C.bg),
                       name: name, width: 520, height: 520, directory: directory)
        }
    }

    /// SwiftUI can trap rather than return nil for a native control outside its application update cycle.
    /// Probe in a child with the same prohibited policy; a renderer trap cannot lose the report or the owned host.
    private static func renderChild(name: String, directory: URL) -> SelfTestCheck {
        let root = directory.appendingPathComponent("probe-" + name)
        let logPath = directory.appendingPathComponent("probe-\(name).log").path
        let p = Process(); p.executableURL = Bundle.main.executableURL
        p.arguments = ["--selftest", root.path, "--no-model", "--render-only", name]
        p.currentDirectoryURL = directory
        do {
            let log = try SecureFS.openAppend(logPath)
            defer { try? log.close() }
            p.standardInput = FileHandle.nullDevice; p.standardOutput = log; p.standardError = log
            let done = DispatchSemaphore(value: 0); p.terminationHandler = { _ in done.signal() }
            try p.run()
            guard done.wait(timeout: .now() + 15) == .success else {
                p.terminate()
                if done.wait(timeout: .now() + 0.5) != .success { kill(p.processIdentifier, SIGKILL) }
                return .renderChildFailure(name, reason: "Windowless render timed out after 15s; probe log: \(logPath)")
            }
            if p.terminationReason == .uncaughtSignal {
                let lines = ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").split(separator: "\n")
                let detail = (lines.first { $0.contains("Fatal error") } ?? lines.last).map(String.init) ?? "no diagnostic"
                return .renderChildFailure(name, reason: "Windowless render exited on signal \(p.terminationStatus): \(detail); log: \(logPath)")
            }
            let report = try JSONDecoder().decode(SelfTestReport.self, from: Data(contentsOf: root.appendingPathComponent("selftest.json")))
            guard report.windows == 0 else {
                return .init(name: "render-" + name, ok: false, ms: 0, detail: "render probe created \(report.windows) windows")
            }
            guard let result = report.checks.first(where: { $0.name == "render-" + name }) else {
                throw SelfTestError(message: "render probe produced no image check (exit \(p.terminationStatus))")
            }
            return result
        } catch {
            return .init(name: "render-" + name, ok: false, ms: 0, detail: error.localizedDescription)
        }
    }

    /// Same technique as the golden snapshots (Tests/StrimAppSnapshotTests/GoldenRender.swift): an NSHostingView that is
    /// never put in a window, drawn with cacheDisplay into a 2x bitmap. ImageRenderer traps on AppKit-backed controls
    /// (`no current update to enqueue action to`) and draws placeholders for them.
    private static func windowless(_ view: some View, width: CGFloat, height: CGFloat) -> CGImage? {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width, height: height).environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true }))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: height)
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    private static func image<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat, directory: URL) -> SelfTestCheck {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let image = windowless(view, width: width, height: height) else {
            return .skip("render-" + name, reason: "windowless NSHostingView returned no bitmap; no NSWindow or window-backed hosting fallback is used")
        }
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data), image.bitsPerPixel >= 8 else {
            return .skip("render-" + name, reason: "windowless render has no readable pixel data")
        }
        let pixelBytes = image.bitsPerPixel / 8
        var distinct = false
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * pixelBytes
                if (0..<pixelBytes).contains(where: { bytes[offset + $0] != bytes[$0] }) { distinct = true; break }
            }
            if distinct { break }
        }
        do {
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SelfTestError(message: "cannot encode rendered image") }
            try SecureFS.writeAtomically(png, to: directory.appendingPathComponent("render-\(name).png").path)
            return .init(name: "render-" + name, ok: distinct, ms: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                         detail: "windowless NSHostingView offscreen \(image.width)x\(image.height); more than one distinct colour=\(distinct)")
        } catch {
            return .init(name: "render-" + name, ok: false, ms: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, detail: error.localizedDescription)
        }
    }
}
