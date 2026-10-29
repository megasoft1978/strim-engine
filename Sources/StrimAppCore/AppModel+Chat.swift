import Foundation
import StrimAPI

/// A message waiting for the generating turn to finish.
public struct QueuedSend: Equatable, Identifiable, Sendable {
    public var threadID: String
    public var text: String
    public var id: String { threadID }
}

/// Streaming state of one thread's current turn.
final class TurnBuffer {
    var pendingText = ""
    var pendingRole: ChatMessage.Role?
    /// First message of the current assistant text run and its raw (tag-bearing) text; see `ThinkSplitter`.
    var rawBase: Int?
    var rawText = ""
    var flushTask: Task<Void, Never>?
    var ledger = TokenLedger()
    var start: Date?
}

// MARK: derived state

extension AppModel {
    public var chat: ChatState {
        guard let sel = selectedThreadID else { return chatProbeError.map { .unavailable($0) } ?? .unknown }
        if let s = liveSessions[sel] { return .ready(s) }
        if let why = chatUnavailable[sel] { return .unavailable(why) }
        return .unknown
    }
    /// Transcript of the selected thread.
    public var chatMessages: [ChatMessage] { selectedThreadID.flatMap { messages[$0] } ?? [] }
    /// The selected thread's turn is running.
    public var chatGenerating: Bool { generatingThreadID != nil && generatingThreadID == selectedThreadID }

    public var selectedThread: ChatThread? { selectedThreadID.flatMap(thread) }
    public var selectedProject: ChatProject? { selectedThread.flatMap { project($0.projectId) } }
    public func thread(_ id: String) -> ChatThread? { threads.first { $0.id == id } }
    public func project(_ id: String) -> ChatProject? { projects.first { $0.id == id } }
    /// Newest activity first.
    public func threads(in projectID: String) -> [ChatThread] {
        threads.filter { $0.projectId == projectID }.sorted { $0.lastActivity > $1.lastActivity }
    }
    public func queuedText(for threadID: String) -> String? { queue.first { $0.threadID == threadID }?.text }
    public func hasLiveSession(_ threadID: String) -> Bool { liveSessions[threadID] != nil }

    /// Working directory a thread's host session uses (scratch threads get their own folder).
    public func cwd(for t: ChatThread) -> String? {
        guard let p = project(t.projectId) else { return nil }
        return p.isScratch ? p.path + "/" + t.id : p.path
    }

    /// nil when the thread's folder is usable. Scratch folders are created lazily, so they are never "missing".
    public func folderProblem(for threadID: String) -> String? {
        guard let t = thread(threadID), let p = project(t.projectId) else { return "Chat not found" }
        if p.isScratch { return nil }
        if case .failure = ProjectFolder.resolve(p.path) { return "Folder moved or deleted" }
        return nil
    }
    public func folderMissing(_ projectID: String) -> Bool {
        guard let p = project(projectID), !p.isScratch else { return false }
        if case .failure = ProjectFolder.resolve(p.path) { return true }
        return false
    }

    public func sendAvailability(for threadID: String) -> Availability {
        if chatReadOnly { return .no("Chat history is read-only (saved by a newer Strim).") }
        if let why = folderProblem(for: threadID) { return .no(why) }
        return .yes
    }

    func threadID(forSession sid: String) -> String? {
        liveSessions.first { $0.value.sessionID == sid || $0.value.jobID == sid }?.key
    }
    func buffer(_ tid: String) -> TurnBuffer {
        if let b = buffers[tid] { return b }
        let b = TurnBuffer(); buffers[tid] = b; return b
    }
    var nowTS: Double { clock.now().timeIntervalSince1970 }
}

// MARK: store, migration

extension AppModel {
    func loadChats() {
        var idx = chatStore.load()
        chatReadOnly = idx.readOnly
        chatStoreNotice = idx.notice
        if idx.isNew && !idx.readOnly {
            // One-time migration: projectPath first, then recents that still resolve.
            var seen = Set<String>()
            for raw in [settings.projectPath].compactMap({ $0 }) + settings.recentProjects {
                guard case .success(let dir) = ProjectFolder.resolve(raw), seen.insert(dir).inserted else { continue }
                idx.projects.append(ChatProject(path: dir, addedAt: nowTS, lastActivity: nowTS))
            }
            projects = idx.projects; threads = idx.threads
            saveIndex()
            return
        }
        projects = idx.projects; threads = idx.threads
    }

    func saveIndex() {
        guard !chatReadOnly else { return }
        do { try chatStore.save(ChatIndex(projects: projects, threads: threads)) }
        catch { lastError = "Saving chats: \(error.localizedDescription)" }
    }

    func loadMessages(_ tid: String) {
        guard messages[tid] == nil else { return }
        let lt = chatStore.loadThread(tid)
        let ms = lt.messages.compactMap(\.chatMessage)
        messages[tid] = ms
        persistedCount[tid] = ms.count
        if lt.skipped > 0 { unreadableMessages[tid] = lt.skipped }
    }

    /// Appends the not-yet-saved tail of the transcript.
    func persistNew(_ tid: String) {
        guard !chatReadOnly, let all = messages[tid] else { return }
        let from = persistedCount[tid] ?? 0
        guard from < all.count else { return }
        do {
            try chatStore.appendThread(tid, all[from...].map { StoredMessage($0, ts: nowTS) })
            persistedCount[tid] = all.count
        } catch { lastError = "Saving chat: \(error.localizedDescription)" }
    }

    func updateThread(_ id: String, save: Bool = true, _ f: (inout ChatThread) -> Void) {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        f(&threads[i])
        if save { saveIndex() }
    }

    static func title(from text: String) -> String {
        var s = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for end in [". ", "? ", "! "] { if let r = s.range(of: end) { s = String(s[..<r.lowerBound]) + String(end.first!); break } }
        return String(s.prefix(60))
    }
}

// MARK: projects and threads

extension AppModel {
    @discardableResult
    public func addProject(_ raw: String) -> Result<ChatProject, ProjectFolder.Problem> {
        switch ProjectFolder.resolve(raw) {
        case .failure(let e):
            lastError = e.message
            return .failure(e)
        case .success(let dir):
            if let p = projects.first(where: { $0.path == dir && !$0.isScratch }) { return .success(p) }
            let p = ChatProject(path: dir, addedAt: nowTS, lastActivity: nowTS)
            projects.append(p); saveIndex()
            return .success(p)
        }
    }

    /// Deletes the project's chats (transcripts and sessions), never the folder.
    public func removeProject(_ id: String) async {
        for t in threads where t.projectId == id { await deleteThread(t.id, saving: false) }
        projects.removeAll { $0.id == id }
        saveIndex()
    }

    /// Repoints a project whose folder moved. Its open sessions end (their cwd changed).
    @discardableResult
    public func relocateProject(_ id: String, path raw: String) async -> Result<ChatProject, ProjectFolder.Problem> {
        guard let i = projects.firstIndex(where: { $0.id == id }), !projects[i].isScratch else {
            return .failure(ProjectFolder.Problem(message: "Project not found"))
        }
        switch ProjectFolder.resolve(raw) {
        case .failure(let e):
            lastError = e.message
            return .failure(e)
        case .success(let dir):
            for t in threads where t.projectId == id {
                if generatingThreadID == t.id { await cancel(t.id) }
                await closeSession(t.id)
                chatUnavailable[t.id] = nil
            }
            projects[i].path = dir
            projects[i].name = (dir as NSString).lastPathComponent
            saveIndex()
            return .success(projects[i])
        }
    }

    private func scratchProject() -> ChatProject {
        if let p = projects.first(where: \.isScratch) { return p }
        let p = ChatProject(path: scratchRoot, name: "Scratch", addedAt: nowTS, lastActivity: nowTS, isScratch: true)
        projects.append(p)
        return p
    }

    /// Creates a chat (reusing an empty "New chat" draft in that project) and selects it.
    /// `projectID` nil: the selected chat's project, else Scratch.
    @discardableResult
    public func newThread(projectID: String? = nil) -> ChatThread? {
        let pid: String
        if let projectID { guard project(projectID) != nil else { return nil }; pid = projectID }
        else if let p = selectedProject { pid = p.id }
        else { pid = scratchProject().id }
        if let draft = threads(in: pid).first(where: { $0.messageCount == 0 && $0.id != generatingThreadID && queuedText(for: $0.id) == nil }) {
            selectThread(draft.id)
            return draft
        }
        let t = ChatThread(projectId: pid, createdAt: nowTS, lastActivity: nowTS, thinking: thinkingEnabled)
        threads.append(t)
        messages[t.id] = []; persistedCount[t.id] = 0
        pruneThreads()
        selectThread(t.id)
        return t
    }

    public func selectThread(_ id: String) {
        guard thread(id) != nil else { return }
        selectedThreadID = id
        chatProbeError = nil
        loadMessages(id)
        updateThread(id, save: false) { $0.unread = false }
        saveIndex()
    }

    public func renameThread(_ id: String, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        updateThread(id) { $0.title = String(t.prefix(100)); $0.titleIsUser = true }
    }

    /// Copies the transcript into a new chat in the same project. The copy has no host context (marked).
    @discardableResult
    public func duplicateThread(_ id: String) -> ChatThread? {
        guard let src = thread(id) else { return nil }
        loadMessages(id)
        var copy = (messages[id] ?? []).map { m -> ChatMessage in var c = m; c.id = UUID(); return c }
        if !copy.isEmpty, copy.last?.marker != .sessionBreak {
            copy.append(ChatMessage(role: .assistant, text: ChatMarker.sessionBreak.text, marker: .sessionBreak))
        }
        let t = ChatThread(projectId: src.projectId, title: src.title + " copy", titleIsUser: true, createdAt: nowTS, lastActivity: nowTS,
                           thinking: src.thinking, messageCount: copy.count)
        threads.append(t)
        messages[t.id] = copy
        do { try chatStore.rewriteThread(t.id, copy.map { StoredMessage($0, ts: nowTS) }); persistedCount[t.id] = copy.count }
        catch { lastError = "Saving chat: \(error.localizedDescription)" }
        pruneThreads()
        selectThread(t.id)
        return t
    }

    public func deleteThread(_ id: String) async { await deleteThread(id, saving: true) }

    func deleteThread(_ id: String, saving: Bool) async {
        guard thread(id) != nil else { return }
        if generatingThreadID == id { await cancel(id) }
        queue.removeAll { $0.threadID == id }
        await closeSession(id, marker: false)
        buffers[id]?.flushTask?.cancel(); buffers[id] = nil
        chatStore.deleteThread(id)
        messages[id] = nil; persistedCount[id] = nil; unreadableMessages[id] = nil; chatUnavailable[id] = nil
        let order = threads(in: thread(id)?.projectId ?? "")
        threads.removeAll { $0.id == id }
        if selectedThreadID == id {
            selectedThreadID = nil
            if let next = order.first(where: { $0.id != id }) ?? threads.sorted(by: { $0.lastActivity > $1.lastActivity }).first { selectThread(next.id) }
        }
        if saving { saveIndex() }
    }

    /// Drops the oldest chats past `ChatLimits.maxThreads` (never the selected, running, queued or live ones).
    private func pruneThreads() {
        guard threads.count > ChatLimits.maxThreads else { return }
        let keep = Set([selectedThreadID, generatingThreadID].compactMap { $0 } + queue.map(\.threadID) + Array(liveSessions.keys))
        let victims = threads.filter { !keep.contains($0.id) }.sorted { $0.lastActivity < $1.lastActivity }.prefix(threads.count - ChatLimits.maxThreads)
        for v in victims {
            chatStore.deleteThread(v.id); messages[v.id] = nil; persistedCount[v.id] = nil
            threads.removeAll { $0.id == v.id }
        }
        log("pruned \(victims.count) old chats")
        saveIndex()
    }

    /// Deletes every transcript (Settings: Delete all chat history).
    public func deleteAllChatHistory() async {
        await closeAllSessions()
        chatStore.deleteAll()
        projects = []; threads = []; messages = [:]; persistedCount = [:]; buffers = [:]; selectedThreadID = nil; unreadableMessages = [:]
        chatUnavailable = [:]; chatReadOnly = false
        saveIndex()
    }
}

// MARK: sessions (LRU)

extension AppModel {
    private func touchLive(_ tid: String) {
        liveOrder.removeAll { $0 == tid }
        if liveSessions[tid] != nil { liveOrder.append(tid) }
    }

    /// Open host session for the thread, opening one (and closing the least-recent idle one at the cap) when needed.
    func ensureSession(_ tid: String) async -> ChatSession? {
        if let s = liveSessions[tid] { touchLive(tid); return s }
        chatUnavailable[tid] = nil
        guard status != nil else { chatUnavailable[tid] = "Host offline"; return nil }
        guard let t = thread(tid), let p = project(t.projectId), let dir = cwd(for: t), !opening.contains(tid) else { return nil }
        if p.isScratch {
            do { try SecureFS.ensureDir(dir) } catch { chatUnavailable[tid] = "Scratch folder: \(error.localizedDescription)"; return nil }
        }
        let cwd: String
        switch ProjectFolder.resolve(dir) {
        case .failure(let e): chatUnavailable[tid] = e.message; return nil
        case .success(let d): cwd = d
        }
        opening.insert(tid)
        defer { opening.remove(tid) }
        while liveSessions.count + opening.count - 1 >= Self.maxLiveSessions {
            guard let victim = liveOrder.first(where: { $0 != generatingThreadID && $0 != tid && !opening.contains($0) }) else {
                chatUnavailable[tid] = "Two chats are busy. Wait for one to finish, then try again."
                return nil
            }
            await closeSession(victim)
        }
        do {
            let s = try await client.chatOpen(ChatOpenRequest(cwd: cwd, enableThinking: thinkingEnabled))
            liveSessions[tid] = s; touchLive(tid)
            return s
        } catch {
            chatUnavailable[tid] = isNotImplemented(error) ? ChatState.notAvailableYet : "Chat error: \(error.localizedDescription)"
            return nil
        }
    }

    /// Ends the thread's host session. Its patch then appears in Jobs; the transcript gets a divider.
    func closeSession(_ tid: String, marker: Bool = true) async {
        guard let s = liveSessions[tid] else { return }
        liveSessions[tid] = nil; liveOrder.removeAll { $0 == tid }
        do { try await client.chatClose(sessionID: s.sessionID); log("closed chat session \(s.sessionID.prefix(8))") }
        catch { log("close chat session failed: \(error.localizedDescription)") }
        if marker, messages[tid]?.isEmpty == false, messages[tid]?.last?.marker != .sessionBreak {
            messages[tid]?.append(ChatMessage(role: .assistant, text: ChatMarker.sessionBreak.text, marker: .sessionBreak))
            persistNew(tid)
        }
        await refreshJobs()
    }

    /// Ends every host session (stop server, quit). Best effort.
    public func closeAllSessions() async {
        queue.removeAll()
        if let g = generatingThreadID { flushPending(g); finishTurn(g) }
        for tid in liveOrder { await closeSession(tid) }
    }
}

// MARK: turns

extension AppModel {
    public func probeChat() async {
        chatProbeError = nil
        if selectedThread == nil {
            switch ProjectFolder.resolve(settings.projectPath) {
            case .failure(let e): chatProbeError = e.message; return
            case .success(let dir):
                guard case .success(let p) = addProject(dir) else { return }
                if let latest = threads(in: p.id).first { selectThread(latest.id) } else { newThread(projectID: p.id) }
            }
        }
        guard let sel = selectedThreadID else { return }
        guard status != nil else { chatUnavailable[sel] = "Host offline"; return }
        loadMessages(sel)
        _ = await ensureSession(sel)
    }

    /// Legacy entry point: sends in the selected thread.
    public func sendChat(_ text: String) async {
        guard let sel = selectedThreadID else { return }
        await send(text, in: sel)
    }

    public func send(_ text: String, in tid: String) async {
        guard thread(tid) != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let avail = sendAvailability(for: tid)
        guard avail.enabled else { lastError = avail.reason; return }
        if generatingThreadID == tid { return }                     // one turn per session; the composer is disabled
        if generatingThreadID != nil {
            guard !queue.contains(where: { $0.threadID == tid }) else { notice = "One message is already waiting in this chat."; return }
            queue.append(QueuedSend(threadID: tid, text: text))
            return
        }
        generatingThreadID = tid                                    // claim the app-wide slot before any await
        await beginTurn(tid, text)
    }

    /// Runs one turn; `generatingThreadID == tid` already.
    private func beginTurn(_ tid: String, _ text: String) async {
        loadMessages(tid)
        guard let s = await ensureSession(tid) else { releaseSlot(tid); return }
        let b = buffer(tid)
        flushPending(tid)
        b.rawBase = nil; b.ledger = TokenLedger(); b.start = clock.now()
        messages[tid, default: []].append(ChatMessage(role: .user, text: text))
        let firstMessage = thread(tid)?.titleIsUser == false && thread(tid)?.messageCount == 0
        updateThread(tid) {
            if firstMessage { let t = Self.title(from: text); if !t.isEmpty { $0.title = t }; $0.thinking = thinkingEnabled }
            $0.lastActivity = nowTS; $0.messageCount = messages[tid]?.count ?? 0
        }
        if let p = thread(tid)?.projectId, let i = projects.firstIndex(where: { $0.id == p }) { projects[i].lastActivity = nowTS }
        touchLive(tid)
        await run("Chat") {
            do { try await client.chatAppend(ChatAppendRequest(sessionID: s.sessionID, text: text, enableThinking: thinkingEnabled)) }
            catch {
                if case ControlClientError.http(404, _) = error { liveSessions[tid] = nil; liveOrder.removeAll { $0 == tid } }
                if let e = error as? APIError, e.code == "not_found" { liveSessions[tid] = nil; liveOrder.removeAll { $0 == tid } }
                releaseSlot(tid)
                throw error
            }
        }
    }

    private func releaseSlot(_ tid: String) {
        if generatingThreadID == tid { generatingThreadID = nil }
        drainQueue()
    }

    private func drainQueue() {
        guard generatingThreadID == nil, !queue.isEmpty else { return }
        let q = queue.removeFirst()
        guard thread(q.threadID) != nil else { drainQueue(); return }
        generatingThreadID = q.threadID
        Task { @MainActor [weak self] in await self?.beginTurn(q.threadID, q.text) }
    }

    public func cancelChat() async {
        guard let sel = selectedThreadID else { return }
        await cancel(sel)
    }

    /// Cancels a queued message, or the thread's running turn.
    public func cancel(_ tid: String) async {
        if queue.contains(where: { $0.threadID == tid }) { queue.removeAll { $0.threadID == tid }; return }
        guard generatingThreadID == tid, let s = liveSessions[tid] else { return }
        await run("Cancel chat") { try await client.chatCancel(ChatCancelRequest(sessionID: s.sessionID)) }
        flushPending(tid)
        finishTurn(tid)
    }

    public func copyMessage(_ id: UUID) {
        guard let m = chatMessages.first(where: { $0.id == id }) else { return }
        let text = m.tool.map { "\($0.name) \($0.args)" + ($0.result.map { "\n\($0)" } ?? "") } ?? m.text
        clipboard.copy(text)
        notice = "Message copied."
    }

    /// Ends the turn: stamps the ledger onto the turn's last non-user message, saves, starts the next queued turn.
    func finishTurn(_ tid: String) {
        guard generatingThreadID == tid else { return }
        generatingThreadID = nil
        let b = buffer(tid)
        if let start = b.start { b.ledger.seconds = max(0, clock.now().timeIntervalSince(start)) }
        b.start = nil
        if let i = messages[tid]?.indices.last, messages[tid]?[i].role != .user { messages[tid]?[i].ledger = b.ledger }
        b.ledger = TokenLedger()
        persistNew(tid)
        updateThread(tid) { $0.lastActivity = nowTS; $0.messageCount = messages[tid]?.count ?? 0; if selectedThreadID != tid { $0.unread = true } }
        drainQueue()
    }

    // MARK: deltas

    /// Text deltas arrive many times per second; they are coalesced (~30 Hz) so SwiftUI redraws stay cheap.
    func applyDelta(_ d: ChatDelta) {
        guard let tid = threadID(forSession: d.sessionID) else { return }
        let b = buffer(tid)
        switch d.kind {
        case .text: appendStreamed(tid, .assistant, d.text)
        case .reasoning: appendStreamed(tid, .reasoning, d.text)
        case .toolCall:
            flushPending(tid)
            b.rawBase = nil
            messages[tid, default: []].append(ChatMessage(role: .tool, text: d.text, tool: ToolCard.call(d.text)))
        case .toolResult:
            flushPending(tid)
            b.rawBase = nil
            let r = ToolCard.parseResult(d.text)
            if let i = messages[tid]?.lastIndex(where: { $0.role == .tool && $0.tool?.finished == false && ($0.tool?.name == r.name || r.name.isEmpty) }) {
                messages[tid]?[i].tool?.result = r.summary; messages[tid]?[i].tool?.isError = r.isError
                messages[tid]?[i].text = d.text
            } else {
                messages[tid, default: []].append(ChatMessage(role: .tool, text: d.text, tool: ToolCard(name: r.name, result: r.summary, isError: r.isError)))
            }
        case .done:
            flushPending(tid, final: true)
            b.rawBase = nil
            finishTurn(tid)
        }
    }

    private func appendStreamed(_ tid: String, _ role: ChatMessage.Role, _ text: String) {
        let b = buffer(tid)
        if b.pendingRole != role { flushPending(tid) }
        b.pendingRole = role; b.pendingText += text
        guard b.flushTask == nil else { return }
        b.flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            self?.flushPending(tid)
        }
    }

    func flushPending(_ tid: String, final: Bool = false) {
        let b = buffer(tid)
        b.flushTask?.cancel(); b.flushTask = nil
        guard let role = b.pendingRole, !b.pendingText.isEmpty else {
            b.pendingRole = nil; b.pendingText = ""
            if final { resplitAssistant(tid, final: true) }
            return
        }
        let text = b.pendingText
        b.pendingRole = nil; b.pendingText = ""
        let count = messages[tid]?.count ?? 0
        if role == .assistant {
            b.rawText = (b.rawBase == nil ? "" : b.rawText) + text
            if b.rawBase == nil { b.rawBase = count }
            resplitAssistant(tid, final: final)
            return
        }
        b.rawBase = nil
        if let last = messages[tid]?.last, last.role == role {
            messages[tid]?[count - 1].text += text
        } else {
            messages[tid, default: []].append(ChatMessage(role: role, text: text))
        }
    }

    /// Rebuilds the messages of the current assistant run from its raw text: `<think>` blocks become reasoning messages.
    private func resplitAssistant(_ tid: String, final: Bool) {
        let b = buffer(tid)
        guard let base = b.rawBase, base <= (messages[tid]?.count ?? 0) else { return }
        let segs = ThinkSplitter.split(b.rawText, final: final)
        let old = Array(messages[tid]![base...])
        var rebuilt: [ChatMessage] = []
        for (k, seg) in segs.enumerated() {
            var m = ChatMessage(role: seg.isReasoning ? .reasoning : .assistant, text: seg.text)
            if k < old.count, old[k].role == m.role { m.id = old[k].id }
            rebuilt.append(m)
        }
        messages[tid]?.replaceSubrange(base..., with: rebuilt)
    }
}
