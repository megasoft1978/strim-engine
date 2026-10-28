import CryptoKit
import Foundation

// The ONLY tunable surface of `strim evolve` (docs/PLAN-PRODUCT-2026-10-27.md section C).
// Sandbox profile, HostPolicy, deny lists, redactor, limit ceilings, tool order, verify command and the MCP
// surface are not representable here: there is no field for them, so no search step can reach them.

public enum SystemVariant: String, Codable, CaseIterable, Sendable { case baseline, verifyFirst = "verify_first", lean }
public enum ToolGuidanceVariant: String, Codable, CaseIterable, Sendable { case baseline, examples, strict }
/// Per task-class playbook snippet appended to the pack memory component.
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
public enum ThinkingPolicy: String, Codable, CaseIterable, Sendable { case off, firstPlanningTurn = "first_planning_turn" }
public enum TemperatureVariant: String, Codable, CaseIterable, Sendable {
    case greedy, warm
    public var value: Double { self == .greedy ? 0 : 0.6 }
}

public struct PackCandidate: Codable, Hashable, Sendable {
    public var systemPrompt: SystemVariant = .baseline
    public var toolGuidance: ToolGuidanceVariant = .baseline
    public var playbookTestFix: PlaybookVariant = .off
    public var playbookRepoQA: PlaybookVariant = .off
    public var playbookMechanicalEdit: PlaybookVariant = .off
    public var resultCap: ResultCapVariant = .harnessDefault
    public var compactionThreshold: CompactionThresholdVariant = .harnessDefault
    public var compactionSummary: CompactionSummaryVariant = .harnessDefault
    public var thinking: ThinkingPolicy = .off
    public var temperature: TemperatureVariant = .greedy

    public init() {}
    public static let baseline = PackCandidate()

    enum CodingKeys: String, CodingKey, CaseIterable {
        case systemPrompt = "system_prompt", toolGuidance = "tool_guidance"
        case playbookTestFix = "playbook_test_fix", playbookRepoQA = "playbook_repo_qa"
        case playbookMechanicalEdit = "playbook_mechanical_edit"
        case resultCap = "result_cap", compactionThreshold = "compaction_threshold"
        case compactionSummary = "compaction_summary", thinking, temperature
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
    case thinking, temperature

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
        case .playbookTestFix: return make(PlaybookVariant.self) { $0.playbookTestFix = $1 }
        case .playbookRepoQA: return make(PlaybookVariant.self) { $0.playbookRepoQA = $1 }
        case .playbookMechanicalEdit: return make(PlaybookVariant.self) { $0.playbookMechanicalEdit = $1 }
        case .resultCap: return make(ResultCapVariant.self) { $0.resultCap = $1 }
        case .compactionThreshold: return make(CompactionThresholdVariant.self) { $0.compactionThreshold = $1 }
        case .compactionSummary: return make(CompactionSummaryVariant.self) { $0.compactionSummary = $1 }
        case .thinking: return make(ThinkingPolicy.self) { $0.thinking = $1 }
        case .temperature: return make(TemperatureVariant.self) { $0.temperature = $1 }
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
