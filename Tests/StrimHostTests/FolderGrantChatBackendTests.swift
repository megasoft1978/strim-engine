import Foundation
import Testing
import StrimHarness
import StrimJobs
@testable import StrimHost

private final class RecChat: ChatBackend, @unchecked Sendable {
    private let l = NSLock()
    private(set) var opens: [(String, AccessLevel)] = []
    func openSession(spec: HarnessJobSpec, sessionID: String, profile: RunProfile) async throws { l.withLock { opens.append((spec.cwd, spec.access)) } }
    func appendUserTurn(sessionID: String, text: String) async throws -> AsyncStream<ChatEvent> { AsyncStream { $0.finish() } }
    func cancelTurn(sessionID: String) async {}
    func closeSession(sessionID: String) async -> HarnessJobResult? { nil }
}

@Suite("chat backend follows folder grants", .serialized)
struct FolderGrantChatBackendTests {
    @Test("granted folder opens with the host's access level; revoke closes it again; maxAccess still caps")
    func grantThenRevoke() async throws {
        let raw = NSTemporaryDirectory() + "fgb-\(UUID().uuidString)"
        let home = raw + "/home", ext = raw + "/ext"
        for d in [home, ext + "/proj"] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(atPath: raw) }
        let g = FolderGrants(roots: [home], configURL: URL(fileURLWithPath: raw + "/cfg/config.json"), home: home)
        let inner = RecChat()
        let spec = { (cwd: String, a: AccessLevel) in HarnessJobSpec(task: "", cwd: cwd, access: a) }
        let rw = PolicyCheckedChatBackend(inner: inner, policy: HostPolicy(maxAccess: .write, allowedRoots: [home], grants: g))
        let ro = PolicyCheckedChatBackend(inner: inner, policy: HostPolicy(maxAccess: .read, allowedRoots: [home], grants: g))
        await #expect(throws: ChatForbidden.self) { try await rw.openSession(spec: spec(ext + "/proj", .write), sessionID: "j_a", profile: .interactive) }
        try g.grant(ext)
        try await rw.openSession(spec: spec(ext + "/proj", .write), sessionID: "j_a", profile: .interactive)
        try await ro.openSession(spec: spec(ext + "/proj", .read), sessionID: "j_b", profile: .interactive)
        await #expect(throws: ChatForbidden.self) { try await ro.openSession(spec: spec(ext + "/proj", .write), sessionID: "j_c", profile: .interactive) }
        #expect(inner.opens.map(\.1) == [.write, .read])
        try g.revoke(ext)
        await #expect(throws: ChatForbidden.self) { try await rw.openSession(spec: spec(ext + "/proj", .write), sessionID: "j_d", profile: .interactive) }
        #expect(inner.opens.count == 2)
    }
}
