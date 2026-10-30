import Foundation
import CryptoKit
import StrimCore
import StrimTemplate

/// Conservative output-only labels. All offsets are raw tokenizer UTF-8 byte offsets.
/// Precedence: valid tool JSON > fenced/inline code > prose. Crossing a boundary,
/// invalid UTF-8, incomplete tool envelopes and unreachable suffix proposals are unknown.
enum MTPContentType: String, CaseIterable, Codable {
    case toolCallJSON = "tool_call_json", code, prose, unknown
}

struct MTPContentClassifier {
    static func labels(bytes: [UInt8]) -> [MTPContentType] {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            return Array(repeating: .unknown, count: bytes.count)
        }
        var labels = Array(repeating: MTPContentType.prose, count: bytes.count)
        func byteRange(_ range: NSRange) -> Range<Int>? {
            guard let r = Range(range, in: text) else { return nil }
            let start = text[..<r.lowerBound].utf8.count
            return start..<(start + text[r].utf8.count)
        }
        func matches(_ pattern: String) -> [NSRange] {
            let re = try! NSRegularExpression(pattern: pattern)
            return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        }
        func fill(_ r: Range<Int>, _ type: MTPContentType) {
            for i in r { labels[i] = type }
        }
        for r in matches("(?ms)^```[^\\n]*\\n.*?(?:^```[^\\n]*(?:\\n|$)|\\z)|`[^`\\n]+`") {
            if let r = byteRange(r) { fill(r, .code) }
        }
        // Unfenced source lines are deliberately conservative; no prompt-based inference.
        for r in matches("(?m)^(?:import |from \\w+ import |func |def |class |const |let |var |function |public (?:func|class|struct) ).*$") {
            if let r = byteRange(r), labels[r.lowerBound] == .prose { fill(r, .code) }
        }
        for r in matches("(?s)<tool_call>.*?(?:</tool_call>|\\z)") {
            guard let r = byteRange(r) else { continue }
            let fragment = String(decoding: bytes[r], as: UTF8.self)
            let body = fragment.replacingOccurrences(of: "<tool_call>", with: "")
                .replacingOccurrences(of: "</tool_call>", with: "")
            fill(r, fragment.hasSuffix("</tool_call>") && isToolJSON(body) ? .toolCallJSON : .unknown)
        }
        // A complete bare tool-call object is also structured output. Ordinary JSON is
        // not assumed to be a tool call. Preserve surrounding whitespace as prose.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isToolJSON(trimmed), let r = text.range(of: trimmed) {
            fill(text[..<r.lowerBound].utf8.count..<(text[..<r.lowerBound].utf8.count + trimmed.utf8.count), .toolCallJSON)
        }
        for r in matches(#"<\|[^>]*\|>|</?think>"#) {
            if let r = byteRange(r) { fill(r, .unknown) }
        }
        return labels
    }

    private static func isToolJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let name = o["name"] as? String, !name.isEmpty, o["arguments"] != nil { return true }
        if let f = o["function"] as? [String: Any], f["name"] is String, f["arguments"] != nil { return true }
        if let calls = o["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            return calls.allSatisfy { call in
                let f = call["function"] as? [String: Any] ?? call
                return f["name"] is String && f["arguments"] != nil
            }
        }
        return false
    }

    static func classify(_ span: Range<Int>, labels: [MTPContentType]) -> MTPContentType {
        guard !span.isEmpty, span.lowerBound >= 0, span.upperBound <= labels.count,
              let first = labels[span].first, labels[span].allSatisfy({ $0 == first }) else { return .unknown }
        return first
    }
}

struct MTPReplayRound {
    /// Number of output tokens emitted before this round. Draft position 1 is offset+1:
    /// offset itself is the pending target token, not a draft.
    var outputOffset: Int
    var depth: Int
    var accepted: Int
}

struct MTPPositionReport: Codable {
    var position: Int
    var proposed: Int
    var reached: Int
    var acceptedPrefix: Int
    var prefixSurvival: Double?
    var conditionalAcceptance: Double?
    var conditionalWilson95: [Double]?
    var prefixWilson95: [Double]?

    init(position: Int, proposed: Int, reached: Int, accepted: Int) {
        self.position = position; self.proposed = proposed; self.reached = reached; acceptedPrefix = accepted
        prefixSurvival = proposed > 0 ? Double(accepted) / Double(proposed) : nil
        conditionalAcceptance = reached > 0 ? Double(accepted) / Double(reached) : nil
        conditionalWilson95 = Self.wilson(accepted, reached)
        prefixWilson95 = Self.wilson(accepted, proposed)
    }
    static func wilson(_ successes: Int, _ count: Int) -> [Double]? {
        guard count > 0 else { return nil }
        let z = 1.959963984540054, n = Double(count), p = Double(successes) / n
        let denom = 1 + z*z/n, mid = (p + z*z/(2*n))/denom
        let half = z * sqrt(p*(1-p)/n + z*z/(4*n*n))/denom
        return [max(0, mid-half), min(1, mid+half)]
    }
    static func positions(_ stats: MTPStats) -> [Self] {
        (0..<MTPStats.positionLimit).map {
            Self(position: $0+1, proposed: stats.proposed[$0], reached: stats.reached[$0], accepted: stats.acceptedPrefix[$0])
        }
    }
}

struct MTPContentCounts {
    var proposed = Array(repeating: 0, count: MTPStats.positionLimit)
    var reached = Array(repeating: 0, count: MTPStats.positionLimit)
    var accepted = Array(repeating: 0, count: MTPStats.positionLimit)
    var positions: [MTPPositionReport] {
        (0..<MTPStats.positionLimit).map {
            MTPPositionReport(position: $0+1, proposed: proposed[$0], reached: reached[$0], accepted: accepted[$0])
        }
    }
}

/// Classify the reached proposal's output slot. Accepted proposals use their own span;
/// the first rejection uses the target replacement at that output position. Later
/// proposals were never reached and remain unknown. No draft text is classified.
func mtpContentCounts(tokenBytes: [[UInt8]], rounds: [MTPReplayRound]) -> [MTPContentType: MTPContentCounts] {
    var result = Dictionary(uniqueKeysWithValues: MTPContentType.allCases.map { ($0, MTPContentCounts()) })
    let bytes = tokenBytes.flatMap { $0 }, labels = MTPContentClassifier.labels(bytes: bytes)
    var spans: [Range<Int>] = [], offset = 0
    for token in tokenBytes { spans.append(offset..<(offset + token.count)); offset += token.count }
    for r in rounds {
        for j in 0..<min(r.depth, MTPStats.positionLimit) {
            let i = r.outputOffset + j + 1
            let label = j <= r.accepted && i < spans.count
                ? MTPContentClassifier.classify(spans[i], labels: labels) : .unknown
            result[label]!.proposed[j] += 1
            if r.accepted >= j { result[label]!.reached[j] += 1 }
            if r.accepted > j { result[label]!.accepted[j] += 1 }
        }
    }
    return result
}

func mtpSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
