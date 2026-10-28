import CryptoKit
import Foundation

public struct DraftVocabError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Frequency-ranked draft vocab for the truncated MTP lm_head (`bench/draft_vocab_<k>.json`).
/// Port of the retired scripts/gen_draft_vocab.py; the file format is unchanged:
/// `{"k":K,"tokenizer_sha256":"<sha256 of tokenizer.json>","corpus_note":"..."?,"ids":[...]}`.
/// StrimCore's `WeightStore` reads `k`, `ids` and `tokenizer_sha256` and refuses a hash mismatch.
public enum DraftVocabBuilder {
    public static let defaultK = 32768
    public static let eosNames = ["<|im_end|>", "<|endoftext|>"]
    /// Files above this size are skipped, as are files with a NUL byte or invalid UTF-8.
    public static let maxBytes = 1024 * 1024
    /// Repo directories whose git-tracked files form the base corpus.
    public static let gitDirs = ["docs", "Sources", "service", "bench", "harness", "scripts"]
    /// Extensions read by `--extra-dir` walks.
    public static let extraExts = [".rs", ".py", ".sql", ".md", ".ts", ".swift", ".cpp", ".h", ".json"]
    /// Run logs never feed the vocab.
    public static let excludePrefix = "bench/results/"

    public struct Source: Sendable {
        public let rel: String
        public let text: String
    }

    public struct Result: Sendable {
        public let k: Int
        public let tokenizerSha256: String
        /// "files=N paths_sha256=HEX" when `--extra-dir` was used.
        public let corpusNote: String?
        public let ids: [Int32]
        public let fileCount: Int
        public let seen: Int
        public let special: Int
        public let base: Int
    }

    /// Builds the draft vocab over the corpus under `root` (git-tracked text in `gitDirs`, plus recursive walks of
    /// `extraDirs`, root-relative). `modelDir` holds tokenizer.json. `outRel` (root-relative) is never counted.
    public static func build(modelDir: URL, root: URL, outRel: String, k: Int, extraDirs: [String] = []) throws -> Result {
        let tokPath = modelDir.appendingPathComponent("tokenizer.json")
        guard let tokData = FileManager.default.contents(atPath: tokPath.path) else {
            throw DraftVocabError("cannot read \(tokPath.path)")
        }
        let tok = try Tokenizer.load(modelDir: modelDir.path)
        var byContent: [String: Int32] = [:]
        for t in try addedTokens(tokenizerJSON: tokData) { byContent[t.content] = t.id }
        let special = Set(byContent.values)
        for name in eosNames {
            guard let id = byContent[name] else { throw DraftVocabError("missing added token \(name) in tokenizer.json") }
            guard tok.encode(name) == [id] else { throw DraftVocabError("id mismatch for \(name)") }
        }
        if k < special.count { throw DraftVocabError("--k \(k) smaller than special token count \(special.count)") }

        var sources = try gitSources(root: root, outRel: outRel)
        var corpusNote: String?
        if !extraDirs.isEmpty {
            let baseRels = Set(sources.map(\.rel))
            sources += try extraSources(root: root, dirs: extraDirs, baseRels: baseRels, outRel: outRel)
            sources.sort { $0.rel.utf8.lexicographicallyPrecedes($1.rel.utf8) }
            corpusNote = "files=\(sources.count) paths_sha256=\(sha256Hex(Data(sources.map(\.rel).joined(separator: "\n").utf8)))"
        }

        var counts: [Int32: Int] = [:]
        for s in sources {
            for id in tok.encode(s.text) { counts[id, default: 0] += 1 }
        }
        let ids = rank(counts: counts, special: special, k: k)
        guard ids.count == k, zip(ids, ids.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw DraftVocabError("internal: ids are not \(k) strictly ascending values")
        }
        for name in eosNames where !ids.contains(byContent[name]!) {
            throw DraftVocabError("EOS token \(name) missing from draft vocab")
        }
        return Result(
            k: k, tokenizerSha256: sha256Hex(tokData), corpusNote: corpusNote, ids: ids, fileCount: sources.count,
            seen: counts.count, special: special.count, base: Set(counts.keys).union(special).count)
    }

    /// Keeps every special id, then the most frequent seen ids (ties: lower id), up to `k`. When fewer ids were
    /// seen, fills with the lowest unused ids.
    public static func rank(counts: [Int32: Int], special: Set<Int32>, k: Int) -> [Int32] {
        let seen = Set(counts.keys)
        let base = seen.union(special)
        if base.count > k {
            let extra = max(k - special.count, 0)
            let ranked = seen.subtracting(special).sorted { a, b in
                let ca = counts[a] ?? 0, cb = counts[b] ?? 0
                return ca != cb ? ca > cb : a < b
            }
            return special.union(ranked.prefix(extra)).sorted()
        }
        var ids = base
        var candidate: Int32 = 0
        while ids.count < k {
            ids.insert(candidate)
            candidate += 1
        }
        return ids.sorted()
    }

    /// The output file: one line, compact JSON, keys in the committed order.
    public static func json(_ r: Result) -> String {
        var s = "{\"k\":\(r.k),\"tokenizer_sha256\":\"\(r.tokenizerSha256)\""
        if let note = r.corpusNote { s += ",\"corpus_note\":\"\(note)\"" }
        s += ",\"ids\":[" + r.ids.map(String.init).joined(separator: ",") + "]}\n"
        return s
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `(id, content)` for every entry of tokenizer.json `added_tokens`.
    public static func addedTokens(tokenizerJSON data: Data) throws -> [(id: Int32, content: String)] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DraftVocabError("tokenizer.json is not a JSON object")
        }
        let arr = obj["added_tokens"] as? [[String: Any]] ?? []
        return arr.compactMap { t in
            guard let id = t["id"] as? Int, let content = t["content"] as? String else { return nil }
            return (Int32(id), content)
        }
    }

    // MARK: corpus

    static func gitSources(root: URL, outRel: String) throws -> [Source] {
        let listed = try runGit(root: root, args: ["ls-files", "--"] + gitDirs)
        var keep: [Source] = []
        for rel in listed.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            if rel.hasPrefix(excludePrefix) || rel == outRel || isGeneratedOutput(rel) { continue }
            if let text = readText(root.appendingPathComponent(rel).path) {
                keep.append(Source(rel: rel, text: text))
            }
        }
        return keep
    }

    /// Recursive walk of `dirs` (root-relative) for `extraExts` files. Skips `.git`, symlinks, files already in
    /// `baseRels`, and previous draft-vocab outputs.
    static func extraSources(root: URL, dirs: [String], baseRels: Set<String>, outRel: String) throws -> [Source] {
        let fm = FileManager.default
        var keep: [String: String] = [:]
        for d in dirs {
            let dirRel = String(URL(fileURLWithPath: "/" + d).standardizedFileURL.path.dropFirst())
            let top = root.appendingPathComponent(d).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: top, isDirectory: &isDir), isDir.boolValue else {
                throw DraftVocabError("--extra-dir not a directory: \(d)")
            }
            // Relative paths from the walk; attributes are not followed, so symlinks show as links and are skipped.
            guard let walker = fm.enumerator(atPath: top) else { continue }
            while let sub = walker.nextObject() as? String {
                let full = top + "/" + sub
                let type = (try? fm.attributesOfItem(atPath: full))?[.type] as? FileAttributeType
                if type == .typeDirectory {
                    if (sub as NSString).lastPathComponent == ".git" { walker.skipDescendants() }
                    continue
                }
                let name = (sub as NSString).lastPathComponent
                guard type == .typeRegular, extraExts.contains(where: { name.hasSuffix($0) }) else { continue }
                let rel = dirRel + "/" + sub
                if baseRels.contains(rel) || keep[rel] != nil || rel == outRel || rel.hasPrefix(excludePrefix)
                    || isGeneratedOutput(rel) {
                    continue
                }
                if let text = readText(full) { keep[rel] = text }
            }
        }
        return keep.map { Source(rel: $0.key, text: $0.value) }
    }

    static func isGeneratedOutput(_ rel: String) -> Bool {
        let base = rel.split(separator: "/").last.map(String.init) ?? rel
        return rel.hasPrefix("bench/") && base.hasPrefix("draft_vocab") && base.hasSuffix(".json")
    }

    /// Regular file (symlinks followed), at most `maxBytes`, no NUL byte, valid UTF-8; nil otherwise.
    static func readText(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxBytes else { return nil }
        guard let data = FileManager.default.contents(atPath: path), !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func runGit(root: URL, args: [String]) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", root.path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw DraftVocabError("git \(args.joined(separator: " ")) failed in \(root.path)") }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
