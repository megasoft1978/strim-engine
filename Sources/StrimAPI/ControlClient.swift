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
    /// Ends a host session (its worktree patch then appears in Jobs). Frees a `max_sessions` slot.
    func chatClose(sessionID: String) async throws
    // Product additions. Defaults throw `not_implemented` so older conformers keep compiling.
    func pauseJobs(_ request: PauseRequest) async throws -> JobsPauseState
    func resumeJobs() async throws -> JobsPauseState
    func cancelJob(_ request: JobCancelRequest) async throws -> JobCancelResult
    func models() async throws -> ModelList
    func pack() async throws -> PackInfo
}

public extension StrimControlClient {
    func chatClose(sessionID: String) async throws { throw APIError(code: "not_implemented", message: "chat close") }
    func pauseJobs(_ request: PauseRequest) async throws -> JobsPauseState { throw APIError(code: "not_implemented", message: "pause") }
    func resumeJobs() async throws -> JobsPauseState { throw APIError(code: "not_implemented", message: "resume") }
    func cancelJob(_ request: JobCancelRequest) async throws -> JobCancelResult { throw APIError(code: "not_implemented", message: "cancel") }
    func models() async throws -> ModelList { throw APIError(code: "not_implemented", message: "models") }
    func pack() async throws -> PackInfo { throw APIError(code: "not_implemented", message: "pack") }
}
