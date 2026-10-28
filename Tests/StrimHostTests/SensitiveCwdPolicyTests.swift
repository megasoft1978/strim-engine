import Foundation
import Testing
import StrimEngine
import StrimHarness
import StrimJobs
import StrimServer
@testable import StrimHost

private final class NoEngine: EngineClient, @unchecked Sendable {
    func openSession(_ config: SessionConfig) async throws -> SessionID { SessionID(raw: 1) }
    func fork(_ session: SessionID, at messageCount: Int?) async throws -> SessionID { session }
    func append(_ session: SessionID, _ input: TurnInput) async throws -> Int { 1 }
    func generate(_ session: SessionID, _ params: GenParams) -> AsyncThrowingStream<GenEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func cancel(_ session: SessionID) async {}
    func prefetch(_ ids: [Int32], priority: Priority) async throws {}
    func ledger(_ session: SessionID) async throws -> LedgerSnapshot { LedgerSnapshot(ids: [], messageCount: 0, ledger: nil) }
    func close(_ session: SessionID) async {}
    func stats() -> EngineStats { EngineStats() }
}

/// H1 (security review 2026-10-28), host side.
@Suite(.serialized) struct SensitiveCwdPolicyTests {
    private func fakeHome() throws -> String {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("fakehome-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: h + "/.strim", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: h + "/proj", withIntermediateDirectories: true)
        return h
    }

    @Test func policyRefusesStrimDirEvenWithoutAllowedRoots() throws {
        let h = try fakeHome(); defer { try? FileManager.default.removeItem(atPath: h) }
        let open = HostPolicy(maxAccess: .write, allowedRoots: [])  // injected unrestricted policy (tests only)
        let msg = open.violation(access: "read", cwd: h + "/.strim", home: h)
        #expect(msg != nil && msg!.contains("credentials or host-state"), "got \(String(describing: msg))")
        #expect(open.violation(access: "read", cwd: h + "/proj", home: h) == nil)
    }

    @Test func productionDefaultIsNotUnrestricted() throws {
        let h = try fakeHome(); defer { try? FileManager.default.removeItem(atPath: h) }
        let (c, defaulted) = HostConfig().withProductionDefaults(home: h)  // what `strim serve` applies to an unset config
        #expect(defaulted && c.allowedRoots == [h])
        let p = HostPolicy(c)
        #expect(p.violation(access: "read", cwd: "/usr", home: h) != nil)
        #expect(p.violation(access: "read", cwd: nil, home: h) != nil)
        #expect(p.violation(access: "read", cwd: h + "/proj", home: h) == nil)
        let (e, d2) = HostConfig(allowedRoots: ["/tmp/x"]).withProductionDefaults(home: h)
        #expect(!d2 && e.allowedRoots == ["/tmp/x"])
    }

    @Test func hostRegistersControlTokenWithRedactor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("strimhost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = "ctl" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try (secret + "\n").write(to: root.appendingPathComponent("control-token"), atomically: true, encoding: .utf8)
        #expect(Redactor.redact("x \(secret)").contains(secret))  // unregistered: passes through
        let exec: JobExecutor = { _, _, onEvent in onEvent(.finished(.done)); return HarnessJobResult(status: .done, summary: "ok") }
        let host = StrimHost(engine: NoEngine(), serverConfig: ServerConfig(modelId: "m", bearerToken: "tok"),
                             hostConfig: HostConfig(), paths: HostPaths(root: root), sandboxed: false, executor: exec)
        _ = try await host.start(port: 0)
        #expect(!Redactor.redact("x \(secret)").contains(secret))
        await host.shutdown()
    }
}
