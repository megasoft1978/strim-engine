import Foundation
import StrimEngine

/// Per-session state owned by `HarnessRunner` (an actor serialises every access).
final class ChatSessionState {
    let id: String
    let spec: HarnessJobSpec
    let profile: RunProfile
    let ws: Workspace
    let loop: AgentLoop
    let conversation: LoopConversation
    let jobDir: String
    let jobTmp: String
    let sink: EventSink
    var turnActive = false
    var turnTask: Task<Void, Never>?
    var closing = false
    var lastPatch = ""
    init(id: String, spec: HarnessJobSpec, profile: RunProfile, ws: Workspace, loop: AgentLoop,
         conversation: LoopConversation, jobDir: String, jobTmp: String, sink: EventSink) {
        self.id = id; self.spec = spec; self.profile = profile; self.ws = ws; self.loop = loop
        self.conversation = conversation; self.jobDir = jobDir; self.jobTmp = jobTmp; self.sink = sink
    }
}

/// Multi-turn sessions. A session is a long-lived job: one workspace (kept until `closeSession`), one engine
/// conversation (append-only transcript), one turn at a time. The parent tree is never written.
extension HarnessRunner {
    /// Opens a session: job dir, isolated workspace, prompt, tools and sandbox exactly as `run` assembles them.
    /// `spec.task` is ignored (the first user turn becomes the task) and `spec.verify` is not used.
    /// Limits come from `profile.limits(requested: spec.limits)` and apply per user turn.
    public func openSession(spec: HarnessJobSpec, sessionID: String, profile: RunProfile = .interactive) async throws {
        guard Self.validJobID(sessionID) else { throw ChatError.openFailed("invalid session id") }
        guard chats[sessionID] == nil else { throw ChatError.openFailed("session exists") }
        let jobDir = jobsDir.appendingPathComponent(sessionID).path
        let jobTmp = jobDir + "/tmp"
        do {
            try Self.makeDir(jobsDir.path); try Self.makeDir(jobDir); try Self.makeDir(jobTmp)
        } catch {
            throw ChatError.openFailed("cannot create job dir: \(error.localizedDescription)")
        }
        func fail(_ message: String, _ ws: Workspace? = nil) async -> ChatError {
            if let ws { await Self.shielded { await self.isolation.cleanup(ws) } }
            GitWorktreeIsolation.makeRemovable(jobTmp, under: jobDir)
            try? FileManager.default.removeItem(atPath: jobTmp)
            return .openFailed(message)
        }
        let cwd: String
        switch Self.validateCwd(spec.cwd) {
        case let .success(p): cwd = p
        case let .failure(e): throw await fail("invalid cwd: \(e.message)")
        }
        var cspec = spec
        cspec.limits = profile.limits(requested: spec.limits)
        cspec.verify = nil
        cspec.task = ""
        let ws: Workspace
        do { ws = try await isolation.prepare(cwd: cwd, access: cspec.access, files: cspec.files) } catch {
            throw await fail("workspace preparation failed: \(error)")
        }
        // The actor may have been re-entered while preparing: re-check before registering.
        if chats[sessionID] != nil { throw await fail("session exists", ws) }
        let asm = await assemble(spec: cspec, ws: ws, cwd: cwd, jobTmp: jobTmp, priority: profile.priority)
        let sink = EventSink(path: jobDir + "/events.jsonl", now: now)
        let conv = asm.loop.openConversation(spec: asm.loopSpec, workspace: ws)
        chats[sessionID] = ChatSessionState(id: sessionID, spec: cspec, profile: profile, ws: ws, loop: asm.loop,
                                            conversation: conv, jobDir: jobDir, jobTmp: jobTmp, sink: sink)
    }

    public func hasSession(_ sessionID: String) -> Bool { chats[sessionID] != nil }

    public func isTurnActive(sessionID: String) -> Bool { chats[sessionID]?.turnActive ?? false }

    public func workspaceRoot(sessionID: String) -> String? { chats[sessionID]?.ws.root }

    /// Thinking for the session's engine generation, sent like the server adapter's `enable_thinking` (true = thinking
    /// template on with tools; nil = unchanged default). Read when the engine session opens, i.e. on the first turn;
    /// a change after that is stored but does not reach the open engine session.
    public func setThinking(sessionID: String, enabled: Bool?) async {
        chats[sessionID]?.conversation.thinking = enabled
    }

    /// Starts a user turn and returns its event stream. Throws `ChatError.turnInProgress` while another turn runs
    /// (turns are rejected, never queued). The stream ends after `.turnFinished`; dropping the stream cancels the turn.
    public func appendUserTurn(sessionID: String, text: String) throws -> AsyncStream<ChatEvent> {
        guard let cs = chats[sessionID] else { throw ChatError.sessionNotFound(sessionID) }
        guard !cs.closing else { throw ChatError.sessionClosed }
        guard !cs.turnActive else { throw ChatError.turnInProgress }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.emptyText }
        guard text.count <= ChatLimits.maxUserTextChars else { throw ChatError.textTooLong(ChatLimits.maxUserTextChars) }
        cs.turnActive = true
        let n = cs.conversation.userTurns + 1
        let (stream, cont) = AsyncStream<ChatEvent>.makeStream(bufferingPolicy: .unbounded)
        let task = Task { await self.runTurn(cs, text: text, userTurn: n, cont: cont) }
        cs.turnTask = task
        cont.onTermination = { reason in if case .cancelled = reason { task.cancel() } }
        return stream
    }

    /// Cancels the running turn (no-op when idle) and returns once it has fully stopped: the engine generation is
    /// cancelled and the session is ready for the next turn. The session and its workspace stay open.
    public func cancelTurn(sessionID: String) async {
        guard let cs = chats[sessionID], cs.turnActive, let t = cs.turnTask else { return }
        t.cancel()
        await t.value
    }

    /// Current diff of the session workspace against its base (empty string when unchanged or read-only).
    public func currentPatch(sessionID: String) async throws -> String {
        guard let cs = chats[sessionID] else { throw ChatError.sessionNotFound(sessionID) }
        guard cs.spec.access == .write else { return "" }
        return try await isolation.collectPatch(cs.ws)
    }

    /// Ends the session: cancels a running turn, closes the engine session once, collects the final patch, removes
    /// the worktree (or retains it with `keepWorkspace`) and writes `result.json`. Returns nil if the session is
    /// unknown or already closing.
    @discardableResult
    public func closeSession(sessionID: String) async -> HarnessJobResult? {
        guard let cs = chats[sessionID], !cs.closing else { return nil }
        cs.closing = true
        if cs.turnActive, let t = cs.turnTask { t.cancel(); await t.value }
        await cs.loop.closeConversation(cs.conversation)
        var result = HarnessJobResult(status: .done, summary: "session closed", base: cs.ws.base,
                                      commands: cs.conversation.commands, usage: cs.conversation.totalUsage)
        if cs.spec.access == .write {
            do {
                let p = try await isolation.collectPatch(cs.ws)
                if !p.isEmpty {
                    let path = cs.jobDir + "/patch.diff"
                    try Self.writeFile(path, Data(p.utf8))
                    result.patchPath = path
                    result.patch = p.utf8.count <= Self.maxInlinePatchBytes ? p : nil
                    result.filesChanged = GitWorktreeIsolation.fileChanges(in: p)
                }
            } catch {
                result.status = .failed
                result.summary += " [patch collection failed: \(error)]"
            }
        }
        cs.sink.close()
        Self.writeResult(result, jobDir: cs.jobDir, workspace: keepWorkspace ? cs.ws : nil, finishedAt: now())
        GitWorktreeIsolation.makeRemovable(cs.jobTmp, under: cs.jobDir)
        try? FileManager.default.removeItem(atPath: cs.jobTmp)
        if keepWorkspace { keepSessionWorkspace(sessionID, cs.ws) } else {
            let ws = cs.ws
            await Self.shielded { await self.isolation.cleanup(ws) }
        }
        chats[sessionID] = nil
        return result
    }

    /// Closes every open session (host shutdown).
    public func closeAllSessions() async {
        for id in Array(chats.keys) { await closeSession(sessionID: id) }
    }

    // MARK: turn

    private func runTurn(_ cs: ChatSessionState, text: String, userTurn: Int,
                         cont: AsyncStream<ChatEvent>.Continuation) async {
        let mapper = ChatEventMapper(streamsDeltas: cs.profile.streamsDeltas)
        let sink = cs.sink
        let emit: @Sendable (HarnessEvent) -> Void = { e in
            sink.handle(e)
            for ce in mapper.map(e) { cont.yield(ce) }
        }
        var result = await cs.loop.runUserTurn(cs.conversation, text: text, onEvent: emit)
        for ce in mapper.flush() { cont.yield(ce) }
        if result.status == .limit { cont.yield(.limit(ChatEventMapper.summary(result.summary))) }

        // Patch of the whole session workspace after every turn that was not cancelled or declined.
        if cs.spec.access == .write, result.status != .cancelled, result.status != .declined, !Task.isCancelled {
            do {
                let p = try await isolation.collectPatch(cs.ws)
                if !p.isEmpty, p != cs.lastPatch {
                    cs.lastPatch = p
                    let path = cs.jobDir + "/patch.diff"
                    try Self.writeFile(path, Data(p.utf8))
                    cont.yield(.patchReady(ChatPatch(userTurn: userTurn,
                                                     patch: p.utf8.count <= Self.maxInlinePatchBytes ? p : nil,
                                                     patchPath: path, filesChanged: GitWorktreeIsolation.fileChanges(in: p))))
                }
            } catch {
                result.status = .failed
                result.summary += " [patch collection failed: \(error)]"
            }
        }
        // Ready for the next turn before the client can see the end of this one.
        cs.turnActive = false
        cs.turnTask = nil
        cont.yield(.turnFinished(ChatTurnResult(userTurn: userTurn, status: result.status,
                                                summary: String(Redactor.redact(result.summary).prefix(1500)),
                                                usage: result.usage, totalUsage: cs.conversation.totalUsage)))
        cont.finish()
    }
}
