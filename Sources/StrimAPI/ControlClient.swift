import Foundation

/// Client surface of the control API. The app depends on this protocol; tests use `FakeControlClient`.
public protocol StrimControlClient: Sendable {
    func status() async throws -> HostStatus
    /// SSE stream. Finishes when the connection closes; throws on transport error.
    func events() -> AsyncThrowingStream<StrimEvent, Error>
    func load(_ request: LoadRequest) async throws
    func unload() async throws
    func jobs() async throws -> [JobSummary]
    func job(id: String) async throws -> JobDetail
    func approve(_ approval: PatchApproval) async throws
    func chatOpen(_ request: ChatOpenRequest) async throws -> ChatSession
    func chatAppend(_ request: ChatAppendRequest) async throws
    func chatCancel(_ request: ChatCancelRequest) async throws
}
