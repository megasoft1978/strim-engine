import Foundation
import Testing
import StrimEngine
import StrimHarness
import StrimServer
import StrimJobs
@testable import StrimHost

private final class RecordingChat: ChatBackend, @unchecked Sendable {
    private let l = NSLock()
    private(set) var opens: [(String, AccessLevel)] = []
    private(set) var appends = 0
    func openSession(spec: HarnessJobSpec, sessionID: String, profile: RunProfile) async throws { l.withLock { opens.append((spec.cwd, spec.access)) } }
    func appendUserTurn(sessionID: String, text: String) async throws -> AsyncStream<ChatEvent> { l.withLock { appends += 1 }; return AsyncStream { $0.finish() } }
    func cancelTurn(sessionID: String) async {}
    func closeSession(sessionID: String) async -> HarnessJobResult? { nil }
}

@Suite("PolicyCheckedChatBackend")
struct ChatPolicyTests {
    private func spec(_ cwd: String, _ a: AccessLevel) -> HarnessJobSpec { HarnessJobSpec(task: "", cwd: cwd, access: a) }

    @Test("allowed roots and maxAccess are enforced before the inner backend sees the open")
    func gate() async throws {
        let root = NSTemporaryDirectory() + "chatroot-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let inner = RecordingChat()
        let b = PolicyCheckedChatBackend(inner: inner, policy: HostPolicy(maxAccess: .read, allowedRoots: [root]))
        await #expect(throws: ChatForbidden.self) { try await b.openSession(spec: spec("/etc", .read), sessionID: "j_a", profile: .interactive) }
        await #expect(throws: ChatForbidden.self) { try await b.openSession(spec: spec(root, .write), sessionID: "j_a", profile: .interactive) }
        await #expect(throws: ChatForbidden.self) { try await b.openSession(spec: spec(root + "/../x", .read), sessionID: "j_a", profile: .interactive) }
        #expect(inner.opens.isEmpty)
        try await b.openSession(spec: spec(root + "/sub", .read), sessionID: "j_a", profile: .interactive)
        #expect(inner.opens.count == 1)
        // later turns carry only text: cwd and access stay what the open recorded
        _ = try await b.appendUserTurn(sessionID: "j_a", text: "hi")
        #expect(inner.opens.count == 1 && inner.appends == 1)
    }

    @Test("the host wraps an injected chat backend: JobManager.openSession is refused and creates nothing")
    func hostWraps() async throws {
        let inner = RecordingChat()
        let root = NSTemporaryDirectory() + "hostroot-\(UUID().uuidString)"
        let host = StrimHost(engine: SlotFakeEngine(), serverConfig: ServerConfig(modelId: "m"),
                             hostConfig: HostConfig(maxAccess: .write, allowedRoots: [root]),
                             paths: HostPaths(root: URL(fileURLWithPath: NSTemporaryDirectory() + "hp-\(UUID().uuidString)")),
                             executor: { _, _, _ in HarnessJobResult(status: .done, summary: "") }, chatBackend: inner)
        do { _ = try await host.jobs.openSession(spec("/etc", .write)); Issue.record("must refuse") }
        catch let e as ChatError { #expect("\(e)".contains("forbidden")) }
        #expect(inner.opens.isEmpty)
        // MCP submission policy is unchanged
        let r = HostPolicy(maxAccess: .write, allowedRoots: [root]).violation(access: "write", cwd: "/etc")
        #expect(r != nil)
    }
}
