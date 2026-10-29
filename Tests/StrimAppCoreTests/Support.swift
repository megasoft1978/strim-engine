import Foundation
import StrimAPI
@testable import StrimAppCore

final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let l = NSLock()
    init(_ v: T) { self.v = v }
    func with<R>(_ f: (inout T) -> R) -> R { l.lock(); defer { l.unlock() }; return f(&v) }
    var value: T { with { $0 } }
}

/// First `auto` sleeps return immediately; later ones block until `release()`. Every call is recorded.
final class RecordingClock: AppClock {
    private let rec = Locked<[Double]>([])
    private let released = Locked(false)
    let auto: Int
    init(auto: Int = 0) { self.auto = auto }
    var sleeps: [Double] { rec.value }
    func release() { released.with { $0 = true } }
    func now() -> Date { Date(timeIntervalSince1970: 1_000_000) }
    func sleep(seconds: Double) async throws {
        let n = rec.with { $0.append(seconds); return $0.count }
        if n <= auto { await Task.yield(); return }
        while !released.value { try await Task.sleep(nanoseconds: 5_000_000) }
    }
}

final class MockLauncher: HostLauncher {
    let result: Locked<HostLaunchResult>
    let calls = Locked(0)
    init(_ r: HostLaunchResult) { result = Locked(r) }
    func start(settings: AppSettings) -> HostLaunchResult { calls.with { $0 += 1 }; return result.value }
}
final class MockClipboard: ClipboardWriting {
    let copied = Locked<[String]>([])
    func copy(_ text: String) { copied.with { $0.append(text) } }
}
final class MockLogin: LoginItemControlling {
    let on = Locked(false)
    let failure = Locked<Error?>(nil)
    var isEnabled: Bool { on.value }
    func setEnabled(_ v: Bool) throws { if let e = failure.value { throw e }; on.with { $0 = v } }
}
struct MockMcp: McpCommandProvider {
    func commands(settings: AppSettings) async -> String { McpTemplate.render(port: settings.port) }
}

/// Every call fails the same way.
struct FailingClient: StrimControlClient {
    var error: Error
    func status() async throws -> HostStatus { throw error }
    func events() -> AsyncThrowingStream<StrimEvent, Error> { AsyncThrowingStream { $0.finish(throwing: error) } }
    func load(_ r: LoadRequest) async throws { throw error }
    func unload() async throws { throw error }
    func jobs() async throws -> [JobSummary] { throw error }
    func job(id: String) async throws -> JobDetail { throw error }
    func approve(_ a: PatchApproval) async throws { throw error }
    func chatOpen(_ r: ChatOpenRequest) async throws -> ChatSession { throw error }
    func chatAppend(_ r: ChatAppendRequest) async throws { throw error }
    func chatCancel(_ r: ChatCancelRequest) async throws { throw error }
    func chatClose(sessionID: String) async throws { throw error }
}

@MainActor
func waitFor(_ what: String = "", timeout: Double = 3, _ cond: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return cond()
}

func status(_ state: HostState, model: String? = "Qwen3.8-27B", progress: Double? = nil, active: Int = 0) -> HostStatus {
    var s = FakeControlClient.sampleStatus
    s.state = state; s.model = model; s.loadProgress = progress; s.activeJobs = active
    return s
}
