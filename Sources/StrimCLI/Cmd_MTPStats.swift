import Foundation
import CryptoKit
import StrimAPI
import StrimCore
import StrimPrompt
import StrimTokenizer
import StrimTemplate
import StrimAgentBench

struct MTPStatsOptions {
    var model: String?, head: String?, prompts: String?, output: String?, extract: String?, out: String?
    var depths = ["adaptive"]
    var maxTokens = 256
    static func parse(_ args: [String]) throws -> Self {
        var o = Self(), seen = Set<String>(), i = 2
        let known: Set<String> = ["--model", "--head", "--prompts", "--depth", "--max-tokens", "--output", "--extract-prompts", "--out"]
        while i < args.count {
            let flag = args[i]
            guard known.contains(flag), seen.insert(flag).inserted, i+1 < args.count else {
                throw TemplateError("unknown, repeated or valueless option \(flag)")
            }
            let value = args[i+1]; i += 2
            switch flag {
            case "--model": o.model = value
            case "--head": o.head = value
            case "--prompts": o.prompts = value
            case "--output": o.output = value
            case "--extract-prompts": o.extract = value
            case "--out": o.out = value
            case "--max-tokens":
                guard let n = Int(value), n > 0 else { throw TemplateError("--max-tokens must be positive") }
                o.maxTokens = n
            case "--depth":
                let d = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard !d.isEmpty, Set(d).count == d.count, d.allSatisfy({ ["1", "2", "3", "4", "adaptive"].contains($0) }),
                      !d.contains("adaptive") || d.count == 1 else { throw TemplateError("--depth must be 1,2,3,4 (or a subset) or adaptive") }
                o.depths = d
            default: break
            }
        }
        if o.extract != nil {
            guard o.out != nil, seen.isSubset(of: ["--extract-prompts", "--out"]) else {
                throw TemplateError("extraction requires only --extract-prompts and --out")
            }
        } else {
            guard o.model != nil, o.head != nil, o.prompts != nil, o.out == nil else {
                throw TemplateError("replay requires --model, --head and --prompts")
            }
        }
        return o
    }
}

private struct MTPFingerprint: Codable {
    var sha256: String
    var files: [String: String]
    /// Full content SHA-256, including weight shards; no mtime/path-only identities.
    static func directory(_ path: String) throws -> Self {
        let root = URL(fileURLWithPath: path)
        let names = try FileManager.default.contentsOfDirectory(atPath: path).filter {
            $0.hasSuffix(".safetensors") || ["config.json", "quant_config.json", "model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "hadamard.json", "draft_vocab.json"].contains($0)
        }.sorted()
        guard names.contains(where: { $0.hasSuffix(".safetensors") }) else { throw TemplateError("no weight shards in \(path)") }
        var files: [String: String] = [:]
        for name in names { files[name] = try file(root.appendingPathComponent(name)) }
        return Self(sha256: mtpSHA256(Data(names.map { $0 + "\u{0}" + files[$0]! }.joined(separator: "\n").utf8)), files: files)
    }
    static func file(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct MTPReplayResult: Codable {
    var id: String
    var depth: String
    var promptTokenIDsSHA256: String
    var promptTokens: Int
    var outputTokens: Int
    var outputSHA256: String
    var tokenIDsSHA256: String
    var counts: MTPStats
    var positions: [MTPPositionReport]
    var byContent: [String: [MTPPositionReport]]
}

private struct MTPDepthReport: Codable {
    var depth: String
    var prompts: Int
    var counts: MTPStats
    var positions: [MTPPositionReport]
    var byContent: [String: [MTPPositionReport]]
    var acceptedTokensPerRound: Double?
    var aggregateAcceptance: Double?
}

private struct MTPReplayReport: Codable {
    var schemaVersion = 1
    var model: MTPFingerprint
    var head: MTPFingerprint
    var tokenizerSHA256: String
    var tokenizerTemplateMetadataSHA256: String?
    var vocab: [String: String]
    var config: [String: String]
    var promptsSHA256: String
    var totals: [MTPDepthReport]
    var replays: [MTPReplayResult]
}

enum MTPStatsCommand {
    static let usage = """
    usage: strim mtpstats --model <dir> --head <dir> --prompts <jsonl>
                         [--depth 1,2,3,4|adaptive] [--max-tokens N=256] [--output <json>]
           strim mtpstats --extract-prompts <ledger.jsonl-or-jobs/run-dir> --out <jsonl>
      Offline greedy replay; shared /tmp/strim-bench.lock acquired before model loading.
      Each prompt/depth uses fresh caches; output runs to the token budget (EOS included).
      JSONL: {"id":"...","messages":[...],"tools":[...]} or {"id":"...","ids":[...]};
      optional enable_thinking boolean. Constraints/sampling overrides are not supported.
      Extraction caps at 1000 deduplicated prompts, 256 KiB/prompt; only job artifacts
      are read. Initial context is reconstructed and marked; clipped mirrors are refused.
      Content labels use emitted UTF-8 slots (target replacement for first rejection);
      unreachable suffix proposals and boundary-crossing tokens are unknown.
      Wilson intervals describe per-position binomial counts, not task-cluster inference.
    """

    static func run(_ args: [String]) throws {
        let o = try MTPStatsOptions.parse(args)
        if let input = o.extract {
            let result = try MTPPromptFiles.extract(at: URL(fileURLWithPath: input))
            let text = result.prompts.map { $0.serialized() }.joined(separator: "\n") + (result.prompts.isEmpty ? "" : "\n")
            try privateWrite(Data(text.utf8), to: o.out!)
            let summary = "extracted \(result.prompts.count), duplicates \(result.duplicates), capped \(result.capped)\n"
            FileHandle.standardError.write(Data((summary + result.diagnostics.joined(separator: "\n") + "\n").utf8))
            return
        }
        guard ProcessInfo.processInfo.environment["STRIM_MTP_DEPTH"] == nil else {
            throw TemplateError("unset STRIM_MTP_DEPTH for explicit replay depths")
        }
        guard (1...4).contains(QwenModel.defaultMaxDepth) else {
            throw TemplateError("STRIM_MTP_MAX_DEPTH must be in 1...4 for replay")
        }
        let promptData = try MTPPromptFiles.boundedRead(URL(fileURLWithPath: o.prompts!), limit: 64 << 20)
        guard let promptText = String(data: promptData, encoding: .utf8) else { throw TemplateError("prompts are not UTF-8") }
        let records = try promptText.split(separator: "\n").map { try OrderedJSON.parse(String($0)) }
        for record in records {
            guard case .object = record else { throw TemplateError("prompt record must be an object") }
            guard record["constraint"] == nil, record["constraints"] == nil,
                  record["temperature"] == nil, record["seed"] == nil else {
                throw TemplateError("replay currently supports unconstrained greedy prompts only")
            }
        }
        // Extraction and argument validation never acquire the GPU lock. Keep it held
        // through fingerprinting, model load and all replays, even on a thrown error.
        let benchLock = try FileLock.acquire(path: "/tmp/strim-bench.lock", timeout: nil, onWait: {
            FileHandle.standardError.write(Data("mtpstats: waiting for /tmp/strim-bench.lock\n".utf8))
        })
        defer { benchLock.release() }
        let modelFP = try MTPFingerprint.directory(o.model!), headFP = try MTPFingerprint.directory(o.head!)
        let tokenizerHash = try MTPFingerprint.file(URL(fileURLWithPath: o.model!).appendingPathComponent("tokenizer.json"))
        let tokenizer = try Tokenizer.load(modelDir: o.model!)
        let store = try WeightStore(dir: URL(fileURLWithPath: o.model!))
        let head = try WeightStore(dir: URL(fileURLWithPath: o.head!)); head.useIntegratedMTPPrefixIfNeeded()
        let vocabActive = store.draftVocab != nil
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["STRIM_DRAFT_VOCAB"], URL(fileURLWithPath: o.model!).appendingPathComponent("draft_vocab.json").path, "bench/draft_vocab_48k.json"].compactMap { $0 }.filter { !$0.isEmpty }
        let vocabPath = candidates.first { FileManager.default.fileExists(atPath: $0) }
        var vocab = ["mode": vocabActive ? "truncated" : "full"]
        if vocabActive, let path = vocabPath { vocab["sha256"] = try MTPFingerprint.file(URL(fileURLWithPath: path)) }
        var totals: [MTPDepthReport] = [], replays: [MTPReplayResult] = []
        for depthName in o.depths {
            var total = MTPStats()
            var categories = Dictionary(uniqueKeysWithValues: MTPContentType.allCases.map { ($0, MTPContentCounts()) })
            for (index, record) in records.enumerated() {
                let ids: [Int32]
                if case .array(let raw)? = record["ids"] {
                    ids = try raw.map {
                        guard case .int(let n) = $0, let id = Int32(exactly: n), id >= 0, !tokenizer.bytes(for: id).isEmpty else {
                            throw TemplateError("invalid token ID")
                        }
                        return id
                    }
                } else {
                    let input = try TokenizeTool.chatInput(json: record.serialized())
                    var thinking: Bool?
                    if let value = record["enable_thinking"] {
                        guard case .bool(let b) = value else { throw TemplateError("enable_thinking must be boolean") }
                        thinking = b
                    }
                    ids = try PromptBuilder.prepare(ledger: StrimPrompt.Ledger(tokenizer: tokenizer), messages: input.messages,
                        tools: input.tools, enableThinking: thinking).newIds
                }
                guard !ids.isEmpty else { throw TemplateError("empty prompt") }
                var rounds: [MTPReplayRound] = [], offset = 0
                let (all, stats) = try QwenModel.generateSpec(prompt: ids, maxTokens: o.maxTokens, store: store, head: head,
                    depth: Int(depthName) ?? 2, adaptive: depthName == "adaptive", maxDepth: depthName == "adaptive" ? QwenModel.defaultMaxDepth : 4,
                    onRound: { depth, accepted, _ in
                        rounds.append(MTPReplayRound(outputOffset: offset, depth: depth, accepted: accepted))
                        offset += accepted + 1
                    })
                let output = Array(all.dropFirst(ids.count)), bytes = output.map { tokenizer.bytes(for: $0) }
                let byContent = mtpContentCounts(tokenBytes: bytes, rounds: rounds)
                total.add(stats.mtp)
                for type in MTPContentType.allCases {
                    for j in 0..<MTPStats.positionLimit {
                        categories[type]!.proposed[j] += byContent[type]!.proposed[j]
                        categories[type]!.reached[j] += byContent[type]!.reached[j]
                        categories[type]!.accepted[j] += byContent[type]!.accepted[j]
                    }
                }
                let idsData = output.withUnsafeBufferPointer { buffer in
                    // Canonical little-endian ids, independent of host byte order.
                    Data(buffer.flatMap { id in (0..<4).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: id) >> ($0*8)) } })
                }
                replays.append(MTPReplayResult(id: record["id"]?.stringValue ?? String(index), depth: depthName,
                    promptTokenIDsSHA256: mtpSHA256(Data(ids.flatMap { id in (0..<4).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: id) >> ($0*8)) } })), promptTokens: ids.count, outputTokens: output.count, outputSHA256: mtpSHA256(Data(bytes.flatMap { $0 })),
                    tokenIDsSHA256: mtpSHA256(idsData), counts: stats.mtp, positions: MTPPositionReport.positions(stats.mtp),
                    byContent: Dictionary(uniqueKeysWithValues: byContent.map { ($0.key.rawValue, $0.value.positions) })))
            }
            totals.append(MTPDepthReport(depth: depthName, prompts: records.count, counts: total,
                positions: MTPPositionReport.positions(total),
                byContent: Dictionary(uniqueKeysWithValues: categories.map { ($0.key.rawValue, $0.value.positions) }),
                acceptedTokensPerRound: total.rounds > 0 ? Double(total.acceptedPrefix.reduce(0, +)) / Double(total.rounds) : nil, aggregateAcceptance: total.proposed.reduce(0, +) > 0 ? Double(total.acceptedPrefix.reduce(0, +)) / Double(total.proposed.reduce(0, +)) : nil))
        }
        var config = ["max_tokens": String(o.maxTokens), "depths": o.depths.joined(separator: ","), "sampling": "greedy", "seed": "0 (unused in greedy)",
                      "constraints": "none", "constraint_sha256": mtpSHA256(Data("none".utf8)), "fresh_caches": "per_prompt_per_depth",
                      "eos": "included; stop at output budget", "labels": "reached output slots (first rejection uses target replacement); unreachable/boundaries unknown",
                      "uncertainty": "Wilson 95% binomial; descriptive, not task-cluster intervals", "version": StrimVersion.current,
                      "adaptive_max_depth": String(QwenModel.defaultMaxDepth), "fixed_max_depth": "4", "draft_chain": QwenModel.defaultDraftChain == .index ? "index" : "host", "device_feed": String(SpecStream.deviceFeed)]
        for key in ["STRIM_MTP_MAX_DEPTH", "STRIM_MTP_POLICY", "STRIM_MTP_HOST", "STRIM_SPEC_DEVICEFEED", "STRIM_GDN_BA_INVARIANT", "STRIM_PIPE_LAYERS", "STRIM_PIPE_PREFILL_LAYERS", "STRIM_PREFILL_MACRO_BF16", "STRIM_TIMING", "STRIM_REC_ELEM", "STRIM_GDN_TENSOR", "STRIM_GDN_METAL", "STRIM_GDN_METAL_MAX_S", "STRIM_GDN_BLOCKED", "STRIM_CONV_TENSOR", "STRIM_SKIP_REC"] {
            config[key] = env[key] ?? "unset"
        }
        if let executable = Bundle.main.executableURL { config["executable_sha256"] = try MTPFingerprint.file(executable) }
        config["template_implementation"] = "StrimTemplate.ChatTemplate; bound to executable fingerprint and per-replay prompt ID hash"
        let report = MTPReplayReport(model: modelFP, head: headFP, tokenizerSHA256: tokenizerHash,
            tokenizerTemplateMetadataSHA256: modelFP.files["chat_template.jinja"], vocab: vocab, config: config,
            promptsSHA256: mtpSHA256(promptData), totals: totals, replays: replays)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report) + Data("\n".utf8)
        if let output = o.output { try privateWrite(data, to: output) }
        else { FileHandle.standardOutput.write(data) }
    }

    private static func privateWrite(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".mtpstats-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw TemplateError("cannot write \(path)")
        }
        defer { unlink(temporary.path) }
        guard rename(temporary.path, path) == 0 else { throw TemplateError("cannot replace \(path)") }
    }
}

func runMTPStats(_ args: [String]) {
    do { try MTPStatsCommand.run(args) }
    catch { FileHandle.standardError.write(Data("mtpstats: \(error)\n\(MTPStatsCommand.usage)\n".utf8)); exit(2) }
}
