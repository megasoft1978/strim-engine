import Foundation

/// Deterministic diagnostics shared by the opt-in bash result shaper and stall reminder.
enum FailureFeedback {
    private static func replace(_ text: String, _ pattern: String, _ replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    static func isDiagnostic(_ line: String) -> Bool {
        line.range(of: #"(?i)(\b(assert\w*|\w*error|\w*exception|ERR_\w+|panic|fatal|failure|failed|expected|actual|not ok)\b|--- FAIL:|✖|✗|×|\bXCTAssert\w*)"#,
                   options: .regularExpression) != nil
    }

    static func normalized(_ line: String) -> String {
        var s = replace(line, #"\x1B\[[0-?]*[ -/]*[@-~]"#, "")
        s = replace(s, #"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?"#, "")
        s = replace(s, #"\b\d{2}:\d{2}:\d{2}(?:\.\d+)?\b"#, "")
        s = replace(s, #"\b0x[0-9a-fA-F]+\b"#, "<address>")
        s = replace(s, #"(?:/private)?/(?:tmp|var/(?:tmp|folders))/[^\s:'\"\)\]]+"#, "<tmp>")
        s = replace(s, #"(?i)(duration_(?:ms|us|ns):?\s*)\d+(?:\.\d+)?"#, "$1<duration>")
        s = replace(s, #"(?i)(\(|\[|\bin\s+|\bafter\s+|\btook\s+|\btime:\s*|\bfinished\s+in\s+|\bduration\s*:?\s*)\d+(?:\.\d+)?\s*(?:nanoseconds?|microseconds?|milliseconds?|seconds?|minutes?|ns|µs|μs|us|ms|secs?|mins?|s)\b"#, "$1<duration>")
        return replace(s, #"\s+"#, " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundedLines(_ output: String) -> [String] {
        let bytes = output.utf8
        let headSize = 256 * 1024
        let tailSize = 32 * 1024
        let headEnd = bytes.index(bytes.startIndex, offsetBy: headSize, limitedBy: bytes.endIndex) ?? bytes.endIndex
        let bounded: String
        if headEnd == bytes.endIndex {
            bounded = output
        } else {
            let tailStart = bytes.index(bytes.endIndex, offsetBy: -tailSize, limitedBy: headEnd) ?? headEnd
            bounded = String(decoding: bytes[..<headEnd], as: UTF8.self) + "\n[... output elided ...]\n" + String(decoding: bytes[tailStart...], as: UTF8.self)
        }
        return bounded.components(separatedBy: .newlines).map { String($0.prefix(400)) }
    }

    /// No signature for success or for an exit-only failure: there must be diagnostic evidence.
    /// Retain nearby assertion values too (e.g. Jest's Expected/Received and Go's indented got/want).
    static func signature(output: String, exitCode: Int32) -> String? {
        guard exitCode != 0 else { return nil }
        let lines = boundedLines(output)
        var selected: [String] = []
        var end = -1
        var blocks = 0
        for i in lines.indices where isDiagnostic(lines[i]) && i > end {
            guard blocks < 3 else { break }
            blocks += 1
            end = min(lines.count - 1, i + 2)
            for j in i...end {
                let s = normalized(lines[j])
                if !s.isEmpty, !s.hasPrefix("[exit code:") { selected.append(s) }
            }
        }
        guard !selected.isEmpty else { return nil }
        return "exit code: \(exitCode) | " + selected.joined(separator: " | ")
    }

    /// The legacy path stays byte-identical. The opt-in path has a strict character budget, including markers.
    static func shape(_ output: String, tool: String, exitCode: Int32, shape: HarnessKnobs.ResultShape, cap: Int) -> String {
        guard tool == "bash", shape == .errorsFirst, exitCode != 0, output.count > cap else {
            return Compaction.capToolOutput(output, cap: cap)
        }
        guard cap > 0 else { return "" }
        let header = "exit code: \(exitCode)"
        let lines = boundedLines(output)
        let errors = lines.indices.filter { isDiagnostic(lines[$0]) }
        var centers: [Int] = []
        for i in errors where centers.last.map({ i > $0 + 2 }) ?? true {
            centers.append(i)
            if centers.count == 3 { break }
        }
        // Prioritize the first diagnostic and final summary even when individual lines are huge.
        let first = centers.first ?? 0
        let last = lines.count - 1
        let summary = lines[last].hasPrefix("[exit code:") && last > 0 ? last - 1 : last
        var chosen: Set<Int> = [first, summary, last]
        let lineCap = max(1, (cap - header.count - 100) / max(chosen.count, 1))
        var clipped: [Int: String] = [:]
        for i in chosen where lines[i].count > lineCap {
            clipped[i] = String(lines[i].prefix(max(0, lineCap - 5))) + "[...]"
        }
        func render(_ indexes: Set<Int>) -> String {
            var parts = [header]
            var previous = -1
            for i in indexes.sorted() {
                if i > previous + 1 { parts.append("[... \(i - previous - 1) lines elided ...]") }
                parts.append(clipped[i] ?? lines[i])
                previous = i
            }
            if previous < last { parts.append("[... \(last - previous) lines elided ...]") }
            return parts.joined(separator: "\n")
        }
        // The trailer is already explicit in the header; omit it if the minimum budget needs the room.
        if render(chosen).count > cap, last != summary, last != first { chosen.remove(last) }
        var priorities = centers
        priorities += Array(max(0, last - 4)...last).reversed()
        for i in centers { priorities += Array(max(0, i - 2)...min(last, i + 2)) }
        if centers.isEmpty { priorities += Array(0...min(last, 2)) }
        for i in priorities where !chosen.contains(i) {
            let proposed = chosen.union([i])
            if render(proposed).count <= cap { chosen = proposed }
        }
        return String(render(chosen).prefix(cap))
    }
}

/// Per-drive state. Only successful file edits count; unchanged reruns neither advance nor trigger reminders.
struct StallTracker {
    private struct Seen {
        var turn: Int
        var edits: Int
        var recurrences = 0
        var lastNote: Int?
    }
    private var seen: [String: Seen] = [:]
    private var edits = 0

    mutating func edited() { edits += 1 }

    mutating func note(signature: String?, turn: Int) -> String? {
        guard let signature else { return nil }
        guard var prior = seen[signature] else {
            seen[signature] = Seen(turn: turn, edits: edits)
            return nil
        }
        let previousTurn = prior.turn
        let delta = edits - prior.edits
        prior.turn = turn
        prior.edits = edits
        if delta > 0 { prior.recurrences += 1 }
        defer { seen[signature] = prior }
        guard delta > 0, prior.recurrences >= 2, prior.lastNote.map({ turn - $0 >= 3 }) ?? true else { return nil }
        prior.lastNote = turn
        return "[harness] Same failure as turn \(previousTurn) after \(delta) edits: \(Compaction.sanitize(signature, max: 240)). Stop and re-check the root cause before editing again."
    }
}
