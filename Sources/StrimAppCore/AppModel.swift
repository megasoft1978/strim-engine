import Foundation
import StrimAPI

public enum ConnectionState: Equatable, Sendable {
    case disconnected(reason: String)
    case connecting
    case connected(HostStatus)

    public var status: HostStatus? { if case .connected(let s) = self { s } else { nil } }
    public var isConnected: Bool { status != nil }
}

public struct Availability: Equatable, Sendable {
    public var enabled: Bool
    public var reason: String?
    public static let yes = Availability(enabled: true, reason: nil)
    public static func no(_ r: String) -> Availability { Availability(enabled: false, reason: r) }
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant, reasoning, tool }
    public var id = UUID()
    public var role: Role
    public var text: String
}

public enum ChatState: Equatable, Sendable {
    case unknown
    case unavailable(String)
    case ready(ChatSession)
    public static let notAvailableYet = "Chat not available yet. The host does not serve chat routes (501)."
}

public struct SourceCount: Equatable, Sendable, Identifiable {
    public var source: JobSource
    public var active: Int
    public var queued: Int
    public var id: String { source.rawValue }
}

/// State machine over any `StrimControlClient`: connecting -> connected(status) -> disconnected(reason) with
/// exponential reconnect. Always exposes a visible state (`menuTitle`, `menuSymbol`).
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var connection: ConnectionState = .connecting
    @Published public private(set) var jobs: [JobSummary] = []
    @Published public private(set) var selectedJob: JobDetail?
    /// Analysis of `selectedJob.patch` (cached; recomputed on selection).
    @Published public private(set) var selectedAnalysis: PatchAnalysis?
    /// Digest of the patch bytes the user was shown and reviewed (set on selection or explicit re-review).
    @Published public private(set) var reviewedDigest: String?
    /// Digest the user ticked the confirmation for. Only counts while it equals the current patch digest.
    @Published public private(set) var confirmedDigest: String?
    /// Where "Copy patch path" writes patches.
    public var patchDirectory = AppPaths.home + "/.strim/patches"
    @Published public private(set) var eventLog: [String] = []
    @Published public private(set) var lastEventTime: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var notice: String?
    @Published public private(set) var chat: ChatState = .unknown
    @Published public private(set) var chatMessages: [ChatMessage] = []
    @Published public private(set) var actionInFlight: String?
    @Published public private(set) var launchAtLogin: Bool
    @Published public private(set) var settings: AppSettings
    @Published public private(set) var reconnectAttempts = 0
    /// Banner about the control-token file (missing, insecure permissions, ...). Never contains the token.
    @Published public private(set) var tokenWarning: String?

    public let testMode: Bool
    public let logLimit = 200

    private var client: StrimControlClient
    private let makeClient: @Sendable (AppSettings) -> StrimControlClient
    private let clock: AppClock
    private let launcher: HostLauncher
    private let mcp: McpCommandProvider
    private let loginItem: LoginItemControlling
    private let clipboard: ClipboardWriting
    private let persist: @Sendable (AppSettings) throws -> Void
    private let pollInterval: Double?
    private let tokenStatus: @Sendable (AppSettings) -> TokenFileStatus
    private var loop: Task<Void, Never>?

    public init(settings: AppSettings = .load(),
                makeClient: @escaping @Sendable (AppSettings) -> StrimControlClient,
                clock: AppClock = SystemClock(),
                launcher: HostLauncher = ProcessHostLauncher(),
                mcp: McpCommandProvider = CLIMcpCommandProvider(),
                loginItem: LoginItemControlling = SMLoginItem(),
                clipboard: ClipboardWriting = PasteboardClipboard(),
                persist: @escaping @Sendable (AppSettings) throws -> Void = { try $0.save() },
                pollInterval: Double? = 5,
                testMode: Bool = ProcessInfo.processInfo.environment["STRIM_APP_TEST"] == "1",
                tokenStatus: @escaping @Sendable (AppSettings) -> TokenFileStatus = { TokenReader(path: $0.controlTokenPath).inspect() }) {
        self.settings = settings; self.makeClient = makeClient; self.client = makeClient(settings)
        self.clock = clock; self.launcher = launcher; self.mcp = mcp; self.loginItem = loginItem
        self.clipboard = clipboard; self.persist = persist; self.pollInterval = pollInterval
        self.testMode = testMode; self.launchAtLogin = loginItem.isEnabled; self.tokenStatus = tokenStatus
        self.tokenWarning = tokenStatus(settings).banner(path: settings.controlTokenPath)
    }

    /// Fixed-client convenience (tests, previews).
    public convenience init(client: StrimControlClient, settings: AppSettings = AppSettings(),
                            clock: AppClock = SystemClock(), launcher: HostLauncher = ProcessHostLauncher(),
                            mcp: McpCommandProvider = CLIMcpCommandProvider(), loginItem: LoginItemControlling = SMLoginItem(),
                            clipboard: ClipboardWriting = PasteboardClipboard(),
                            persist: @escaping @Sendable (AppSettings) throws -> Void = { _ in },
                            pollInterval: Double? = 5, testMode: Bool = false,
                            tokenStatus: @escaping @Sendable (AppSettings) -> TokenFileStatus = { _ in .ok }) {
        self.init(settings: settings, makeClient: { _ in client }, clock: clock, launcher: launcher, mcp: mcp,
                  loginItem: loginItem, clipboard: clipboard, persist: persist, pollInterval: pollInterval, testMode: testMode,
                  tokenStatus: tokenStatus)
    }

    // MARK: derived UI state

    public var menuTitle: String { StatsFormat.menuTitle(connection) }
    public var menuSymbol: String { StatsFormat.menuSymbol(connection) }
    public var status: HostStatus? { connection.status }

    public var offlineBanner: String? {
        if case .disconnected(let r) = connection { return r }
        return nil
    }

    public var showTestBanner: Bool {
        if testMode { return true }
        if let s = status, s.state != .ready { return true }
        return false
    }
    public var rawState: String {
        switch connection {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected(let s): s.state.rawValue
        }
    }
    public var eventLogTail: [String] { Array(eventLog.suffix(12)) }

    public var sourceCounts: [SourceCount] {
        JobSource.allCases.map { src in
            let mine = jobs.filter { $0.source == src }
            let active = mine.filter { [.running, .awaitingApproval, .pausedInteractive].contains($0.status) }.count
            return SourceCount(source: src, active: active, queued: mine.filter { $0.status == .queued }.count)
        }
    }

    public var loadAvailability: Availability {
        guard let s = status else { return .no("Host offline") }
        if actionInFlight != nil { return .no("Another action is in progress") }
        if s.state == .loading { return .no("Model is loading") }
        if (s.state == .ready || s.state == .busy), s.model != nil { return .no("Model already loaded") }
        guard let m = settings.modelPath, !m.isEmpty else { return .no("Set model_path in Settings (~/.strim/app.json)") }
        return .yes
    }
    public var unloadAvailability: Availability {
        guard let s = status else { return .no("Host offline") }
        if actionInFlight != nil { return .no("Another action is in progress") }
        if s.state == .loading { return .no("Model is loading") }
        if s.model == nil || s.state == .stopped { return .no("No model loaded") }
        if s.activeJobs > 0 || s.state == .busy { return .no("Jobs are running") }
        return .yes
    }
    public var pauseAvailability: Availability { .no("Pause is not available on this host yet") }

    public func approveAvailability(for job: JobDetail?) -> Availability {
        guard status != nil else { return .no("Host offline") }
        guard let job else { return .no("Select a job") }
        if actionInFlight != nil { return .no("Another action is in progress") }
        guard job.patch?.isEmpty == false else { return .no("Job has no patch") }
        guard job.summary.status == .awaitingApproval else { return .no("Job is \(job.summary.status.rawValue), not awaiting approval") }
        return .yes
    }

    /// Apply gate: everything `approveAvailability` checks, plus the patch analysis.
    /// Unparseable patches can only be rejected; special or suspicious ones need the confirmation tick.
    public func applyAvailability(for job: JobDetail?) -> Availability {
        let base = approveAvailability(for: job)
        guard base.enabled, let job, let patch = job.patch else { return base }
        if job == selectedJob, patchChangedSinceReview {
            return .no("The patch changed since you reviewed it. Review the updated patch, then acknowledge.")
        }
        let a = (job == selectedJob ? selectedAnalysis : nil) ?? DiffParser.analyze(patch)
        if a.blocked {
            return .no("Patch could not be fully understood (\(a.issues.first { $0.blocking }?.reason ?? "unknown")). Reject only.")
        }
        if a.needsConfirmation, !(patchConfirmed && job == selectedJob) {
            return .no("Tick the confirmation: \(a.confirmationText ?? "special patch")")
        }
        return .yes
    }

    public func setPatchConfirmed(_ on: Bool) { confirmedDigest = on ? selectedPatchDigest : nil }

    /// Writes the patch to a file and copies its path, so the user can inspect it with real tools.
    public func copyPatchPath() {
        guard let job = selectedJob, let patch = job.patch else { return }
        let safe = String(job.id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
        let path = patchDirectory + "/" + safe + ".patch"
        do {
            try SecureFS.writeAtomically(Data(patch.utf8), to: path)     // 0600 file in a 0700 directory
            clipboard.copy(path)
            notice = "Patch path copied: \(path)"
        } catch { lastError = "Copy patch path: \(error.localizedDescription)" }
    }

    /// Digest of the patch currently held in `selectedJob`.
    public var selectedPatchDigest: String? { selectedJob?.patch.map(PatchDigest.sha256) }
    public var patchConfirmed: Bool { confirmedDigest != nil && confirmedDigest == selectedPatchDigest }
    /// The job's patch differs from what the user reviewed.
    public var patchChangedSinceReview: Bool { selectedPatchDigest != nil && selectedPatchDigest != reviewedDigest }

    /// The user looked at the updated patch now on screen: it becomes the reviewed one. Ticks do not carry over.
    public func acknowledgeUpdatedPatch() { reviewedDigest = selectedPatchDigest }

    public var hostCanBeStarted: Bool { !connection.isConnected }

    // MARK: lifecycle

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.runLoop() }
    }
    public func stop() { loop?.cancel(); loop = nil }

    /// Cancel any pending backoff and reconnect immediately.
    public func reconnectNow() {
        stop(); reconnectAttempts = 0; start()
    }

    private func runLoop() async {
        var backoff = Backoff()
        while !Task.isCancelled {
            connection = .connecting
            refreshTokenWarning()
            do {
                let s = try await client.status()
                backoff.reset(); reconnectAttempts = 0
                lastError = nil
                connection = .connected(s)
                log("connected: state=\(s.state.rawValue)")
                await refreshJobs()
                try await runSession()
                if Task.isCancelled { return }
                disconnect(OfflineBanner.streamEnded + " Reconnecting.")
            } catch {
                if Task.isCancelled { return }
                disconnect(OfflineBanner.text(for: error, hostURL: settings.hostURL), error: error)
            }
            let delay = backoff.next()
            reconnectAttempts += 1
            log(String(format: "reconnect in %.0fs (attempt %d)", delay, reconnectAttempts))
            do { try await clock.sleep(seconds: delay) } catch { return }
        }
    }

    private func refreshTokenWarning() {
        tokenWarning = tokenStatus(settings).banner(path: settings.controlTokenPath)
    }

    /// Runs until the event stream ends or the poll fails; throws on transport error.
    private func runSession() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in try await consumeEvents() }
            if let p = pollInterval {
                group.addTask { [self] in try await pollStatus(every: p) }
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func consumeEvents() async throws {
        for try await ev in client.events() {
            handle(ev)
        }
    }

    private func pollStatus(every seconds: Double) async throws {
        while true {
            try await clock.sleep(seconds: seconds)
            let s = try await client.status()
            if case .connected = connection { connection = .connected(s) }
        }
    }

    private func disconnect(_ reason: String, error: Error? = nil) {
        connection = .disconnected(reason: reason)
        if let error { lastError = error.localizedDescription }
        log("disconnected: \(reason)")
    }

    func handle(_ ev: StrimEvent) {
        lastEventTime = clock.now()
        switch ev {
        case .status(let s):
            if !connection.isConnected { log("connected via event") }
            connection = .connected(s)
            log("status: \(s.state.rawValue)")
        case .jobEvent(let j):
            log("job \(j.jobID.prefix(8)): \(j.status.rawValue)" + (j.verify.map { " [\($0.rawValue)]" } ?? ""))
            Task { await refreshJobs(); if selectedJob?.id == j.jobID { await refreshSelectedJob() } }
        case .harnessEvent(let h):
            log("harness \(h.jobID.prefix(8)): \(h.kind)" + (h.text.map { " \($0.prefix(80))" } ?? ""))
        case .chatDelta(let d):
            applyDelta(d)
        case .error(let e):
            lastError = "\(e.code): \(e.message)"
            log("host error: \(e.code): \(e.message)")
        }
    }

    func log(_ line: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        eventLog.append("\(f.string(from: clock.now())) \(line)")
        if eventLog.count > logLimit { eventLog.removeFirst(eventLog.count - logLimit) }
    }

    // MARK: actions

    private func run(_ name: String, _ body: () async throws -> Void) async {
        actionInFlight = name
        defer { actionInFlight = nil }
        do { try await body() } catch {
            lastError = "\(name): \(error.localizedDescription)"
            log("\(name) failed: \(error.localizedDescription)")
        }
    }

    private func refreshStatus() async {
        if let s = try? await client.status(), connection.isConnected { connection = .connected(s) }
    }

    public func loadModel() async {
        guard loadAvailability.enabled, let m = settings.modelPath else { return }
        let mtp = settings.mtpPath.flatMap { $0.isEmpty ? nil : $0 }
        await run("Load") { try await client.load(LoadRequest(model: m, mtp: mtp)); log("load requested: \(m)") }
        await refreshStatus()
    }
    public func unloadModel() async {
        guard unloadAvailability.enabled else { return }
        await run("Unload") { try await client.unload(); log("unload requested") }
        await refreshStatus()
    }

    public func refreshJobs() async {
        do { jobs = try await client.jobs().sorted { $0.started > $1.started } }
        catch { if !isNotImplemented(error) { lastError = "Jobs: \(error.localizedDescription)" } }
    }
    public func selectJob(_ id: String?) async {
        guard let id else { selectedJob = nil; selectedAnalysis = nil; reviewedDigest = nil; confirmedDigest = nil; return }
        do {
            install(try await client.job(id: id))
            reviewedDigest = selectedPatchDigest     // explicit selection = the user is looking at this patch now
        }
        catch { lastError = "Job \(id.prefix(8)): \(error.localizedDescription)" }
    }

    private func install(_ d: JobDetail) {
        selectedJob = d
        selectedAnalysis = d.patch.map { DiffParser.analyze($0) }
    }

    /// Background refresh (job events). Shows the new patch but does NOT count as a review.
    public func refreshSelectedJob() async {
        guard let id = selectedJob?.id else { return }
        do { install(try await client.job(id: id)) }
        catch { lastError = "Job \(id.prefix(8)): \(error.localizedDescription)" }
    }

    public func approve(_ action: ApprovalAction) async {
        guard let job = selectedJob else { return }
        guard (action == .apply ? applyAvailability(for: job) : approveAvailability(for: job)).enabled else { return }
        var digest: String?
        if action == .apply {
            // Bind the approval to the reviewed bytes: re-fetch right before sending and compare.
            guard let reviewed = reviewedDigest else { return }
            do {
                let fresh = try await client.job(id: job.id)
                if fresh.patch.map(PatchDigest.sha256) != reviewed {
                    install(fresh)
                    lastError = "Apply cancelled: the patch changed since you reviewed it. Review the updated patch."
                    log("apply blocked: patch digest changed")
                    return
                }
            } catch {
                lastError = "Apply: could not re-check the patch (\(error.localizedDescription))"
                return
            }
            digest = reviewed
        }
        await run(action == .apply ? "Apply" : "Reject") {
            try await client.approve(PatchApproval(jobID: job.id, action: action, patchSHA256: digest))
            log("\(action.rawValue) sent for job \(job.id.prefix(8))")
        }
        await refreshJobs()
        await refreshSelectedJob()
    }

    public func startHost() {
        switch launcher.start(settings: settings) {
        case .started(let pid):
            notice = "Started strim serve (pid \(pid)). Log: ~/.strim/host.log"
            log("started host pid \(pid)")
            reconnectNow()
        case .binaryMissing(let cmd):
            clipboard.copy(cmd)
            notice = "strim binary not found. Command copied; paste it in Terminal: \(cmd)"
            log("strim binary missing; command copied")
        case .binaryInvalid(let why, let cmd):
            clipboard.copy(cmd)
            notice = "strim_binary was not run (\(why)). Command copied; paste it in Terminal: \(cmd)"
            log("strim_binary rejected: \(why)")
        case .needsModel:
            notice = "Set model_path in ~/.strim/app.json (Settings tab) before starting the host."
        case .failed(let e):
            lastError = "Start host: \(e)"
        }
    }

    public func copyMCPCommands() async {
        let text = await mcp.commands(settings: settings)
        clipboard.copy(text)
        notice = "MCP registration commands copied (they read ~/.strim/token; the token itself is not shown)."
    }

    public func setLaunchAtLogin(_ on: Bool) {
        do { try loginItem.setEnabled(on) } catch { lastError = "Launch at login: \(error.localizedDescription)" }
        launchAtLogin = loginItem.isEnabled
    }

    public func update(settings new: AppSettings) {
        let connChanged = new.hostURL != settings.hostURL || new.controlTokenPath != settings.controlTokenPath
        settings = new
        do { try persist(new) } catch { lastError = "Saving settings: \(error.localizedDescription)" }
        refreshTokenWarning()
        if connChanged {
            client = makeClient(new); reconnectNow()
        }
    }

    public func dismissNotice() { notice = nil }

    // MARK: chat

    public func probeChat() async {
        guard status != nil else { chat = .unavailable("Host offline"); return }
        switch ProjectFolder.resolve(settings.projectPath) {
        case .failure(let e):
            chat = .unavailable(e.message)
        case .success(let cwd):
            do { chat = .ready(try await client.chatOpen(ChatOpenRequest(cwd: cwd))) }
            catch {
                chat = .unavailable(isNotImplemented(error) ? ChatState.notAvailableYet : "Chat error: \(error.localizedDescription)")
            }
        }
    }
    public func sendChat(_ text: String) async {
        guard case .ready(let s) = chat, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        chatMessages.append(ChatMessage(role: .user, text: text))
        await run("Chat") { try await client.chatAppend(ChatAppendRequest(sessionID: s.sessionID, text: text)) }
    }
    public func cancelChat() async {
        guard case .ready(let s) = chat else { return }
        await run("Cancel chat") { try await client.chatCancel(ChatCancelRequest(sessionID: s.sessionID)) }
    }
    private func applyDelta(_ d: ChatDelta) {
        let role: ChatMessage.Role
        switch d.kind {
        case .text: role = .assistant
        case .reasoning: role = .reasoning
        case .toolCall, .toolResult: role = .tool
        case .done: return
        }
        if role != .tool, let last = chatMessages.last, last.role == role {
            chatMessages[chatMessages.count - 1].text += d.text
        } else {
            chatMessages.append(ChatMessage(role: role, text: d.text))
        }
    }
}

/// The folder a chat session works in. Never the home folder, `/` or anything that contains home.
public enum ProjectFolder {
    public struct Problem: Error, Equatable, Sendable { public var message: String }

    public static func resolve(_ raw: String?, home: String = NSHomeDirectory()) -> Result<String, Problem> {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(Problem(message: "Choose a project folder in Settings (project_path) to start a chat."))
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .failure(Problem(message: "The project folder must be an absolute path.")) }
        let dir = URL(fileURLWithPath: ((expanded as NSString).standardizingPath)).resolvingSymlinksInPath().path
        let homeR = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return .failure(Problem(message: "The project folder does not exist or is not a folder."))
        }
        if dir == homeR || dir == "/" || homeR.hasPrefix(dir + "/") {
            return .failure(Problem(message: "The project folder cannot be your home folder or a parent of it. Pick a specific project."))
        }
        return .success(dir)
    }
}
