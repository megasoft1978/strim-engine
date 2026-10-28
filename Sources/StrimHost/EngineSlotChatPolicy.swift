import Foundation
import StrimHarness
import StrimJobs

/// A chat open refused by the host policy (`mcp.allowedRoots`, `mcp.maxAccess` in `~/.strim/config.json`).
public struct ChatForbidden: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    /// Prefix `forbidden: ` is how the control API recognises it after `JobManager` wraps backend failures.
    public var description: String { "forbidden: \(message)" }
}

/// Applies the same `HostPolicy` as MCP task submission before any chat session (and so any worktree) exists.
/// A session's cwd and access are fixed at open: the backend API has no way to change them on a later turn, and
/// this wrapper adds none. `requireApproval` has no effect on chat: the user is the app, and patches are applied
/// only by explicit approval anyway.
public struct PolicyCheckedChatBackend: ChatBackend {
    public let inner: any ChatBackend
    public let policy: HostPolicy
    public init(inner: any ChatBackend, policy: HostPolicy) { self.inner = inner; self.policy = policy }

    public func openSession(spec: HarnessJobSpec, sessionID: String, profile: RunProfile) async throws {
        if let v = policy.violation(access: spec.access.rawValue, cwd: spec.cwd) { throw ChatForbidden(v) }
        try await inner.openSession(spec: spec, sessionID: sessionID, profile: profile)
    }
    public func appendUserTurn(sessionID: String, text: String) async throws -> AsyncStream<ChatEvent> {
        try await inner.appendUserTurn(sessionID: sessionID, text: text)
    }
    public func cancelTurn(sessionID: String) async { await inner.cancelTurn(sessionID: sessionID) }
    public func closeSession(sessionID: String) async -> HarnessJobResult? { await inner.closeSession(sessionID: sessionID) }
}
