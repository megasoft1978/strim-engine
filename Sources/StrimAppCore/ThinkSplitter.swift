import Foundation

/// Splits raw assistant text into reasoning and answer segments by `<think>` / `</think>` tags.
///
/// Pure function of the whole raw text so far, so tags split across streaming chunks need no state:
/// - `<think>...</think>` blocks (any number) become reasoning segments.
/// - A closing tag with no opening tag (templates that put `<think>` in the prompt) turns the text before it into
///   reasoning when answer text follows it; a trailing stray closer (nothing after it) is just dropped.
/// - Tags inside fenced code blocks stay literal.
/// - While streaming (`final == false`) a trailing partial tag such as `</thi` is withheld.
public enum ThinkSplitter {
    public struct Segment: Equatable, Sendable {
        public var isReasoning: Bool
        public var text: String
        public init(isReasoning: Bool, text: String) { self.isReasoning = isReasoning; self.text = text }
    }

    private static let open = Array("<think>")
    private static let close = Array("</think>")

    public static func split(_ raw: String, final: Bool) -> [Segment] {
        let s = Array(raw)
        var segs: [(reasoning: Bool, text: String, strayBefore: Bool)] = []
        var cur = ""
        var inThink = false
        var inFence = false
        var strayMarks: [Int] = []          // segs.count at each stray closer
        var i = 0
        var atLineStart = true

        func flush() {
            if !cur.isEmpty { segs.append((inThink, cur, false)); cur = "" }
        }
        func matches(_ tag: [Character], at k: Int) -> Bool {
            k + tag.count <= s.count && Array(s[k..<(k + tag.count)]) == tag
        }
        func isPartialTag(at k: Int) -> Bool {
            let rest = Array(s[k...])
            return [open, close].contains { rest.count < $0.count && Array($0[0..<rest.count]) == rest }
        }

        while i < s.count {
            if atLineStart {
                var j = i
                while j < s.count, s[j] == " ", j - i < 3 { j += 1 }
                if j + 3 <= s.count, s[j] == "`", s[j + 1] == "`", s[j + 2] == "`" { inFence.toggle() }
            }
            if !inFence {
                if matches(open, at: i) {
                    flush(); inThink = true; i += open.count; atLineStart = false; continue
                }
                if matches(close, at: i) {
                    flush()
                    if inThink { inThink = false } else { strayMarks.append(segs.count) }
                    i += close.count; atLineStart = false
                    continue
                }
                if !final, isPartialTag(at: i) { break }
            }
            cur.append(s[i])
            atLineStart = s[i] == "\n"
            i += 1
        }
        flush()

        // Stray closers: text before one is reasoning when answer text follows it.
        var out = segs.map { Segment(isReasoning: $0.reasoning, text: $0.text) }
        for mark in strayMarks.reversed() {
            let after = out[mark...].contains { !$0.isReasoning && !$0.text.allSatisfy(\.isWhitespace) }
            if after { for k in 0..<mark where !out[k].isReasoning { out[k].isReasoning = true } }
        }

        // Trim the whitespace that separates blocks, merge neighbours of the same kind, drop empties.
        var merged: [Segment] = []
        for seg in out {
            if let last = merged.last, last.isReasoning == seg.isReasoning { merged[merged.count - 1].text += seg.text }
            else { merged.append(seg) }
        }
        return merged.compactMap { seg in
            var t = seg.text
            t = trimLeadingNewlines(t)
            if seg.isReasoning { t = trimTrailingNewlines(t) }
            return t.allSatisfy(\.isWhitespace) ? nil : Segment(isReasoning: seg.isReasoning, text: t)
        }
    }

    private static func trimLeadingNewlines(_ t: String) -> String {
        String(t.drop { $0 == "\n" || $0 == "\r" })
    }
    private static func trimTrailingNewlines(_ t: String) -> String {
        var t = t
        while let l = t.last, l == "\n" || l == "\r" { t.removeLast() }
        return t
    }
}
