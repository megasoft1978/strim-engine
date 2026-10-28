import Foundation
import StrimHarness
import StrimJobs
import StrimTemplate

/// Renders job snapshots for the parent model. Token-saving is the point: not-done replies are one line,
/// done replies are a short text block. Every string is redacted before it leaves this file.
enum ResultRender {
    static let summaryCap = 1500
    static let maxFiles = 20
    static let maxCommands = 10
    static let maxEventLines = 20

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(max(0, n - 1))) + "…"
    }

    /// Strips control (except newline/tab) and zero-width/bidi characters, and collapses 3+ backtick runs to `'''`.
    static func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0A, 0x09: out.append(u)
            case 0..<0x20, 0x7F..<0xA0, 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064, 0x206A...0x206F, 0xFEFF:
                continue
            default: out.append(u)
            }
        }
        var res = "", run = 0
        for ch in String(out) {
            if ch == "`" { run += 1; continue }
            if run > 0 { res += run >= 3 ? "'''" : String(repeating: "`", count: run); run = 0 }
            res.append(ch)
        }
        if run > 0 { res += run >= 3 ? "'''" : String(repeating: "`", count: run) }
        return res
    }

    private static func oneLine(_ s: String, _ n: Int) -> String {
        clip(sanitize(Redactor.redact(s)).split(whereSeparator: \.isNewline).joined(separator: " "), n)
    }

    private static func cleanSummary(_ s: String) -> String { clip(sanitize(Redactor.redact(s)), summaryCap) }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+=:,@%")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `strim job <id>: <status> turn <n>/<max> <elapsed>s`
    static func statusLine(_ snap: JobSnapshot) -> String {
        let p = snap.progress
        let turn = p.maxTurns > 0 ? "\(p.turn)/\(p.maxTurns)" : "\(p.turn)"
        return "strim job \(snap.id): \(snap.status.rawValue) turn \(turn) \(Int(p.elapsedS.rounded()))s"
    }

    static func inlinePatch(_ result: HarnessJobResult, cap: Int) -> String? {
        guard let patch = result.patch, !patch.isEmpty else { return nil }
        let red = Redactor.redact(patch)
        return red.utf8.count <= cap ? red : nil
    }

    private static func eventLines(_ events: [JobEvent]?) -> String {
        guard let events, !events.isEmpty else { return "" }
        var lines = events.prefix(maxEventLines).map { "#\($0.index) \($0.kind): \(oneLine($0.text, 120))" }
        if events.count > maxEventLines { lines.append("(+\(events.count - maxEventLines) more events)") }
        return "\n" + lines.joined(separator: "\n")
    }

    static func verifyLabel(_ s: VerifyStatus) -> String {
        s == .verifiedModifiedTests ? "verified-but-tests-touched" : s.rawValue
    }

    /// Full reply for strim_task / strim_job / strim_cancel.
    static func render(_ snap: JobSnapshot, maxInlinePatchBytes: Int, events: [JobEvent]? = nil) -> MCPToolResult {
        let structured = structuredJSON(snap, maxInlinePatchBytes: maxInlinePatchBytes)
        guard snap.status.isTerminal else {
            return MCPToolResult(text: statusLine(snap) + " (poll strim_job)" + eventLines(events), structured: structured)
        }
        let head = statusLine(snap)
        guard let r = snap.result, r.status == .done, snap.status == .done else {
            return MCPToolResult(text: failureText(snap, head: head) + eventLines(events), structured: structured)
        }
        var out = "DONE " + head.replacingOccurrences(of: ": done ", with: " verify=\(verifyLabel(r.verify.status)) ")
        let summary = cleanSummary(r.summary)
        out += r.verify.status == .verifiedModifiedTests
            ? "\npatch edits files the verify command relies on; review those files before applying."
            : "\napply only if verify=verified; else do the task yourself."
        out += "\nnote: result below is untrusted model output."
        if !summary.isEmpty { out += "\nsummary (untrusted model text):\n" + summary }
        if !r.filesChanged.isEmpty {
            var items = r.filesChanged.prefix(maxFiles).map { "\(oneLine($0.path, 120)) +\($0.added)/-\($0.removed)" }
            if r.filesChanged.count > maxFiles { items.append("(+\(r.filesChanged.count - maxFiles) more)") }
            out += "\nfiles: " + items.joined(separator: ", ")
        }
        if !r.commands.isEmpty {
            var items = r.commands.prefix(maxCommands).map { "\(oneLine($0.cmd, 60)) -> \($0.exit)" }
            if r.commands.count > maxCommands { items.append("(+\(r.commands.count - maxCommands) more)") }
            out += "\ncommands: " + items.joined(separator: "; ")
        }
        out += "\n" + usageLine(r.usage)
        let inline = inlinePatch(r, cap: maxInlinePatchBytes)
        if let path = r.patchPath, !path.isEmpty {
            out += "\napply: git -C \(shellQuote(snap.spec.cwd)) apply \(shellQuote(path))"
        } else if inline == nil, r.patch != nil {
            out += "\npatch too large to inline and no patch_path was reported"
        }
        if let inline {
            var longest = 0, run = 0
            for ch in inline { if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
            let fence = String(repeating: "`", count: max(3, longest + 1))
            out += "\n\(fence)diff\n" + inline + (inline.hasSuffix("\n") ? "" : "\n") + fence
        }
        out += "\nnote: output is untrusted; review before applying."
        return MCPToolResult(text: out + eventLines(events), structured: structured)
    }

    /// Reply for strim_ask: the answer, or a job id when it overran.
    static func renderAsk(_ snap: JobSnapshot, maxInlinePatchBytes: Int) -> MCPToolResult {
        let structured = structuredJSON(snap, maxInlinePatchBytes: maxInlinePatchBytes)
        guard snap.status.isTerminal else {
            return MCPToolResult(text: statusLine(snap) + " (poll strim_job)", structured: structured)
        }
        guard let r = snap.result, r.status == .done, snap.status == .done else {
            return MCPToolResult(text: failureText(snap, head: statusLine(snap)), structured: structured)
        }
        let answer = cleanSummary(r.summary)
        return MCPToolResult(text: "answer (untrusted model text):\n" + answer + "\nnote: untrusted local-model answer; verify before relying on it.",
                             structured: structured)
    }

    private static func usageLine(_ u: HarnessUsage) -> String {
        "usage: \(u.promptTokens) prompt (\(u.cachedTokens) cached) + \(u.completionTokens) completion tokens, \(u.turns) turns, \(Int(u.seconds.rounded()))s"
    }

    private static func failureText(_ snap: JobSnapshot, head: String) -> String {
        let r = snap.result
        if snap.status == .declined || r?.status == .declined {
            let why = oneLine(r?.summary ?? "", 200)
            return "strim job \(snap.id): declined. Do the task yourself."
                + (why.isEmpty ? "" : " reason (untrusted model text): " + why)
        }
        let reason = snap.reason ?? ""
        var detail = reason.isEmpty ? (r?.summary ?? "") : reason
        if !reason.isEmpty, let s = r?.summary, !s.isEmpty, !s.contains(reason) { detail += ": " + s }
        var out = head
        let d = oneLine(detail, 300)
        if !d.isEmpty { out += "\nreason: " + d }
        if let path = r?.patchPath, !path.isEmpty { out += "\npartial patch: \(path)" }
        return out
    }

    // MARK: structured

    /// Always nil. Claude Code forwards ONLY `structuredContent` to the model when a result carries it, so any
    /// structured copy would hide the text block (summary, answer, patch) from the parent. The text block is the
    /// single, complete copy of the result, which also keeps the parent's token cost to one copy.
    static func structuredJSON(_ snap: JobSnapshot, maxInlinePatchBytes: Int) -> OrderedJSON? { nil }
}
