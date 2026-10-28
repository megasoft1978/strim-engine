import Foundation
import Testing
import StrimEngine
import StrimHarness
import StrimJobs
import StrimServer
@testable import StrimHost

private final class QuietChat: ChatBackend, @unchecked Sendable {
    func openSession(spec: HarnessJobSpec, sessionID: String, profile: RunProfile) async throws {}
    func appendUserTurn(sessionID: String, text: String) async throws -> AsyncStream<ChatEvent> { AsyncStream { $0.finish() } }
    func cancelTurn(sessionID: String) async {}
    func closeSession(sessionID: String) async -> HarnessJobResult? { nil }
}

private func gitRun(_ args: [String], in dir: String) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: SandboxProfile.trustedGitPath ?? "/usr/bin/git")
    p.arguments = args; p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                     "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    try p.run(); p.waitUntilExit()
}

@Suite("chat sessions across a host crash", .serialized)
struct ChatCrashRecoveryTests {
    @Test("host start fails an open chat job (host_restart) and sweeps its leftover worktree")
    func orphanChatWorktree() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("crash-\(UUID().uuidString)").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo").path
        let base = root.appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try gitRun(["init", "-q", "-b", "main"], in: repo)
        try "x\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        try gitRun(["add", "."], in: repo); try gitRun(["commit", "-q", "-m", "i"], in: repo)

        // The dead host: a chat job persisted as running, and its session worktree on disk.
        let paths = HostPaths(root: root.appendingPathComponent("home"))
        let dead = JobManager(executor: { _, _, _ in HarnessJobResult(status: .done, summary: "") },
                              store: FileJobStore(root: paths.jobs), pollInterval: .seconds(60), chat: QuietChat())
        let id = try await dead.openSession(HarnessJobSpec(task: "", cwd: repo, access: .write))
        await dead.flush()
        let ws = try await GitWorktreeIsolation(baseDir: base).prepare(cwd: repo, access: .write, files: [])
        #expect(FileManager.default.fileExists(atPath: ws.root))

        // A new host over the same directories.
        let host = StrimHost(engine: SlotFakeEngine(), serverConfig: ServerConfig(modelId: "m"), paths: paths,
                             executor: { _, _, _ in HarnessJobResult(status: .done, summary: "") },
                             chatBackend: QuietChat(), isolationBaseDir: base, orphanGraceSeconds: 0)
        _ = try await host.start(port: 0)
        defer { Task { await host.shutdown() } }

        let snap = try await host.jobs.status(id, waitS: 0)
        #expect(snap.status == .failed && snap.reason == JobFailureReason.hostRestart)
        #expect(!FileManager.default.fileExists(atPath: ws.root), "orphaned chat worktree must be swept")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        #expect(left.isEmpty)
        // the parent repo is untouched
        #expect(try String(contentsOfFile: repo + "/f.txt", encoding: .utf8) == "x\n")
    }
}
