import Foundation
import StrimEngine
import StrimTemplate

// Interfaces for the agent harness (see docs/PLAN-AGENT-HARNESS-2026-10-26.md). Declarations only;
// the loop, tools, sandbox runner and worktree isolation land in W1.

/// What a job may do to the workspace. Enforced at run time, not by changing the tool list
/// (the tool schemas stay byte-identical so the prefix cache is stable).
public enum AccessLevel: String, Sendable, Codable {
    case read, write
}

/// Result of one tool call, fed back to the model as a `.tool` message.
public struct ToolResult: Sendable, Equatable {
    public var output: String
    public var isError: Bool
    /// Set by the `finish` tool: ends the loop with this summary.
    public var finishSummary: String?
    public init(output: String, isError: Bool = false, finishSummary: String? = nil) {
        self.output = output; self.isError = isError; self.finishSummary = finishSummary
    }
}

/// Per-call environment handed to a tool.
public struct ToolContext: Sendable {
    /// Workspace root every file path must stay inside.
    public var root: String
    public var access: AccessLevel
    public init(root: String, access: AccessLevel) { self.root = root; self.access = access }
}

/// One tool the model can call (`read_file`, `list_files`, `grep`, `edit_file`, `write_file`, `bash`, `finish`).
public protocol HarnessTool: Sendable {
    var name: String { get }
    /// Tool description plus JSON-schema parameters, in the form the chat template renders.
    var spec: ToolSpec { get }
    func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult
}

public struct CommandOutput: Sendable, Equatable {
    public var exitCode: Int32
    /// Combined stdout/stderr, truncated to the requested cap.
    public var output: String
    public var timedOut: Bool
    public var truncated: Bool
    public init(exitCode: Int32, output: String, timedOut: Bool = false, truncated: Bool = false) {
        self.exitCode = exitCode; self.output = output; self.timedOut = timedOut; self.truncated = truncated
    }
}

/// Runs a shell command (sandboxed in the real implementation); cancellation kills the process group.
public protocol CommandRunner: Sendable {
    func run(_ command: String, cwd: String, env: [String: String],
             timeout: TimeInterval, outputCap: Int) async throws -> CommandOutput
}

/// A prepared working copy for one job.
public struct Workspace: Sendable, Equatable {
    public var root: String
    /// Base revision the patch is relative to (git commit, or a snapshot id for non-git trees).
    public var base: String
    public init(root: String, base: String) { self.root = root; self.base = base }
}

/// Isolates a job from the parent tree (git worktree, or APFS clone for non-git dirs).
public protocol WorkspaceIsolation: Sendable {
    func prepare(cwd: String, access: AccessLevel, files: [String]) async throws -> Workspace
    /// Unified diff of the workspace against its base.
    func collectPatch(_ workspace: Workspace) async throws -> String
    func cleanup(_ workspace: Workspace) async
    /// Host-side facts about the workspace after `collectPatch`, for judging how far `verify` can be trusted.
    /// nil when the isolation cannot say (the runner then falls back to parsing the patch headers).
    func integrityScan(_ workspace: Workspace) async throws -> WorkspaceIntegrity?
}

public extension WorkspaceIsolation {
    func integrityScan(_ workspace: Workspace) async throws -> WorkspaceIntegrity? { nil }
}

/// What the agent left in the workspace, read by git on the host (NUL-separated, never from patch text).
public struct WorkspaceIntegrity: Sendable, Equatable {
    /// Every path the patch changes, both sides of renames and copies.
    public var changedPaths: [String]
    /// Files present in the workspace but absent from the patch (gitignored), collapsed to directories where possible.
    public var ignoredPaths: [String]
    /// Parsing failed or a path was odd (non-UTF8, control characters, absolute, `..`, `.git`): fail closed.
    public var suspicious: Bool
    public init(changedPaths: [String] = [], ignoredPaths: [String] = [], suspicious: Bool = false) {
        self.changedPaths = changedPaths; self.ignoredPaths = ignoredPaths; self.suspicious = suspicious
    }
}

public struct HarnessLimits: Sendable, Equatable {
    public var maxTurns = 40
    public var maxSeconds: TimeInterval = 900
    public var maxGeneratedTokens = 60_000
    /// Abort after this many identical consecutive tool calls.
    public var maxRepeatedCalls = 3
    /// Abort after this many consecutive tool errors.
    public var maxConsecutiveErrors = 5
    public init() {}
}

/// Progress stream for the UI, `events.jsonl` and the trajectory.
public enum HarnessEvent: Sendable {
    case turn(Int)
    case textDelta(String)
    case reasoningDelta(String)
    case toolCall(name: String, args: String)
    case toolResult(name: String, output: String, isError: Bool)
    /// A command or write waiting for user approval (`requireApproval`).
    case approval(command: String)
    case usage(Usage)
    case finished(HarnessStatus)
}

/// Terminal outcome of a harness run.
public enum HarnessStatus: String, Sendable, Codable {
    case done, failed, cancelled, limit
    /// The model refused the task up front (`finish` with `declined: true`).
    case declined
}

/// Outcome of the harness-run `verify` command.
public enum VerifyStatus: String, Sendable, Codable {
    case verified, failed, unverified
    /// The command passed, but the patch edits files it relies on (tests, build config, scripts): not proof.
    case verifiedModifiedTests = "verified_modified_tests"
}

/// The harness runs the job's `verify` command itself, after the loop and before the patch is collected.
public struct VerifyResult: Sendable, Equatable, Codable {
    public static let maxTailChars = 600
    public var status: VerifyStatus
    public var exitCode: Int32?
    /// Last `maxTailChars` chars of the (redacted) output.
    public var outputTail: String
    /// Up to `maxTouchedPaths` integrity-sensitive paths the patch touches (see `HarnessRunner.sensitivePaths`).
    public var touchedSensitive: [String]
    public static let maxTouchedPaths = 5
    public init(status: VerifyStatus = .unverified, exitCode: Int32? = nil, outputTail: String = "",
                touchedSensitive: [String] = []) {
        self.status = status; self.exitCode = exitCode; self.outputTail = outputTail
        self.touchedSensitive = touchedSensitive
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(VerifyStatus.self, forKey: .status)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        outputTail = try c.decodeIfPresent(String.self, forKey: .outputTail) ?? ""
        touchedSensitive = try c.decodeIfPresent([String].self, forKey: .touchedSensitive) ?? []
    }
    public static let unverified = VerifyResult()
}

public struct HarnessJobSpec: Sendable {
    public var task: String
    /// Absolute path of the parent project.
    public var cwd: String
    public var context: String?
    public var files: [String]
    public var access: AccessLevel
    public var limits: HarnessLimits
    /// Shell command the harness runs in the workspace after the loop (exit 0 = verified). Never agent-controlled.
    public var verify: String?
    public init(task: String, cwd: String, context: String? = nil, files: [String] = [],
                access: AccessLevel = .read, limits: HarnessLimits = HarnessLimits(), verify: String? = nil) {
        self.task = task; self.cwd = cwd; self.context = context; self.files = files
        self.access = access; self.limits = limits; self.verify = verify
    }
}

public struct FileChange: Sendable, Equatable, Codable {
    public var path: String
    public var added: Int
    public var removed: Int
    public init(path: String, added: Int, removed: Int) { self.path = path; self.added = added; self.removed = removed }
}

public struct CommandRecord: Sendable, Equatable, Codable {
    public var cmd: String
    public var exit: Int32
    public init(cmd: String, exit: Int32) { self.cmd = cmd; self.exit = exit }
}

public struct HarnessUsage: Sendable, Equatable, Codable {
    public var promptTokens = 0
    public var cachedTokens = 0
    public var completionTokens = 0
    public var turns = 0
    public var seconds: Double = 0
    public init() {}
}

public struct HarnessJobResult: Sendable, Equatable {
    public var status: HarnessStatus
    /// At most 1.5K chars.
    public var summary: String
    public var filesChanged: [FileChange]
    /// Inline patch, at most 16 KB; the full patch is at `patchPath`.
    public var patch: String?
    public var patchPath: String?
    public var base: String?
    public var commands: [CommandRecord]
    public var usage: HarnessUsage
    public var verify: VerifyResult
    public init(status: HarnessStatus, summary: String, filesChanged: [FileChange] = [], patch: String? = nil,
                patchPath: String? = nil, base: String? = nil, commands: [CommandRecord] = [],
                usage: HarnessUsage = HarnessUsage(), verify: VerifyResult = .unverified) {
        self.status = status; self.summary = summary; self.filesChanged = filesChanged; self.patch = patch
        self.patchPath = patchPath; self.base = base; self.commands = commands; self.usage = usage
        self.verify = verify
    }
}
