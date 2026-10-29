import Foundation
import StrimEngine
import StrimHarness
import StrimJobs
import StrimMCP
import StrimServer
import StrimTemplate

/// Wraps a tool provider and rejects `strim_task`/`strim_ask` calls that exceed the host policy before
/// anything is queued.
struct PolicyToolProvider: MCPToolProvider {
    let inner: any MCPToolProvider
    let policy: HostPolicy

    func definitions() -> [MCPToolDefinition] { inner.definitions() }

    func call(name: String, arguments: OrderedJSON, progress: @Sendable (Double, String) -> Void) async -> MCPToolResult {
        if name == "strim_task" || name == "strim_ask" {
            let access = name == "strim_task" ? (arguments["access"]?.stringValue ?? "read") : "read"
            if let msg = policy.violation(access: access, cwd: arguments["cwd"]?.stringValue) {
                return MCPToolResult(text: msg, structured: nil, isError: true)   // text only: see ResultRender
            }
        }
        return await inner.call(name: name, arguments: arguments, progress: progress)
    }
}

/// Counts executors that are still running (including their cleanup) so shutdown can wait for them.
final class InflightTracker: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func enter() { l.withLock { n += 1 } }
    func leave() { l.withLock { n -= 1 } }
    var count: Int { l.withLock { n } }
}

/// Composition root: engine client + OpenAI server + `/mcp` route + job manager in one process.
/// `strim serve` and the menu-bar app both build one of these.
public actor StrimHost {
    public static let version = "0.1"
    public static let instructions = "Delegate routine, self-verifiable local tasks (file exploration, test-fix loops, repo questions, boilerplate) with strim_task. Results are patches: review before applying."

    public nonisolated let engine: any EngineClient
    public nonisolated let server: StrimOpenAIServer
    public nonisolated let jobs: JobManager
    public nonisolated let jobStore: FileJobStore
    public nonisolated let hostConfig: HostConfig
    /// Runtime folder grants (shared with `hostPolicy`); changed only through the control plane.
    public nonisolated let folderGrants: FolderGrants
    public nonisolated let hostPolicy: HostPolicy
    public nonisolated let paths: HostPaths
    private let prefetchIDs: [Int32]?
    private let sweepWorktrees: Bool
    private let isolationBaseDir: URL?
    private let orphanGraceSeconds: TimeInterval
    private let chatSweepInterval: Duration
    private var chatSweeper: Task<Void, Never>?
    /// Runs chat sessions (nil when the host was built with an injected executor and no chat backend).
    public nonisolated let chatRunner: HarnessRunner?
    private nonisolated let inflight = InflightTracker()
    /// Seconds `shutdown` waits for cancelled executors to finish their cleanup.
    public nonisolated let shutdownGrace: TimeInterval
    private var lock: HostLock?
    private var started = false

    /// - lock: an already acquired host lock (acquire it before loading the model); otherwise `start` acquires it.
    /// - executor: replaces `HarnessRunner.run` (tests).
    /// - providerFactory: builds the tool provider; the policy wrapper is applied on top.
    /// - prefetchIDs: token ids of the fixed system prompt to warm at start (best effort).
    public init(engine: any EngineClient, serverConfig: ServerConfig, hostConfig: HostConfig = HostConfig(),
                paths: HostPaths = .default, lock: HostLock? = nil, sandboxed: Bool = true,
                executor: JobExecutor? = nil,
                providerFactory: (@Sendable (JobManager) -> any MCPToolProvider)? = nil,
                prefetchIDs: [Int32]? = nil, progressInterval: Duration = .seconds(5),
                shutdownGrace: TimeInterval = 10,
                chatBackend: (any ChatBackend)? = nil, maxChatSessions: Int = ChatLimits.defaultMaxSessions,
                chatIdleTimeout: TimeInterval = ChatLimits.defaultIdleTimeout, chatSweepInterval: Duration = .seconds(30),
                isolationBaseDir: URL? = nil, orphanGraceSeconds: TimeInterval = 30) {
        self.shutdownGrace = shutdownGrace
        self.isolationBaseDir = isolationBaseDir
        self.orphanGraceSeconds = orphanGraceSeconds
        self.chatSweepInterval = chatSweepInterval
        // injected executors (tests) never touch the real worktree dir unless they name their own
        self.sweepWorktrees = executor == nil || isolationBaseDir != nil
        self.engine = engine
        self.hostConfig = hostConfig
        self.paths = paths
        self.lock = lock
        self.prefetchIDs = prefetchIDs
        let grants = FolderGrants(roots: hostConfig.allowedRoots, configURL: paths.config)
        let policy = HostPolicy(hostConfig, grants: grants)
        self.folderGrants = grants
        self.hostPolicy = policy
        let exec: JobExecutor
        let inflight = self.inflight
        var chat: (any ChatBackend)? = chatBackend
        if let executor {
            exec = { spec, id, onEvent in
                if let v = policy.violation(access: spec.access.rawValue, cwd: spec.cwd) {
                    onEvent(.finished(.failed)); return HarnessJobResult(status: .failed, summary: v)
                }
                inflight.enter(); defer { inflight.leave() }
                return await executor(spec, id, onEvent)
            }
        } else {
            let runner = isolationBaseDir.map {
                HarnessRunner(engine: engine, isolation: GitWorktreeIsolation(baseDir: $0), sandboxed: sandboxed, jobsDir: paths.jobs, hostID: HostIdentity.id(for: paths.root))
            } ?? HarnessRunner(engine: engine, sandboxed: sandboxed, jobsDir: paths.jobs, hostID: HostIdentity.id(for: paths.root))
            chat = chat ?? runner
            exec = { spec, id, onEvent in
                if let v = policy.violation(access: spec.access.rawValue, cwd: spec.cwd) {
                    onEvent(.finished(.failed)); return HarnessJobResult(status: .failed, summary: v)
                }
                inflight.enter(); defer { inflight.leave() }
                return await runner.run(spec: spec, jobID: id, onEvent: onEvent)
            }
        }
        let store = FileJobStore(root: paths.jobs)
        self.chatRunner = chat as? HarnessRunner
        let jobs = JobManager(executor: exec, store: store, requireApproval: hostConfig.requireApproval,
                              chat: chat.map { PolicyCheckedChatBackend(inner: $0, policy: policy) }, maxChatSessions: maxChatSessions, chatIdleTimeout: chatIdleTimeout,
                              admission: serverConfig.admission)
        self.jobStore = store
        self.jobs = jobs
        let server = StrimOpenAIServer(engine: engine, config: serverConfig)
        self.server = server
        let inner: any MCPToolProvider = providerFactory?(jobs) ?? StrimMCPToolProvider(jobs: jobs)
        let route = MCPRoute(provider: PolicyToolProvider(inner: inner, policy: policy), serverName: "strim",
                             version: Self.version, instructions: Self.instructions, progressInterval: progressInterval)
        for m in ["POST", "GET", "DELETE"] {
            server.addGuardedRoute(m, "/mcp") { req, r in try await route.handle(request: req, responder: r) }
        }
    }

    /// Acquires the host lock, registers the token for redaction, recovers persisted jobs, starts the server
    /// and warms the prefix cache. Returns the bound port.
    public func start(port: UInt16) async throws -> UInt16 {
        if lock == nil { lock = try HostLock.acquire(at: paths.lock) }
        do {
            Redactor.registerStrimToken(from: paths.token)
            // The control token sits next to the API token and unlocks approve/load/unload: never let it out in job output.
            Redactor.registerStrimToken(from: paths.token.deletingLastPathComponent().appendingPathComponent("control-token"))
            await jobs.recover()
            // Lock held: no live job of ours exists, so marked processes are leftovers of a killed host.
            OrphanSweep.killMarkedProcesses(hostID: HostIdentity.id(for: paths.root),
                                           includeLegacy: HostIdentity.id(for: paths.root) == HostIdentity.id(for: HostIdentity.defaultRoot))
            if sweepWorktrees {
                // Chat sessions open when a previous host died left worktrees behind; their jobs were just
                // failed(host_restart) by `recover`.
                let iso = isolationBaseDir.map { GitWorktreeIsolation(baseDir: $0) } ?? GitWorktreeIsolation()
                await iso.sweepOrphans(graceSeconds: orphanGraceSeconds)
            }
            let bound = try await server.start(port: port)
            started = true
            let jobs = self.jobs, every = chatSweepInterval
            chatSweeper = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: every)
                    if Task.isCancelled { return }
                    await jobs.sweepIdleSessions()
                }
            }
            if let ids = prefetchIDs, !ids.isEmpty { try? await engine.prefetch(ids, priority: .background) }
            return bound
        } catch {
            lock?.release(); lock = nil
            throw error
        }
    }

    /// Cancels live jobs, closes the server and releases the lock. The engine is shut down by its owner.
    public func shutdown() async {
        chatSweeper?.cancel(); chatSweeper = nil
        let records = (try? await jobStore.list()) ?? []
        for r in records where !r.status.isTerminal { _ = try? await jobs.cancel(r.id) }
        // Cancelled executors still run their cleanup (worktree removal); wait for them, bounded.
        let deadline = Date().addingTimeInterval(shutdownGrace)
        while inflight.count > 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        await chatRunner?.closeAllSessions()
        await jobs.flush()
        server.stop()
        started = false
        lock?.release(); lock = nil
    }

    public var isStarted: Bool { started }
}
