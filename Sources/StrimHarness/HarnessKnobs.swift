import Foundation

/// The non-prompt knobs of a pack (`STRIM_PACK_DIR/knobs.json`, written by `strim evolve`): tool-result cap,
/// compaction threshold and summary guidance, thinking policy, sampling temperature and seed.
///
/// Safety model: the file is data from a pack directory, so it is validated like untrusted input.
/// - Strict: an unknown key (`maxTurns`, `sandbox`, `tools`, ...) makes the whole file invalid. There is no field for
///   limits, sandbox, tool set or tool order, so a pack cannot reach them.
/// - Every value is clamped into a safe range (never past the harness's own ceilings): the result cap can only go
///   down to 200 chars or up to the existing 8000 hard maximum, the compaction threshold stays within 0.4...0.9 of the
///   context, temperature within 0...1. Non-finite numbers fall back to the default.
/// - The default value of every field reproduces today's behaviour exactly (`HarnessKnobs() == nil knobs`).
public struct HarnessKnobs: Codable, Equatable, Sendable {
    public enum Context: String, Codable, Sendable {
        case standard, long, xlong
        public var requestedTokens: Int {
            switch self { case .standard: 32_768; case .long: 65_536; case .xlong: 131_072 }
        }
        /// Conservative ceiling within MemoryModel.requestReserveBytes, including MTP (docs/EVOLVE.md).
        public var tokens: Int { min(requestedTokens, 65_536) }
        public var compactionTokens: Int { self == .standard ? 28_000 : 56_000 }
        public var turnTokens: Int { self == .standard ? 4096 : 8192 }
        public var thinkingTokens: Int { self == .standard ? 8192 : 16_384 }
    }
    public enum Sampling: String, Codable, Sendable { case greedy, qwen }
    public enum PreserveThinking: String, Codable, Sendable { case off, on }
    public enum ProgressGate: String, Codable, Sendable { case off, on }
    public enum TestStatus: String, Codable, Sendable { case plain, structured }
    public enum StallNudge: String, Codable, Sendable { case off, on }
    public enum ResultShape: String, Codable, Sendable { case headTail = "head_tail", errorsFirst = "errors_first" }

    public enum Thinking: String, Codable, Sendable {
        case off
        /// Thinking on for the first assistant turn of a job (and of a fresh session after a compaction) only.
        case firstPlanningTurn = "first_planning_turn"
        /// Thinking on for every assistant generation in the job.
        case allTurns = "all_turns"
        /// One recovery generation after an unchanged failure recurrence or a stall reminder.
        case onStall = "on_stall"
    }

    /// Context length the compaction fraction refers to. The shipped default threshold (28 000 tokens) is 0.855 of it.
    public static let contextTokens = 32_768
    public static let defaultCompactionTokens = 28_000
    public static let resultCapRange = 200...Compaction.toolOutputCap
    public static let compactionFractionRange = 0.4...0.9
    public static let temperatureRange = 0.0...1.0
    public static let summaryGuidanceMaxChars = 1000
    public static let maxFileBytes = 64 * 1024
    /// Fixed default so sampled runs are reproducible without any configuration.
    public static let defaultSeed: UInt64 = 20_261_027
    /// Sampling used when temperature > 0 (Qwen card values). Greedy runs use the engine defaults, as before.
    public static let sampledTopP: Float = 0.95
    public static let sampledTopK = 20
    /// Output budget of a thinking turn (the default per-turn cap of 4096 would cut a planning turn short).
    /// Still bounded by the job's `maxGeneratedTokens`.
    public static let thinkingTurnTokens = 8192

    public var context: Context
    /// nil preserves the existing temperature knob; explicit greedy overrides it.
    public var sampling: Sampling?
    public var preserve_thinking: PreserveThinking
    public var progress_gate: ProgressGate
    public var test_status: TestStatus
    public var stall_nudge: StallNudge
    public var result_shape: ResultShape
    public var resultCapChars: Int?
    public var compactionThreshold: Double?
    public var compactionSummaryPrompt: String?
    public var thinking: Thinking
    public var reasoningEffort: String
    public var temperature: Double
    public var seed: UInt64
    /// "greedy" | "sampled": informational (evolve records it); `temperature` is what the loop uses.
    public var decoding: String?

    public init(resultCapChars: Int? = nil, compactionThreshold: Double? = nil, compactionSummaryPrompt: String? = nil,
                thinking: Thinking = .off, reasoningEffort: String = "medium", temperature: Double = 0, seed: UInt64 = HarnessKnobs.defaultSeed,
                decoding: String? = nil, stall_nudge: StallNudge = .off, result_shape: ResultShape = .headTail,
                progress_gate: ProgressGate = .off, test_status: TestStatus = .plain,
                context: Context = .standard, sampling: Sampling? = nil, preserve_thinking: PreserveThinking = .off) {
        self.context = context
        self.sampling = sampling
        self.preserve_thinking = preserve_thinking
        self.progress_gate = progress_gate
        self.test_status = test_status
        self.stall_nudge = stall_nudge
        self.result_shape = result_shape
        self.resultCapChars = resultCapChars.map { min(max($0, Self.resultCapRange.lowerBound), Self.resultCapRange.upperBound) }
        self.compactionThreshold = compactionThreshold.flatMap { $0.isFinite ? min(max($0, Self.compactionFractionRange.lowerBound), Self.compactionFractionRange.upperBound) : nil }
        self.compactionSummaryPrompt = Self.sanitizeGuidance(compactionSummaryPrompt)
        self.thinking = thinking
        self.reasoningEffort = ["low", "medium", "high", "xhigh"].contains(reasoningEffort) ? reasoningEffort : "medium"
        self.temperature = temperature.isFinite ? min(max(temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound) : 0
        self.seed = seed
        self.decoding = decoding
    }

    private enum Key: String, CodingKey, CaseIterable {
        case context, sampling, preserve_thinking, progress_gate, test_status, stall_nudge, result_shape, resultCapChars, compactionThreshold, compactionSummaryPrompt, thinking, reasoningEffort, temperature, seed, decoding
    }

    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self)
        let allowed = Set(Key.allCases.map(\.rawValue))
        if let bad = raw.allKeys.map(\.stringValue).sorted().first(where: { !allowed.contains($0) }) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "knob not supported: \(bad)"))
        }
        let c = try decoder.container(keyedBy: Key.self)
        let decoding = try c.decodeIfPresent(String.self, forKey: .decoding)
        if let d = decoding, d != "greedy", d != "sampled" {
            throw DecodingError.dataCorrupted(.init(codingPath: [Key.decoding], debugDescription: "decoding must be greedy or sampled"))
        }
        let effort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? "medium"
        guard ["low", "medium", "high", "xhigh"].contains(effort) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [Key.reasoningEffort], debugDescription: "reasoningEffort must be low, medium, high, or xhigh"))
        }
        self.init(resultCapChars: try c.decodeIfPresent(Int.self, forKey: .resultCapChars),
                  compactionThreshold: try c.decodeIfPresent(Double.self, forKey: .compactionThreshold),
                  compactionSummaryPrompt: try c.decodeIfPresent(String.self, forKey: .compactionSummaryPrompt),
                  thinking: try c.decodeIfPresent(Thinking.self, forKey: .thinking) ?? .off,
                  reasoningEffort: effort,
                  temperature: try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0,
                  seed: try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? Self.defaultSeed,
                  decoding: decoding,
                  stall_nudge: try c.decodeIfPresent(StallNudge.self, forKey: .stall_nudge) ?? .off,
                  result_shape: try c.decodeIfPresent(ResultShape.self, forKey: .result_shape) ?? .headTail,
                  progress_gate: try c.decodeIfPresent(ProgressGate.self, forKey: .progress_gate) ?? .off,
                  test_status: try c.decodeIfPresent(TestStatus.self, forKey: .test_status) ?? .plain,
                  context: try c.decodeIfPresent(Context.self, forKey: .context) ?? .standard,
                  sampling: try c.decodeIfPresent(Sampling.self, forKey: .sampling),
                  preserve_thinking: try c.decodeIfPresent(PreserveThinking.self, forKey: .preserve_thinking) ?? .off)
    }

    /// Keep legacy encoded bytes: only the new opt-in values add keys.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        if context != .standard { try c.encode(context, forKey: .context) }
        try c.encodeIfPresent(sampling, forKey: .sampling)
        if preserve_thinking != .off { try c.encode(preserve_thinking, forKey: .preserve_thinking) }
        try c.encode(stall_nudge, forKey: .stall_nudge)
        try c.encode(result_shape, forKey: .result_shape)
        try c.encodeIfPresent(resultCapChars, forKey: .resultCapChars)
        try c.encodeIfPresent(compactionThreshold, forKey: .compactionThreshold)
        try c.encodeIfPresent(compactionSummaryPrompt, forKey: .compactionSummaryPrompt)
        try c.encode(thinking, forKey: .thinking)
        try c.encode(reasoningEffort, forKey: .reasoningEffort)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(seed, forKey: .seed)
        try c.encodeIfPresent(decoding, forKey: .decoding)
        if progress_gate != .off { try c.encode(progress_gate, forKey: .progress_gate) }
        if test_status != .plain { try c.encode(test_status, forKey: .test_status) }
    }

    public static func decode(_ data: Data) throws -> HarnessKnobs {
        try JSONDecoder().decode(HarnessKnobs.self, from: data)
    }

    // MARK: derived values the loop uses

    /// Cap on one tool result shown to the model (the loop-level head+tail cap; tools keep their own, lower or equal, caps).
    public var toolOutputCap: Int { resultCapChars ?? Compaction.toolOutputCap }

    /// Estimated prompt tokens above which the loop compacts.
    public var compactionTokens: Int {
        compactionThreshold.map { Int(Double(context.tokens) * $0) } ?? context.compactionTokens
    }

    public var isSampled: Bool { sampling.map { $0 == .qwen } ?? (temperature > 0) }

    /// Presets override temperature only when explicitly selected. Omission keeps legacy warm/greedy traffic.
    public func samplingValues(thinking: Bool) -> (temperature: Float, topP: Float, topK: Int) {
        switch sampling {
        case .qwen: (thinking ? 1 : 0.7, thinking ? 0.95 : 0.8, 20)
        case .greedy: (0, 1, 0)
        case nil: (Float(temperature), isSampled ? Self.sampledTopP : 1, isSampled ? Self.sampledTopK : 0)
        }
    }

    /// Match ServerLimits without coupling the harness to the HTTP server. Applied only to larger contexts.
    public func outputCap(thinking: Bool, promptTokens: Int, turnCap: Int, background: Bool,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard context != .standard else { return thinking ? max(turnCap, Self.thinkingTurnTokens) : turnCap }
        func ceiling(_ key: String, _ fallback: Int) -> Int {
            min(max(Int(environment[key] ?? "") ?? fallback, 1), 1 << 24)
        }
        return max(1, min(thinking ? context.thinkingTokens : context.turnTokens,
                          context.tokens - max(0, promptTokens),
                          ceiling("STRIM_MAX_OUTPUT_TOKENS", 1 << 20),
                          background ? ceiling("STRIM_BACKGROUND_MAX_TOKENS", 32_768) : Int.max))
    }

    /// Seed of the n-th generation (1-based) of a drive: fixed base plus the ordinal, so a rerun with the same
    /// knobs and the same engine output samples identically. Unused (nil) when greedy.
    public func seed(forGeneration n: Int) -> UInt64? {
        isSampled ? seed &+ UInt64(max(n, 0)) : nil
    }

    /// Single-line-safe guidance text for the compaction message: control scalars dropped (newlines and tabs kept),
    /// `<` escaped so no tag or Qwen control token survives, bounded. nil when empty.
    static func sanitizeGuidance(_ s: String?) -> String? {
        guard let s else { return nil }
        let kept = String.UnicodeScalarView(s.unicodeScalars.filter { u in
            if u == "\n" || u == "\t" { return true }
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        })
        var t = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > summaryGuidanceMaxChars { t = String(t.prefix(summaryGuidanceMaxChars)) }
        t = t.replacingOccurrences(of: "<", with: "&lt;")
        return t.isEmpty ? nil : t
    }
}
