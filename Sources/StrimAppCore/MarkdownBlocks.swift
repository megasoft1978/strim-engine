import Foundation

/// Block-level split of chat markdown: prose paragraphs and fenced code. Newlines inside fences are kept verbatim.
public enum MarkdownBlock: Equatable, Sendable {
    case prose(String)
    case code(language: String, text: String)

    public static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var lang = ""
        var inFence = false
        func flushProse() {
            let t = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.isEmpty { blocks.append(.prose(t)) }
            prose = []
        }
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            let isFence = trimmed.hasPrefix("```") && line.count - trimmed.count <= 3
            if isFence {
                if inFence {
                    blocks.append(.code(language: lang, text: code.joined(separator: "\n"))); code = []; inFence = false
                } else {
                    flushProse(); lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased(); inFence = true
                }
            } else if inFence { code.append(line) } else { prose.append(line) }
        }
        if inFence { blocks.append(.code(language: lang, text: code.joined(separator: "\n"))) }   // still streaming
        else { flushProse() }
        return blocks
    }
}

/// Line classes of a diff, for colouring (indigo added, coral removed, never green).
public enum DiffLineKind: Equatable, Sendable {
    case added, removed, hunk, header, context

    public static func classify(_ line: String) -> DiffLineKind {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return .header }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }

    /// True for fences tagged diff/patch.
    public static func isDiffLanguage(_ l: String) -> Bool { l == "diff" || l == "patch" || l == "udiff" }
}
