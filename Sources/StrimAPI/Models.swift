import Foundation

/// Control-API data contract shared by the daemon (StrimControl) and clients (StrimApp).
/// JSON keys are stable snake_case, fixed by explicit CodingKeys. Do not rename without bumping `StrimRoutes.apiVersion`.

/// Lifecycle of the engine host.
public enum HostState: String, Codable, Sendable, Equatable, CaseIterable {
    case stopped, loading, ready, busy, error
}

/// Memory breakdown in GiB.
public struct MemoryStats: Codable, Sendable, Equatable {
    public var weightsGB: Double
    public var prefixTrieGB: Double
    public var mlxCacheGB: Double
    public var headroomGB: Double
    public init(weightsGB: Double, prefixTrieGB: Double, mlxCacheGB: Double, headroomGB: Double) {
        self.weightsGB = weightsGB; self.prefixTrieGB = prefixTrieGB
        self.mlxCacheGB = mlxCacheGB; self.headroomGB = headroomGB
    }
    enum CodingKeys: String, CodingKey {
        case weightsGB = "weights_gb", prefixTrieGB = "prefix_trie_gb"
        case mlxCacheGB = "mlx_cache_gb", headroomGB = "headroom_gb"
    }
}

/// Snapshot of host health and throughput. Optional fields are omitted from JSON when nil.
public struct HostStatus: Codable, Sendable, Equatable {
    public var state: HostState
    /// Loaded model identifier (nil when stopped).
    public var model: String?
    /// MTP head identifier (nil when none).
    public var mtp: String?
    /// 0...1 while `state == .loading`.
    public var loadProgress: Double?
    public var memory: MemoryStats
    public var decodeTPS: Double
    public var prefillTPS: Double
    public var mtpAcceptance: Double
    public var mtpDepth: Double
    public var prefixHitRate: Double
    public var savedPrefillSeconds: Double
    public var activeJobs: Int
    public var queuedJobs: Int
    public var tokensToday: Int
    public var localTokensGenerated: Int
    public var uptimeSeconds: Double
    public var lastCrash: String?
    /// Estimate only; UI must label it as such.
    public var parentTokensSavedEstimate: Int?
    /// Background jobs are paused (`POST pause`). Nil from hosts that predate the pause route.
    public var jobsPaused: Bool?
    /// Hash of the loaded model's per-tensor quantization specs (`<model>/<head>`); nil when stopped or from older hosts.
    public var quantFingerprint: String?
    public init(state: HostState, model: String? = nil, mtp: String? = nil, loadProgress: Double? = nil,
                memory: MemoryStats, decodeTPS: Double = 0, prefillTPS: Double = 0, mtpAcceptance: Double = 0,
                mtpDepth: Double = 0, prefixHitRate: Double = 0, savedPrefillSeconds: Double = 0,
                activeJobs: Int = 0, queuedJobs: Int = 0, tokensToday: Int = 0, localTokensGenerated: Int = 0,
                uptimeSeconds: Double = 0, lastCrash: String? = nil, parentTokensSavedEstimate: Int? = nil,
                jobsPaused: Bool? = nil, quantFingerprint: String? = nil) {
        self.quantFingerprint = quantFingerprint
        self.state = state; self.model = model; self.mtp = mtp; self.loadProgress = loadProgress
        self.memory = memory; self.decodeTPS = decodeTPS; self.prefillTPS = prefillTPS
        self.mtpAcceptance = mtpAcceptance; self.mtpDepth = mtpDepth; self.prefixHitRate = prefixHitRate
        self.savedPrefillSeconds = savedPrefillSeconds; self.activeJobs = activeJobs; self.queuedJobs = queuedJobs
        self.tokensToday = tokensToday; self.localTokensGenerated = localTokensGenerated
        self.uptimeSeconds = uptimeSeconds; self.lastCrash = lastCrash
        self.parentTokensSavedEstimate = parentTokensSavedEstimate; self.jobsPaused = jobsPaused
    }
    enum CodingKeys: String, CodingKey {
        case state, model, mtp, memory
        case loadProgress = "load_progress", decodeTPS = "decode_tps", prefillTPS = "prefill_tps"
        case mtpAcceptance = "mtp_acceptance", mtpDepth = "mtp_depth", prefixHitRate = "prefix_hit_rate"
        case savedPrefillSeconds = "saved_prefill_seconds", activeJobs = "active_jobs", queuedJobs = "queued_jobs"
        case tokensToday = "tokens_today", localTokensGenerated = "local_tokens_generated"
        case uptimeSeconds = "uptime_seconds", lastCrash = "last_crash"
        case parentTokensSavedEstimate = "parent_tokens_saved_estimate", jobsPaused = "jobs_paused"
        case quantFingerprint = "quant_fingerprint"
    }
}

/// POST load body.
public struct LoadRequest: Codable, Sendable, Equatable {
    public var model: String
    public var mtp: String?
    public init(model: String, mtp: String? = nil) { self.model = model; self.mtp = mtp }
}

/// Who created a job.
public enum JobSource: String, Codable, Sendable, Equatable, CaseIterable {
    case mcp, chat, cli, evolve
}

/// Job lifecycle; raw values match StrimJobs.JobStatus.
public enum JobStatusDTO: String, Codable, Sendable, Equatable, CaseIterable {
    case queued, running, awaitingApproval = "awaiting_approval", pausedInteractive = "paused_interactive"
    case done, failed, cancelled, limit
}

/// Verify outcome of a job.
public enum VerifyResult: String, Codable, Sendable, Equatable, CaseIterable {
    case verified, failed, unverified
}

public struct JobSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: JobSource
    public var status: JobStatusDTO
    public var verify: VerifyResult?
    /// Seconds since 1970.
    public var started: Double
    public var finished: Double?
    public var title: String?
    public var cwd: String?
    public init(id: String, source: JobSource, status: JobStatusDTO, verify: VerifyResult? = nil,
                started: Double, finished: Double? = nil, title: String? = nil, cwd: String? = nil) {
        self.id = id; self.source = source; self.status = status; self.verify = verify
        self.started = started; self.finished = finished; self.title = title; self.cwd = cwd
    }
}

public struct JobDetail: Codable, Sendable, Equatable, Identifiable {
    public var summary: JobSummary
    public var id: String { summary.id }
    /// Final summary text from the worker.
    public var resultSummary: String?
    /// Unified diff proposed for the parent tree (awaiting approval).
    public var patch: String?
    public var turns: Int
    public var localTokens: Int
    public var verifyOutput: String?
    /// Lowercase hex SHA-256 over the exact UTF-8 bytes of `patch`, when the server provides it.
    public var patchSHA256: String?
    public init(summary: JobSummary, resultSummary: String? = nil, patch: String? = nil, turns: Int = 0,
                localTokens: Int = 0, verifyOutput: String? = nil, patchSHA256: String? = nil) {
        self.summary = summary; self.resultSummary = resultSummary; self.patch = patch
        self.turns = turns; self.localTokens = localTokens; self.verifyOutput = verifyOutput
        self.patchSHA256 = patchSHA256
    }
    enum CodingKeys: String, CodingKey {
        case summary, patch, turns
        case patchSHA256 = "patch_sha256"
        case resultSummary = "result_summary", localTokens = "local_tokens", verifyOutput = "verify_output"
    }
}

public enum ApprovalAction: String, Codable, Sendable, Equatable { case apply, reject }

public struct PatchApproval: Codable, Sendable, Equatable {
    public var jobID: String
    public var action: ApprovalAction
    /// Lowercase hex SHA-256 of the exact patch bytes the user reviewed. Optional on the wire for backward
    /// compatibility, but REQUIRED by the server for `action == .apply`: it must refuse the apply when the
    /// digest is missing or differs from the stored patch.
    public var patchSHA256: String?
    public init(jobID: String, action: ApprovalAction, patchSHA256: String? = nil) {
        self.jobID = jobID; self.action = action; self.patchSHA256 = patchSHA256
    }
    enum CodingKeys: String, CodingKey { case jobID = "job_id", action, patchSHA256 = "patch_sha256" }
}

public struct ChatOpenRequest: Codable, Sendable, Equatable {
    public var cwd: String
    public var profile: String
    /// Thinking on/off for the session (nil = host default). Honored when the chat backend supports it.
    public var enableThinking: Bool?
    public init(cwd: String, profile: String = "interactive", enableThinking: Bool? = nil) {
        self.cwd = cwd; self.profile = profile; self.enableThinking = enableThinking
    }
    enum CodingKeys: String, CodingKey { case cwd, profile, enableThinking = "enable_thinking" }
}

public struct ChatAppendRequest: Codable, Sendable, Equatable {
    public var sessionID: String
    public var text: String
    /// Thinking on/off for this and following turns (nil = unchanged). Honored when the chat backend supports it.
    public var enableThinking: Bool?
    public init(sessionID: String, text: String, enableThinking: Bool? = nil) {
        self.sessionID = sessionID; self.text = text; self.enableThinking = enableThinking
    }
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", text, enableThinking = "enable_thinking" }
}

/// A chat session is a job that accepts further user turns.
public struct ChatSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String { sessionID }
    public var sessionID: String
    public var jobID: String
    public var cwd: String
    public var profile: String
    public init(sessionID: String, jobID: String, cwd: String, profile: String) {
        self.sessionID = sessionID; self.jobID = jobID; self.cwd = cwd; self.profile = profile
    }
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", jobID = "job_id", cwd, profile }
}

public struct ChatCancelRequest: Codable, Sendable, Equatable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}

/// Error body returned with any non-2xx: `{"error":{"code":"...","message":"..."}}`.
public struct APIError: Codable, Sendable, Equatable, Error, LocalizedError {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    /// Human text for UI (`error.localizedDescription`); `code` and `message` stay the wire fields.
    public var errorDescription: String? {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = m.isEmpty ? "" : (m.prefix(1).uppercased() + m.dropFirst() + (m.hasSuffix(".") ? "" : "."))
        switch code {
        case "not_found": return sentence.isEmpty ? "That item no longer exists." : "Not found: \(m)."
        case "max_sessions": return "Too many chats are open. Close one and try again."
        case "load_failed": return sentence.isEmpty ? "The model failed to load." : sentence + " Try again in a moment."
        case "not_implemented": return "This Strim server doesn't support that yet."
        default: return sentence.isEmpty ? "The Strim server returned an error (\(code))." : sentence
        }
    }
}
public struct APIErrorEnvelope: Codable, Sendable, Equatable {
    public var error: APIError
    public init(error: APIError) { self.error = error }
}

/// Job lifecycle notification.
public struct JobEvent: Codable, Sendable, Equatable {
    public var jobID: String
    public var status: JobStatusDTO
    public var verify: VerifyResult?
    public init(jobID: String, status: JobStatusDTO, verify: VerifyResult? = nil) {
        self.jobID = jobID; self.status = status; self.verify = verify
    }
    enum CodingKeys: String, CodingKey { case jobID = "job_id", status, verify }
}

/// Harness progress inside a job (tool call, turn, compaction...).
public struct HarnessEvent: Codable, Sendable, Equatable {
    public var jobID: String
    public var kind: String
    public var text: String?
    public init(jobID: String, kind: String, text: String? = nil) { self.jobID = jobID; self.kind = kind; self.text = text }
    enum CodingKeys: String, CodingKey { case jobID = "job_id", kind, text }
}

public enum ChatDeltaKind: String, Codable, Sendable, Equatable {
    case text, reasoning, toolCall = "tool_call", toolResult = "tool_result", done
}

/// Streaming chunk of a chat turn.
public struct ChatDelta: Codable, Sendable, Equatable {
    public var sessionID: String
    public var kind: ChatDeltaKind
    public var text: String
    public init(sessionID: String, kind: ChatDeltaKind, text: String) {
        self.sessionID = sessionID; self.kind = kind; self.text = text
    }
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", kind, text }
}

/// One SSE frame. Wire form: `{"type":"<case>","data":{...}}`; the SSE `event:` name equals `type`.
public enum StrimEvent: Codable, Sendable, Equatable {
    case status(HostStatus)
    case jobEvent(JobEvent)
    case harnessEvent(HarnessEvent)
    case chatDelta(ChatDelta)
    case error(APIError)

    /// SSE event name / `type` tag.
    public var typeName: String {
        switch self {
        case .status: "status"
        case .jobEvent: "job_event"
        case .harnessEvent: "harness_event"
        case .chatDelta: "chat_delta"
        case .error: "error"
        }
    }
    enum CodingKeys: String, CodingKey { case type, data }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .type)
        switch t {
        case "status": self = .status(try c.decode(HostStatus.self, forKey: .data))
        case "job_event": self = .jobEvent(try c.decode(JobEvent.self, forKey: .data))
        case "harness_event": self = .harnessEvent(try c.decode(HarnessEvent.self, forKey: .data))
        case "chat_delta": self = .chatDelta(try c.decode(ChatDelta.self, forKey: .data))
        case "error": self = .error(try c.decode(APIError.self, forKey: .data))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event type \(t)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .status(let v): try c.encode(v, forKey: .data)
        case .jobEvent(let v): try c.encode(v, forKey: .data)
        case .harnessEvent(let v): try c.encode(v, forKey: .data)
        case .chatDelta(let v): try c.encode(v, forKey: .data)
        case .error(let v): try c.encode(v, forKey: .data)
        }
    }
}
