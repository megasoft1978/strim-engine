import XCTest
import SwiftUI
import AppKit
@testable import StrimApp
import StrimAppCore
import StrimAPI

/// Windowless golden snapshots of every app view state (see GoldenRender / GoldenCompare / StandIns).
/// Goldens: Tests/Goldens/<state>-<size>-<theme>.png. `STRIM_UPDATE_GOLDENS=1 swift test` rewrites them.
@MainActor
final class AppViewSnapshotTests: XCTestCase {
    typealias Size = (w: CGFloat, h: CGFloat)
    static let s640: Size = (640, 460), s800: Size = (800, 560), s1440: Size = (1440, 900)
    static let allSizes = [s640, s800, s1440]
    static let clock = SnapshotMode.now

    /// Goldens drawn on another macOS major version or scroller style skip (see `GoldenCompare.platformSkipReason`).
    override func setUpWithError() throws {
        try super.setUpWithError()
        if let reason = GoldenCompare.platformSkipReason() { throw XCTSkip(reason) }
    }

    /// Writes `Tests/Goldens/PLATFORM`. Runs only when regenerating goldens (`STRIM_UPDATE_GOLDENS=1`).
    func testRecordPlatform() throws {
        try XCTSkipUnless(GoldenCompare.updating, "records the platform only when regenerating goldens")
        XCTAssertTrue(GoldenCompare.recordPlatform(), "cannot write Tests/Goldens/PLATFORM")
    }

    func shoot<V: View>(_ name: String, size: CGSize?, _ view: (Bool) -> V) {
        for dark in [true, false] {
            let z = size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "fit"
            let full = "\(name)-\(z)-\(dark ? "dark" : "light")"
            guard let image = GoldenRender.render(view(dark), size: size, dark: dark) else { XCTFail("\(full): render failed"); continue }
            if let failure = GoldenCompare.check(image, name: full) { XCTFail(failure) }
        }
        GoldenRender.assertNoWindows()
    }

    func window<D: View>(_ name: String, _ model: AppModel, _ section: AppSection, sizes: [Size], sidebarOpen: Bool = false,
                         @ViewBuilder _ detail: @escaping (CGFloat) -> D) {
        for s in sizes {
            shoot(name, size: CGSize(width: s.w, height: s.h)) { _ in
                WindowStandIn(model: model, section: section, width: s.w, height: s.h, sidebarOpen: sidebarOpen, now: Self.clock, detail: detail)
                    .environment(\.strimNow, Date(timeIntervalSince1970: Self.clock))
            }
        }
    }

    // MARK: chat

    func testChatStates() async {
        let full = await Fixtures.projects()
        let flow = ProjectsFlow()
        func chat(_ name: String, _ tid: String, sizes: [Size], open: Bool = false) {
            full.selectThread(tid)
            window(name, full, .chat, sizes: sizes, sidebarOpen: open) { _ in ChatTab(model: full).environmentObject(flow) }
        }
        chat("chat-generating", "t-a1", sizes: Self.allSizes)
        chat("chat-queued", "t-a2", sizes: [Self.s640, Self.s800])
        chat("chat-error", "t-b1", sizes: [Self.s640, Self.s800])
        chat("chat-divider", "t-a4", sizes: [Self.s800])
        chat("chat-folder-missing", "t-c1", sizes: [Self.s800])
        chat("chat-scratch", "t-s1", sizes: [Self.s800])
        chat("chat-sidebar-open", "t-a1", sizes: [Self.s640], open: true)
        let empty = await Fixtures.projects(empty: true)
        window("chat-empty", empty, .chat, sizes: Self.allSizes) { _ in ChatTab(model: empty).environmentObject(flow) }
    }

    /// Composer with the mic button: idle, listening with a partial, and the permission-denied notice.
    func testChatDictation() async {
        let m = await Fixtures.model("dictation") { await SnapshotMode.projectsModel() }
        let fake = FakeDictation()
        m.dictationFactory = { fake }
        let flow = ProjectsFlow()
        m.selectThread("t-a4")
        window("chat-dictation-idle", m, .chat, sizes: [Self.s800]) { _ in ChatTab(model: m).environmentObject(flow) }
        fake.onStart = [.state(.preparing), .state(.listening), .partial("rename the timeout")]
        m.toggleDictation(in: "t-a4", draft: "Please")
        let drafts = ["t-a4": m.dictationOutput?.text ?? ""]
        XCTAssertEqual(drafts["t-a4"], "Please rename the timeout")
        for s in [Self.s640, Self.s800] {
            window("chat-dictation-listening", m, .chat, sizes: [s]) { _ in ChatTab(model: m, drafts: drafts).environmentObject(flow) }
        }
        m.stopDictation()
        fake.onStart = [.state(.preparing), .state(.error(.microphoneDenied))]
        m.toggleDictation(in: "t-a4", draft: "")
        window("chat-dictation-denied", m, .chat, sizes: [Self.s640, Self.s800]) { _ in ChatTab(model: m).environmentObject(flow) }
        m.dismissDictationMessage()
    }

    func testChatToolOutput() async {
        let m = await Fixtures.chatTools()
        let flow = ProjectsFlow()
        window("chat-tool-output", m, .chat, sizes: [Self.s800]) { _ in ChatTab(model: m, expandAll: true).environmentObject(flow) }
    }

    func testSidebar() async {
        let full = await Fixtures.projects()
        full.selectThread("t-a2")
        shoot("sidebar-projects", size: CGSize(width: PaneWidths.sidebarSnapshot, height: 640)) { _ in
            SidebarStandIn(model: full, section: .chat, now: Self.clock)
        }
        let empty = await Fixtures.projects(empty: true)
        shoot("sidebar-empty", size: CGSize(width: PaneWidths.sidebarSnapshot, height: 300)) { _ in
            SidebarStandIn(model: empty, section: .status, now: Self.clock)
        }
    }

    // MARK: status, jobs

    func testStatus() async {
        let running = await Fixtures.status("running")
        window("status-running", running, .status, sizes: Self.allSizes) { _ in StatusView(model: running) }
        for key in ["idle", "stopped", "error", "loading"] {
            let m = await Fixtures.status(key)
            window("status-\(key)", m, .status, sizes: [Self.s800]) { _ in StatusView(model: m) }
        }
    }

    func testJobs() async {
        let patch = await Fixtures.jobs(select: "j_bcdefghi34")
        window("jobs-patch", patch, .jobs, sizes: Self.allSizes) { w in JobsStandIn(model: patch, detailWidth: w) }
        let running = await Fixtures.jobs(select: "j_abcdefgh23")
        window("jobs-running", running, .jobs, sizes: [Self.s800]) { w in JobsStandIn(model: running, detailWidth: w) }
        let none = await Fixtures.jobs(select: nil)
        window("jobs-list", none, .jobs, sizes: [Self.s640, Self.s800]) { w in JobsStandIn(model: none, detailWidth: w) }
    }

    /// Relative job times come from the injected clock, not the wall clock: the same instant renders the same pixels
    /// after real time has passed, and a later instant changes the labels (so the injection is actually used).
    func testJobRowsUseInjectedClock() async {
        let m = await Fixtures.jobs(select: nil)
        func pixels(_ now: Double) -> [UInt8]? {
            let view = JobListStandIn(model: m).environment(\.strimNow, Date(timeIntervalSince1970: now))
            guard let image = GoldenRender.render(view, size: CGSize(width: 300, height: 200), dark: false) else { return nil }
            return GoldenCompare.pixels(image)?.data
        }
        let first = pixels(Self.clock)
        XCTAssertNotNil(first)
        try? await Task.sleep(for: .seconds(1))
        XCTAssertEqual(first, pixels(Self.clock), "same injected instant rendered different pixels after 1 s of real time")
        XCTAssertNotEqual(first, pixels(Self.clock + 3600), "injected clock ignored: labels did not move one hour later")
        GoldenRender.assertNoWindows()
    }

    // MARK: first run

    func testFirstRunStates() async {
        for key in ["needs-download", "low-disk", "downloading", "paused", "verifying", "starting-server", "failed"] {
            let m = await Fixtures.firstRun(key)
            window("firstrun-\(key)", m, .status, sizes: key == "downloading" ? [Self.s640, Self.s800] : [Self.s800]) { _ in FirstRunView(model: m) }
        }
    }

    // MARK: settings, popover, consent

    func testSettingsPanes() async {
        let running = await Fixtures.status("running")
        let full = await Fixtures.projects()
        func pane<P: View>(_ name: String, _ p: P) {
            shoot("settings-\(name)", size: CGSize(width: 520, height: 520)) { _ in
                p.formStyle(.grouped).tint(Strim.C.accent).frame(width: 520, height: 520, alignment: .top).background(Strim.C.bg)
            }
        }
        pane("general", GeneralPane(model: running))
        pane("model", ModelPane(model: running))
        pane("server", ServerPane(model: running))
        pane("chat", ChatPane(model: full))
        pane("about", AboutPane(model: running))
    }

    func testPopovers() async {
        for (name, key) in [("running", "status-running"), ("stopped", "status-stopped"), ("downloading", "fr-downloading")] {
            let m: AppModel
            switch name {
            case "running": m = await Fixtures.status("running")
            case "stopped": m = await Fixtures.status("stopped")
            default: m = await Fixtures.firstRun("downloading")
            }
            _ = key
            shoot("popover-\(name)", size: nil) { _ in
                MenuContent(model: m).fixedSize()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Strim.C.hairline))
                    .padding(20).background(Strim.C.bg)
            }
        }
    }

    func testConsentSheet() async {
        for (name, error) in [("consent", String?.none), ("consent-error", "/System/Library is inside a protected system location (/System)")] {
            let c = await Fixtures.consent(error: error)
            shoot("sheet-\(name)", size: nil) { _ in
                ConsentSheet(consent: c, allow: {}, cancel: {})
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Strim.C.hairline))
                    .padding(24).background(Strim.C.surface2)
            }
        }
    }
}
