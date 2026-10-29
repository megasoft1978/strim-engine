import Foundation
import StrimEngine

/// How a run is driven. The ONLY difference between a delegated MCP job and an interactive chat session:
/// same loop, same tool set (`ToolCatalog`), same prompt pack, same sandbox.
public struct RunProfile: Sendable, Equatable {
    public var name: String
    /// Default and maximum assistant steps (model generations) per run, or per user turn in a chat.
    public var maxTurns: Int
    /// Default and maximum wall-clock seconds per run / per user turn.
    public var maxSeconds: TimeInterval
    public var maxGeneratedTokens: Int
    public var priority: Priority
    /// The caller's verify command is required and run by the harness after the loop.
    public var verifyRequired: Bool
    /// Assistant text and reasoning are streamed to the client as they are produced (after redaction).
    public var streamsDeltas: Bool
    /// Changes are shown to the user as a patch and only applied by an explicit approval; never auto-applied.
    public var patchApproval: Bool

    public init(name: String, maxTurns: Int, maxSeconds: TimeInterval, maxGeneratedTokens: Int, priority: Priority,
                verifyRequired: Bool, streamsDeltas: Bool, patchApproval: Bool) {
        self.name = name; self.maxTurns = maxTurns; self.maxSeconds = maxSeconds
        self.maxGeneratedTokens = maxGeneratedTokens; self.priority = priority
        self.verifyRequired = verifyRequired; self.streamsDeltas = streamsDeltas; self.patchApproval = patchApproval
    }

    /// MCP / background jobs: 40 turns, 15 min, background priority, verify required.
    public static let delegated = RunProfile(name: "delegated", maxTurns: 40, maxSeconds: 900, maxGeneratedTokens: 60_000,
                                             priority: .background, verifyRequired: true, streamsDeltas: false,
                                             patchApproval: false)
    /// Chat: 80 turns and 30 min per user turn, interactive priority, streaming deltas, patch approval.
    public static let interactive = RunProfile(name: "interactive", maxTurns: 80, maxSeconds: 1800, maxGeneratedTokens: 120_000,
                                               priority: .interactive, verifyRequired: false, streamsDeltas: true,
                                               patchApproval: true)

    /// Profile by wire name (`ChatOpenRequest.profile`).
    public static func named(_ name: String) -> RunProfile? {
        switch name {
        case "delegated": return .delegated
        case "interactive": return .interactive
        default: return nil
        }
    }

    /// Limits for a run. The untouched default `HarnessLimits()` means "use the profile"; anything else is clamped to
    /// the profile ceilings (a caller can ask for less, never more).
    public func limits(requested: HarnessLimits = HarnessLimits()) -> HarnessLimits {
        var l = requested
        if requested == HarnessLimits() {
            l.maxTurns = maxTurns; l.maxSeconds = maxSeconds; l.maxGeneratedTokens = maxGeneratedTokens
        } else {
            l.maxTurns = min(requested.maxTurns, maxTurns)
            l.maxSeconds = min(requested.maxSeconds, maxSeconds)
            l.maxGeneratedTokens = min(requested.maxGeneratedTokens, maxGeneratedTokens)
        }
        return l
    }
}

// MARK: - Chat events

/// A patch produced by a chat turn (against the session base), ready for review.
public struct ChatPatch: Sendable, Equatable {
    public var userTurn: Int
    /// Inline when at most `HarnessRunner.maxInlinePatchBytes`, otherwise nil (read `patchPath`).
    public var patch: String?
    public var patchPath: String?
    public var filesChanged: [FileChange]
    public init(userTurn: Int, patch: String?, patchPath: String?, filesChanged: [FileChange]) {
        self.userTurn = userTurn; self.patch = patch; self.patchPath = patchPath; self.filesChanged = filesChanged
    }
}

public struct ChatTurnResult: Sendable, Equatable {
    public var userTurn: Int
    public var status: HarnessStatus
    /// Final assistant text or finish summary, redacted, at most 1.5K chars.
    public var summary: String
    /// Tokens spent by this user turn.
    public var usage: HarnessUsage
    /// Tokens spent by the whole session so far.
    public var totalUsage: HarnessUsage
    public init(userTurn: Int, status: HarnessStatus, summary: String, usage: HarnessUsage, totalUsage: HarnessUsage) {
        self.userTurn = userTurn; self.status = status; self.summary = summary
        self.usage = usage; self.totalUsage = totalUsage
    }
}

/// Neutral stream of one chat turn (StrimHarness does not know StrimAPI; see docs/CHAT-CORE.md for the mapping).
/// Every string has been redacted; tool summaries are truncated. The stream ends right after `turnFinished`.
public enum ChatEvent: Sendable, Equatable {
    /// An assistant step (one model generation) begins.
    case stepStarted(Int)
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallStarted(name: String, summary: String)
    case toolCallFinished(name: String, summary: String, isError: Bool)
    /// Per generation token usage.
    case usage(promptTokens: Int, cachedTokens: Int, completionTokens: Int)
    /// Context was compacted into a fresh engine session (transcript prefix restarts).
    case compaction(String)
    /// A per-turn limit (steps, time, tokens, repeated calls) ended the turn.
    case limit(String)
    case patchReady(ChatPatch)
    case turnFinished(ChatTurnResult)
}

/// Typed failures of the chat session API. `code` is the stable wire name.
public enum ChatError: Error, Equatable, Sendable {
    case sessionNotFound(String)
    /// A turn is already running; turns are rejected, not queued.
    case turnInProgress
    case sessionClosed
    case idleTimeout
    case maxSessions(Int)
    case emptyText
    case textTooLong(Int)
    case openFailed(String)
    case unknownProfile(String)

    public var code: String {
        switch self {
        case .sessionNotFound: "session_not_found"
        case .turnInProgress: "turn_in_progress"
        case .sessionClosed: "session_closed"
        case .idleTimeout: "idle_timeout"
        case .maxSessions: "max_sessions"
        case .emptyText: "empty_text"
        case .textTooLong: "text_too_long"
        case .openFailed: "open_failed"
        case .unknownProfile: "unknown_profile"
        }
    }
}

public enum ChatLimits {
    public static let maxUserTextChars = 32_000
    public static let defaultMaxSessions = 2
    public static let defaultIdleTimeout: TimeInterval = 1800
    public static let summaryChars = 800
}

// MARK: - Redaction of streamed text

/// Redacts a stream split into arbitrary deltas. Text is released only up to a safe cut (a newline, or whitespace
/// when no secret-looking keyword precedes it), so a secret split across deltas, or a `Bearer <token>` / `password = x`
/// pair split at the space, is redacted as a whole. Unterminated PEM blocks are held back entirely.
struct StreamRedactor {
    private(set) var pending = ""
    static let holdChars = 4200
    static let forceAfter = 8192
    static let pemCap = 65_536
    private static let triggers = ["bearer", "password", "passwd", "secret", "api_key", "api-key", "apikey", "token", "://",
                                   "-----begin", "eyj", "authorization", "credential"]

    mutating func push(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        pending += s
        return drain()
    }

    mutating func flush() -> String {
        defer { pending = "" }
        return pending.isEmpty ? "" : Redactor.redact(pending)
    }

    private mutating func drain() -> String {
        let low = pending.lowercased()
        if let b = low.range(of: "-----begin"), low.range(of: "-----end", range: b.upperBound..<low.endIndex) == nil {
            if pending.count < Self.pemCap { return "" }
            pending = ""
            return Redactor.redact("-----BEGIN PRIVATE KEY-----")
        }
        guard let cut = cutIndex() else { return "" }
        let head = String(pending[..<cut])
        pending = String(pending[cut...])
        return Redactor.redact(head)
    }

    private func cutIndex() -> String.Index? {
        if let ws = pending.lastIndex(where: { $0.isWhitespace }) {
            let end = pending.index(after: ws)
            let window = pending[..<end].suffix(256).lowercased()
            if !Self.triggers.contains(where: { window.contains($0) }) { return end }
            if let nl = pending.lastIndex(of: "\n") { return pending.index(after: nl) }
        }
        guard pending.count > Self.forceAfter else { return nil }
        // Pathological single line: keep the last `holdChars` characters, cut at whitespace before that.
        let limit = pending.index(pending.endIndex, offsetBy: -Self.holdChars)
        if let ws = pending[..<limit].lastIndex(where: { $0.isWhitespace }) { return pending.index(after: ws) }
        return limit
    }
}

/// Maps loop events to `ChatEvent`s: redacts and truncates everything that leaves the process.
final class ChatEventMapper: @unchecked Sendable {
    static let summaryChars = ChatLimits.summaryChars
    private let lock = NSLock()
    private var text = StreamRedactor()
    private var reasoning = StreamRedactor()
    private let streamsDeltas: Bool
    /// Assistant text emitted since the last tool call (or the start of the turn).
    private var textSinceTool = false

    init(streamsDeltas: Bool) { self.streamsDeltas = streamsDeltas }

    func map(_ e: HarnessEvent) -> [ChatEvent] {
        lock.withLock {
            switch e {
            case let .textDelta(t):
                guard streamsDeltas else { return [] }
                let o = text.push(t)
                if !o.isEmpty { textSinceTool = true }
                return o.isEmpty ? [] : [.textDelta(o)]
            case let .reasoningDelta(t):
                guard streamsDeltas else { return [] }
                let o = reasoning.push(t)
                return o.isEmpty ? [] : [.reasoningDelta(o)]
            default:
                var out = flushLocked()
                switch e {
                case let .turn(n): out.append(.stepStarted(n))
                case let .toolCall(name, args):
                    if name != "finish" { textSinceTool = false }
                    out.append(.toolCallStarted(name: Self.name(name), summary: Self.summary("\(name) \(args)")))
                case let .toolResult(name, output, isError):
                    if name == "_compaction" { out.append(.compaction(Self.summary(output))) } else {
                        out.append(.toolCallFinished(name: Self.name(name), summary: Self.summary(output, keepNewlines: true), isError: isError))
                    }
                case let .usage(u): out.append(.usage(promptTokens: u.promptTokens, cachedTokens: u.cachedTokens,
                                                      completionTokens: u.completionTokens))
                case .approval, .finished, .textDelta, .reasoningDelta: break
                }
                return out
            }
        }
    }

    /// A turn that ended through `finish` (or a non-streaming reply) has no assistant text on the wire: the closing summary is the answer.
    func closingText(status: HarnessStatus, summary: String) -> String? {
        lock.withLock { (status == .done || status == .declined) && !textSinceTool && !summary.isEmpty ? summary : nil }
    }

    /// Releases held-back text (call before the turn's closing events).
    func flush() -> [ChatEvent] { lock.withLock { flushLocked() } }

    private func flushLocked() -> [ChatEvent] {
        var out: [ChatEvent] = []
        let r = reasoning.flush()
        if !r.isEmpty { out.append(.reasoningDelta(r)) }
        let t = text.flush()
        if !t.isEmpty { out.append(.textDelta(t)); textSinceTool = true }
        return out
    }

    static func name(_ s: String) -> String { Compaction.sanitize(s, max: 80) }

    /// Redact first, then flatten (tool output keeps its line breaks) and clip (a secret cut by the clip cannot leak a prefix).
    static func summary(_ s: String, keepNewlines: Bool = false) -> String {
        let red = Redactor.redact(s)
        let flat = keepNewlines ? red : red.replacingOccurrences(of: "\n", with: " ")
        return flat.count > summaryChars ? String(flat.prefix(summaryChars)) + "…" : flat
    }
}
