import CryptoKit
import Foundation

// The ONLY tunable surface of `strim evolve` (docs/PLAN-PRODUCT-2026-10-27.md section C).
// Sandbox profile, HostPolicy, deny lists, redactor, limit ceilings, tool order, verify command and the MCP
// surface are not representable here: there is no field for them, so no search step can reach them.

public enum SystemVariant: String, Codable, CaseIterable, Sendable { case baseline, verifyFirst = "verify_first", lean, ambitious }
public enum ToolGuidanceVariant: String, Codable, CaseIterable, Sendable { case baseline, examples, strict }
/// Per task-class playbook snippet appended to the pack memory component.
public enum TestFixPlaybookVariant: String, Codable, CaseIterable, Sendable { case off, concise, stepwise, converge }
public enum ProgressGateVariant: String, Codable, CaseIterable, Sendable { case off, on }
public enum TestStatusVariant: String, Codable, CaseIterable, Sendable { case plain, structured }
public enum StallNudgeVariant: String, Codable, CaseIterable, Sendable { case off, on }
public enum ResultShapeVariant: String, Codable, CaseIterable, Sendable { case headTail = "head_tail", errorsFirst = "errors_first" }
public enum PlaybookVariant: String, Codable, CaseIterable, Sendable { case off, concise, stepwise }
/// Cap on one tool result, in characters. `harnessDefault` leaves the harness value alone.
public enum ResultCapVariant: String, Codable, CaseIterable, Sendable {
    case harnessDefault = "harness_default", tight, wide
    public var chars: Int? { switch self { case .harnessDefault: nil; case .tight: 1_500; case .wide: 8_000 } }
}
/// Context fraction at which compaction starts.
public enum CompactionThresholdVariant: String, Codable, CaseIterable, Sendable {
    case harnessDefault = "harness_default", early, late
    public var fraction: Double? { switch self { case .harnessDefault: nil; case .early: 0.6; case .late: 0.85 } }
}
public enum CompactionSummaryVariant: String, Codable, CaseIterable, Sendable { case harnessDefault = "harness_default", structured, terse }
public enum ThinkingPolicy: String, Codable, CaseIterable, Sendable {
    case off, firstPlanningTurn = "first_planning_turn", allTurnsMedium = "all_turns_medium", onStallMedium = "on_stall_medium"
    case allTurnsHigh = "all_turns_high", allTurnsXhigh = "all_turns_xhigh"
    case onStallHigh = "on_stall_high", onStallXhigh = "on_stall_xhigh"
    public var harnessValue: String {
        switch self {
        case .off: "off"
        case .firstPlanningTurn: "first_planning_turn"
        case .allTurnsMedium, .allTurnsHigh, .allTurnsXhigh: "all_turns"
        case .onStallMedium, .onStallHigh, .onStallXhigh: "on_stall"
        }
    }
    /// Qwen's template rejects high; the explicit high variants alias its supported xhigh effort.
    public var reasoningEffort: String? {
        switch self {
        case .off, .firstPlanningTurn: nil
        case .allTurnsMedium, .onStallMedium: "medium"
        default: "xhigh"
        }
    }
}
public enum ContextVariant: String, Codable, CaseIterable, Sendable { case standard, long, xlong }
public enum SamplingVariant: String, Codable, CaseIterable, Sendable { case greedy, qwen }
public enum PreserveThinkingVariant: String, Codable, CaseIterable, Sendable { case off, on }

public enum TemperatureVariant: String, Codable, CaseIterable, Sendable {
    case greedy, warm
    public var value: Double { self == .greedy ? 0 : 0.6 }
}

public struct PackCandidate: Codable, Hashable, Sendable {
    public var systemPrompt: SystemVariant = .baseline
    public var toolGuidance: ToolGuidanceVariant = .baseline
    public var playbookTestFix: TestFixPlaybookVariant = .off
    public var playbookRepoQA: PlaybookVariant = .off
    public var playbookMechanicalEdit: PlaybookVariant = .off
    public var resultCap: ResultCapVariant = .harnessDefault
    public var compactionThreshold: CompactionThresholdVariant = .harnessDefault
    public var compactionSummary: CompactionSummaryVariant = .harnessDefault
    public var thinking: ThinkingPolicy = .off
    public var temperature: TemperatureVariant = .greedy

    public var context: ContextVariant = .standard
    public var sampling: SamplingVariant = .greedy
    public var preserveThinking: PreserveThinkingVariant = .off
    public var isSampled: Bool { sampling == .qwen || temperature != .greedy }

    public var progressGate: ProgressGateVariant = .off
    public var testStatus: TestStatusVariant = .plain
    public var stallNudge: StallNudgeVariant = .off
    public var resultShape: ResultShapeVariant = .headTail

    public init() {}
    public static let baseline = PackCandidate()

    enum CodingKeys: String, CodingKey, CaseIterable {
        case systemPrompt = "system_prompt", toolGuidance = "tool_guidance"
        case playbookTestFix = "playbook_test_fix", playbookRepoQA = "playbook_repo_qa"
        case playbookMechanicalEdit = "playbook_mechanical_edit"
        case resultCap = "result_cap", compactionThreshold = "compaction_threshold"
        case compactionSummary = "compaction_summary", thinking, temperature, context, sampling
        case preserveThinking = "preserve_thinking"
        case stallNudge = "stall_nudge", resultShape = "result_shape"
        case progressGate = "progress_gate", testStatus = "test_status"
    }

    /// Strict: an unknown key (for example `sandbox` or `deny_list`) is an error, never silently ignored.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        if let bad = raw.allKeys.map(\.stringValue).sorted().first(where: { !allowed.contains($0) }) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "field not tunable: \(bad)"))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ d: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? d }
        systemPrompt = try get(.systemPrompt, .baseline); toolGuidance = try get(.toolGuidance, .baseline)
        playbookTestFix = try get(.playbookTestFix, .off); playbookRepoQA = try get(.playbookRepoQA, .off)
        playbookMechanicalEdit = try get(.playbookMechanicalEdit, .off)
        resultCap = try get(.resultCap, .harnessDefault); compactionThreshold = try get(.compactionThreshold, .harnessDefault)
        compactionSummary = try get(.compactionSummary, .harnessDefault); thinking = try get(.thinking, .off)
        temperature = try get(.temperature, .greedy)
        context = try get(.context, .standard); sampling = try get(.sampling, .greedy)
        preserveThinking = try get(.preserveThinking, .off)
        progressGate = try get(.progressGate, .off); testStatus = try get(.testStatus, .plain)
        stallNudge = try get(.stallNudge, .off); resultShape = try get(.resultShape, .headTail)
    }

    /// Omit new default fields so every pre-existing candidate keeps its canonical bytes and fingerprint.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(systemPrompt, forKey: .systemPrompt); try c.encode(toolGuidance, forKey: .toolGuidance)
        try c.encode(playbookTestFix, forKey: .playbookTestFix); try c.encode(playbookRepoQA, forKey: .playbookRepoQA)
        try c.encode(playbookMechanicalEdit, forKey: .playbookMechanicalEdit); try c.encode(resultCap, forKey: .resultCap)
        try c.encode(compactionThreshold, forKey: .compactionThreshold); try c.encode(compactionSummary, forKey: .compactionSummary)
        try c.encode(thinking, forKey: .thinking); try c.encode(temperature, forKey: .temperature)
        if context != .standard { try c.encode(context, forKey: .context) }
        if sampling != .greedy { try c.encode(sampling, forKey: .sampling) }
        if preserveThinking != .off { try c.encode(preserveThinking, forKey: .preserveThinking) }
        if progressGate != .off { try c.encode(progressGate, forKey: .progressGate) }
        if testStatus != .plain { try c.encode(testStatus, forKey: .testStatus) }
        if stallNudge != .off { try c.encode(stallNudge, forKey: .stallNudge) }
        if resultShape != .headTail { try c.encode(resultShape, forKey: .resultShape) }
    }

    struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Short label of the fields that differ from baseline, for reports.
    public var label: String {
        let d = PackCandidate.baseline
        var parts: [String] = []
        for c in Coordinate.allCases where c.value(of: self) != c.value(of: d) { parts.append("\(c.rawValue)=\(c.value(of: self))") }
        return parts.isEmpty ? "baseline" : parts.joined(separator: ",")
    }
}

/// One search dimension. Coordinate ascent changes one coordinate at a time.
public enum Coordinate: String, CaseIterable, Codable, Sendable {
    case systemPrompt = "system_prompt", toolGuidance = "tool_guidance"
    case playbookTestFix = "playbook_test_fix", playbookRepoQA = "playbook_repo_qa", playbookMechanicalEdit = "playbook_mechanical_edit"
    case resultCap = "result_cap", compactionThreshold = "compaction_threshold", compactionSummary = "compaction_summary"
    case thinking, temperature, context, sampling
    case preserveThinking = "preserve_thinking"
    case stallNudge = "stall_nudge", resultShape = "result_shape"
    case progressGate = "progress_gate", testStatus = "test_status"

    /// True: the harness reads this knob. Prompt text reaches the model through `STRIM_PACK_DIR` (PackLoader.builtin);
    /// the other knobs reach it through `STRIM_PACK_DIR/knobs.json` (PackLoader.builtinKnobs -> HarnessKnobs -> AgentLoop).
    public var consumedByHarness: Bool { true }
    public static var consumed: [Coordinate] { allCases.filter(\.consumedByHarness) }

    public func value(of c: PackCandidate) -> String {
        switch self {
        case .systemPrompt: c.systemPrompt.rawValue
        case .toolGuidance: c.toolGuidance.rawValue
        case .playbookTestFix: c.playbookTestFix.rawValue
        case .playbookRepoQA: c.playbookRepoQA.rawValue
        case .playbookMechanicalEdit: c.playbookMechanicalEdit.rawValue
        case .resultCap: c.resultCap.rawValue
        case .compactionThreshold: c.compactionThreshold.rawValue
        case .compactionSummary: c.compactionSummary.rawValue
        case .thinking: c.thinking.rawValue
        case .temperature: c.temperature.rawValue
        case .context: c.context.rawValue
        case .sampling: c.sampling.rawValue
        case .preserveThinking: c.preserveThinking.rawValue
        case .progressGate: c.progressGate.rawValue
        case .testStatus: c.testStatus.rawValue
        case .stallNudge: c.stallNudge.rawValue
        case .resultShape: c.resultShape.rawValue
        }
    }

    /// Every option of this coordinate with all other fields taken from `base` (includes `base` itself).
    public func variants(of base: PackCandidate) -> [PackCandidate] {
        func make<T: CaseIterable>(_ t: T.Type, _ set: (inout PackCandidate, T) -> Void) -> [PackCandidate] {
            T.allCases.map { var c = base; set(&c, $0); return c }
        }
        switch self {
        case .systemPrompt: return make(SystemVariant.self) { $0.systemPrompt = $1 }
        case .toolGuidance: return make(ToolGuidanceVariant.self) { $0.toolGuidance = $1 }
        case .playbookTestFix: return make(TestFixPlaybookVariant.self) { $0.playbookTestFix = $1 }
        case .playbookRepoQA: return make(PlaybookVariant.self) { $0.playbookRepoQA = $1 }
        case .playbookMechanicalEdit: return make(PlaybookVariant.self) { $0.playbookMechanicalEdit = $1 }
        case .resultCap: return make(ResultCapVariant.self) { $0.resultCap = $1 }
        case .compactionThreshold: return make(CompactionThresholdVariant.self) { $0.compactionThreshold = $1 }
        case .compactionSummary: return make(CompactionSummaryVariant.self) { $0.compactionSummary = $1 }
        case .thinking: return make(ThinkingPolicy.self) { $0.thinking = $1 }
        case .context: return make(ContextVariant.self) { $0.context = $1 }
        case .sampling: return make(SamplingVariant.self) { $0.sampling = $1 }
        case .preserveThinking: return make(PreserveThinkingVariant.self) { $0.preserveThinking = $1 }
        case .temperature: return make(TemperatureVariant.self) { $0.temperature = $1 }
        case .progressGate: return make(ProgressGateVariant.self) { $0.progressGate = $1 }
        case .testStatus: return make(TestStatusVariant.self) { $0.testStatus = $1 }
        case .stallNudge: return make(StallNudgeVariant.self) { $0.stallNudge = $1 }
        case .resultShape: return make(ResultShapeVariant.self) { $0.resultShape = $1 }
        }
    }
}

public enum Canonical {
    /// Sorted keys, no slash escaping, no whitespace: byte-stable for equal values.
    public static func json<T: Encodable>(_ v: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)) ?? Data()
    }
    public static func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    public static func sha256Hex(_ s: String) -> String { sha256Hex(Data(s.utf8)) }
}
