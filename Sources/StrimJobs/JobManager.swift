import Foundation
import StrimHarness
import StrimAdmission

/// Runs one job. Production passes `HarnessRunner.run(spec:jobID:onEvent:)`.
/// A failed result whose summary contains `insufficient_memory` is retried (admission rejection).
public typealias JobExecutor = @Sendable (HarnessJobSpec, String, @escaping @Sendable (HarnessEvent) -> Void) async -> HarnessJobResult

public actor JobManager: JobManaging {
    private struct Job {
        var id: JobID
        var spec: HarnessJobSpec
        var priority: JobPriority
        var status: JobStatus = .queued
        var createdAt: Date
        var startedAt: Date?
        var finishedAt: Date?
        var pausedAccum: TimeInterval = 0
        var pausedSince: Date?
        var turn = 0
        var lastSteps: [String] = []
        var events: [JobEvent] = []
        var result: HarnessJobResult?
        var reason: String?
        var task: Task<Void, Never>?
        var monitor: Task<Void, Never>?
        var approvalDecision: Bool?
        var approvalCont: CheckedContinuation<Bool, Never>?
        // Chat sessions (nil profile = delegated job).
        var chatProfile: RunProfile?
        var chatProfileName: String?
        var turnActive = false
        var chatClosing = false
        var lastActivity: Date?
        /// Chat: pending / held admission slot of the running user turn (interactive profile outranks background).
        var turnAdmission: Task<AdmissionLease, Error>?
        var turnLease: AdmissionLease?
    }

    private struct Waiter {
        var cont: CheckedContinuation<Void, Never>
        var timeout: Task<Void, Never>
    }

    private let executor: JobExecutor
    private let store: JobStore
    private let maxConcurrent: Int
    private var requireApproval: Bool
    private let interactiveBusy: @Sendable () async -> Bool
    private let pollInterval: Duration
    private let admissionRetryDelay: Duration
    private let maxAdmissionRetries: Int
    private let retentionAge: TimeInterval
    private let retentionCount: Int
    private let now: @Sendable () -> Date
    private let chat: ChatBackend?
    private let maxChatSessions: Int
    private let chatIdleTimeout: TimeInterval
    private let admission: (any AdmissionControlling)?
    /// Unfinished jobs (queued, running, awaiting approval) accepted before `submit` throws `JobError.queueFull`.
    private let maxPending: Int

    private var jobs: [JobID: Job] = [:]
    private var queue: [JobID] = []
    private var active: Set<JobID> = []
    private var waiters: [JobID: [UUID: Waiter]] = [:]
    private var persistTail: Task<Void, Never>?
    /// Background pause: queued jobs are not admitted and an approved job waits before it takes its admission slot.
    /// Chat sessions (interactive) are never affected.
    private var backgroundPaused = false

    public init(executor: @escaping JobExecutor,
                store: JobStore = InMemoryJobStore(),
                maxConcurrent: Int = 1,
                requireApproval: Bool = false,
                interactiveBusy: @escaping @Sendable () async -> Bool = { false },
                pollInterval: Duration = .milliseconds(500),
                admissionRetryDelay: Duration = .seconds(10),
                maxAdmissionRetries: Int = 3,
                retentionAge: TimeInterval = 7 * 86400,
                retentionCount: Int = 50,
                now: @escaping @Sendable () -> Date = { Date() },
                chat: ChatBackend? = nil,
                maxChatSessions: Int = ChatLimits.defaultMaxSessions,
                chatIdleTimeout: TimeInterval = ChatLimits.defaultIdleTimeout,
                admission: (any AdmissionControlling)? = nil,
                maxPending: Int = JobManager.defaultMaxPending) {
        self.maxPending = max(1, maxPending)
        self.admission = admission
        self.chat = chat; self.maxChatSessions = max(1, maxChatSessions); self.chatIdleTimeout = chatIdleTimeout
        self.executor = executor; self.store = store; self.maxConcurrent = max(1, maxConcurrent)
        self.requireApproval = requireApproval; self.interactiveBusy = interactiveBusy
        self.pollInterval = pollInterval; self.admissionRetryDelay = admissionRetryDelay
        self.maxAdmissionRetries = maxAdmissionRetries; self.retentionAge = retentionAge
        self.retentionCount = retentionCount; self.now = now
    }

    public func setRequireApproval(_ on: Bool) { requireApproval = on }

    // MARK: - Background pause

    public var isBackgroundPaused: Bool { backgroundPaused }

    /// Delegated (non-chat) jobs: queued, and admitted-but-unfinished ones.
    public var backgroundCounts: (queued: Int, running: Int) {
        let bg = jobs.values.filter { $0.chatProfileName == nil && !$0.status.isTerminal }
        return (bg.filter { $0.status == .queued }.count, bg.filter { $0.status != .queued }.count)
    }

    /// Stops admitting background jobs. Running ones finish, or are cancelled with `cancelRunning`. Queued jobs stay
    /// queued. Idempotent. Returns how many jobs were cancelled.
    @discardableResult
    public func pauseBackground(cancelRunning: Bool = false) async -> Int {
        backgroundPaused = true
        guard cancelRunning else { return 0 }
        var n = 0
        for id in Array(active) where jobs[id]?.chatProfileName == nil && jobs[id]?.status.isTerminal == false {
            _ = try? await cancel(id)
            n += 1
        }
        return n
    }

    /// Admits queued background jobs again. Idempotent.
    public func resumeBackground() {
        backgroundPaused = false
        pump()
    }

    // MARK: - API

    public static let defaultMaxPending = 64

    public func submit(_ spec: HarnessJobSpec, priority: JobPriority = .normal) async throws -> JobID {
        if jobs.values.reduce(0, { $0 + ($1.status.isTerminal || $1.chatProfileName != nil ? 0 : 1) }) >= maxPending {
            throw JobError.queueFull(limit: maxPending)
        }
        var id = Self.newID()
        while jobs[id] != nil { id = Self.newID() }
        jobs[id] = Job(id: id, spec: spec, priority: priority, createdAt: now())
        if priority == .quick {
            let idx = queue.firstIndex { jobs[$0]?.priority != .quick } ?? queue.count
            queue.insert(id, at: idx)
        } else {
            queue.append(id)
        }
        persist(id)
        pump()
        return id
    }

    public func status(_ id: JobID, waitS: Double = 0) async throws -> JobSnapshot {
        guard let j = jobs[id] else { throw JobError.notFound(id) }
        let w = min(max(waitS.isNaN ? 0 : waitS, 0), 25)
        if w > 0, !j.status.isTerminal {
            let token = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    if Task.isCancelled { cont.resume(); return }
                    let t = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(w))
                        await self?.expire(id, token)
                    }
                    waiters[id, default: [:]][token] = Waiter(cont: cont, timeout: t)
                }
            } onCancel: {
                Task { await self.expire(id, token) }
            }
        }
        guard let cur = jobs[id] else { throw JobError.notFound(id) }
        return snapshot(cur)
    }

    public func cancel(_ id: JobID) async throws -> JobSnapshot {
        guard let j = jobs[id] else { throw JobError.notFound(id) }
        if j.chatProfileName != nil, !j.status.isTerminal { return await closeChat(id, status: .cancelled, reason: nil) }
        if !j.status.isTerminal {
            if let qi = queue.firstIndex(of: id) { queue.remove(at: qi) }
            let task = j.task
            finalize(id, status: .cancelled, summary: "cancelled", reason: nil)
            task?.cancel()
        }
        return snapshot(jobs[id]!)
    }

    public func eventsSince(_ id: JobID, index: Int) async throws -> [JobEvent] {
        guard let j = jobs[id] else { throw JobError.notFound(id) }
        return j.events.filter { $0.index >= index }
    }

    public func approve(_ id: JobID) async throws { try decide(id, true) }
    public func reject(_ id: JobID) async throws { try decide(id, false) }

    /// Waits for queued persistence writes (tests, shutdown).
    public func flush() async {
        while let t = persistTail {
            await t.value
            if persistTail == nil || persistTail == t { break }
        }
    }

    /// Startup: load persisted jobs, fail any non-terminal one (`host_restart`), apply retention.
    public func recover() async {
        let records = (try? await store.list()) ?? []
        for r in records where jobs[r.id] == nil {
            var j = Job(id: r.id, spec: Self.spec(r), priority: r.priority, createdAt: r.createdAt)
            j.status = r.status; j.startedAt = r.startedAt; j.finishedAt = r.finishedAt
            j.pausedAccum = r.pausedS; j.turn = r.turn; j.lastSteps = r.lastSteps; j.reason = r.reason
            j.chatProfileName = r.profile
            j.result = r.result.map(Self.result)
            j.events = (try? await store.events(r.id)) ?? []
            if !j.status.isTerminal {
                j.status = .failed; j.reason = JobFailureReason.hostRestart; j.finishedAt = now()
                j.result = HarnessJobResult(status: .failed, summary: JobFailureReason.hostRestart)
                jobs[r.id] = j
                persist(r.id)
            } else {
                jobs[r.id] = j
            }
        }
        prune()
        await flush()
    }

    // MARK: - Chat sessions

    /// True while any chat session runs a user turn (background jobs pause meanwhile).
    public var hasActiveChatTurn: Bool { jobs.values.contains { $0.turnActive } }

    /// Chat sessions that are not closed.
    public var openChatSessions: Int { jobs.values.filter { $0.chatProfileName != nil && !$0.status.isTerminal }.count }

    /// Opens a chat session as a long-lived job (status `running` until closed). Throws `ChatError.maxSessions` when
    /// `maxChatSessions` are open, `ChatError.openFailed` when the backend cannot prepare the workspace.
    public func openSession(_ spec: HarnessJobSpec, profile: RunProfile = .interactive) async throws -> JobID {
        guard let chat else { throw ChatError.openFailed("chat is not available") }
        guard openChatSessions < maxChatSessions else { throw ChatError.maxSessions(maxChatSessions) }
        var id = Self.newID()
        while jobs[id] != nil { id = Self.newID() }
        var js = spec
        js.limits = profile.limits(requested: spec.limits)
        js.verify = nil
        var job = Job(id: id, spec: js, priority: .normal, createdAt: now())
        job.status = .preparing; job.chatProfile = profile; job.chatProfileName = profile.name; job.lastActivity = now()
        jobs[id] = job
        persist(id)
        do {
            try await chat.openSession(spec: js, sessionID: id, profile: profile)
        } catch {
            let message = (error as? ChatError).map { "\($0.code)" } ?? "\(error)"
            finalize(id, status: .failed, summary: "session open failed: \(message)", reason: nil)
            if let e = error as? ChatError { throw e }
            throw ChatError.openFailed("\(error)")
        }
        guard jobs[id]?.status.isTerminal == false else { throw ChatError.sessionClosed }
        jobs[id]?.startedAt = now()
        jobs[id]?.lastActivity = now()
        setStatus(id, .running)
        jobs[id]?.monitor = Task { await self.chatMonitor(id) }
        return id
    }

    /// Starts a user turn. Typed failures: `sessionNotFound`, `turnInProgress` (turns are rejected, not queued),
    /// `idleTimeout` / `sessionClosed` for a closed session, `emptyText`, `textTooLong`.
    /// The stream ends after `.turnFinished`; dropping it cancels the turn.
    public func appendUserTurn(_ id: JobID, text: String) async throws -> AsyncStream<ChatEvent> {
        guard let chat, let j = jobs[id], j.chatProfileName != nil else { throw ChatError.sessionNotFound(id) }
        if j.status.isTerminal { throw j.reason == JobFailureReason.idleTimeout ? ChatError.idleTimeout : ChatError.sessionClosed }
        guard !j.chatClosing else { throw ChatError.sessionClosed }
        guard !j.turnActive else { throw ChatError.turnInProgress }
        jobs[id]?.turnActive = true
        jobs[id]?.lastActivity = now()
        if let admission {
            let cls: AdmissionClass = (j.chatProfile?.priority ?? .interactive) == .interactive ? .interactive : .background
            let wait = Task { try await admission.lease(cls) }
            jobs[id]?.turnAdmission = wait
            let lease: AdmissionLease
            do { lease = try await withTaskCancellationHandler { try await wait.value } onCancel: { wait.cancel() } } catch {
                jobs[id]?.turnAdmission = nil
                jobs[id]?.turnActive = false
                throw jobs[id]?.chatClosing == true || jobs[id]?.status.isTerminal == true ? ChatError.sessionClosed : error
            }
            jobs[id]?.turnAdmission = nil
            guard let cur = jobs[id], !cur.chatClosing, !cur.status.isTerminal else {
                await lease.release()
                jobs[id]?.turnActive = false
                throw ChatError.sessionClosed
            }
            jobs[id]?.turnLease = lease
        }
        let inner: AsyncStream<ChatEvent>
        do { inner = try await chat.appendUserTurn(sessionID: id, text: text) } catch {
            jobs[id]?.turnActive = false
            releaseTurnLease(id)
            throw error
        }
        let (out, cont) = AsyncStream<ChatEvent>.makeStream(bufferingPolicy: .unbounded)
        let pump = Task {
            for await ev in inner {
                await self.ingestChat(id, ev)
                cont.yield(ev)
            }
            if Task.isCancelled { await chat.cancelTurn(sessionID: id) }
            self.chatTurnEnded(id)
            cont.finish()
        }
        cont.onTermination = { reason in if case .cancelled = reason { pump.cancel() } }
        return out
    }

    /// Forwards the thinking toggle to the backend for an open session (no-op when unsupported).
    public func setChatThinking(_ id: JobID, enabled: Bool?) async throws {
        guard let chat, let j = jobs[id], j.chatProfileName != nil else { throw ChatError.sessionNotFound(id) }
        if j.status.isTerminal { throw j.reason == JobFailureReason.idleTimeout ? ChatError.idleTimeout : ChatError.sessionClosed }
        await chat.setThinking(sessionID: id, enabled: enabled)
    }

    /// Cancels the running turn; returns once it has stopped. The session stays open.
    public func cancelTurn(_ id: JobID) async throws {
        guard let chat, let j = jobs[id], j.chatProfileName != nil else { throw ChatError.sessionNotFound(id) }
        if j.status.isTerminal { throw j.reason == JobFailureReason.idleTimeout ? ChatError.idleTimeout : ChatError.sessionClosed }
        await chat.cancelTurn(sessionID: id)
        jobs[id]?.lastActivity = now()
    }

    /// Ends the session (cancels a running turn, removes the worktree) and finalizes its job as `done`.
    @discardableResult
    public func closeSession(_ id: JobID) async throws -> JobSnapshot {
        guard let j = jobs[id], j.chatProfileName != nil else { throw ChatError.sessionNotFound(id) }
        if j.status.isTerminal { return snapshot(j) }
        return await closeChat(id, status: .done, reason: nil)
    }

    /// Closes every open session idle longer than the timeout; returns their ids. Called by each session's monitor
    /// (every `pollInterval`) and directly by tests with an injected clock.
    @discardableResult
    public func sweepIdleSessions() async -> [JobID] {
        let t = now()
        let due = jobs.values.filter { isIdle($0, at: t) }.map(\.id)
        for id in due { _ = await closeChat(id, status: .done, reason: JobFailureReason.idleTimeout) }
        return due
    }

    private func isIdle(_ j: Job, at t: Date) -> Bool {
        guard j.chatProfileName != nil, !j.status.isTerminal, j.status == .running, !j.turnActive, !j.chatClosing,
              let last = j.lastActivity else { return false }
        return t.timeIntervalSince(last) >= chatIdleTimeout
    }

    private func chatMonitor(_ id: JobID) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return }
            guard let j = jobs[id], isIdle(j, at: now()) else { continue }
            // Closing runs in its own task: finalize cancels this monitor, which must not cancel the close itself.
            Task { _ = await self.closeChat(id, status: .done, reason: JobFailureReason.idleTimeout) }
            return
        }
    }

    private func closeChat(_ id: JobID, status: JobStatus, reason: String?) async -> JobSnapshot {
        guard var j = jobs[id] else { return JobSnapshot(id: id, status: .failed, spec: HarnessJobSpec(task: "", cwd: "")) }
        if j.status.isTerminal || j.chatClosing { return snapshot(j) }
        j.chatClosing = true
        jobs[id] = j
        j.turnAdmission?.cancel()
        var result = HarnessJobResult(status: .done, summary: "session closed")
        if let r = await chat?.closeSession(sessionID: id) { result = r }
        if status == .cancelled { result.status = .cancelled; result.summary = "cancelled" }
        jobs[id]?.turnActive = false
        releaseTurnLease(id)
        finalize(id, status: status, result: result, reason: reason)
        return snapshot(jobs[id]!)
    }

    private func releaseTurnLease(_ id: JobID) {
        guard let l = jobs[id]?.turnLease else { return }
        jobs[id]?.turnLease = nil
        Task { await l.release() }
    }

    private func chatTurnEnded(_ id: JobID) {
        releaseTurnLease(id)
        jobs[id]?.turnActive = false
        jobs[id]?.lastActivity = now()
    }

    private func ingestChat(_ id: JobID, _ ev: ChatEvent) {
        guard var j = jobs[id], !j.status.isTerminal else { return }
        var kind: String
        var text = ""
        switch ev {
        case .stepStarted(let n): kind = "turn"; text = String(n); j.turn = n
        case .toolCallStarted(let name, let summary):
            kind = "tool_call"
            let full = Self.redacted("\(name) \(summary)")
            text = Self.clip(full, 300)
            j.lastSteps.append(Self.clip(full, 60))
            if j.lastSteps.count > 5 { j.lastSteps.removeFirst(j.lastSteps.count - 5) }
        case .toolCallFinished(let name, let summary, let isErr):
            kind = "tool_result"; text = Self.clip(Self.redacted("\(name)\(isErr ? " ERROR" : ""): \(summary)"), 300)
        case .usage: kind = "usage"
        case .compaction(let s): kind = "compaction"; text = Self.clip(Self.redacted(s), 300)
        case .limit(let s): kind = "limit"; text = Self.clip(Self.redacted(s), 300)
        case .patchReady(let p): kind = "patch"; text = Self.clip(Self.redacted(p.filesChanged.map(\.path).joined(separator: ", ")), 300)
        case .turnFinished(let r): kind = "turn_finished"; text = r.status.rawValue; j.turnActive = false  // before the client sees the end
        case .textDelta, .reasoningDelta: return
        }
        j.lastActivity = now()
        let event = JobEvent(index: (j.events.last?.index ?? -1) + 1, kind: kind, text: text)
        j.events.append(event)
        jobs[id] = j
        mirror(id, event)
    }

    // MARK: - Scheduling

    private func pump() {
        guard !backgroundPaused else { return }
        while active.count < maxConcurrent, let id = queue.first {
            queue.removeFirst()
            guard jobs[id]?.status == .queued else { continue }
            active.insert(id)
            setStatus(id, .preparing)
            jobs[id]?.task = Task { await self.runWrapper(id) }
        }
    }

    private func runWrapper(_ id: JobID) async {
        await run(id)
        jobs[id]?.monitor?.cancel()
        jobs[id]?.monitor = nil
        active.remove(id)
        pump()
    }

    private func run(_ id: JobID) async {
        if requireApproval {
            setStatus(id, .awaitingApproval)
            wake(id)
            let approved: Bool = await withCheckedContinuation { cont in
                guard let d = jobs[id]?.approvalDecision else {
                    if jobs[id]?.status.isTerminal != false { cont.resume(returning: false) } else { jobs[id]?.approvalCont = cont }
                    return
                }
                cont.resume(returning: d)
            }
            if !approved {
                finalize(id, status: .cancelled, summary: "rejected", reason: nil)
                return
            }
        }
        guard jobs[id]?.status.isTerminal == false else { return }
        // Paused after this job was admitted (for example while awaiting approval): hold until resumed or cancelled.
        while backgroundPaused, jobs[id]?.status.isTerminal == false {
            do { try await Task.sleep(for: min(pollInterval, .milliseconds(200))) } catch { return }
        }
        guard jobs[id]?.status.isTerminal == false else { return }
        // Delegated jobs are background work: wait for a slot (interactive outranks; cancel while waiting drops out).
        var lease: AdmissionLease?
        if let admission {
            do { lease = try await admission.lease(.background) } catch { return }
        }
        await execute(id, lease: lease)
        await lease?.release()
    }

    private func execute(_ id: JobID, lease: AdmissionLease?) async {
        guard let j0 = jobs[id], !j0.status.isTerminal else { return }
        jobs[id]?.startedAt = now()
        setStatus(id, .running)
        jobs[id]?.monitor = Task { await self.monitorLoop(id) }

        // The manager owns the wall-clock limit (it excludes paused time), so the executor gets a huge one.
        var spec = j0.spec
        spec.limits.maxSeconds = max(spec.limits.maxSeconds, 86_400)
        let (stream, cont) = AsyncStream<HarnessEvent>.makeStream()
        let consumer = Task { for await ev in stream { await self.ingest(id, ev) } }
        let emit: @Sendable (HarnessEvent) -> Void = { cont.yield($0) }

        var attempt = 0
        var result: HarnessJobResult
        while true {
            result = await Self.runExecutor(executor, spec, id, emit, lease)
            guard !Task.isCancelled, jobs[id]?.status.isTerminal == false else { break }
            if result.status == .failed, result.summary.contains(JobFailureReason.insufficientMemory),
               attempt < maxAdmissionRetries {
                attempt += 1
                setStatus(id, .queued)
                try? await Task.sleep(for: admissionRetryDelay)
                guard !Task.isCancelled, jobs[id]?.status.isTerminal == false else { break }
                setStatus(id, .running)
                continue
            }
            break
        }
        cont.finish()
        await consumer.value
        guard jobs[id]?.status.isTerminal == false else { return }
        let failedReason = result.status == .failed && result.summary.contains(JobFailureReason.insufficientMemory)
            ? JobFailureReason.insufficientMemory : nil
        finalize(id, result: result, reason: failedReason)
    }

    /// Runs the executor with the turn-boundary hook bound (background jobs only; no-op without admission).
    private static func runExecutor(_ exec: JobExecutor, _ spec: HarnessJobSpec, _ id: String,
                                    _ emit: @escaping @Sendable (HarnessEvent) -> Void,
                                    _ lease: AdmissionLease?) async -> HarnessJobResult {
        let hook: (@Sendable () async throws -> Void)? = lease.map { l in { @Sendable () async throws -> Void in try await l.checkpoint() } }
        return await AdmissionCheckpoint.$current.withValue(hook) { await exec(spec, id, emit) }
    }

    private func monitorLoop(_ id: JobID) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return }
            var busy = await interactiveBusy() || hasActiveChatTurn
            if !busy, let admission { busy = await admission.interactivePresent() }
            if Task.isCancelled { return }
            tick(id, busy: busy)
        }
    }

    private func tick(_ id: JobID, busy: Bool) {
        guard var j = jobs[id] else { return }
        let t = now()
        switch j.status {
        case .running where busy:
            j.pausedSince = t
            jobs[id] = j
            setStatus(id, .pausedInteractive)
        case .pausedInteractive where !busy:
            if let s = j.pausedSince { j.pausedAccum += t.timeIntervalSince(s) }
            j.pausedSince = nil
            jobs[id] = j
            setStatus(id, .running)
        default: break
        }
        guard let cur = jobs[id], cur.status == .running || cur.status == .pausedInteractive,
              let started = cur.startedAt else { return }
        let active = t.timeIntervalSince(started) - pausedTotal(cur, at: t)
        if active > cur.spec.limits.maxSeconds {
            let task = cur.task
            finalize(id, status: .limit, summary: "wall-clock limit reached (\(Int(cur.spec.limits.maxSeconds))s)", reason: nil)
            task?.cancel()
        }
    }

    private func ingest(_ id: JobID, _ ev: HarnessEvent) {
        guard var j = jobs[id], !j.status.isTerminal else { return }
        var kind: String
        var text = ""
        switch ev {
        case .turn(let n): kind = "turn"; text = String(n); j.turn = n
        case .toolCall(let name, let args):
            kind = "tool_call"
            let full = Self.redacted("\(name) \(args)")   // redact first, then clip
            text = Self.clip(full, 300)
            j.lastSteps.append(Self.clip(full, 60))
            if j.lastSteps.count > 5 { j.lastSteps.removeFirst(j.lastSteps.count - 5) }
        case .toolResult(let name, let out, let isErr):
            kind = "tool_result"; text = Self.clip(Self.redacted("\(name)\(isErr ? " ERROR" : ""): \(out)"), 300)
        case .approval(let cmd): kind = "approval"; text = Self.clip(Self.redacted(cmd), 300)
        case .usage: kind = "usage"
        case .finished(let s):
            kind = "finished"; text = s.rawValue
            if j.status == .running || j.status == .pausedInteractive { jobs[id] = j; setStatus(id, .finalizing); j = jobs[id]! }
        case .textDelta, .reasoningDelta: jobs[id] = j; return
        }
        let event = JobEvent(index: (j.events.last?.index ?? -1) + 1, kind: kind, text: text)
        j.events.append(event)
        jobs[id] = j
        mirror(id, event)
    }

    // MARK: - State

    private func decide(_ id: JobID, _ approve: Bool) throws {
        guard let j = jobs[id] else { throw JobError.notFound(id) }
        guard j.status == .awaitingApproval, j.approvalDecision == nil else { throw JobError.notAwaitingApproval(id) }
        jobs[id]?.approvalDecision = approve
        if let c = jobs[id]?.approvalCont {
            jobs[id]?.approvalCont = nil
            c.resume(returning: approve)
        }
    }

    private func setStatus(_ id: JobID, _ s: JobStatus) {
        guard jobs[id] != nil, jobs[id]?.status.isTerminal == false else { return }
        jobs[id]?.status = s
        persist(id)
    }

    private func finalize(_ id: JobID, status: JobStatus, summary: String, reason: String?) {
        var usage = HarnessUsage()
        usage.turns = jobs[id]?.turn ?? 0
        let hs: HarnessStatus = status == .limit ? .limit : (status == .cancelled ? .cancelled : .failed)
        finalize(id, status: status, result: HarnessJobResult(status: hs, summary: summary, usage: usage), reason: reason)
    }

    private func finalize(_ id: JobID, result: HarnessJobResult, reason: String?) {
        let s: JobStatus
        switch result.status {
        case .done: s = .done
        case .failed: s = .failed
        case .cancelled: s = .cancelled
        case .limit: s = .limit
        case .declined: s = .declined
        }
        finalize(id, status: s, result: result, reason: reason)
    }

    private func finalize(_ id: JobID, status: JobStatus, result: HarnessJobResult, reason: String?) {
        guard var j = jobs[id], !j.status.isTerminal else { return }
        let t = now()
        if let s = j.pausedSince { j.pausedAccum += t.timeIntervalSince(s); j.pausedSince = nil }
        j.status = status; j.finishedAt = t; j.result = Self.redactedResult(result); j.reason = reason.map(Self.redacted)
        j.monitor?.cancel(); j.monitor = nil
        let cont = j.approvalCont
        j.approvalCont = nil
        jobs[id] = j
        cont?.resume(returning: false)
        if let qi = queue.firstIndex(of: id) { queue.remove(at: qi) }
        persist(id)
        wake(id)
        prune()
    }

    private func pausedTotal(_ j: Job, at t: Date) -> TimeInterval {
        j.pausedAccum + (j.pausedSince.map { t.timeIntervalSince($0) } ?? 0)
    }

    private func snapshot(_ j: Job) -> JobSnapshot {
        let t = j.finishedAt ?? now()
        let elapsed = j.startedAt.map { max(0, t.timeIntervalSince($0)) } ?? 0
        let p = JobProgress(turn: j.turn, maxTurns: j.spec.limits.maxTurns, elapsedS: elapsed,
                            pausedS: pausedTotal(j, at: t), lastSteps: j.lastSteps)
        return JobSnapshot(id: j.id, status: j.status, spec: j.spec, progress: p, result: j.result, reason: j.reason.map(Self.redacted),
                           profile: j.chatProfileName, turnActive: j.turnActive, lastActivityAt: j.lastActivity)
    }

    // MARK: - Waiters

    private func wake(_ id: JobID) {
        guard let ws = waiters.removeValue(forKey: id) else { return }
        for (_, w) in ws { w.timeout.cancel(); w.cont.resume() }
    }

    private func expire(_ id: JobID, _ token: UUID) {
        guard let w = waiters[id]?.removeValue(forKey: token) else { return }
        if waiters[id]?.isEmpty == true { waiters[id] = nil }
        w.timeout.cancel()
        w.cont.resume()
    }

    // MARK: - Persistence and retention

    private func chain(_ op: @escaping @Sendable () async -> Void) {
        let prev = persistTail
        persistTail = Task { await prev?.value; await op() }
    }

    private func persist(_ id: JobID) {
        guard let j = jobs[id] else { return }
        let rec = record(j)
        let store = self.store
        chain { try? await store.save(rec) }
    }

    private func mirror(_ id: JobID, _ e: JobEvent) {
        let store = self.store
        chain { try? await store.appendEvent(id, e) }
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-retentionAge)
        func stamp(_ j: Job) -> Date { j.finishedAt ?? j.createdAt }
        let terminal = jobs.values.filter { $0.status.isTerminal }.sorted { stamp($0) > stamp($1) }
        var drop: [JobID] = terminal.filter { stamp($0) < cutoff }.map(\.id)
        let kept = terminal.filter { !drop.contains($0.id) }
        if kept.count > retentionCount { drop += kept.dropFirst(retentionCount).map(\.id) }
        let store = self.store
        for id in drop {
            jobs[id] = nil
            waiters[id] = nil
            chain { try? await store.remove(id) }
        }
    }

    private func record(_ j: Job) -> JobRecord {
        let r = Self.redacted
        let l = j.spec.limits
        var rr: JobRecordResult?
        if let res = j.result {
            rr = JobRecordResult(
                status: res.status, summary: r(res.summary),
                filesChanged: res.filesChanged.map { FileChange(path: r($0.path), added: $0.added, removed: $0.removed) },
                patch: res.patch.map(r), patchPath: res.patchPath.map(r), base: res.base.map(r),
                commands: res.commands.map { CommandRecord(cmd: r($0.cmd), exit: $0.exit) }, usage: res.usage,
                verify: Self.redactedVerify(res.verify))
        }
        return JobRecord(
            id: j.id, status: j.status, priority: j.priority, task: r(j.spec.task), cwd: r(j.spec.cwd),
            context: j.spec.context.map(r), files: j.spec.files.map(r), access: j.spec.access,
            verify: j.spec.verify.map(r),
            maxTurns: l.maxTurns, maxSeconds: l.maxSeconds, maxGeneratedTokens: l.maxGeneratedTokens,
            maxRepeatedCalls: l.maxRepeatedCalls, maxConsecutiveErrors: l.maxConsecutiveErrors,
            createdAt: j.createdAt, startedAt: j.startedAt, finishedAt: j.finishedAt,
            pausedS: j.pausedAccum, turn: j.turn, lastSteps: j.lastSteps.map(r), reason: j.reason.map(r), result: rr,
            profile: j.chatProfileName)
    }

    private static func spec(_ r: JobRecord) -> HarnessJobSpec {
        var l = HarnessLimits()
        l.maxTurns = r.maxTurns; l.maxSeconds = r.maxSeconds; l.maxGeneratedTokens = r.maxGeneratedTokens
        l.maxRepeatedCalls = r.maxRepeatedCalls; l.maxConsecutiveErrors = r.maxConsecutiveErrors
        return HarnessJobSpec(task: r.task, cwd: r.cwd, context: r.context, files: r.files, access: r.access, limits: l, verify: r.verify)
    }

    /// Redacts every field handed to the parent except `patch`: redaction would break `git apply`
    /// (the patch is untrusted data and the executor is responsible for scrubbing it).
    private static func redactedResult(_ r: HarnessJobResult) -> HarnessJobResult {
        var o = r
        o.summary = redacted(r.summary)
        o.filesChanged = r.filesChanged.map { FileChange(path: redacted($0.path), added: $0.added, removed: $0.removed) }
        o.patchPath = r.patchPath.map(redacted); o.base = r.base.map(redacted)
        o.commands = r.commands.map { CommandRecord(cmd: redacted($0.cmd), exit: $0.exit) }
        o.verify = redactedVerify(r.verify)
        return o
    }

    private static func redactedVerify(_ v: VerifyResult) -> VerifyResult {
        VerifyResult(status: v.status, exitCode: v.exitCode, outputTail: redacted(v.outputTail),
                     touchedSensitive: v.touchedSensitive.map(redacted))
    }

    private static func result(_ r: JobRecordResult) -> HarnessJobResult {
        HarnessJobResult(status: r.status, summary: r.summary, filesChanged: r.filesChanged, patch: r.patch,
                         patchPath: r.patchPath, base: r.base, commands: r.commands, usage: r.usage,
                         verify: r.verify ?? .unverified)
    }

    // MARK: - Helpers

    @Sendable private static func redacted(_ s: String) -> String { Redactor.redact(s) }

    private static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    static func newID() -> JobID {
        var g = SystemRandomNumberGenerator()
        return "j_" + String((0..<10).map { _ in alphabet[Int(g.next() % 32)] })
    }
}
