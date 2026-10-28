import Foundation
import StrimTokenizer

// strim draft-vocab [--k N=32768] [--out PATH=bench/draft_vocab_32k.json] [--model DIR=models/qwen38-4bit]
//                   [--extra-dir DIR]...
// Run from the repo root. Ranks tokens over the corpus (git-tracked text in docs, Sources, service, bench,
// harness, scripts; plus recursive walks of each --extra-dir) and writes the truncated MTP lm_head vocab.
// The committed bench/draft_vocab_48k.json: --k 49152 --out bench/draft_vocab_48k.json --extra-dir vendor --extra-dir docs

func runDraftVocab(_ args: [String]) {
    let usage = "usage: strim draft-vocab [--k N] [--out PATH] [--model DIR] [--extra-dir DIR]..."
    func fail(_ s: String) -> Never {
        FileHandle.standardError.write(Data((s + "\n").utf8))
        exit(2)
    }
    var k = DraftVocabBuilder.defaultK
    var out = "bench/draft_vocab_32k.json"
    var model = "models/qwen38-4bit"
    var extraDirs: [String] = []
    var i = 2
    func next(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("missing value for \(flag)\n\(usage)") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--k":
            guard let n = Int(next("--k")), n > 0 else { fail("bad --k\n\(usage)") }
            k = n
        case "--out": out = next("--out")
        case "--model": model = next("--model")
        case "--extra-dir": extraDirs.append(next("--extra-dir"))
        default: fail("unknown option \(args[i])\n\(usage)")
        }
        i += 1
    }

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    let outURL = URL(fileURLWithPath: out, relativeTo: root).standardizedFileURL
    // Output inside the repo is excluded from the corpus; elsewhere nothing needs excluding.
    let outRel = outURL.path.hasPrefix(root.path + "/") ? String(outURL.path.dropFirst(root.path.count + 1)) : ""
    do {
        let r = try DraftVocabBuilder.build(
            modelDir: URL(fileURLWithPath: model, relativeTo: root), root: root, outRel: outRel, k: k, extraDirs: extraDirs)
        try DraftVocabBuilder.json(r).write(to: outURL, atomically: false, encoding: .utf8)
        print("out=\(out) k=\(r.k)")
        if let note = r.corpusNote { print("corpus_note=\(note)") }
        print("files=\(r.fileCount)")
        print("seen=\(r.seen) special=\(r.special) base=\(r.base)")
        print("filled=\(max(k - r.base, 0)) trimmed=\(max(r.base - k, 0))")
        print("total=\(r.ids.count) max_id=\(r.ids.last ?? -1)")
    } catch {
        fail("error: \(error)")
    }
}
