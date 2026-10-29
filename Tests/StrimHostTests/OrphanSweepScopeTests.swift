import Foundation
import Testing
import StrimHost
import StrimHarness

@Suite struct OrphanSweepScopeTests {
    @Test func ownersAndLegacyAreScoped() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("sleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
        let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "--force", binary.path]; sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit(); #expect(sign.terminationStatus == 0)
        let marker = "test-" + UUID().uuidString
        func child(_ owner: String?) throws -> Process {
            let p = Process(); p.executableURL = binary; p.arguments = ["60"]
            var env = ["STRIM_JOB": marker, "PATH": "/usr/bin:/bin"]
            if let owner { env["STRIM_HOST"] = owner }
            p.environment = env; try p.run(); return p
        }
        let defaultID = HostIdentity.id(for: HostIdentity.defaultRoot)
        let otherID = HostIdentity.id(for: dir.appendingPathComponent("other-state"))
        #expect(defaultID != otherID)
        #expect(otherID == HostIdentity.id(for: dir.appendingPathComponent("nested/../other-state")))
        let a = try child(defaultID), b = try child(otherID), legacy = try child(nil)
        defer { for p in [a, b, legacy] where p.isRunning { p.terminate() } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(OrphanSweep.killMarkedProcesses(marker: "STRIM_JOB=" + marker, hostID: defaultID, includeLegacy: false) == 1)
        for _ in 0..<100 where a.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!a.isRunning && b.isRunning && legacy.isRunning)
        #expect(OrphanSweep.killMarkedProcesses(marker: "STRIM_JOB=" + marker, hostID: otherID, includeLegacy: true) == 1)
        for _ in 0..<100 where b.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!b.isRunning && legacy.isRunning)
        #expect(OrphanSweep.killMarkedProcesses(marker: "STRIM_JOB=" + marker, hostID: defaultID, includeLegacy: true) == 1)
        for _ in 0..<100 where legacy.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!legacy.isRunning)
    }
}
