import Foundation
import StrimPrompt
import StrimTemplate

/// Location-transparent engine API. Everything crossing it is a Sendable value (ids, strings,
/// small structs), so the same protocol can later be served by a launchd host over IPC.

public struct SessionID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
    public var description: String { "s\(raw)" }
}

public enum Priority: Int, Sendable, Comparable {
    case interactive = 0
    case background = 1
    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

public struct SessionConfig: Sendable {
    public var tools: [ToolSpec]
    public var reasoningPolicy: ReasoningPolicy
    public var enableThinking: Bool?
    public var toolChoice: String?
    public var reasoningEffort: String?
    public var preserveThinking: Bool?
    public init(tools: [ToolSpec] = [], reasoningPolicy: ReasoningPolicy = .disableWhenTools,
                enableThinking: Bool? = nil, toolChoice: String? = nil,
                reasoningEffort: String? = nil, preserveThinking: Bool? = nil) {
        self.tools = tools; self.reasoningPolicy = reasoningPolicy; self.enableThinking = enableThinking
        self.toolChoice = toolChoice; self.reasoningEffort = reasoningEffort
        self.preserveThinking = preserveThinking
    }
}

public enum TurnInput: Sendable {
    /// New messages appended to the session's conversation (the engine keeps the history,
    /// including the assistant turns it generated).
    case messages([Message])
    /// The client's full message list (OpenAI-style resend); reconciled against the ledger.
    case history([Message])
    /// Raw token ids appended verbatim (no template, no ledger records).
    case ids([Int32])
}

public struct GenParams: Sendable {
    public var maxTokens: Int
    public var temperature: Float
    public var topP: Float
    public var topK: Int
    public var seed: UInt64?
    public var stopIds: [Int32]
    public var priority: Priority
    /// Do not stop on the model's default end tokens (`<|im_end|>`, `<|endoftext|>`); only `stopIds` stop.
    public var ignoreEOS: Bool
    /// Constrained decoding (structured output, forced tool calls) and the reasoning budget. nil: plain decode, zero overhead.
    public var constraint: ConstraintSpec?
    public init(maxTokens: Int = 256, temperature: Float = 0, topP: Float = 1, topK: Int = 0,
                seed: UInt64? = nil, stopIds: [Int32] = [], priority: Priority = .interactive,
                ignoreEOS: Bool = false, constraint: ConstraintSpec? = nil) {
        self.constraint = constraint
        self.maxTokens = maxTokens; self.temperature = temperature; self.topP = topP; self.topK = topK
        self.seed = seed; self.stopIds = stopIds; self.priority = priority; self.ignoreEOS = ignoreEOS
    }
    public var isGreedy: Bool { temperature <= 0 }
}

public enum FinishReason: String, Sendable {
    case stop, length, cancelled
}

public struct Usage: Sendable {
    public var promptTokens = 0
    /// Prompt tokens served from hot session state or the prefix trie.
    public var cachedTokens = 0
    public var completionTokens = 0
    /// Fraction of MTP drafts accepted during this request (nil: no MTP rounds ran).
    public var mtpAccept: Double?
    /// Verify rounds run for this request (0 without MTP).
    public var mtpPasses = 0
    /// Request arrival -> first generated token.
    public var ttft: Double = 0
    public var prefillSeconds: Double = 0
    public var decodeSeconds: Double = 0
    public init() {}
}

public enum GenEvent: Sendable {
    /// Generated ids of one decode unit (stop token excluded) and the content text they added
    /// (reasoning and tool-call syntax are routed out of `text` into the events below).
    case tokens([Int32], String)
    case reasoning(String)
    case toolCallBegin(name: String)
    case toolCallArg(key: String, value: OrderedJSON)
    case toolCallEnd
    /// The model produced an incomplete tool-call envelope; no call was accepted.
    case toolCallError(String)
    case finished(FinishReason, Usage)
}

public struct LedgerSnapshot: Sendable {
    public var ids: [Int32]
    public var messageCount: Int
    /// nil for sessions driven with raw `.ids`.
    public var ledger: Ledger?
    public init(ids: [Int32], messageCount: Int, ledger: Ledger? = nil) {
        self.ids = ids; self.messageCount = messageCount; self.ledger = ledger
    }
}

public struct EngineStats: Sendable {
    public var healthy = true
    public var unhealthyReason: String?
    public var lastHeartbeat = Date()
    public var unitsRun = 0
    public var activeRequests = 0
    public var sessions = 0
    public var hotSessions = 0
    public var trieBytes = 0
    public var trieNodes = 0
    public var trieEvictions = 0
    public var mlxActiveBytes = 0
    public var mlxCacheBytes = 0
    public var mlxPeakBytes = 0
    public var footprintBytes = 0
    public var trieThinned = 0
    public var pressureTrims = 0
    public var admittedBytes = 0
    public var budgetBytes = 0
    public init() {}
}

public enum EngineError: Error, CustomStringConvertible, Sendable {
    case unhealthy(String)
    case insufficientMemory(needed: Int, available: Int)
    case unknownSession(SessionID)
    case busy(SessionID)
    case badInput(String)
    case mlx(String)
    case shutdown

    public var description: String {
        switch self {
        case let .unhealthy(r): return "engine unhealthy: \(r)"
        case let .insufficientMemory(n, a):
            return "insufficient memory: request needs \(n >> 20) MB, \(max(a, 0) >> 20) MB available under the admission budget"
        case let .unknownSession(s): return "unknown session \(s)"
        case let .busy(s): return "session \(s) has a generation in flight"
        case let .badInput(m): return "bad input: \(m)"
        case let .mlx(m): return "MLX error: \(m)"
        case .shutdown: return "engine shut down"
        }
    }
}

public protocol EngineClient: Sendable {
    func openSession(_ config: SessionConfig) async throws -> SessionID
    /// New session sharing the first `messageCount` messages (nil: all) of `session`'s ledger.
    func fork(_ session: SessionID, at messageCount: Int?) async throws -> SessionID
    /// Adds input to the session; returns the ledger length in ids afterwards.
    func append(_ session: SessionID, _ input: TurnInput) async throws -> Int
    /// Starts generating from the session's current ledger. Errors arrive as stream failures.
    func generate(_ session: SessionID, _ params: GenParams) -> AsyncThrowingStream<GenEvent, Error>
    /// Cancels the session's in-flight generation (it finishes with `.cancelled`).
    func cancel(_ session: SessionID) async
    /// Prefills `ids` into the prefix trie without generating.
    func prefetch(_ ids: [Int32], priority: Priority) async throws
    func ledger(_ session: SessionID) async throws -> LedgerSnapshot
    func close(_ session: SessionID) async
    func stats() -> EngineStats
}
