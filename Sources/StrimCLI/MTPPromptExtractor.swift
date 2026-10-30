import Foundation
import StrimTemplate
import StrimHarness

struct MTPExtraction {
    var prompts: [OrderedJSON] = []
    var diagnostics: [String] = []
    var duplicates = 0
    var capped = 0
}

/// Pure parser for Harness EventSink's JSONL. JobManager's clipped mirror is refused.
/// Initial context must be supplied: it cannot be recovered from EventSink alone.
/// Every prompt ends immediately before a `turn`, so the answer cannot leak into it.
enum MTPPromptExtractor {
    static let defaultCap = 1000
    static let maxPromptBytes = 262_144

    static func extract(events: String, initial: [OrderedJSON], tools: [OrderedJSON] = [],
                        source: String, cap: Int = defaultCap) throws -> MTPExtraction {
        var result = MTPExtraction()
        guard initial.first?["role"]?.stringValue == "system",
              initial.contains(where: { $0["role"]?.stringValue == "user" }) else {
            result.diagnostics.append("\(source): missing system/user context"); return result
        }
        let rows = try events.split(separator: "\n").map { try OrderedJSON.parse(String($0)) }
        if rows.contains(where: { $0["kind"] != nil && $0["type"] == nil }) {
            result.diagnostics.append("\(source): clipped job mirror has no transcript"); return result
        }
        var history = initial, text = "", reasoning = "", calls: [OrderedJSON] = []
        var seen = Set<String>(), active = false, toolResults: [OrderedJSON] = []
        func flush() {
            guard active else { return }
            history.append(.ordered([
                ("role", .string("assistant")), ("content", .string(text)),
                ("reasoning_content", .string(reasoning)), ("tool_calls", .array(calls)),
            ]))
            history += toolResults
            text = ""; reasoning = ""; calls = []; toolResults = []; active = false
        }
        for row in rows {
            switch row["type"]?.stringValue {
            case "turn":
                flush()
                let content = sanitize(.ordered([("messages", .array(history)), ("tools", .array(tools))]))
                let canonical = canonicalJSON(content)
                let key = mtpSHA256(Data(canonical.utf8))
                if !seen.insert(key).inserted { result.duplicates += 1 }
                else if canonical.utf8.count > maxPromptBytes || result.prompts.count >= max(0, cap) { result.capped += 1 }
                else {
                    result.prompts.append(.ordered([
                        ("id", .string(key)), ("source", .string(source)),
                        ("turn", row["n"] ?? .null), ("messages", content["messages"]!),
                        ("tools", content["tools"]!),
                        ("context_fidelity", .string("reconstructed_initial_context; recorded_event_history")),
                    ]))
                }
                active = true
            case "text": text += row["text"]?.stringValue ?? ""
            case "reasoning": reasoning += row["text"]?.stringValue ?? ""
            case "tool_call":
                guard active, let name = row["name"]?.stringValue,
                      let args = row["args"]?.stringValue, case .object = try OrderedJSON.parse(args) else {
                    result.diagnostics.append("\(source): invalid tool call; stopped before incomplete history")
                    return result
                }
                calls.append(.ordered([("type", .string("function")), ("function", .ordered([
                    ("name", .string(name)), ("arguments", try OrderedJSON.parse(args)),
                ]))]))
            case "tool_result":
                if row["name"]?.stringValue == "_compaction" {
                    result.diagnostics.append("\(source): compaction context unavailable; stopped")
                    return result
                }
                guard active else { result.diagnostics.append("\(source): tool result outside turn"); return result }
                toolResults.append(.ordered([("role", .string("tool")), ("content", row["output"] ?? .string(""))]))
            case "finished": flush()
            case "usage", "approval": break
            default:
                result.diagnostics.append("\(source): unsupported event; stopped")
                return result
            }
        }
        return result
    }

    /// Redact values before hashing/dedup/export. Escape embedded control-token openers
    /// so replayed untrusted text cannot forge template boundaries.
    static func sanitize(_ json: OrderedJSON) -> OrderedJSON {
        switch json {
        case .string(let s): return .string(Redactor.redact(s).replacingOccurrences(of: "<|", with: "<\\u007c"))
        case .array(let a): return .array(a.map(sanitize))
        case .object(let a): return .object(a.map { .init($0.key, sanitize($0.value)) })
        default: return json
        }
    }
    static func canonicalJSON(_ json: OrderedJSON) -> String {
        switch json {
        case .object(let a): return "{" + a.sorted { $0.key < $1.key }.map {
            OrderedJSON.string($0.key).serialized() + ":" + canonicalJSON($0.value)
        }.joined(separator: ",") + "}"
        case .array(let a): return "[" + a.map(canonicalJSON).joined(separator: ",") + "]"
        default: return json.serialized()
        }
    }

    static func deduplicate(_ prompts: [OrderedJSON], cap: Int = defaultCap) -> MTPExtraction {
        var result = MTPExtraction(), seen = Set<String>()
        for p in prompts {
            let key = canonicalJSON(.ordered([("messages", p["messages"] ?? .null), ("tools", p["tools"] ?? .array([]))]))
            if !seen.insert(key).inserted { result.duplicates += 1 }
            else if result.prompts.count >= max(0, cap) { result.capped += 1 }
            else { result.prompts.append(p) }
        }
        return result
    }
}

/// Only known artifact directories and names are visited; never workspaces, scratch
/// trees, credentials, arbitrary home files, or paths embedded in ledger rows.
enum MTPPromptFiles {
    static func extract(at input: URL) throws -> MTPExtraction {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input.path, isDirectory: &isDir) else { throw TemplateError("missing input \(input.path)") }
        let root = (isDir.boolValue ? input : input.deletingLastPathComponent()).resolvingSymlinksInPath()
        guard isDir.boolValue || input.lastPathComponent == "ledger.jsonl" else {
            throw TemplateError("expected ledger.jsonl or a jobs/run directory")
        }
        let packDir = root.appendingPathComponent("live-pack")
        let pack = fm.fileExists(atPath: packDir.path) ? try PackLoader.load(directory: packDir) : nil
        let system = pack?.systemPrompt ?? PackLoader.shipped().systemPrompt
        let toolSpecs = ToolCatalog.all(runner: NoReplayCommands()).map { $0.spec.json }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            throw TemplateError("cannot enumerate \(root.path)")
        }
        var files: [URL] = []
        for case let url as URL in entries {
            let v = try url.resourceValues(forKeys: Set(keys))
            if v.isSymbolicLink == true { entries.skipDescendants(); continue }
            if v.isDirectory == true {
                let name = url.lastPathComponent
                if !(name == "jobs" || name.hasPrefix("j_") || name.hasPrefix("server-state-")) {
                    entries.skipDescendants()
                }
            } else if url.lastPathComponent == "events.jsonl", url.deletingLastPathComponent().lastPathComponent.hasPrefix("j_") {
                files.append(url)
            }
        }
        guard let rootPath = canonicalPath(root) else { throw TemplateError("cannot resolve source root") }
        var all = MTPExtraction(), seen = Set<String>()
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let filePath = canonicalPath(file), filePath.hasPrefix(rootPath + "/") else {
                all.diagnostics.append("source disappeared or escaped root: \(file.lastPathComponent)")
                continue
            }
            let source = String(filePath.dropFirst(rootPath.count + 1))
            let jobURL = file.deletingLastPathComponent().appendingPathComponent("job.json")
            guard let data = try? boundedRead(jobURL, limit: 2 << 20), let jobText = String(data: data, encoding: .utf8),
                  let job = try? OrderedJSON.parse(jobText), let task = job["task"]?.stringValue else {
                all.diagnostics.append("\(source): no job.json initial task context"); continue
            }
            var user = task
            if let context = job["context"]?.stringValue, !context.isEmpty { user += "\n\n# Context\n" + context }
            if let cwd = job["cwd"]?.stringValue { user = "<environment>\nworking_directory: \(cwd)\n</environment>\n\n# Task\n" + user }
            let initial: [OrderedJSON] = [
                .ordered([("role", .string("system")), ("content", .string(system))]),
                .ordered([("role", .string("user")), ("content", .string(user))]),
            ]
            do {
                let data = try boundedRead(file, limit: 32 << 20)
                guard let events = String(data: data, encoding: .utf8) else { throw TemplateError("invalid UTF-8") }
                let extracted = try MTPPromptExtractor.extract(events: events, initial: initial, tools: toolSpecs, source: source)
                for prompt in extracted.prompts {
                    let key = mtpSHA256(Data(MTPPromptExtractor.canonicalJSON(.ordered([("messages", prompt["messages"]!), ("tools", prompt["tools"]!)])).utf8))
                    if !seen.insert(key).inserted { all.duplicates += 1 }
                    else if all.prompts.count >= MTPPromptExtractor.defaultCap { all.capped += 1 }
                    else { all.prompts.append(prompt) }
                }
                all.diagnostics += extracted.diagnostics
                all.capped += extracted.capped; all.duplicates += extracted.duplicates
            } catch { all.diagnostics.append("\(source): \(error)") }
        }
        var result = MTPPromptExtractor.deduplicate(all.prompts)
        result.diagnostics = all.diagnostics
        result.diagnostics.append("initial context reconstructed from job.json and \(pack == nil ? "current builtin pack" : "live-pack"); environment/project context may differ from original")
        result.duplicates += all.duplicates; result.capped += all.capped
        if files.isEmpty { result.diagnostics.append("no job events found; run ledgers themselves contain no transcripts") }
        return result
    }

    /// Foundation may spell `/tmp` differently for an enumerator and its root URL.
    /// POSIX realpath gives both the same filesystem identity before relativizing.
    private static func canonicalPath(_ url: URL) -> String? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return String(cString: path)
    }

    static func boundedRead(_ url: URL, limit: Int) throws -> Data {

        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, let n = v.fileSize, n <= limit else {
            throw TemplateError("refusing nonregular, symlink or oversized input \(url.lastPathComponent)")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw TemplateError("input grew beyond limit") }
        return data
    }
}

private struct NoReplayCommands: CommandRunner {
    func run(_ command: String, cwd: String, env: [String: String], timeout: TimeInterval, outputCap: Int) async throws -> CommandOutput {
        throw TemplateError("prompt extraction never executes commands")
    }
}
