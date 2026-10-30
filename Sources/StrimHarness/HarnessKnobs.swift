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
    public enum Thinking: String, Codable, Sendable {
        case off
        /// Thinking on for the first assistant turn of a job (and of a fresh session after a compaction) only.
        case firstPlanningTurn = "first_planning_turn"
        /// Thinking on for every assistant generation in the job.
        case allTurns = "all_turns"
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
                decoding: String? = nil) {
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
        case resultCapChars, compactionThreshold, compactionSummaryPrompt, thinking, reasoningEffort, temperature, seed, decoding
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
                  decoding: decoding)
    }

    public static func decode(_ data: Data) throws -> HarnessKnobs {
        try JSONDecoder().decode(HarnessKnobs.self, from: data)
    }

    // MARK: derived values the loop uses

    /// Cap on one tool result shown to the model (the loop-level head+tail cap; tools keep their own, lower or equal, caps).
    public var toolOutputCap: Int { resultCapChars ?? Compaction.toolOutputCap }

    /// Estimated prompt tokens above which the loop compacts.
    public var compactionTokens: Int {
        compactionThreshold.map { Int(Double(Self.contextTokens) * $0) } ?? Self.defaultCompactionTokens
    }

    public var isSampled: Bool { temperature > 0 }

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
