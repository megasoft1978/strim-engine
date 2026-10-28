import Foundation

/// Parsed text reply of the strim MCP tools (see ResultRender in StrimMCP).
public struct HarnessReply: Sendable, Equatable {
    public var jobId: String?
    public var status: String?
    public var verify: String?
    public var done = false
    public var terminal = false
    public var promptTokens: Int?
    public var cachedTokens: Int?
    public var completionTokens: Int?
    public var turns: Int?
    public var patchPath: String?
    public var inlinePatch: String?
    public var summary: String?
    public var answer: String?

    static func firstMatch(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    public static func parse(_ text: String) -> HarnessReply {
        var r = HarnessReply()
        r.done = text.hasPrefix("DONE")
        if let m = firstMatch(#"strim job (\S+?):? (?:verify=(\w+)|(\w+))"#, text) {
            r.jobId = m[1]
            if !m[2].isEmpty { r.verify = m[2]; r.status = "done" } else { r.status = m[3] }
        }
        if r.status == nil, let m = firstMatch(#"strim job (\S+?): (\w+)"#, text) { r.jobId = m[1]; r.status = m[2] }
        if let s = r.status { r.terminal = ["done", "failed", "cancelled", "limit", "declined"].contains(s) }
        if let m = firstMatch(#"usage: (\d+) prompt \((\d+) cached\) \+ (\d+) completion tokens, (\d+) turns"#, text) {
            r.promptTokens = Int(m[1]); r.cachedTokens = Int(m[2]); r.completionTokens = Int(m[3]); r.turns = Int(m[4])
        }
        if let m = firstMatch(#"(?m)^apply: git -C .+? apply (.+)$"#, text) {
            var p = m[1].trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("'"), p.hasSuffix("'"), p.count >= 2 { p = String(p.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'") }
            r.patchPath = p
        }
        if let m = firstMatch(#"(?s)(`{3,})diff\n(.*?)\n\1"#, text) { r.inlinePatch = m[2] + "\n" }
        let stops = #"(?=\nfiles: |\ncommands: |\nusage: |\napply: |\nnote: |\n`{3,}diff|$)"#
        if let m = firstMatch(#"summary \(untrusted model text\):\n(.*?)"# + stops, text, options: [.dotMatchesLineSeparators]) {
            r.summary = m[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let m = firstMatch(#"answer \(untrusted model text\):\n(.*?)(?=\nnote: untrusted|$)"#, text, options: [.dotMatchesLineSeparators]) {
            r.answer = m[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return r
    }

    /// The harness's verify verdict for the ledger: the `verify=` value of a DONE reply, `declined`, else `none`.
    public static func verifyLabel(_ r: HarnessReply) -> String {
        if r.done { return r.verify ?? "none" }
        return r.status == "declined" ? "declined" : "none"
    }

    /// `verify.exit_code` from the job's result.json, which sits next to patch.diff (`~/.strim/jobs/<id>/`).
    public static func verifyExit(besidePatch patch: String) -> Int? {
        let url = URL(fileURLWithPath: patch).deletingLastPathComponent().appendingPathComponent("result.json")
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = o["verify"] as? [String: Any] else { return nil }
        return (v["exit_code"] as? NSNumber)?.intValue
    }
}
