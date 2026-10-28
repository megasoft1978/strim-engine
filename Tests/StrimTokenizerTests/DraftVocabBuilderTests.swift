import Foundation
import XCTest
@testable import StrimTokenizer

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

final class DraftVocabBuilderTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("draftvocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func write(_ root: URL, _ rel: String, _ bytes: [UInt8]) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: u)
    }

    func testRankKeepsSpecialsThenFrequencyThenLowerId() {
        let counts: [Int32: Int] = [5: 10, 7: 10, 9: 3, 2: 1]
        // Trimmed: specials 0 and 1 kept, then the two most frequent (ties by lower id).
        XCTAssertEqual(DraftVocabBuilder.rank(counts: counts, special: [0, 1], k: 4), [0, 1, 5, 7])
        // Tie at count 10 between 3 and 5: lower id wins.
        XCTAssertEqual(DraftVocabBuilder.rank(counts: [5: 10, 3: 10], special: [], k: 1), [3])
    }

    func testRankFillsWithLowestUnusedIds() {
        let counts: [Int32: Int] = [5: 10, 7: 10, 9: 3, 2: 1]
        XCTAssertEqual(DraftVocabBuilder.rank(counts: counts, special: [0, 1], k: 8), [0, 1, 2, 3, 4, 5, 7, 9])
        XCTAssertEqual(DraftVocabBuilder.rank(counts: [:], special: [0], k: 3), [0, 1, 2])
    }

    func testJSONLayoutMatchesCommittedFormat() {
        let plain = DraftVocabBuilder.Result(k: 4, tokenizerSha256: "ab", corpusNote: nil, ids: [0, 1, 2, 3],
                                             fileCount: 0, seen: 0, special: 0, base: 0)
        XCTAssertEqual(DraftVocabBuilder.json(plain), "{\"k\":4,\"tokenizer_sha256\":\"ab\",\"ids\":[0,1,2,3]}\n")
        let noted = DraftVocabBuilder.Result(k: 2, tokenizerSha256: "ab", corpusNote: "files=1 paths_sha256=cd",
                                             ids: [7, 9], fileCount: 1, seen: 0, special: 0, base: 0)
        XCTAssertEqual(DraftVocabBuilder.json(noted),
                       "{\"k\":2,\"tokenizer_sha256\":\"ab\",\"corpus_note\":\"files=1 paths_sha256=cd\",\"ids\":[7,9]}\n")
    }

    func testSHA256KnownVector() {
        XCTAssertEqual(DraftVocabBuilder.sha256Hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testAddedTokensReadsIdAndContent() throws {
        let json = #"{"added_tokens":[{"id":248046,"content":"<|im_end|>"},{"id":248044,"content":"<|endoftext|>"}],"model":{}}"#
        let t = try DraftVocabBuilder.addedTokens(tokenizerJSON: Data(json.utf8))
        XCTAssertEqual(t.map(\.id), [248046, 248044])
        XCTAssertEqual(t.map(\.content), ["<|im_end|>", "<|endoftext|>"])
    }

    /// Extra walks: only listed extensions, no .git, no symlinks, no base files, no run logs or previous outputs,
    /// no NUL or invalid UTF-8, no files over maxBytes.
    func testExtraSourcesRules() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "vendor/x.py", Array("print(1)\n".utf8))
        try write(root, "vendor/sub/z.swift", Array("let z = 1\n".utf8))
        try write(root, "vendor/.git/y.py", Array("hidden\n".utf8))
        try write(root, "vendor/bin.py", [0x61, 0x00, 0x62])
        try write(root, "vendor/bad.md", [0xff, 0xfe, 0x41])
        try write(root, "vendor/notes.txt", Array("not a listed extension\n".utf8))
        try write(root, "vendor/big.md", [UInt8](repeating: 0x41, count: DraftVocabBuilder.maxBytes + 1))
        try write(root, "bench/results/r.json", Array("{}".utf8))
        try write(root, "bench/draft_vocab_old.json", Array("{}".utf8))
        try write(root, "bench/keep.json", Array("{}".utf8))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("vendor/link.py"), withDestinationURL: root.appendingPathComponent("vendor/x.py"))

        let walked = try DraftVocabBuilder.extraSources(root: root, dirs: ["vendor"], baseRels: ["vendor/x.py"], outRel: "")
        XCTAssertEqual(walked.map(\.rel), ["vendor/sub/z.swift"])
        XCTAssertEqual(walked.first?.text, "let z = 1\n")

        let bench = try DraftVocabBuilder.extraSources(root: root, dirs: ["bench"], baseRels: [], outRel: "bench/keep.json")
        XCTAssertEqual(bench.map(\.rel), [])

        XCTAssertThrowsError(try DraftVocabBuilder.extraSources(root: root, dirs: ["missing"], baseRels: [], outRel: ""))
    }

    /// End to end on a synthetic git corpus with the real Qwen tokenizer: the output equals the frequency ranking
    /// computed directly, carries the tokenizer hash, and the corpus note counts the extra files.
    func testBuildOnSyntheticRepo() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("models/qwen38-4bit/tokenizer.json").path),
                          "needs models/qwen38-4bit (weights are not in the repository)")
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try DraftVocabBuilder.runGit(root: root, args: ["init", "-q"])
        try write(root, "docs/a.md", Array("the quick brown fox jumps over the lazy dog. the dog sleeps.\n".utf8))
        try write(root, "Sources/s.swift", Array("func f() -> Int { return 42 }\n".utf8))
        try write(root, "bench/results/skip.md", Array("ignored run log text ignored\n".utf8))
        _ = try DraftVocabBuilder.runGit(root: root, args: ["add", "docs", "Sources", "bench"])
        try write(root, "extra/e.py", Array("def g():\n    return 'fox'\n".utf8))

        let modelDir = repoRoot.appendingPathComponent("models/qwen38-4bit")
        let k = 400
        let r = try DraftVocabBuilder.build(modelDir: modelDir, root: root, outRel: "bench/draft_vocab_test.json", k: k,
                                            extraDirs: ["extra"])
        XCTAssertEqual(r.ids.count, k)
        XCTAssertEqual(zip(r.ids, r.ids.dropFirst()).allSatisfy { $0 < $1 }, true)
        XCTAssertEqual(r.fileCount, 3)
        XCTAssertNotNil(r.corpusNote)
        XCTAssertTrue(r.corpusNote?.hasPrefix("files=3 paths_sha256=") ?? false)

        let tok = try Tokenizer.load(modelDir: modelDir.path)
        let tokBytes = try Data(contentsOf: modelDir.appendingPathComponent("tokenizer.json"))
        XCTAssertEqual(r.tokenizerSha256, DraftVocabBuilder.sha256Hex(tokBytes))

        var counts: [Int32: Int] = [:]
        let texts = ["the quick brown fox jumps over the lazy dog. the dog sleeps.\n",
                     "func f() -> Int { return 42 }\n", "def g():\n    return 'fox'\n"]
        for t in texts { for id in tok.encode(t) { counts[id, default: 0] += 1 } }
        let special = Set(try DraftVocabBuilder.addedTokens(tokenizerJSON: tokBytes).map(\.id))
        XCTAssertEqual(r.ids, DraftVocabBuilder.rank(counts: counts, special: special, k: k))
        for name in DraftVocabBuilder.eosNames {
            XCTAssertTrue(r.ids.contains(tok.encode(name)[0]), name)
        }

        // Deterministic: a second run is identical, and the skipped run log did not feed the counts.
        let again = try DraftVocabBuilder.build(modelDir: modelDir, root: root, outRel: "bench/draft_vocab_test.json", k: k,
                                                extraDirs: ["extra"])
        XCTAssertEqual(DraftVocabBuilder.json(again), DraftVocabBuilder.json(r))
    }
}
