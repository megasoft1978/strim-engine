import Foundation
import Darwin
import Testing
@testable import StrimAppCore

struct SelfTestReportTests {
    @Test func reportSchemaRoundTrips() throws {
        let report = SelfTestReport(version: "1.2.3", windows: 0, checks: [
            SelfTestCheck(name: "settings", ok: true, ms: 12.5, detail: "default model"),
            .skip("inference", reason: "--no-model")
        ])
        let data = try JSONEncoder().encode(report)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schema_version"] as? Int == 1)
        #expect(json["version"] as? String == "1.2.3")
        #expect(json["windows"] as? Int == 0)
        let checks = try #require(json["checks"] as? [[String: Any]])
        #expect(checks[0]["name"] as? String == "settings")
        #expect(checks[0]["ok"] as? Bool == true)
        #expect(checks[0]["ms"] as? Double == 12.5)
        #expect(checks[0]["detail"] as? String == "default model")
        #expect(try JSONDecoder().decode(SelfTestReport.self, from: data) == report)
    }

    @Test func anyFailureMakesExitNonzeroEvenWithSkips() {
        let report = SelfTestReport(version: "v", windows: 0, checks: [
            .init(name: "bad", ok: false, ms: 0, detail: "failed"), .skip("model", reason: "disabled")
        ])
        #expect(report.exitCode == 1)
    }

    @Test func skippedIsNotPassedAndDoesNotFailTheRun() {
        let skip = SelfTestCheck.skip("model", reason: "--no-model")
        #expect(skip.skipped && !skip.ok && !skip.detail.isEmpty)
        let report = SelfTestReport(version: "v", windows: 0, checks: [
            .init(name: "settings", ok: true, ms: 1, detail: "ok"), skip
        ])
        #expect(report.exitCode == 0)
        #expect(report.summary.contains("1 passed") && report.summary.contains("1 skipped"))
    }

    @Test func windowsFailTheGate() {
        let report = SelfTestReport(version: "v", windows: 1, checks: [.init(name: "ok", ok: true, ms: 0, detail: "ok")])
        #expect(report.exitCode == 1)
    }

    @Test func emptyReportCannotPass() {
        #expect(SelfTestReport(version: "v", windows: 0, checks: []).exitCode == 1)
    }

    @Test func refusesProtectedStateAndDescendantsWithoutCreatingThem() throws {
        let base = try #require(realpath("/tmp", nil))
        defer { free(base) }
        let home = String(cString: base) + "/selftest-home-\(UUID().uuidString)"
        #expect(throws: (any Error).self) { try SelfTestIsolation.directory(home + "/.strim", home: home) }
        #expect(throws: (any Error).self) { try SelfTestIsolation.directory(home + "/.strim/state", home: home) }
        #expect(!FileManager.default.fileExists(atPath: home))
        let actual = try SelfTestIsolation.directory(home + "/.strim-other", home: home).path
        let expected = home + "/.strim-other"
        #expect(actual == expected, "resolved=\(actual); expected=\(expected)")
    }

    @Test func refusesSymlinkIntoProtectedState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("home/.strim"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("alias"), withDestinationURL: dir.appendingPathComponent("home/.strim"))
        #expect(throws: (any Error).self) {
            try SelfTestIsolation.directory(dir.appendingPathComponent("alias/state").path, home: dir.appendingPathComponent("home").path)
        }
    }

    @Test func reportWritesOnlyToExplicitTemporaryDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = SelfTestReport(version: "v", windows: 0, checks: [.skip("inference", reason: "disabled")])
        try report.write(to: dir)
        let decoded = try JSONDecoder().decode(SelfTestReport.self, from: Data(contentsOf: dir.appendingPathComponent("selftest.json")))
        #expect(decoded == report)
    }

    @Test func passwdHomeStaysProtectedWhenHomeIsOverridden() throws {
        let pw = try #require(getpwuid(getuid()))
        let real = String(cString: try #require(pw.pointee.pw_dir))
        let fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-home-\(UUID().uuidString)").path
        #expect(throws: (any Error).self) { try SelfTestIsolation.directory(real + "/.strim/state", home: fakeHome) }
        #expect(throws: (any Error).self) { try SelfTestIsolation.directory(real + "/.strim", home: fakeHome) }
        #expect(!FileManager.default.fileExists(atPath: fakeHome))
    }

    @Test func renderChildTimeoutOrSignalFailsTheRun() {
        let failure = SelfTestCheck.renderChildFailure("menu", reason: "timed out")
        #expect(!failure.skipped && !failure.ok && failure.name == "render-menu")
        #expect(SelfTestReport(version: "v", windows: 0, checks: [failure]).exitCode == 1)
    }
}

private final class FakeTable: HostProcessTable, @unchecked Sendable {
    private let l = NSLock()
    private var alive: Bool
    let exe: String?
    let ignoresTerm: Bool
    private(set) var terms = 0, kills = 0
    init(alive: Bool = true, exe: String? = "/opt/strim", ignoresTerm: Bool = false) {
        self.alive = alive; self.exe = exe; self.ignoresTerm = ignoresTerm
    }
    func isAlive(_ pid: Int32) -> Bool { l.lock(); defer { l.unlock() }; return alive }
    func terminate(_ pid: Int32) { l.lock(); terms += 1; if !ignoresTerm { alive = false }; l.unlock() }
    func kill(_ pid: Int32) { l.lock(); kills += 1; alive = false; l.unlock() }
    func executablePath(of pid: Int32) -> String? { exe }
    func lockOwner() -> Int32? { nil }
    var counts: (Int, Int) { l.lock(); defer { l.unlock() }; return (terms, kills) }
}

struct SelfTestGuardTests {
    @Test func cleanupTermsOurServer() {
        let t = FakeTable()
        let g = SelfTestGuard(binary: "/opt/strim", table: t, grace: 0.5, exit: { _ in })
        g.hostStarted(4242)
        g.cleanup(); g.cleanup()
        #expect(t.counts == (1, 0))
    }

    @Test func cleanupKillsAfterGraceWhenTermIgnored() {
        let t = FakeTable(ignoresTerm: true)
        let g = SelfTestGuard(binary: "/opt/strim", table: t, grace: 0.2, exit: { _ in })
        g.hostStarted(4242)
        g.cleanup()
        #expect(t.counts == (1, 1))
    }

    @Test func cleanupLeavesReusedPidAndUnstartedHostAlone() {
        let reused = FakeTable(exe: "/usr/bin/other")
        let g = SelfTestGuard(binary: "/opt/strim", table: reused, grace: 0.1, exit: { _ in })
        g.hostStarted(4242); g.cleanup()
        #expect(reused.counts == (0, 0))
        let t = FakeTable()
        let none = SelfTestGuard(binary: "/opt/strim", table: t, grace: 0.1, exit: { _ in })
        none.cleanup()
        #expect(t.counts == (0, 0))
    }

    @Test func watchdogCleansUpAndExitsOneAtDeadline() async {
        let t = FakeTable()
        let code = LockedBox<Int32?>(nil)
        let g = SelfTestGuard(binary: "/opt/strim", table: t, grace: 0.2, exit: { code.set($0) })
        g.hostStarted(4242)
        g.armWatchdog(seconds: 0.15)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(code.get() == nil && t.counts == (0, 0))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(code.get() == 1 && t.counts == (1, 0))
        g.disarm()
    }

    @Test func signalCleansUpAndExits130() async {
        let t = FakeTable()
        let code = LockedBox<Int32?>(nil)
        let g = SelfTestGuard(binary: "/opt/strim", table: t, grace: 0.2, exit: { code.set($0) })
        g.hostStarted(4242)
        g.installSignals([SIGUSR2])
        raise(SIGUSR2)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(code.get() == 130 && t.counts == (1, 0))
        g.disarm()
        signal(SIGUSR2, SIG_DFL)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let l = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func set(_ x: T) { l.lock(); v = x; l.unlock() }
    func get() -> T { l.lock(); defer { l.unlock() }; return v }
}
