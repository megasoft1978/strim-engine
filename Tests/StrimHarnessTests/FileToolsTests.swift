import Foundation
import Testing
import StrimTemplate
@testable import StrimHarness

private func makeWorkspace() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("filetools-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ text: String, to root: URL, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ root: URL, _ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

private func args(_ pairs: [(String, OrderedJSON)]) -> [String: OrderedJSON] {
    Dictionary(uniqueKeysWithValues: pairs)
}

private func ctx(_ root: URL, _ access: AccessLevel = .write) -> ToolContext {
    ToolContext(root: root.path, access: access)
}

private func lines(_ n: Int, width: Int = 10) -> String {
    (1...n).map { String(format: "line %0\(width - 5)d", $0) }.joined(separator: "\n")
}

private final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Runs `tool` and gives up after `seconds`; nil means the call did not return in time.
private func runWithin(_ seconds: Double, _ tool: any HarnessTool, _ args: [String: OrderedJSON],
                       _ context: ToolContext) async -> ToolResult? {
    await withCheckedContinuation { (cont: CheckedContinuation<ToolResult?, Never>) in
        let gate = TestGate()
        Task.detached {
            let r = try? await tool.run(args, context: context)
            if gate.claim() { cont.resume(returning: r) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if gate.claim() { cont.resume(returning: nil) }
        }
    }
}

private func makeFifo(_ root: URL, _ path: String) throws {
    let p = root.appendingPathComponent(path).path
    guard mkfifo(p, 0o644) == 0 else { throw CocoaError(.fileWriteUnknown) }
}

@Suite struct FileToolsTests {
    // MARK: read_file

    @Test func readFileNumbersLinesWithDefaults() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("alpha\nbeta\ngamma\n", to: root, "a.txt")
        let r = try await ReadFileTool().run(args([("path", .string("a.txt"))]), context: ctx(root))
        #expect(!r.isError)
        #expect(r.output == "1\talpha\n2\tbeta\n3\tgamma")
    }

    @Test func readFileOffsetAndLimit() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("one\ntwo\nthree\nfour\nfive", to: root, "n.txt")
        let r = try await ReadFileTool().run(
            args([("path", .string("n.txt")), ("offset", .int(2)), ("limit", .int(2))]), context: ctx(root))
        #expect(r.output == "2\ttwo\n3\tthree\n[2 more lines; use offset=4]")
    }

    @Test func readFileOffsetBeyondEndIsError() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("only\n", to: root, "o.txt")
        let r = try await ReadFileTool().run(args([("path", .string("o.txt")), ("offset", .int(5))]), context: ctx(root))
        #expect(r.isError)
        #expect(r.output.contains("beyond end"))
    }

    @Test func readFileCapsOutputWithMarker() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write(lines(1000, width: 30), to: root, "big.txt")
        let r = try await ReadFileTool().run(
            args([("path", .string("big.txt")), ("limit", .int(1000))]), context: ctx(root))
        #expect(!r.isError)
        #expect(r.output.count <= 8000)
        #expect(r.output.contains("... [truncated; use offset]"))
        #expect(r.output.hasPrefix("1\tline"))
        #expect(r.output.hasSuffix("1000\tline " + String(format: "%025d", 1000)))
    }

    @Test func readFileMissingAndDirectoryAreErrors() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("x", to: root, "sub/f.txt")
        let missing = try await ReadFileTool().run(args([("path", .string("nope.txt"))]), context: ctx(root))
        #expect(missing.isError)
        let dir = try await ReadFileTool().run(args([("path", .string("sub"))]), context: ctx(root))
        #expect(dir.isError)
    }

    @Test func readFileBinarySkipped() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try Data([0x89, 0x50, 0x00, 0x47]).write(to: root.appendingPathComponent("img.bin"))
        let r = try await ReadFileTool().run(args([("path", .string("img.bin"))]), context: ctx(root))
        #expect(r.isError)
        #expect(r.output.contains("binary"))
    }

    // MARK: list_files

    @Test func listFilesNonRecursiveSkipsHeavyDirs() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("a", to: root, "top.txt")
        try write("b", to: root, "src/deep.swift")
        try write("c", to: root, ".git/config")
        try write("d", to: root, "node_modules/x.js")
        try write("e", to: root, ".build/y.o")
        let r = try await ListFilesTool().run([:], context: ctx(root))
        #expect(!r.isError)
        #expect(r.output == "src/\ntop.txt")
    }

    @Test func listFilesGlobRecursiveAndBasenameMatch() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("a", to: root, "Sources/A/one.swift")
        try write("b", to: root, "Sources/two.swift")
        try write("c", to: root, "Sources/notes.md")
        try write("d", to: root, ".git/hooks/x.swift")
        let deep = try await ListFilesTool().run(args([("glob", .string("**/*.swift"))]), context: ctx(root))
        #expect(deep.output == "Sources/A/one.swift\nSources/two.swift")
        let base = try await ListFilesTool().run(args([("glob", .string("*.md"))]), context: ctx(root))
        #expect(base.output == "Sources/notes.md")
        let anchored = try await ListFilesTool().run(args([("glob", .string("Sources/*.swift"))]), context: ctx(root))
        #expect(anchored.output == "Sources/two.swift")
    }

    @Test func listFilesCapsAt200() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<205 { try write("x", to: root, String(format: "d/f%03d.txt", i)) }
        let r = try await ListFilesTool().run(args([("path", .string("d")), ("glob", .string("*.txt"))]), context: ctx(root))
        #expect(r.output.contains("[5 more; narrow with glob or path]"))
        #expect(r.output.split(separator: "\n").count == 201)
    }

    @Test func listFilesRejectsFileAsDirectory() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("x", to: root, "f.txt")
        let r = try await ListFilesTool().run(args([("path", .string("f.txt"))]), context: ctx(root))
        #expect(r.isError)
    }

    // MARK: grep

    @Test func grepReportsPathLineText() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("first\nneedle here\nlast needle\n", to: root, "src/a.txt")
        try write("no match\n", to: root, "b.txt")
        let r = try await GrepTool().run(args([("pattern", .string("needle"))]), context: ctx(root))
        #expect(!r.isError)
        #expect(r.output == "src/a.txt:2:needle here\nsrc/a.txt:3:last needle")
    }

    @Test func grepPathAndGlobFilter() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("hit\n", to: root, "a/x.swift")
        try write("hit\n", to: root, "a/x.md")
        try write("hit\n", to: root, "b/y.swift")
        let r = try await GrepTool().run(
            args([("pattern", .string("hit")), ("path", .string("a")), ("glob", .string("*.swift"))]), context: ctx(root))
        #expect(r.output == "a/x.swift:1:hit")
        let single = try await GrepTool().run(
            args([("pattern", .string("hit")), ("path", .string("b/y.swift"))]), context: ctx(root))
        #expect(single.output == "b/y.swift:1:hit")
    }

    @Test func grepSkipsBinaryAndLargeFiles() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        var binary = Data("needle".utf8); binary.append(0)
        try binary.write(to: root.appendingPathComponent("bin.dat"))
        var big = Data(repeating: UInt8(ascii: "a"), count: 1_048_577)
        big.append(contentsOf: Array("needle".utf8))
        try big.write(to: root.appendingPathComponent("big.txt"))
        try write("needle ok\n", to: root, "small.txt")
        let r = try await GrepTool().run(args([("pattern", .string("needle"))]), context: ctx(root))
        #expect(r.output == "small.txt:1:needle ok")
    }

    @Test func grepCapsAt100Matches() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "hit\n", count: 150), to: root, "many.txt")
        let r = try await GrepTool().run(args([("pattern", .string("hit"))]), context: ctx(root))
        #expect(r.output.contains("[stopped at 100 matches]"))
        #expect(r.output.split(separator: "\n").filter { $0.hasPrefix("many.txt:") }.count == 100)
    }

    @Test func grepInvalidRegexIsError() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let r = try await GrepTool().run(args([("pattern", .string("("))]), context: ctx(root))
        #expect(r.isError)
    }

    // MARK: edit_file

    @Test func editFileReplacesUniqueMatch() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("let a = 1\nlet b = 2\n", to: root, "code.swift")
        let r = try await EditFileTool().run(
            args([("path", .string("code.swift")), ("old", .string("let b = 2")), ("new", .string("let b = 3"))]),
            context: ctx(root))
        #expect(!r.isError)
        #expect(try read(root, "code.swift") == "let a = 1\nlet b = 3\n")
    }

    @Test func editFileEmptyNewDeletes() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("keep\ndrop me\n", to: root, "d.txt")
        let r = try await EditFileTool().run(
            args([("path", .string("d.txt")), ("old", .string("drop me\n")), ("new", .string(""))]), context: ctx(root))
        #expect(!r.isError)
        #expect(try read(root, "d.txt") == "keep\n")
    }

    @Test func editFileZeroMatchesIsError() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("hello\n", to: root, "h.txt")
        let r = try await EditFileTool().run(
            args([("path", .string("h.txt")), ("old", .string("absent")), ("new", .string("x"))]), context: ctx(root))
        #expect(r.isError)
        #expect(r.output.contains("0 matches"))
        #expect(try read(root, "h.txt") == "hello\n")
    }

    @Test func editFileMultipleMatchesIsError() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("x = 1\nx = 1\n", to: root, "m.txt")
        let r = try await EditFileTool().run(
            args([("path", .string("m.txt")), ("old", .string("x = 1")), ("new", .string("x = 2"))]), context: ctx(root))
        #expect(r.isError)
        #expect(r.output.contains("matches 2 times"))
        #expect(try read(root, "m.txt") == "x = 1\nx = 1\n")
    }

    @Test func editFileEmptyOldIsError() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("abc", to: root, "e.txt")
        let r = try await EditFileTool().run(
            args([("path", .string("e.txt")), ("old", .string("")), ("new", .string("x"))]), context: ctx(root))
        #expect(r.isError)
        #expect(try read(root, "e.txt") == "abc")
    }

    // MARK: write_file

    @Test func writeFileCreatesParentsAndOverwrites() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try await WriteFileTool().run(
            args([("path", .string("new/dir/f.txt")), ("content", .string("v1"))]), context: ctx(root))
        #expect(!created.isError)
        #expect(try read(root, "new/dir/f.txt") == "v1")
        let again = try await WriteFileTool().run(
            args([("path", .string("new/dir/f.txt")), ("content", .string("v2"))]), context: ctx(root))
        #expect(!again.isError)
        #expect(try read(root, "new/dir/f.txt") == "v2")
    }

    @Test func writeFileRefusesOversizeContent() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let big = String(repeating: "a", count: 1_048_577)
        let r = try await WriteFileTool().run(
            args([("path", .string("big.txt")), ("content", .string(big))]), context: ctx(root))
        #expect(r.isError)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("big.txt").path))
    }

    // MARK: access and containment

    @Test func readOnlyBlocksEditAndWrite() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("orig\n", to: root, "r.txt")
        let ro = ctx(root, .read)
        let edit = try await EditFileTool().run(
            args([("path", .string("r.txt")), ("old", .string("orig")), ("new", .string("changed"))]), context: ro)
        #expect(edit.isError)
        #expect(edit.output.contains("read-only"))
        let wr = try await WriteFileTool().run(
            args([("path", .string("w.txt")), ("content", .string("x"))]), context: ro)
        #expect(wr.isError)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("w.txt").path))
        #expect(try read(root, "r.txt") == "orig\n")
        let rd = try await ReadFileTool().run(args([("path", .string("r.txt"))]), context: ro)
        #expect(!rd.isError)
    }

    @Test func traversalAndAbsoluteOutsideAreDenied() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("secret-outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escaped = "../" + outside.lastPathComponent
        let r = try await ReadFileTool().run(args([("path", .string(escaped))]), context: ctx(root))
        #expect(r.isError)
        #expect(!r.output.contains("secret-outside"))
        let abs = try await ReadFileTool().run(args([("path", .string(outside.path))]), context: ctx(root))
        #expect(abs.isError)
        #expect(!abs.output.contains("secret-outside"))
        let w = try await WriteFileTool().run(
            args([("path", .string("../" + outside.lastPathComponent)), ("content", .string("pwned"))]), context: ctx(root))
        #expect(w.isError)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "secret-outside")
        let g = try await GrepTool().run(
            args([("pattern", .string("secret")), ("path", .string(".."))]), context: ctx(root))
        #expect(g.isError)
    }

    @Test func deniedFilesAreRefused() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("TOKEN=abc", to: root, ".env")
        let r = try await ReadFileTool().run(args([("path", .string(".env"))]), context: ctx(root))
        #expect(r.isError)
        #expect(!r.output.contains("TOKEN"))
    }

    @Test func outputIsRedacted() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let secret = "FILETOOLS-SECRET-\(UUID().uuidString)"
        Redactor.register(secret: secret)
        try write("token is \(secret)\n", to: root, "t.txt")
        let r = try await ReadFileTool().run(args([("path", .string("t.txt"))]), context: ctx(root))
        #expect(!r.output.contains(secret))
        #expect(r.output.contains("[REDACTED]"))
    }

    @Test func deniedEntriesHiddenFromGrepAndListing() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let needle = "NEEDLE-\(UUID().uuidString)"
        try write("\(needle) env\n", to: root, ".env")
        try write("\(needle) key\n", to: root, "key.pem")
        try write("\(needle) id\n", to: root, ".ssh/id_rsa")
        try write("\(needle) creds\n", to: root, ".aws/credentials")
        try write("\(needle) normal\n", to: root, "normal.txt")
        let c = ctx(root)

        let grep = try await GrepTool().run(args([("pattern", .string(needle))]), context: c)
        #expect(!grep.isError)
        #expect(grep.output == "normal.txt:1:\(needle) normal")

        let top = try await ListFilesTool().run([:], context: c)
        #expect(top.output == "normal.txt")

        let all = try await ListFilesTool().run(args([("glob", .string("**"))]), context: c)
        #expect(all.output == "normal.txt")

        let direct = try await ReadFileTool().run(args([("path", .string(".env"))]), context: c)
        #expect(direct.isError)
        #expect(!direct.output.contains(needle))
    }

    // MARK: robustness: overflow, regex and glob cost, special files, size and link limits

    @Test func readFileHugeLimitDoesNotTrap() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("one\ntwo\nthree\n", to: root, "h.txt")
        let r = try await ReadFileTool().run(
            args([("path", .string("h.txt")), ("offset", .int(2)), ("limit", .int(Int.max))]), context: ctx(root))
        #expect(!r.isError)
        #expect(r.output == "2\ttwo\n3\tthree")
    }

    @Test func readFileNonPositiveOffsetOrLimitIsError() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("a\nb\n", to: root, "p.txt")
        for extra in [("offset", OrderedJSON.int(-5)), ("offset", .int(0)), ("limit", .int(0)), ("limit", .int(-1))] {
            let r = try await ReadFileTool().run(args([("path", .string("p.txt")), extra]), context: ctx(root))
            #expect(r.isError, "\(extra.0)")
        }
    }

    @Test func readFileLargeFileReadsWindowAndSaysSo() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "0123456789abcdef\n", count: 300_000), to: root, "huge.txt")
        let r = try await ReadFileTool().run(args([("path", .string("huge.txt"))]), context: ctx(root))
        #expect(!r.isError)
        #expect(r.output.hasPrefix("1\t0123456789abcdef"))
        #expect(r.output.contains("first 256 KB"))
    }

    @Test func globLongerThan256IsRejected() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("a", to: root, "a.txt")
        let huge = await runWithin(8, ListFilesTool(),
                                   args([("glob", .string(String(repeating: "*", count: 20_000)))]), ctx(root))
        #expect(huge?.isError == true)
        let over = await runWithin(8, ListFilesTool(),
                                   args([("glob", .string(String(repeating: "*", count: 257)))]), ctx(root))
        #expect(over?.isError == true)
        let atLimit = await runWithin(8, ListFilesTool(),
                                      args([("glob", .string(String(repeating: "*", count: 256)))]), ctx(root))
        #expect(atLimit?.isError == false)
        #expect(atLimit?.output == "a.txt")
    }

    @Test func globMatchingIsPolynomial() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("x", to: root, String(repeating: "a", count: 40))
        let start = Date()
        let r = await runWithin(8, ListFilesTool(),
                                args([("glob", .string("*a*a*a*a*a*a*a*ac"))]), ctx(root))
        #expect(r?.output == "(no entries)")
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func grepNestedQuantifierIsRejectedOrTimesOut() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "a", count: 36) + "b\n", to: root, "long.txt")
        let r = await runWithin(8, GrepTool(), args([("pattern", .string("(a+)+$"))]), ctx(root))
        #expect(r != nil, "grep did not return within 8 s")
        #expect(r?.isError == true)
    }

    @Test func grepOversizedPatternIsRejected() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("aaa\n", to: root, "a.txt")
        let big = await runWithin(8, GrepTool(), args([("pattern", .string(String(repeating: "a", count: 201)))]), ctx(root))
        #expect(big?.isError == true)
        let ok = await runWithin(8, GrepTool(), args([("pattern", .string(String(repeating: "a", count: 200)))]), ctx(root))
        #expect(ok?.isError == false)
    }

    @Test func grepCapsLongLines() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "x", count: 1_000_000) + "needle\n", to: root, "wide.txt")
        try write("needle" + String(repeating: "y", count: 10_000) + "\n", to: root, "near.txt")
        let far = await runWithin(8, GrepTool(), args([("pattern", .string("needle")), ("path", .string("wide.txt"))]), ctx(root))
        #expect(far?.output == "(no matches)")
        let near = await runWithin(8, GrepTool(), args([("pattern", .string("needle")), ("path", .string("near.txt"))]), ctx(root))
        #expect(near?.output.hasPrefix("near.txt:1:needle") == true)
        #expect((near?.output.count ?? Int.max) <= 4200)
    }

    @Test func fifoIsRejectedByReadEditAndGrepPromptly() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try makeFifo(root, "pipe")
        let read = await runWithin(8, ReadFileTool(), args([("path", .string("pipe"))]), ctx(root))
        #expect(read?.isError == true)
        let edit = await runWithin(8, EditFileTool(),
                                   args([("path", .string("pipe")), ("old", .string("a")), ("new", .string("b"))]), ctx(root))
        #expect(edit?.isError == true)
        let grep = await runWithin(8, GrepTool(), args([("pattern", .string("a")), ("path", .string("pipe"))]), ctx(root))
        #expect(grep?.isError == true)
    }

    @Test func fifoIsSkippedByDirectoryWalks() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try makeFifo(root, "pipe")
        try write("needle\n", to: root, "ok.txt")
        let grep = await runWithin(8, GrepTool(), args([("pattern", .string("needle"))]), ctx(root))
        #expect(grep?.output == "ok.txt:1:needle")
        let list = await runWithin(8, ListFilesTool(), args([("glob", .string("*"))]), ctx(root))
        #expect(list?.output == "ok.txt")
    }

    @Test func editFileRefusesFilesOverOneMegabyte() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let big = String(repeating: "a", count: 5 * 1024 * 1024) + "\nneedle\n"
        try write(big, to: root, "big.txt")
        let r = try await EditFileTool().run(
            args([("path", .string("big.txt")), ("old", .string("needle")), ("new", .string("x"))]), context: ctx(root))
        #expect(r.isError)
        #expect(r.output.contains("1 MB"))
        #expect(try read(root, "big.txt") == big)
    }

    @Test func hardlinkedFileRefusedForEditWriteAndRead() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("hl-outside-\(UUID().uuidString).txt")
        try Data("secret\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.linkItem(at: outside, to: root.appendingPathComponent("hl.txt"))
        let edit = try await EditFileTool().run(
            args([("path", .string("hl.txt")), ("old", .string("secret")), ("new", .string("pwned"))]), context: ctx(root))
        #expect(edit.isError)
        let wr = try await WriteFileTool().run(
            args([("path", .string("hl.txt")), ("content", .string("pwned"))]), context: ctx(root))
        #expect(wr.isError)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "secret\n")
        let rd = try await ReadFileTool().run(args([("path", .string("hl.txt"))]), context: ctx(root))
        #expect(rd.isError)
        #expect(!rd.output.contains("secret"))
    }

    @Test func writeAtomicallyDoesNotFollowLinkedFinalComponent() throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("swap-target-\(UUID().uuidString).txt")
        try Data("secret-outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        // Stands in for a swap between resolve and write: the final component is now a link out of the workspace.
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        var threw = false
        do { try writeAtomically(Data("pwned".utf8), to: link, root: root.path) } catch { threw = true }
        #expect(threw)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "secret-outside")
    }

    @Test func writeAtomicallyRefusesParentOutsideWorkspace() throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let outsideDir = root.deletingLastPathComponent().appendingPathComponent("swap-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        // An intermediate component is a link out of the workspace: the parent's real path is outside.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a"), withDestinationURL: outsideDir)
        var threw = false
        do { try writeAtomically(Data("x".utf8), to: root.appendingPathComponent("a/sub/new.txt"), root: root.path) } catch { threw = true }
        #expect(threw)
        #expect(!FileManager.default.fileExists(atPath: outsideDir.appendingPathComponent("sub/new.txt").path))
    }

    @Test func writeAtomicallyReplacesRegularFileAndKeepsMode() throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write("old\n", to: root, "run.sh")
        let url = root.appendingPathComponent("run.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try writeAtomically(Data("new\n".utf8), to: url, root: root.path)
        #expect(try read(root, "run.sh") == "new\n")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
    }

    @Test func deadlineAbandonsWorkThatNeverReturns() async {
        let start = Date()
        let stuck: Int? = await runWithDeadline(0.2) { () -> Int in
            Thread.sleep(forTimeInterval: 3)
            return 1
        }
        #expect(stuck == nil)
        #expect(Date().timeIntervalSince(start) < 2)
        let quick: Int? = await runWithDeadline(5) { () -> Int in 7 }
        #expect(quick == 7)
    }

    @Test func grepAbortsPolynomialMatchAtDeadline() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "a", count: 3000) + "\n", to: root, "poly.txt")
        let grep = GrepTool()
        let start = Date()
        let r = await runWithin(20, grep, args([("pattern", .string(".*.*.*.*.*x")), ("path", .string("poly.txt"))]), ctx(root))
        #expect(r?.isError == true)
        #expect(r?.output.contains("timed out") == true)
        #expect(Date().timeIntervalSince(start) < 7)
        // The stop flag must end the matching worker; it must not keep spinning after its deadline.
        var waited = 0.0
        while grep.limiter.runningCount > 0 && waited < 3 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        #expect(grep.limiter.runningCount == 0)
        #expect(!grep.limiter.isDisabled)
        // Follow-up search on the same tool instance still works.
        let follow = await runWithin(8, grep, args([("pattern", .string("a{3}")), ("path", .string("poly.txt"))]), ctx(root))
        #expect(follow?.isError == false)
        #expect(follow?.output.hasPrefix("poly.txt:1:") == true)
    }

    @Test func abandonedSearchDisablesSearchingAfterGrace() async throws {
        let limiter = SearchLimiter()
        var timedOut = false
        do {
            _ = try await runSearch(limiter, seconds: 0.2, grace: 0.2) { () -> Int? in
                Thread.sleep(forTimeInterval: 1.5)
                return 1
            }
        } catch {
            timedOut = true
        }
        #expect(timedOut)
        try await Task.sleep(for: .milliseconds(700))
        #expect(limiter.isDisabled)
        var refused = false
        do { _ = try await runSearch(limiter) { () -> Int? in 2 } } catch { refused = true }
        #expect(refused)
    }

    @Test func searchesAreCappedWhileWorkersAreAlive() {
        let limiter = SearchLimiter()
        let tokens = (0..<4).compactMap { _ in limiter.acquire() }
        #expect(tokens.count == 4)
        #expect(limiter.acquire() == nil)
        limiter.release(tokens[0])
        #expect(limiter.acquire() != nil)
    }

    @Test func listFilesWithoutGlobStopsAtCap() async throws {
        let root = try makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<205 { try write("x", to: root, String(format: "d/f%03d.txt", i)) }
        let r = await runWithin(8, ListFilesTool(), args([("path", .string("d"))]), ctx(root))
        #expect(r?.output.contains("[more entries not listed; narrow with path]") == true)
        #expect(r?.output.split(separator: "\n").count == 201)
        #expect(r?.output.hasPrefix("d/f000.txt\nd/f001.txt") == true)
    }

    @Test func specsDeclareRequiredParameters() {
        #expect(ReadFileTool().spec.name == "read_file")
        #expect(ListFilesTool().spec.name == "list_files")
        #expect(GrepTool().spec.name == "grep")
        #expect(EditFileTool().spec.name == "edit_file")
        #expect(WriteFileTool().spec.name == "write_file")
        #expect(EditFileTool().spec.parameters?["required"] == .array([.string("path"), .string("old"), .string("new")]))
    }
}
