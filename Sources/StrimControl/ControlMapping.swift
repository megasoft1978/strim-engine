import Foundation
import StrimAPI
import StrimHarness
import StrimHost
import StrimJobs

/// JobRecord / slot state -> StrimAPI DTOs.
enum ControlMapping {
    static let gib = 1_073_741_824.0
    static let jobIDPattern = try! NSRegularExpression(pattern: "^j_[a-z2-7]{10}$")

    static func isValidJobID(_ id: String) -> Bool {
        jobIDPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }

    static func status(_ s: StrimJobs.JobStatus) -> JobStatusDTO {
        switch s {
        case .queued: .queued
        case .preparing, .running, .finalizing: .running
        case .pausedInteractive: .pausedInteractive
        case .awaitingApproval: .awaitingApproval
        case .done: .done
        case .failed, .declined: .failed
        case .cancelled: .cancelled
        case .limit: .limit
        }
    }

    static func verify(_ v: StrimHarness.VerifyResult?) -> StrimAPI.VerifyResult? {
        guard let v else { return nil }
        switch v.status {
        case .verified: return .verified
        case .failed: return .failed
        case .unverified, .verifiedModifiedTests: return .unverified   // modified tests: the pass is not proof
        }
    }

    static func summary(_ r: JobRecord) -> JobSummary {
        let title: String
        let firstLine = r.task.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        if r.profile != nil {
            title = firstLine.isEmpty ? "Chat: " + (r.cwd as NSString).lastPathComponent : String(firstLine.prefix(120))
        } else {
            title = String(firstLine.prefix(120))
        }
        return JobSummary(id: r.id, source: r.profile != nil ? .chat : .mcp, status: status(r.status),
                          verify: verify(r.result?.verify),
                          started: (r.startedAt ?? r.createdAt).timeIntervalSince1970,
                          finished: r.finishedAt?.timeIntervalSince1970,
                          title: title.isEmpty ? nil : title, cwd: r.cwd)
    }

    static func detail(_ r: JobRecord, patch: String?) -> JobDetail {
        JobDetail(summary: summary(r), resultSummary: r.result?.summary, patch: patch,
                  turns: r.result?.usage.turns ?? r.turn, localTokens: r.result?.usage.completionTokens ?? 0,
                  verifyOutput: r.result?.verify.map(\.outputTail).flatMap { $0.isEmpty ? nil : $0 })
    }

    static func hostState(_ s: SlotState) -> HostState { HostState(rawValue: s.rawValue) ?? .error }

    static func isActive(_ s: StrimJobs.JobStatus) -> Bool {
        switch s {
        case .preparing, .running, .finalizing, .pausedInteractive: true
        default: false
        }
    }

    /// Non-terminal work, for the slot's unload guard: running jobs and open chat sessions (their engine sessions die with the engine).
    static func activeJobCount(_ records: [JobRecord]) -> Int {
        records.filter { isActive($0.status) }.count
    }

    /// ChatEvent -> wire events (docs/CHAT-CORE.md).
    static func events(_ e: ChatEvent, sessionID id: String) -> [StrimEvent] {
        func delta(_ k: ChatDeltaKind, _ t: String) -> [StrimEvent] { [.chatDelta(ChatDelta(sessionID: id, kind: k, text: t))] }
        func harness(_ k: String, _ t: String) -> [StrimEvent] { [.harnessEvent(HarnessEvent(jobID: id, kind: k, text: t))] }
        switch e {
        case .textDelta(let t): return delta(.text, t)
        case .reasoningDelta(let t): return delta(.reasoning, t)
        case let .toolCallStarted(name, summary): return delta(.toolCall, "\(name) \(summary)")
        case let .toolCallFinished(name, summary, isError): return delta(.toolResult, "\(name)\(isError ? " ERROR" : ""): \(summary)")
        case .turnFinished(let r): return delta(.done, r.summary)
        case .stepStarted(let n): return harness("turn", "\(n)")
        case let .usage(p, c, o): return harness("usage", "\(p)/\(c)/\(o)")
        case .compaction(let s): return harness("compaction", s)
        case .limit(let s): return harness("limit", s)
        case .patchReady(let p): return harness("patch", p.filesChanged.map(\.path).joined(separator: ","))
        }
    }

    /// ChatError -> typed API error (table in docs/CHAT-CORE.md).
    static func error(_ e: ChatError) -> ControlError {
        let msg = "\(e.code): \(e)"
        switch e {
        case .sessionNotFound: return .notFound(msg)
        case .turnInProgress, .maxSessions, .sessionClosed, .idleTimeout: return .conflict(msg)
        case .emptyText, .textTooLong, .unknownProfile: return .badRequest(msg)
        case .openFailed(let m) where m.hasPrefix("forbidden: "): return .forbidden(String(m.dropFirst("forbidden: ".count)))
        case .openFailed(let m): return m.hasPrefix("invalid cwd") ? .badRequest(msg) : .internalError(msg)
        }
    }
}
