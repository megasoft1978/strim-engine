import Foundation
import StrimHarness

// Async job management: states, snapshots, persistence and the manager protocol.

public typealias JobID = String

public enum JobStatus: String, Sendable, Codable {
    case queued, preparing, running
    /// Interactive chat took the engine; the background job resumes afterwards.
    case pausedInteractive = "paused_interactive"
    case awaitingApproval = "awaiting_approval"
    case finalizing
    case done, failed, cancelled, limit
    /// The model refused the task up front.
    case declined

    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled, .limit, .declined: return true
        default: return false
        }
    }
}

public enum JobPriority: String, Sendable, Codable {
    case normal
    /// Short `strim_ask`-style jobs jump ahead of queued normal jobs (never preempt a running one).
    case quick
}

public enum JobError: Error, Equatable, Sendable {
    case notFound(String)
    case notAwaitingApproval(String)
    /// Too many unfinished jobs (`JobManager.maxPending`); retry after some finish.
    case queueFull(limit: Int)
}

extension JobError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let id): return "notFound(\"\(id)\")"
        case .notAwaitingApproval(let id): return "notAwaitingApproval(\"\(id)\")"
        case .queueFull(let limit): return "job queue is full (\(limit) unfinished jobs); retry after some finish"
        }
    }
}

/// Well-known failure reasons surfaced on `JobSnapshot.reason`.
public enum JobFailureReason {
    public static let insufficientMemory = "insufficient_memory"
    public static let hostRestart = "host_restart"
    /// A chat session was closed after sitting idle past its timeout.
    public static let idleTimeout = "idle_timeout"
}

/// Minimal progress for polling; the MCP layer renders it as one line.
public struct JobProgress: Sendable, Equatable, Codable {
    public var turn: Int
    public var maxTurns: Int
    /// Active wall-clock seconds since the job started running, including paused time.
    public var elapsedS: Double
    public var pausedS: Double
    /// Last 5 tool steps, short.
    public var lastSteps: [String]
    public init(turn: Int = 0, maxTurns: Int = 0, elapsedS: Double = 0, pausedS: Double = 0, lastSteps: [String] = []) {
        self.turn = turn; self.maxTurns = maxTurns; self.elapsedS = elapsedS; self.pausedS = pausedS
        self.lastSteps = lastSteps
    }
}

/// Snapshot of a job as reported by `strim_job`.
public struct JobSnapshot: Sendable {
    public var id: JobID
    public var status: JobStatus
    public var spec: HarnessJobSpec
    public var progress: JobProgress
    /// Present once the status is terminal.
    public var result: HarnessJobResult?
    /// Failure reason for failed jobs (`insufficient_memory`, `host_restart`, ...).
    public var reason: String?
    /// Chat sessions only: the run profile name (`interactive`); nil for delegated jobs.
    public var profile: String?
    /// Chat sessions only: a user turn is running.
    public var turnActive: Bool
    /// Chat sessions only: last turn start or end (the idle timeout counts from here).
    public var lastActivityAt: Date?
    public init(id: JobID, status: JobStatus, spec: HarnessJobSpec, progress: JobProgress = JobProgress(),
                result: HarnessJobResult? = nil, reason: String? = nil, profile: String? = nil,
                turnActive: Bool = false, lastActivityAt: Date? = nil) {
        self.id = id; self.status = status; self.spec = spec; self.progress = progress
        self.result = result; self.reason = reason; self.profile = profile
        self.turnActive = turnActive; self.lastActivityAt = lastActivityAt
    }
}

/// One mirrored harness event (`events.jsonl`). Text deltas are not recorded.
public struct JobEvent: Sendable, Equatable, Codable {
    public var index: Int
    public var kind: String
    public var text: String
    public init(index: Int, kind: String, text: String) { self.index = index; self.kind = kind; self.text = text }
}

/// Codable form of `HarnessJobResult`.
public struct JobRecordResult: Sendable, Equatable, Codable {
    public var status: HarnessStatus
    public var summary: String
    public var filesChanged: [FileChange]
    public var patch: String?
    public var patchPath: String?
    public var base: String?
    public var commands: [CommandRecord]
    public var usage: HarnessUsage
    /// Absent in records written before verify existed.
    public var verify: VerifyResult?
}

/// What is persisted in `job.json`. All strings are redacted before they get here.
public struct JobRecord: Sendable, Equatable, Codable {
    public var id: JobID
    public var status: JobStatus
    public var priority: JobPriority
    public var task: String
    public var cwd: String
    public var context: String?
    public var files: [String]
    public var access: AccessLevel
    /// Redacted verify command (absent in older records).
    public var verify: String?
    public var maxTurns: Int
    public var maxSeconds: Double
    public var maxGeneratedTokens: Int
    public var maxRepeatedCalls: Int
    public var maxConsecutiveErrors: Int
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var pausedS: Double
    public var turn: Int
    public var lastSteps: [String]
    public var reason: String?
    public var result: JobRecordResult?
    /// Chat sessions: run profile name. Absent for delegated jobs and in older records.
    public var profile: String?
}

/// Persistence under `~/.strim/jobs/<id>/` (job.json, events.jsonl).
public protocol JobStore: Sendable {
    func save(_ record: JobRecord) async throws
    func load(_ id: JobID) async throws -> JobRecord?
    func list() async throws -> [JobRecord]
    func remove(_ id: JobID) async throws
    func appendEvent(_ id: JobID, _ event: JobEvent) async throws
    func events(_ id: JobID) async throws -> [JobEvent]
}

public protocol JobManaging: Sendable {
    /// Queues a job; returns immediately.
    func submit(_ spec: HarnessJobSpec, priority: JobPriority) async throws -> JobID
    /// Waits up to `waitS` seconds (clamped 0-25) for a terminal status, then returns the current snapshot.
    func status(_ id: JobID, waitS: Double) async throws -> JobSnapshot
    func cancel(_ id: JobID) async throws -> JobSnapshot
    /// Events with `index >= index`.
    func eventsSince(_ id: JobID, index: Int) async throws -> [JobEvent]
    func approve(_ id: JobID) async throws
    func reject(_ id: JobID) async throws
}

public extension JobManaging {
    func start(_ spec: HarnessJobSpec) async throws -> JobID { try await submit(spec, priority: .normal) }
}

/// Runs chat sessions for the manager. Production: `HarnessRunner` (see `HarnessRunner+ChatBackend`).
public protocol ChatBackend: Sendable {
    func openSession(spec: HarnessJobSpec, sessionID: String, profile: RunProfile) async throws
    func appendUserTurn(sessionID: String, text: String) async throws -> AsyncStream<ChatEvent>
    /// Returns once the turn has fully stopped (engine generation cancelled).
    func cancelTurn(sessionID: String) async
    /// Closes the session exactly once; nil when unknown or already closing.
    func closeSession(sessionID: String) async -> HarnessJobResult?
}

extension HarnessRunner: ChatBackend {}
