import Foundation

/// Usage and behaviour extracted from a Claude Code `--output-format stream-json --verbose` stream (or the
/// single JSON object of `--output-format json`).
public struct ClaudeRun: Sendable, Equatable {
    public var inputUncached: Int?
    public var cacheCreate: Int?
    public var cacheRead: Int?
    public var output: Int?
    public var costUsd: Double?
    public var turns: Int?
    public var isError = false
    public var sawResult = false
    public var resultText = ""
    public var toolNames: [String] = []
    /// `strim_task` + `strim_ask` calls.
    public var delegations = 0
    /// `strim_job` calls.
    public var polls = 0
    /// nil: no `git apply` attempted. true/false: last real apply succeeded/failed.
    public var patchApplied: Bool?
    /// The parent edited files after a delegation that did not come back verified.
    public var redo = false
    /// Local-model usage reported inside strim tool results (arm M).
    public var localPrompt = 0, localCached = 0, localCompletion = 0, localTurns = 0
    public var sawLocalUsage = false
    /// The client reported an error and never used the model (not logged in, API refused, startup failure): an
    /// environment problem, not a task result, so it must not count as a run.
    public var failedBeforeModel: Bool { isError && (total ?? 0) == 0 }
    public var total: Int? {
        guard inputUncached != nil || cacheCreate != nil || cacheRead != nil || output != nil else { return nil }
        return (inputUncached ?? 0) + (cacheCreate ?? 0) + (cacheRead ?? 0) + (output ?? 0)
    }
}

public enum ClaudeParser {
    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    static func resultText(of block: [String: Any]) -> String {
        if let s = block["content"] as? String { return s }
        if let arr = block["content"] as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    public static func parse(_ text: String) -> ClaudeRun {
        var run = ClaudeRun()
        var events: [[String: Any]] = text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        if !events.contains(where: { $0["type"] as? String == "result" }),
           let whole = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            events = [whole]
        }
        var pending: [String: (name: String, command: String)] = [:]
        var needsRedoCheck = false
        for ev in events {
            switch ev["type"] as? String {
            case "assistant":
                let msg = ev["message"] as? [String: Any] ?? [:]
                for b in (msg["content"] as? [[String: Any]]) ?? [] where b["type"] as? String == "tool_use" {
                    let name = b["name"] as? String ?? ""
                    let input = b["input"] as? [String: Any] ?? [:]
                    run.toolNames.append(name)
                    if let id = b["id"] as? String { pending[id] = (name, input["command"] as? String ?? "") }
                    if name.hasSuffix("strim_task") || name.hasSuffix("strim_ask") { run.delegations += 1 }
                    if name.hasSuffix("strim_job") { run.polls += 1 }
                    if needsRedoCheck, name == "Edit" || name == "Write" || name == "MultiEdit" || name == "NotebookEdit" { run.redo = true }
                }
            case "user":
                let msg = ev["message"] as? [String: Any] ?? [:]
                for b in (msg["content"] as? [[String: Any]]) ?? [] where b["type"] as? String == "tool_result" {
                    guard let id = b["tool_use_id"] as? String, let p = pending[id] else { continue }
                    let isErr = b["is_error"] as? Bool ?? false
                    let body = resultText(of: b)
                    if p.name.hasSuffix("strim_task") || p.name.hasSuffix("strim_job") || p.name.hasSuffix("strim_ask") {
                        let hr = HarnessReply.parse(body)
                        if let pt = hr.promptTokens {
                            run.sawLocalUsage = true
                            run.localPrompt += pt; run.localCached += hr.cachedTokens ?? 0
                            run.localCompletion += hr.completionTokens ?? 0; run.localTurns += hr.turns ?? 0
                        }
                    }
                    if p.name == "Bash", p.command.contains("git apply"), !p.command.contains("--check") {
                        run.patchApplied = !isErr
                    }
                    if p.name.hasSuffix("strim_task") || p.name.hasSuffix("strim_job") {
                        // A terminal reply that is not DONE ... verify=verified means the parent must do it alone.
                        let terminal = body.hasPrefix("DONE") || body.contains(": failed") || body.contains(": limit")
                            || body.contains(": declined") || body.contains(": cancelled")
                        if isErr || (terminal && !body.contains("verify=verified")) { needsRedoCheck = true }
                    }
                }
            case "result":
                run.sawResult = true
                let u = ev["usage"] as? [String: Any] ?? [:]
                run.inputUncached = int(u["input_tokens"])
                run.cacheCreate = int(u["cache_creation_input_tokens"])
                run.cacheRead = int(u["cache_read_input_tokens"])
                run.output = int(u["output_tokens"])
                run.costUsd = (ev["total_cost_usd"] as? NSNumber)?.doubleValue
                run.turns = int(ev["num_turns"])
                run.isError = ev["is_error"] as? Bool ?? false
                run.resultText = ev["result"] as? String ?? ""
            default: break
            }
        }
        return run
    }

    /// Heuristic: the final message does not report failure.
    public static func claimsDone(_ r: ClaudeRun) -> Bool {
        guard r.sawResult, !r.isError else { return false }
        let t = r.resultText.lowercased()
        if t.isEmpty { return false }
        let negatives = ["fail", "unable to", "could not", "couldn't", "cannot", "can't", "not able", "did not pass", "still failing", "gave up"]
        return !negatives.contains { t.contains($0) }
    }
}
