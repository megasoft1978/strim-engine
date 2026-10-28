import Foundation
import Testing
import StrimTemplate
@testable import StrimHarness

private func workspace() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("editfb-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func put(_ data: Data, _ root: URL, _ name: String) throws {
    try data.write(to: root.appendingPathComponent(name))
}

private func edit(_ root: URL, _ path: String, old: String, new: String) async throws -> ToolResult {
    try await EditFileTool().run(
        [("path", OrderedJSON.string(path)), ("old", .string(old)), ("new", .string(new))]
            .reduce(into: [String: OrderedJSON]()) { $0[$1.0] = $1.1 },
        context: ToolContext(root: root.path, access: .write))
}

private func bytes(_ root: URL, _ name: String) throws -> Data {
    try Data(contentsOf: root.appendingPathComponent(name))
}

@Suite struct FileToolsEditFeedbackTests {
    @Test func successReportsRangeAndContext() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try put(Data(text.utf8), root, "f.txt")
        let r = try await edit(root, "f.txt", old: "line 5", new: "LINE FIVE")
        #expect(!r.isError)
        let expected = """
            edited f.txt: replaced line 5; now line 5
            2\tline 2
            3\tline 3
            4\tline 4
            5\tLINE FIVE
            6\tline 6
            7\tline 7
            8\tline 8
            """
        #expect(r.output == expected)
    }

    @Test func multiLineReplaceAndDeleteRanges() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data("a\nb\nc\nd\n".utf8), root, "g.txt")
        let r = try await edit(root, "g.txt", old: "b\nc\n", new: "X\nY\nZ\n")
        #expect(r.output.hasPrefix("edited g.txt: replaced lines 2-3; now lines 2-4\n"))
        let d = try await edit(root, "g.txt", old: "X\nY\nZ\n", new: "")
        #expect(d.output.hasPrefix("edited g.txt: removed lines 2-4\n"))
        #expect(try bytes(root, "g.txt") == Data("a\nd\n".utf8))
    }

    @Test func successOutputIsRedacted() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data("k = 1\n".utf8), root, "s.txt")
        let secret = "ghp_" + String(repeating: "Q", count: 36)
        let r = try await edit(root, "s.txt", old: "k = 1", new: "k = \(secret)")
        #expect(!r.isError && !r.output.contains(secret))
    }

    @Test func longEditIsElided() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data("a\nb\n".utf8), root, "l.txt")
        let big = (1...200).map { "n\($0)" }.joined(separator: "\n") + "\n"
        let r = try await edit(root, "l.txt", old: "a\n", new: big)
        #expect(r.output.contains("lines not shown"))
        #expect(r.output.split(separator: "\n").count < 40)
    }

    @Test func trailingWhitespaceIsNormalizedWhenUnique() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data("one  \ntwo\t\nthree\n".utf8), root, "w.txt")
        let r = try await edit(root, "w.txt", old: "one\ntwo\n", new: "1\n2\n")
        #expect(!r.isError)
        #expect(r.output.contains("normalizing trailing whitespace/CRLF"))
        #expect(try bytes(root, "w.txt") == Data("1\n2\nthree\n".utf8))
    }

    @Test func crlfFileKeepsCRLFAfterNormalizedEdit() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data("a\r\nb\r\nc\r\n".utf8), root, "c.txt")
        let r = try await edit(root, "c.txt", old: "a\nb\n", new: "A\nB\n")
        #expect(!r.isError)
        #expect(r.output.contains("normalizing"))
        #expect(try bytes(root, "c.txt") == Data("A\r\nB\r\nc\r\n".utf8))
    }

    @Test func normalizedAmbiguityIsRefused() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data("x = 1 \nx = 1\t\n".utf8), root, "n.txt")
        let r = try await edit(root, "n.txt", old: "x = 1\n", new: "y\n")
        #expect(r.isError && r.output.contains("0 matches"))
        #expect(try bytes(root, "n.txt") == Data("x = 1 \nx = 1\t\n".utf8))
    }

    @Test func exactMatchesAreNeverNormalized() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data("p\nq \n".utf8), root, "e.txt")
        let r = try await edit(root, "e.txt", old: "q ", new: "Q")
        #expect(!r.isError && !r.output.contains("normalizing"))
        #expect(try bytes(root, "e.txt") == Data("p\nQ\n".utf8))
    }

    @Test func multiMatchListsCountAndLines() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data("x = 1\ny\nx = 1\nz\nx = 1\n".utf8), root, "m.txt")
        let r = try await edit(root, "m.txt", old: "x = 1", new: "x = 2")
        #expect(r.isError)
        #expect(r.output == "error: old matches 3 times in m.txt (starting at lines 1, 3, 5); nothing was changed. "
            + "Include more surrounding lines in old so it matches exactly once.")
        #expect(try bytes(root, "m.txt") == Data("x = 1\ny\nx = 1\nz\nx = 1\n".utf8))
    }

    @Test func nearMissIndentationDifference() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data("fn a() {\n    let x = 1\n    return x\n}\n".utf8), root, "i.txt")
        let r = try await edit(root, "i.txt", old: "  let x = 1\n  return x", new: "z")
        #expect(r.isError)
        #expect(r.output.contains("0 matches"))
        #expect(r.output.contains("lines 2-3 only if whitespace"))
        #expect(r.output.contains("read_file"))
    }

    @Test func nearMissSuggestsClosestLine() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data("alpha\nlet total = compute(items)\nomega\n".utf8), root, "t.txt")
        let r = try await edit(root, "t.txt", old: "let total = compute(items)\nreturn totl", new: "z")
        #expect(r.isError)
        #expect(r.output.contains("Closest lines:"))
        #expect(r.output.contains("2: let total = compute(items)"))
        #expect(r.output.contains("read_file"))
    }

    @Test func noSimilarLine() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data("alpha\nbeta\n".utf8), root, "u.txt")
        let r = try await edit(root, "u.txt", old: "completely different text", new: "z")
        #expect(r.isError && r.output.contains("No similar line found") && r.output.contains("read_file"))
    }

    @Test func binaryFileDoesNotCrash() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try put(Data([0x00, 0xFF, 0x10, 0x80, 0x00]), root, "b.bin")
        let r = try await edit(root, "b.bin", old: "a", new: "b")
        #expect(r.isError && r.output.contains("binary"))
    }

    @Test func hugeFileAndNearMissStayBounded() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let line = String(repeating: "word ", count: 40) + "\n"
        let body = String(repeating: line, count: 4000)  // ~800 KB, 4000 lines
        try put(Data(body.utf8), root, "big.txt")
        let start = Date()
        let r = try await edit(root, "big.txt", old: String(repeating: "word ", count: 60) + "zzz\nnext", new: "q")
        #expect(r.isError && r.output.contains("0 matches"))
        #expect(Date().timeIntervalSince(start) < 5)
        let tooBig = Data(String(repeating: "a\n", count: 600_000).utf8)
        try put(tooBig, root, "huge.txt")
        let h = try await edit(root, "huge.txt", old: "a", new: "b")
        #expect(h.isError && h.output.contains("1 MB"))
    }

    @Test func longLinesInSnippetsAreTruncated() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let long = "const v = " + String(repeating: "x", count: 5000)
        try put(Data((long + "\n").utf8), root, "long.txt")
        let r = try await edit(root, "long.txt", old: "const v = " + String(repeating: "y", count: 10) + "\n" + long, new: "z")
        #expect(r.isError)
        #expect(r.output.count < 1500)
    }
}
