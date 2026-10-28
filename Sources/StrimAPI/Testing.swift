import Foundation

/// Scriptable in-memory `StrimControlClient` for UI and unit tests.
/// Configure responses via the setters, push events with `emit`, end streams with `finishEvents`.
public actor FakeControlClient: StrimControlClient {
    public private(set) var statusValue: HostStatus
    public private(set) var jobList: [JobSummary] = []
    public private(set) var details: [String: JobDetail] = [:]
    public private(set) var session: ChatSession
    /// Every mutating call, in order, e.g. "load:model", "unload", "approve:id:apply", "chat_append:sid:text".
    public private(set) var calls: [String] = []
    /// Full approval requests (including `patchSHA256`), in order.
    public private(set) var approvals: [PatchApproval] = []
    public private(set) var pauseState = JobsPauseState(paused: false)
    public private(set) var modelList = ModelList(models: [])
    public private(set) var packValue = PackInfo()
    /// Full chat append requests (including `enableThinking`), in order.
    public private(set) var appends: [ChatAppendRequest] = []
    /// When set, the next call to any method throws it (then clears).
    public var failNext: Error?

    private var continuations: [UUID: AsyncThrowingStream<StrimEvent, Error>.Continuation] = [:]
    private var backlog: [StrimEvent] = []

    public init(status: HostStatus = FakeControlClient.sampleStatus,
                session: ChatSession = ChatSession(sessionID: "s1", jobID: "j-chat", cwd: "/tmp", profile: "interactive")) {
        self.statusValue = status; self.session = session
    }

    public static let sampleStatus = HostStatus(
        state: .ready, model: "Qwen3.8-27B", mtp: "mtp-head",
        memory: MemoryStats(weightsGB: 15.2, prefixTrieGB: 2, mlxCacheGB: 1, headroomGB: 20), jobsPaused: false,
        quantFingerprint: "0123456789abcdef/fedcba9876543210")

    public func setStatus(_ s: HostStatus) { statusValue = s }
    public func setJobs(_ j: [JobSummary]) { jobList = j }
    public func setDetail(_ d: JobDetail) { details[d.id] = d }
    public func setModels(_ m: [LocalModel]) { modelList = ModelList(models: m) }
    public func setPack(_ p: PackInfo) { packValue = p }
    public func setFailNext(_ e: Error?) { failNext = e }

    /// Events emitted before any subscriber exists are replayed to the first one.
    public func emit(_ e: StrimEvent) {
        if continuations.isEmpty { backlog.append(e) }
        for c in continuations.values { c.yield(e) }
    }
    public func finishEvents(throwing error: Error? = nil) {
        for c in continuations.values { if let error { c.finish(throwing: error) } else { c.finish() } }
        continuations.removeAll()
    }

    private func check() throws { if let e = failNext { failNext = nil; throw e } }

    public func status() async throws -> HostStatus { try check(); return statusValue }

    public nonisolated func events() -> AsyncThrowingStream<StrimEvent, Error> {
        AsyncThrowingStream { cont in
            let id = UUID()
            Task { await self.subscribe(id, cont) }
            cont.onTermination = { _ in Task { await self.unsubscribe(id) } }
        }
    }
    private func subscribe(_ id: UUID, _ c: AsyncThrowingStream<StrimEvent, Error>.Continuation) {
        if let e = failNext { failNext = nil; c.finish(throwing: e); return }
        continuations[id] = c
        for e in backlog { c.yield(e) }
        backlog.removeAll()
    }
    private func unsubscribe(_ id: UUID) { continuations[id] = nil }

    public func load(_ request: LoadRequest) async throws {
        try check(); calls.append("load:\(request.model)")
        statusValue.state = .ready; statusValue.model = request.model; statusValue.mtp = request.mtp
    }
    public func unload() async throws {
        try check(); calls.append("unload")
        statusValue.state = .stopped; statusValue.model = nil
    }
    public func jobs() async throws -> [JobSummary] { try check(); return jobList }
    public func job(id: String) async throws -> JobDetail {
        try check()
        if let d = details[id] { return d }
        if let s = jobList.first(where: { $0.id == id }) { return JobDetail(summary: s) }
        throw APIError(code: "not_found", message: "no job \(id)")
    }
    public func approve(_ approval: PatchApproval) async throws {
        try check(); calls.append("approve:\(approval.jobID):\(approval.action.rawValue)"); approvals.append(approval)
    }
    public func chatOpen(_ request: ChatOpenRequest) async throws -> ChatSession {
        try check(); calls.append("chat_open:\(request.cwd)")
        var s = session; s.cwd = request.cwd; s.profile = request.profile; return s
    }
    public func chatAppend(_ request: ChatAppendRequest) async throws {
        try check(); calls.append("chat_append:\(request.sessionID):\(request.text)"); appends.append(request)
    }
    public func chatCancel(_ request: ChatCancelRequest) async throws {
        try check(); calls.append("chat_cancel:\(request.sessionID)")
    }

    public func pauseJobs(_ request: PauseRequest) async throws -> JobsPauseState {
        try check(); calls.append("pause:\(request.cancelRunning)")
        pauseState.paused = true; statusValue.jobsPaused = true
        return pauseState
    }
    public func resumeJobs() async throws -> JobsPauseState {
        try check(); calls.append("resume")
        pauseState.paused = false; statusValue.jobsPaused = false
        return pauseState
    }
    public func cancelJob(_ request: JobCancelRequest) async throws -> JobCancelResult {
        try check(); calls.append("cancel_job:\(request.jobID)")
        guard let i = jobList.firstIndex(where: { $0.id == request.jobID }) else { throw APIError(code: "not_found", message: "no job") }
        let was = jobList[i].status
        let terminal: [JobStatusDTO] = [.done, .failed, .cancelled, .limit]
        if !terminal.contains(was) { jobList[i].status = .cancelled }
        return JobCancelResult(jobID: request.jobID, status: jobList[i].status, cancelled: !terminal.contains(was))
    }
    public func models() async throws -> ModelList { try check(); return modelList }
    public func pack() async throws -> PackInfo { try check(); return packValue }
}
