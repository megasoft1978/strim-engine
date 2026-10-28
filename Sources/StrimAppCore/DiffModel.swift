import Foundation

public struct DiffLine: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case context, added, removed, meta }
    public var id: Int
    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
    /// Contains invisible/bidirectional/control characters.
    public var hasHidden = false
    /// Contains non-ASCII whitespace (NBSP, ideographic space, ...): a soft note, not a tick.
    public var hasUnusualSpace = false
    /// Text safe to render: hidden characters appear as `\u{..}` escapes.
    public var displayText: String { DiffText.visible(text) }
}

public struct DiffHunk: Equatable, Sendable, Identifiable {
    public var id: Int
    public var header: String
    public var lines: [DiffLine]
    public var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
    /// False when the body did not have exactly the line counts the `@@` header promised.
    public var countsMatch = true
    public var displayHeader: String { DiffText.visible(header) }
}

/// A header line of a file section. Every one is kept and shown; `tag` is the badge text.
public struct HeaderRow: Equatable, Sendable, Identifiable {
    public var id: Int
    public var text: String
    public var tag: String
    public var displayText: String { DiffText.visible(text) }
}

public enum ChangeKind: String, Sendable, Equatable {
    case modified, added, deleted, renamed, copied, modeChange = "mode change", symlink, binary
}

public struct DiffFile: Equatable, Sendable, Identifiable {
    public var id: Int
    public var path: String
    public var oldPath: String?
    public var isNew = false
    public var isDeleted = false
    public var oldMode: String?
    public var newMode: String?
    public var renameFrom: String?, renameTo: String?
    public var copyFrom: String?, copyTo: String?
    public var isSymlink = false
    public var symlinkTarget: String?
    public var isBinary = false
    public var binaryLineCount = 0
    public var headerRows: [HeaderRow] = []
    public var hunks: [DiffHunk] = []
    /// Lines that fit no category (kept so nothing is hidden).
    public var strayLines: [String] = []
    public var kinds: [ChangeKind] = []
    public var added = 0
    public var removed = 0
    /// Code lines containing invisible/bidirectional/control characters.
    public var hiddenLineCount = 0
    /// Code lines with unusual (non-ASCII) whitespace; reported as a note only.
    public var unusualSpaceLineCount = 0
    public var displayPath: String { DiffText.visible(path) }
    var pendingIssues: [PatchIssue] = []
}

public struct PatchIssue: Equatable, Sendable {
    public var reason: String
    /// Blocking issues mean the patch is not understood: Apply is never offered.
    public var blocking: Bool
}

/// Result of analyzing a patch for the approval screen.
public struct PatchAnalysis: Equatable, Sendable {
    public var files: [DiffFile]
    public var issues: [PatchIssue]
    public var preamble: [String]
    public var byteSize: Int
    /// What is special about this patch, e.g. "adds a symlink", "makes a file executable".
    public var specials: [String]
    /// Non-blocking observations that do not require a tick (e.g. unusual whitespace in code).
    public var notes: [String] = []

    public var suspicious: Bool { !issues.isEmpty }
    public var blocked: Bool { issues.contains { $0.blocking } }
    public var needsConfirmation: Bool { !blocked && (!specials.isEmpty || suspicious) }
    public var totalAdded: Int { files.reduce(0) { $0 + $1.added } }
    public var totalRemoved: Int { files.reduce(0) { $0 + $1.removed } }

    public var confirmationText: String? {
        guard needsConfirmation else { return nil }
        var t = ""
        if !specials.isEmpty {
            t = "This patch " + (specials.count == 1 ? specials[0]
                : specials.dropLast().joined(separator: ", ") + " and " + specials[specials.count - 1])
        }
        let sus = issues.map(\.reason)
        if !sus.isEmpty { t += (t.isEmpty ? "This patch looks suspicious: " : "; suspicious: ") + sus.joined(separator: "; ") }
        return t
    }

    public var summary: String { DiffParser.summary(files) + ", " + DiffParser.byteString(byteSize) }
}

/// Parses a unified/git diff and keeps EVERY line: headers become rows, unknown lines become stray lines.
/// Hunk bodies are validated against their `@@` counts.
public enum DiffParser {
    public static func parse(_ patch: String) -> [DiffFile] { analyze(patch).files }

    public static func analyze(data: Data) -> PatchAnalysis {
        var a = analyze(String(decoding: data, as: UTF8.self), byteSize: data.count)
        if String(data: data, encoding: .utf8) == nil, !a.issues.contains(where: { $0.reason.contains("UTF-8") }) {
            a.issues.insert(PatchIssue(reason: "patch is not valid UTF-8", blocking: true), at: 0)
        }
        return a
    }

    public static func analyze(_ patch: String) -> PatchAnalysis { analyze(patch, byteSize: patch.utf8.count) }

    // MARK: implementation

    private enum Mode { case header, hunk, binaryHeader, binaryData }

    private static func analyze(_ patch: String, byteSize: Int) -> PatchAnalysis {
        var files: [DiffFile] = []
        var issues: [PatchIssue] = []
        var preamble: [String] = []
        var cur: DiffFile?
        var mode = Mode.header
        var hunk: DiffHunk?
        var oldRem = 0, newRem = 0, oldN = 0, newN = 0
        var lineID = 0, hunkID = 0, rowID = 0
        var strayCount = 0
        var binHunks = 0, binDataLines = 0

        func block(_ r: String) { issues.append(PatchIssue(reason: r, blocking: true)) }
        func suspect(_ r: String) { issues.append(PatchIssue(reason: r, blocking: false)) }

        if patch.utf8.contains(0) { block("patch contains NUL bytes") }
        if patch.unicodeScalars.contains("\u{FFFD}") { block("patch contains invalid UTF-8") }

        func finishHunk() {
            guard var h = hunk else { return }
            if oldRem != 0 || newRem != 0 {
                h.countsMatch = false
                block("hunk \(DiffText.visible(h.header)) in \(show(cur?.path ?? "?")): line counts do not match its @@ header")
            }
            cur?.hunks.append(h)
            hunk = nil; oldRem = 0; newRem = 0
        }
        func finishFile() {
            finishHunk()
            guard var f = cur else { return }
            if mode == .binaryData { block("binary patch for \(show(f.path)) is truncated (no terminating blank line)") }
            if mode == .binaryHeader, binHunks == 0 { block("binary patch for \(show(f.path)) has no data") }
            if strayCount > 0 {
                block("\(strayCount) unexpected line(s) outside any hunk in \(show(f.path))")
            }
            strayCount = 0
            finalize(&f)
            files.append(f)
            cur = nil
        }
        func row(_ text: String, _ tag: String) {
            rowID += 1
            cur?.headerRows.append(HeaderRow(id: rowID, text: text, tag: tag))
        }
        func stray(_ line: String) { cur?.strayLines.append(line); strayCount += 1 }
        func startFile(path: String, old: String?) {
            cur = DiffFile(id: files.count, path: path, oldPath: old)
            mode = .header; binHunks = 0; binDataLines = 0
        }
        func startHunk(_ line: String) {
            finishHunk()
            if cur?.isBinary == true { block("text hunk inside a binary file section (\(show(cur?.path ?? "?")))") }
            guard let r = parseHunkHeader(line) else {
                block("malformed hunk header: \(show(String(line.prefix(80))))")
                stray(line); return
            }
            hunk = DiffHunk(id: hunkID, header: line, lines: [], oldStart: r.os, oldCount: r.oc, newStart: r.ns, newCount: r.nc)
            hunkID += 1
            oldRem = r.oc; newRem = r.nc; oldN = r.os; newN = r.ns
            mode = .hunk
        }
        func addLine(_ kind: DiffLine.Kind, _ text: String) {
            lineID += 1
            let l: DiffLine
            switch kind {
            case .added: l = DiffLine(id: lineID, kind: kind, text: text, oldNumber: nil, newNumber: newN); newN += 1; newRem -= 1
            case .removed: l = DiffLine(id: lineID, kind: kind, text: text, oldNumber: oldN, newNumber: nil); oldN += 1; oldRem -= 1
            case .context: l = DiffLine(id: lineID, kind: kind, text: text, oldNumber: oldN, newNumber: newN); oldN += 1; newN += 1; oldRem -= 1; newRem -= 1
            case .meta: l = DiffLine(id: lineID, kind: kind, text: text, oldNumber: nil, newNumber: nil)
            }
            var l2 = l
            if kind != .meta {
                if DiffText.hasHiddenInCode(text) { l2.hasHidden = true }
                if DiffText.hasUnusualSpaceInCode(text) { l2.hasUnusualSpace = true }
            }
            hunk?.lines.append(l2)
        }

        /// `--- a/P` / `+++ b/P` must name the same file as the `diff --git` line (or /dev/null).
        func checkPathHeader(_ line: String, _ prefix: String, expect: String?) {
        var p = String(line.dropFirst(prefix.count))
        if let t = p.firstIndex(of: "\t") { p = String(p[..<t]) }
        if p == "/dev/null" { return }
        if p.hasPrefix("\"") { cur?.pendingIssues.append(PatchIssue(reason: "quoted path in \(prefix.trimmingCharacters(in: .whitespaces)) header: \(show(p))", blocking: false)); return }
        let stripped = (p.hasPrefix("a/") || p.hasPrefix("b/")) ? String(p.dropFirst(2)) : p
        if let e = expect, Array(stripped.utf8) != Array(e.utf8) {      // bytes, not String ==: that is canonical equivalence
            let canon = stripped == e ? " (canonically equivalent Unicode with different bytes: normalization trick)" : ""
            cur?.pendingIssues.append(PatchIssue(reason: "\(prefix.trimmingCharacters(in: .whitespaces)) path \(show(stripped)) differs from diff header path \(show(e))\(canon)", blocking: false))
        }
    }


        func headerLine(_ line: String) {
        func val(_ p: String) -> String { String(line.dropFirst(p.count)) }
        if line.hasPrefix("old mode ") { cur?.oldMode = val("old mode "); row(line, "old mode") }
        else if line.hasPrefix("new mode ") { cur?.newMode = val("new mode "); row(line, "new mode") }
        else if line.hasPrefix("new file mode ") { cur?.isNew = true; cur?.newMode = val("new file mode "); row(line, "new file mode") }
        else if line.hasPrefix("deleted file mode ") { cur?.isDeleted = true; cur?.oldMode = val("deleted file mode "); row(line, "deleted file mode") }
        else if line.hasPrefix("rename from ") { cur?.renameFrom = val("rename from "); row(line, "rename from") }
        else if line.hasPrefix("rename to ") { cur?.renameTo = val("rename to "); row(line, "rename to") }
        else if line.hasPrefix("copy from ") { cur?.copyFrom = val("copy from "); row(line, "copy from") }
        else if line.hasPrefix("copy to ") { cur?.copyTo = val("copy to "); row(line, "copy to") }
        else if line.hasPrefix("similarity index ") { row(line, "similarity") }
        else if line.hasPrefix("dissimilarity index ") { row(line, "dissimilarity") }
        else if line.hasPrefix("index ") {
            row(line, "index")
            // "index abc..def 120000" carries the mode when it did not change
            let parts = line.split(separator: " ")
            if parts.count == 3 {
                if cur?.newMode == nil { cur?.newMode = String(parts[2]) }
                if cur?.oldMode == nil { cur?.oldMode = String(parts[2]) }
            } else if parts.count != 2 {
                cur?.pendingIssues.append(PatchIssue(reason: "malformed index line \(show(String(line.prefix(80))))", blocking: true))
            }
        }
        else if line.hasPrefix("--- ") { row(line, "old file"); checkPathHeader(line, "--- ", expect: cur?.renameFrom ?? cur?.copyFrom ?? cur?.oldPath) }
        else if line.hasPrefix("+++ ") { row(line, "new file path"); checkPathHeader(line, "+++ ", expect: cur?.renameTo ?? cur?.copyTo ?? cur?.path) }
        else if line.hasPrefix("Binary files "), line.hasSuffix(" differ") { cur?.isBinary = true; row(line, "binary") }
        else if line == "GIT binary patch" { cur?.isBinary = true; row(line, "binary"); mode = .binaryHeader; binHunks = 0 }
        else {
                row(line, "unknown")
                let why = "unrecognized header line \(show(String(line.prefix(80)))) in \(show(cur?.path ?? "?"))"
                cur?.pendingIssues.append(PatchIssue(reason: why, blocking: true))
            }
    }


        func headerState(_ line: String) {
            if line.hasPrefix("@@") { startHunk(line) } else { headerLine(line) }
        }

        var lines = patch.utf8.split(separator: 10, omittingEmptySubsequences: false).map { String(Substring($0)) }
        if lines.last == "" { lines.removeLast() }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                finishFile()
                let (a, b) = parseGitPaths(String(line.dropFirst("diff --git ".count)))
                startFile(path: b, old: a)
                if a.contains("\"") || b.contains("\"") { suspect("quoted/escaped path in diff header (unusual characters): \(show(line))") }
                continue
            }
            if cur == nil {
                if line.isEmpty { continue }
                if line.hasPrefix("@@") || line.hasPrefix("--- ") {
                    block("no 'diff --git' header before the first hunk")
                    startFile(path: "(patch)", old: nil)
                } else { preamble.append(line); continue }
            }
            switch mode {
            case .binaryHeader:
                if isBinaryHunkHeader(line) { row(line, "binary hunk"); binDataLines = 0; mode = .binaryData }
                else {
                    if binHunks == 0 { block("binary patch for \(show(cur?.path ?? "?")) has no 'literal'/'delta' data") }
                    mode = .header
                    headerState(line)
                }
            case .binaryData:
                if line.isEmpty {
                    if binDataLines == 0 { block("empty binary hunk in \(show(cur?.path ?? "?"))") }
                    binHunks += 1
                    mode = binHunks < 2 ? .binaryHeader : .header
                } else if isBase85Line(line) {
                    binDataLines += 1; cur?.binaryLineCount += 1
                } else {
                    stray(line)
                    block("invalid data inside a binary patch for \(show(cur?.path ?? "?")): \(show(String(line.prefix(60))))")
                    mode = .header
                }
            case .hunk:
                if oldRem > 0 || newRem > 0 {
                    if line.hasPrefix("@@") { startHunk(line); continue }
                    if line.hasPrefix(" ") || line.isEmpty, oldRem > 0, newRem > 0 { addLine(.context, String(line.dropFirst())) }
                    else if line.hasPrefix("-"), oldRem > 0 { addLine(.removed, String(line.dropFirst())) }
                    else if line.hasPrefix("+"), newRem > 0 { addLine(.added, String(line.dropFirst())) }
                    else if line.hasPrefix("\\") { addLine(.meta, line) }
                    else { stray(line); hunk?.countsMatch = false; block("hunk line counts do not match its @@ header (line that does not fit)") }
                } else {
                    if line.hasPrefix("@@") { startHunk(line) }
                    else if line.hasPrefix("\\") { addLine(.meta, line) }
                    else {
                        stray(line)
                        if line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") {
                            hunk?.countsMatch = false
                            block("hunk line counts do not match its @@ header (extra line after the hunk)")
                        }
                    }
                }
            case .header:
                headerState(line)
            }
        }
        finishFile()

        if !preamble.isEmpty { block("content before the first diff header (\(preamble.count) line(s))") }
        if files.isEmpty { block("patch contains no file changes") }

        issues.append(contentsOf: files.flatMap(\.pendingIssues))
        var seen = Set<[UInt8]>(); issues = issues.filter { seen.insert(Array($0.reason.utf8)).inserted }
        var cleaned = files
        for i in cleaned.indices { cleaned[i].pendingIssues = [] }

        var specials: [String] = []
        for f in cleaned { for s in specialsFor(f) where !specials.contains(s) { specials.append(s) } }
        var exec: [String] = []
        for f in cleaned {
            for p in [f.path, f.oldPath, f.renameFrom, f.renameTo, f.copyFrom, f.copyTo].compactMap({ $0 }) where ExecutingPaths.matches(p) {
                let v = DiffText.visible(p)
                if !exec.contains(v) { exec.append(v) }
            }
        }
        if !exec.isEmpty {
            let shown = exec.prefix(3).joined(separator: ", ") + (exec.count > 3 ? " and \(exec.count - 3) more" : "")
            specials.append("touches files that run on open, commit or build (\(shown))")
        }
        var notes: [String] = []
        for f in cleaned where f.unusualSpaceLineCount > 0 {
            notes.append("\(f.unusualSpaceLineCount) line(s) in \(show(f.path)) contain unusual whitespace (e.g. non-breaking space), shown as \\u{..} escapes")
        }
        return PatchAnalysis(files: cleaned, issues: issues, preamble: preamble, byteSize: byteSize, specials: specials, notes: notes)
    }

    private static func parseGitPaths(_ rest: String) -> (String, String) {
        if rest.contains("\"") { return (rest, rest) }
        var best: (String, String)?
        var searchStart = rest.startIndex
        while let r = rest.range(of: " b/", range: searchStart..<rest.endIndex) {
            var left = String(rest[..<r.lowerBound]); let right = String(rest[r.upperBound...])
            if left.hasPrefix("a/") { left = String(left.dropFirst(2)) }
            best = (left, right)
            if left == right { return (left, right) }
            searchStart = r.upperBound
        }
        return best ?? (rest, rest)
    }

    private static func parseHunkHeader(_ h: String) -> (os: Int, oc: Int, ns: Int, nc: Int)? {
        // @@ -a[,b] +c[,d] @@ ...
        let parts = h.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4, parts[0] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+"), parts[3].hasPrefix("@@") else { return nil }
        func range(_ s: Substring) -> (Int, Int)? {
            let f = s.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard f.count <= 2, let a = Int(f[0]), a >= 0 else { return nil }
            if f.count == 2 { guard let b = Int(f[1]), b >= 0 else { return nil }; return (a, b) }
            return (a, 1)
        }
        guard let o = range(parts[1]), let n = range(parts[2]) else { return nil }
        return (o.0, o.1, n.0, n.1)
    }

    private static func finalize(_ f: inout DiffFile) {
        f.unusualSpaceLineCount = f.hunks.reduce(0) { $0 + $1.lines.reduce(0) { $0 + ($1.hasUnusualSpace ? 1 : 0) } }
        f.hiddenLineCount = f.hunks.reduce(0) { $0 + $1.lines.reduce(0) { $0 + ($1.hasHidden ? 1 : 0) } }
        if f.hiddenLineCount > 0 {
            f.pendingIssues.append(PatchIssue(reason: "\(f.hiddenLineCount) line(s) in \(show(f.path)) contain invisible or bidirectional characters (shown as \\u{..} escapes)", blocking: false))
        }
        f.added = f.hunks.reduce(0) { $0 + $1.lines.reduce(0) { $0 + ($1.kind == .added ? 1 : 0) } }
        f.removed = f.hunks.reduce(0) { $0 + $1.lines.reduce(0) { $0 + ($1.kind == .removed ? 1 : 0) } }
        let om = f.oldMode.flatMap(GitMode.parse), nm = f.newMode.flatMap(GitMode.parse)
        for raw in [f.oldMode, f.newMode] {
            guard let raw else { continue }
            if let m = GitMode.parse(raw), GitMode.isAllowed(m) { continue }
            f.pendingIssues.append(PatchIssue(reason: "invalid or unsupported file mode \(show(raw)) for \(show(f.path))", blocking: true))
        }
        f.isSymlink = om.map(GitMode.isSymlink) == true || nm.map(GitMode.isSymlink) == true
        if f.isSymlink {
            let all = f.hunks.flatMap(\.lines)
            f.symlinkTarget = (f.isDeleted ? all.first { $0.kind == .removed } : all.first { $0.kind == .added })?.text
            if let t = f.symlinkTarget {
                if t.hasPrefix("/") { f.pendingIssues.append(PatchIssue(reason: "symlink target is an absolute path: \(show(t))", blocking: false)) }
                else if t.split(separator: "/").contains("..") { f.pendingIssues.append(PatchIssue(reason: "symlink target escapes with '..': \(show(t))", blocking: false)) }
            }
        }
        var k: [ChangeKind] = []
        if f.isNew { k.append(.added) }
        if f.isDeleted { k.append(.deleted) }
        if f.renameFrom != nil || f.renameTo != nil { k.append(.renamed) }
        if f.copyFrom != nil || f.copyTo != nil { k.append(.copied) }
        if f.isSymlink { k.append(.symlink) }
        if f.isBinary { k.append(.binary) }
        if !f.isNew, !f.isDeleted, let o = om, let n = nm, o != n { k.append(.modeChange) }
        if !f.hunks.isEmpty, !f.isNew, !f.isDeleted { k.append(.modified) }
        f.kinds = k

        // path validation over every path the patch names
        var named: [String] = [f.path]
        if let o = f.oldPath { named.append(o) }
        for p in [f.renameFrom, f.renameTo, f.copyFrom, f.copyTo] { if let p { named.append(p) } }
        var seen = Set<[UInt8]>()      // byte identity: canonically-equal spellings are still examined separately
        for p in named where seen.insert(Array(p.utf8)).inserted {
            if let why = pathProblem(p) { f.pendingIssues.append(PatchIssue(reason: "path \(show(p)): \(why)", blocking: false)) }
        }
        if f.renameFrom == nil, f.copyFrom == nil, let o = f.oldPath, Array(o.utf8) != Array(f.path.utf8), !f.path.contains("\"") {
            f.pendingIssues.append(PatchIssue(reason: "paths differ without a rename: \(show(o)) vs \(show(f.path))", blocking: false))
        }
    }

    static func pathProblem(_ p: String) -> String? {
        if p.isEmpty { return "empty path" }
        if p.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return "contains control characters" }
        if DiffText.hasHidden(p) { return "contains invisible, blank-looking or unusual-whitespace characters" }
        if Array(p.utf8) != Array(p.precomposedStringWithCanonicalMapping.utf8) { return "is not in NFC Unicode form (decomposed or normalization-trick name)" }
        if p.contains("\"") || p.contains("\\") { return "contains quote or backslash characters" }
        if p.hasPrefix("/") { return "absolute path" }
        let comps = p.split(separator: "/", omittingEmptySubsequences: false)
        if comps.contains("..") { return "contains '..' (path traversal)" }
        if comps.contains(where: { $0.lowercased() == ".git" }) { return "touches a '.git' directory" }
        return nil
    }

    static func specialsFor(_ f: DiffFile) -> [String] {
        var s: [String] = []
        if f.isSymlink { s.append(f.isNew ? "adds a symlink" : f.isDeleted ? "deletes a symlink" : "changes a symlink") }
        let om = f.oldMode.flatMap(GitMode.parse), nm = f.newMode.flatMap(GitMode.parse)
        if om.map(GitMode.isGitlink) == true || nm.map(GitMode.isGitlink) == true { s.append("touches a submodule") }
        if !f.isSymlink {
            let ox = om.map(GitMode.isExecutable) ?? false, nx = nm.map(GitMode.isExecutable) ?? false
            if f.isNew, nx { s.append("adds an executable file") }
            else if !f.isNew, !f.isDeleted, let o = om, let n = nm, o != n {
                if nx && !ox { s.append("makes a file executable") }
                else if ox && !nx { s.append("removes the executable bit") }
                else { s.append("changes a file mode") }
            }
        }
        if f.renameFrom != nil || f.renameTo != nil { s.append("renames a file") }
        if f.copyFrom != nil || f.copyTo != nil { s.append("copies a file") }
        if f.isBinary { s.append("contains binary data") }
        return s
    }

    private static let base85: Set<UInt8> = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~".utf8)

    /// `literal N` or `delta N`.
    static func isBinaryHunkHeader(_ l: String) -> Bool {
        for p in ["literal ", "delta "] where l.hasPrefix(p) {
            let n = l.dropFirst(p.count)
            return !n.isEmpty && n.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        }
        return false
    }
    /// One git base85 line: a length char ('A'-'Z' = 1...26, 'a'-'z' = 27...52) then ceil(len/4)*5 base85 chars.
    static func isBase85Line(_ l: String) -> Bool {
        let u = Array(l.utf8)
        guard let f = u.first else { return false }
        let len: Int
        if f >= 65 && f <= 90 { len = Int(f) - 64 } else if f >= 97 && f <= 122 { len = Int(f) - 96 + 26 } else { return false }
        guard u.count - 1 == ((len + 3) / 4) * 5 else { return false }
        return u.dropFirst().allSatisfy { base85.contains($0) }
    }

    /// Quoted printable form of text: control, format and bidi characters become `\\u{..}` escapes.
    static func show(_ s: String) -> String { "'" + DiffText.visible(s) + "'" }

    public static func summary(_ files: [DiffFile]) -> String {
        let a = files.reduce(0) { $0 + $1.added }, r = files.reduce(0) { $0 + $1.removed }
        return "\(files.count) file\(files.count == 1 ? "" : "s"), +\(a) -\(r)"
    }
    public static func byteString(_ n: Int) -> String {
        n < 1024 ? "\(n) B" : n < 1_048_576 ? String(format: "%.1f KB", Double(n) / 1024) : String(format: "%.1f MB", Double(n) / 1_048_576)
    }
}


/// Git file modes, normalised the way git reads them: octal digits only, compared as integers.
public enum GitMode {
    /// Trims whitespace; nil unless the rest is non-empty octal digits.
    public static func parse(_ raw: String) -> Int? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.utf8.count <= 12, t.utf8.allSatisfy({ $0 >= 48 && $0 <= 55 }) else { return nil }
        return Int(t, radix: 8)
    }
    public static func isSymlink(_ m: Int) -> Bool { (m & 0o170000) == 0o120000 }
    public static func isGitlink(_ m: Int) -> Bool { m == 0o160000 }
    public static func isExecutable(_ m: Int) -> Bool { (m & 0o111) != 0 }
    /// The only modes accepted in an applicable patch.
    public static func isAllowed(_ m: Int) -> Bool { [0o100644, 0o100755, 0o120000, 0o160000].contains(m) }
}

import CryptoKit

/// SHA-256 over the exact UTF-8 bytes of a patch, lowercase hex.
public enum PatchDigest {
    public static func sha256(_ patch: String) -> String {
        SHA256.hash(data: Data(patch.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Rendering helpers: nothing invisible or blank-looking is ever shown raw.
public enum DiffText {
    private static let blankLooking: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x034F, 0x180E]

    /// Invisible or blank-looking: control (except tab), format (bidi, zero-width, BOM, soft hyphen, tags), line/paragraph
    /// separators, default-ignorable code points, variation selectors and the explicit filler/blank set.
    public static func isHidden(_ u: Unicode.Scalar) -> Bool {
        if u == "\t" { return false }
        if blankLooking.contains(u.value) { return true }
        let p = u.properties
        if p.isDefaultIgnorableCodePoint || p.isVariationSelector { return true }
        switch p.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
    /// Any space separator other than U+0020 (NBSP, U+1680, U+2000...U+200A, U+202F, U+205F, U+3000).
    public static func isUnusualSpace(_ u: Unicode.Scalar) -> Bool {
        u != " " && u.properties.generalCategory == .spaceSeparator
    }
    private static func needsScan(_ s: String) -> Bool {
        s.utf8.contains { $0 >= 0x80 || ($0 < 0x20 && $0 != 9) || $0 == 0x7f }
    }
    /// For PATHS: hidden characters and unusual spaces both count.
    public static func hasHidden(_ s: String) -> Bool {
        needsScan(s) && s.unicodeScalars.contains(where: { isHidden($0) || isUnusualSpace($0) })
    }
    /// Code lines: hidden characters only (a single trailing CR from CRLF files is ignored).
    /// Unusual spaces in code are a soft note (`hasUnusualSpaceInCode`), not a reason to demand a tick.
    static func hasHiddenInCode(_ s: String) -> Bool {
        guard needsScan(s) else { return false }
        var u = Array(s.unicodeScalars)
        if u.last == "\r" { u.removeLast() }
        return u.contains(where: isHidden)
    }
    static func hasUnusualSpaceInCode(_ s: String) -> Bool {
        needsScan(s) && s.unicodeScalars.contains(where: isUnusualSpace)
    }
    /// Escapes everything above (and unusual spaces) as `\u{..}`.
    public static func visible(_ s: String) -> String {
        guard needsScan(s) else { return s }
        var out = ""
        for u in s.unicodeScalars {
            if isHidden(u) || isUnusualSpace(u) { out += "\\u{" + String(u.value, radix: 16) + "}" } else { out.unicodeScalars.append(u) }
        }
        return out
    }
}

/// Paths that execute code when a folder is opened, committed, built or tested.
public enum ExecutingPaths {
    private static let dirs: Set<String> = [".vscode", ".husky", ".githooks", "scripts", ".github"]
    private static let files: Set<String> = [".envrc", "makefile", "gnumakefile", "package.json", "package.swift", "pyproject.toml",
                                              "setup.py", "conftest.py", ".gitattributes", ".gitmodules", ".npmrc", ".pre-commit-config.yaml"]
    public static func matches(_ path: String) -> Bool {
        let comps = path.split(separator: "/").map { $0.lowercased() }
        guard let last = comps.last else { return false }
        if comps.dropLast().contains(where: { dirs.contains($0) }) { return true }
        return files.contains(last) || last.hasPrefix("dockerfile")
    }
}
