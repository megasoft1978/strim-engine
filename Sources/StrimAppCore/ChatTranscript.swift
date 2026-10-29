import Foundation
import StrimAPI

/// A tool call shown as a collapsible card: name, a one-line args summary, and the result once it arrives.
public struct ToolCard: Equatable, Sendable {
    public var name: String
    public var args: String
    public var result: String?
    public var isError = false
    public var finished: Bool { result != nil }

    public init(name: String, args: String = "", result: String? = nil, isError: Bool = false) {
        self.name = name; self.args = args; self.result = result; self.isError = isError
    }

    /// `tool_call` delta text: `"<name> <args summary>"`.
    public static func call(_ text: String) -> ToolCard {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        return ToolCard(name: parts.first.map(String.init) ?? "tool", args: parts.count > 1 ? String(parts[1]) : "")
    }

    /// `tool_result` delta text: `"<name>[ ERROR]: <summary>"`. Returns (name, isError, summary).
    public static func parseResult(_ text: String) -> (name: String, isError: Bool, summary: String) {
        guard let colon = text.firstIndex(of: ":") else { return ("", false, text) }
        var head = String(text[..<colon])
        var summary = String(text[text.index(after: colon)...])
        if summary.hasPrefix(" ") { summary.removeFirst() }
        let err = head.hasSuffix(" ERROR")
        if err { head.removeLast(6) }
        return (head, err, summary)
    }
}

/// Tool output shown verbatim: first `maxLines` lines, the rest behind a "N more lines" affordance.
public enum ToolResultPreview {
    public static func split(_ text: String, maxLines: Int = 8) -> (shown: String, hidden: Int) {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        guard lines.count > maxLines else { return (lines.joined(separator: "\n"), 0) }
        return (lines.prefix(maxLines).joined(separator: "\n"), lines.count - maxLines)
    }
}

/// Token accounting of one chat turn. `local` tokens are the ones the local model generated.
public struct TokenLedger: Equatable, Sendable {
    public var prompt = 0
    public var cached = 0
    public var completion = 0
    public var seconds: Double?
    public init(prompt: Int = 0, cached: Int = 0, completion: Int = 0, seconds: Double? = nil) {
        self.prompt = prompt; self.cached = cached; self.completion = completion; self.seconds = seconds
    }
    public var local: Int { completion }
    /// Generated tokens per second over the whole turn (includes tool time), nil when unknown.
    public var tokensPerSecond: Double? {
        guard let s = seconds, s > 0.05, completion > 0 else { return nil }
        return Double(completion) / s
    }
    public mutating func add(prompt p: Int, cached c: Int, completion o: Int) { prompt += p; cached += c; completion += o }

    /// `usage` harness frame text: `"prompt/cached/completion"`.
    public static func parse(_ text: String) -> (Int, Int, Int)? {
        let n = text.split(separator: "/").compactMap { Int($0) }
        return n.count == 3 ? (n[0], n[1], n[2]) : nil
    }

    /// e.g. `prompt 1,204 (cached 900) · completion 87 · local 87 · 41.2 tok/s`
    public var summary: String {
        var parts = ["prompt \(StatsFormat.tokens(prompt))"]
        if cached > 0 { parts[0] += " (cached \(StatsFormat.tokens(cached)))" }
        parts.append("completion \(StatsFormat.tokens(completion))")
        parts.append("local \(StatsFormat.tokens(local))")
        if let t = tokensPerSecond { parts.append(StatsFormat.tps(t)) }
        return parts.joined(separator: " · ")
    }
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant, reasoning, tool }
    public var id = UUID()
    public var role: Role
    public var text: String
    /// Set for `.tool` messages.
    public var tool: ToolCard?
    /// Set on the last message of a finished turn.
    public var ledger: TokenLedger?
    /// Set for divider rows (session ended, earlier messages trimmed); their `text` is the divider copy.
    public var marker: ChatMarker?
    public init(role: Role, text: String, tool: ToolCard? = nil, ledger: TokenLedger? = nil, marker: ChatMarker? = nil) {
        self.role = role; self.text = text; self.tool = tool; self.ledger = ledger; self.marker = marker
    }
}
