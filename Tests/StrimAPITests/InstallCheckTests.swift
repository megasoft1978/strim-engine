import XCTest
@testable import StrimAPI

final class InstallCheckTests: XCTestCase {
    struct Probe: InstallProbe {
        var copies: [InstallCopy] = []
        var processes: [InstallProcess] = []
        var caskInstalled: Bool? = true
        var brewPrefix: String? = "/opt/homebrew"
        var serverVersion: String?
    }
    func testMultipleCopiesAndVersionMismatch() {
        let p = Probe(copies: [.init(path: "/Applications/Strim.app", version: "1"), .init(path: "/tmp/Strim.app", version: "0")])
        let findings = InstallCheck.findings(probe: p, cliVersion: "1")
        XCTAssertEqual(findings.count, 2)
        XCTAssertTrue(findings[0].message.contains("/Applications/Strim.app (1)"))
        XCTAssertTrue(findings[0].message.contains("/tmp/Strim.app (0)"))
        XCTAssertTrue(findings[1].message.contains("/tmp/Strim.app"))
        XCTAssertFalse(findings.contains { $0.fix.isEmpty })
    }
    func testRunningOutsideAllowedPathsAndServerMismatch() {
        let p = Probe(processes: [.init(path: "/tmp/Strim.app/Contents/MacOS/StrimApp", version: "0", pid: 42), .init(path: "/opt/homebrew/bin/strim", version: nil, pid: 43)], serverVersion: "0")
        let findings = InstallCheck.findings(probe: p, cliVersion: "1")
        XCTAssertEqual(findings.count, 2)
        XCTAssertTrue(findings[0].message.contains("/tmp/Strim.app"))
        XCTAssertTrue(findings[0].fix.contains("42"))
        XCTAssertTrue(findings[1].message.contains("0"))
    }
    func testMissingCaskAndUnknownState() {
        let copy = InstallCopy(path: "/Applications/Strim.app", version: "1")
        XCTAssertTrue(InstallCheck.findings(probe: Probe(copies: [copy], caskInstalled: false), cliVersion: "1").contains { $0.fix == "brew install --cask strim-app" })
        XCTAssertTrue(InstallCheck.findings(probe: Probe(copies: [copy], caskInstalled: nil), cliVersion: "1").isEmpty)
        XCTAssertTrue(InstallCheck.findings(probe: Probe(caskInstalled: false), cliVersion: "1").isEmpty)
    }
    func testPathBoundariesAndUnknownVersions() {
        let p = Probe(copies: [.init(path: "/tmp/Strim.app", version: nil)], processes: [.init(path: "/Applications/Strim.app.fake/x", version: nil, pid: 9), .init(path: "/opt/homebrew-other/strim", version: nil, pid: 10)])
        let findings = InstallCheck.findings(probe: p, cliVersion: "1")
        XCTAssertEqual(findings.count, 2)
        XCTAssertTrue(findings.allSatisfy { $0.message.contains("unknown") })
    }
    func testRunnerDrainsOutputLargerThanPipeBuffer() {
        let result = InstallProcessRunner.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' a"], timeout: 5)
        XCTAssertEqual(result?.status, 0)
        XCTAssertEqual(result?.output.utf8.count, 300_000)
    }
    func testRunnerTerminatesSleepingChildAtLimit() {
        let start = Date()
        XCTAssertNil(InstallProcessRunner.run("/bin/sleep", ["5"], timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testRunnerReturnsNilForMissingExecutable() {
        XCTAssertNil(InstallProcessRunner.run("/nonexistent/strim-tool", [], timeout: 1))
    }
}
