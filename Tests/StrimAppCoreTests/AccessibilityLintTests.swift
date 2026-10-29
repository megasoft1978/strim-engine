import Foundation
import Testing

/// Reads the SwiftUI view sources (Sources/StrimApp) relative to this file, with comments blanked and line numbers kept.
enum ViewSources {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let dir = root.appendingPathComponent("Sources/StrimApp")

    static func allFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".swift") }.sorted()
    }
    static func raw(_ file: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)) ?? "" }

    /// Line comments blanked (strings in these files never contain "//").
    static func code(_ file: String) -> String { stripComments(raw(file)) }
    static func stripComments(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
    }
}

/// Source scanner: every Button / Toggle / Picker / Menu whose label is only an image needs `.accessibilityLabel` or `.help`.
enum AccessibilityLint {
    struct Finding: Equatable, CustomStringConvertible {
        var file: String
        var line: Int
        var control: String
        var description: String { "\(file):\(line): icon-only \(control) has no .accessibilityLabel or .help" }
    }

    static func findings(in source: String, file: String) -> [Finding] {
        let chars = Array(source)
        var out: [Finding] = []
        let regex = try! NSRegularExpression(pattern: #"\b(Button|Toggle|Picker|Menu)\s*([({])"#)
        let ns = source as NSString
        for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            // NSString offsets are UTF-16; the sources are ASCII apart from comments and strings, so map by prefix length.
            let startOffset = source.utf16.index(source.utf16.startIndex, offsetBy: m.range(at: 2).location)
            let open = source.distance(from: source.startIndex, to: startOffset)
            guard let label = labelClosure(chars, open: open) else { continue }
            let text = String(chars[label.range])
            let iconOnly = text.contains("Image(") && !text.contains("Text(") && !text.contains("Label(") && !text.contains("label()")
            guard iconOnly else { continue }
            let chain = modifierChain(chars, from: label.end)
            if chain.contains(".accessibilityLabel(") || chain.contains(".help(") { continue }
            let line = chars[..<open].filter { $0 == "\n" }.count + 1
            out.append(Finding(file: file, line: line, control: name))
        }
        return out
    }

    // MARK: parsing helpers

    /// The label closure of the control whose opening `(` or `{` is at `open`, or nil when the label is a title.
    private static func labelClosure(_ c: [Character], open: Int) -> (range: Range<Int>, end: Int)? {
        var i = open
        if c[i] == "(" {
            let close = skipBalanced(c, from: i)
            let args = String(c[(i + 1)..<(close - 1)])
            // Titled controls (`Button("Save")`, `Toggle("Name", isOn:)`, `Button(model.title)`) are labelled by the title.
            let first = args.trimmingCharacters(in: .whitespacesAndNewlines)
            guard first.hasPrefix("action:") || first.hasPrefix("isOn:") else { return nil }
            i = skipSpace(c, close)
            guard i < c.count, c[i] == "{" else { return nil }
            let end = skipBalanced(c, from: i)
            return ((i + 1)..<(end - 1), end)
        }
        // `{ action-or-content } label: { ... }`
        let afterBody = skipBalanced(c, from: i)
        let j = skipSpace(c, afterBody)
        let tag = Array("label:")
        guard j + tag.count <= c.count, Array(c[j..<(j + tag.count)]) == tag else { return nil }
        let k = skipSpace(c, j + tag.count)
        guard k < c.count, c[k] == "{" else { return nil }
        let end = skipBalanced(c, from: k)
        return ((k + 1)..<(end - 1), end)
    }

    /// Text of the `.modifier(...)` calls chained after `from` (across newlines).
    private static func modifierChain(_ c: [Character], from: Int) -> String {
        var i = from
        var chain = ""
        while true {
            let j = skipSpace(c, i)
            guard j < c.count, c[j] == "." else { break }
            var k = j + 1
            while k < c.count, c[k].isLetter || c[k].isNumber || c[k] == "_" { k += 1 }
            chain += String(c[j..<k])
            while k < c.count, c[k] == " " { k += 1 }   // `.onHover { ... }` (trailing closure after a space)
            if k < c.count, c[k] == "(" || c[k] == "{" {
                let end = skipBalanced(c, from: k)
                chain += String(c[k..<end])
                k = end
            }
            i = k
        }
        return chain
    }

    private static func skipSpace(_ c: [Character], _ from: Int) -> Int {
        var i = from
        while i < c.count, c[i].isWhitespace { i += 1 }
        return i
    }

    /// Index just past the bracket that closes the one at `from`; string literals (with `\( )` interpolation) are skipped.
    private static func skipBalanced(_ c: [Character], from: Int) -> Int {
        var depth = 0
        var i = from
        while i < c.count {
            switch c[i] {
            case "\"": i = skipString(c, i); continue
            case "(", "{", "[": depth += 1
            case ")", "}", "]":
                depth -= 1
                if depth == 0 { return i + 1 }
            default: break
            }
            i += 1
        }
        return c.count
    }
    private static func skipString(_ c: [Character], _ from: Int) -> Int {
        var i = from + 1
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count {
                if c[i + 1] == "(" { i = skipBalanced(c, from: i + 1); continue }
                i += 2; continue
            }
            if c[i] == "\"" { return i + 1 }
            i += 1
        }
        return c.count
    }
}

@Suite struct AccessibilityLintTests {
    @Test func everyIconOnlyControlHasALabel() {
        let files = ViewSources.allFiles()
        #expect(files.count >= 10, "view sources not found next to the tests (\(ViewSources.dir.path))")
        var all: [AccessibilityLint.Finding] = []
        for f in files { all += AccessibilityLint.findings(in: ViewSources.code(f), file: "Sources/StrimApp/\(f)") }
        #expect(all.isEmpty, Comment(rawValue: all.map(\.description).joined(separator: "\n")))
    }

    @Test func lintFlagsAnIconOnlyButtonWithoutALabel() {
        let bad = """
        struct V {
            var body: some View {
                Button { go() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                Button(action: go) { Image(systemName: "plus").font(.title) }
                Toggle(isOn: $on) { Image(systemName: "star") }
                Menu { Button("A") { a() } } label: { Image(systemName: "ellipsis") }.menuStyle(.button)
            }
        }
        """
        let found = AccessibilityLint.findings(in: bad, file: "V.swift")
        #expect(found.map(\.line) == [3, 5, 6, 7])
        #expect(found.map(\.control) == ["Button", "Button", "Toggle", "Menu"])
        #expect(found[0].description == "V.swift:3: icon-only Button has no .accessibilityLabel or .help")
    }

    @Test func lintAcceptsLabelledAndTitledControls() {
        let good = """
        Button { go() } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain)
            .foregroundStyle(.red).help("Dismiss")
        Button(action: go) { Image(systemName: "plus") }.accessibilityLabel("Add")
        Button("Save") { save() }
        Button(title) { save() }
        Toggle("Name", isOn: $on).labelsHidden()
        Button { go() } label: { Label("Back", systemImage: "chevron.left") }
        Menu { Text("x") } label: { Image(systemName: "plus") }
            .menuStyle(.button)
            .onHover { hover = $0 }
            .accessibilityLabel("Add project")
        Button { go("a (b") } label: { Image(systemName: "i") }.help("x")
        """
        #expect(AccessibilityLint.findings(in: good, file: "V.swift").isEmpty)
    }
}
