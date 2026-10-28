import CryptoKit
import Foundation
import StrimAPI
import StrimHarness
import StrimHost
import StrimHTTP
import StrimJobs
import StrimServer

/// Extra route constants (additive to the frozen `StrimRoutes`).
public enum ControlRoutes {
    /// `POST` with `ChatCancelRequest`: closes the session (same as `DELETE /v1/strim/chat/{session_id}`).
    public static let chatClose = "/v1/strim/chat/close"
    public static let chatPrefix = "/v1/strim/chat/"
    public static func chatSession(_ id: String) -> String { chatPrefix + id }
}

/// The control API (`docs/CONTROL-API.md`) on the host's HTTP server. Every route sits behind the server's bearer
/// token and re-checks loopback Host/Origin. The API/MCP token only unlocks `GET status`.
public final class StrimControlPlane: Sendable {
    public struct Options: Sendable {
        public var statusInterval: Duration = .seconds(1)
        public var jobPollInterval: Duration = .milliseconds(500)
        public var pingInterval: Duration = .seconds(15)
        /// A chat turn started by `chat/append` (202 mode) is cancelled when no `/events` subscriber has been
        /// connected for this long.
        public var orphanTurnGrace: Duration = .seconds(30)
        public var maxBodyBytes = 1_048_576
        /// Concurrent `/events` connections (429 beyond).
        public var maxEventSubscribers = 8
        /// `load` may only name models under these directories (canonical, symlinks resolved). Empty: loading over
        /// the API is refused. `strim serve` adds `~/models`, the directories of its own model/head and `--model-dir`.
        public var modelRoots: [String] = []
        /// How long a live chat diff is reused by detail reads (approve always reads fresh).
        public var patchCacheTTL: TimeInterval = 2
        public init() {}
    }

    let slot: EngineSlot
    let jobs: JobManager
    let store: any JobStore
    let jobsRoot: URL
    let policy: HostPolicy
    let currentPatch: (@Sendable (String) async throws -> String)?
    let auth: ControlAuth
    let startedAt: Date
    let options: Options
    let hub: EventHub
    let pollerLock = Locked<Task<Void, Never>?>(nil)
    private let patchCache = Locked<[String: (at: Date, data: Data?)]>([:])
    let applier = PatchApplier()
    private let applying = Locked<Set<String>>([])
    /// Test seam: runs between hashing the patch and applying it.
    let afterPatchHash = Locked<(@Sendable () -> Void)?>(nil)

    public init(slot: EngineSlot, jobs: JobManager, store: any JobStore, jobsRoot: URL, policy: HostPolicy,
                currentPatch: (@Sendable (String) async throws -> String)? = nil, auth: ControlAuth,
                startedAt: Date = Date(), options: Options = Options()) {
        self.slot = slot; self.jobs = jobs; self.store = store; self.jobsRoot = jobsRoot; self.policy = policy
        self.currentPatch = currentPatch; self.auth = auth; self.startedAt = startedAt
        self.options = options
        self.hub = EventHub(maxSubscribers: options.maxEventSubscribers)
    }

    public convenience init(host: StrimHost, slot: EngineSlot, auth: ControlAuth, options: Options = Options()) {
        var patch: (@Sendable (String) async throws -> String)?
        if let runner = host.chatRunner { patch = { @Sendable (id: String) async throws -> String in try await runner.currentPatch(sessionID: id) } }
        self.init(slot: slot, jobs: host.jobs, store: host.jobStore, jobsRoot: host.paths.jobs,
                  policy: HostPolicy(host.hostConfig),
                  currentPatch: patch,
                  auth: auth, options: options)
    }

    /// Running jobs and open chat sessions: what blocks an unload.
    public static func activeWork(in store: any JobStore) async -> Int {
        ControlMapping.activeJobCount((try? await store.list()) ?? [])
    }

    // MARK: registration

    public func register(on server: StrimOpenAIServer) {
        add(server, "GET", StrimRoutes.status, write: false) { c, _ in try Reply.json(await c.hostStatus()) }
        server.addOpenRoute("GET", StrimRoutes.events) { [self] req, r in try await events(req, r) }
        add(server, "POST", StrimRoutes.load, write: true) { c, req in try await c.load(req) }
        add(server, "POST", StrimRoutes.unload, write: true) { c, _ in try await c.unload() }
        add(server, "GET", StrimRoutes.jobs, write: false) { c, _ in try await c.listJobs() }
        add(server, "POST", StrimRoutes.jobApprove, write: true) { c, req in try await c.approve(req) }
        add(server, "POST", StrimRoutes.chatOpen, write: true) { c, req in try await c.chatOpen(req) }
        add(server, "POST", StrimRoutes.chatCancel, write: true) { c, req in try await c.chatCancel(req) }
        add(server, "POST", ControlRoutes.chatClose, write: true) { c, req in
            let b = try ControlJSON.decode(ChatCancelRequest.self, from: req.body)
            return try await c.chatClose(b.sessionID)
        }
        server.addOpenRoute("POST", StrimRoutes.chatAppend) { [self] req, r in try await chatAppend(req, r) }
        server.addOpenRoute("GET", StrimRoutes.jobs + "/", prefix: true) { [self] req, r in
            await respond(r) {
                try ControlGuard.check(req, status: false, auth: auth)
                return try await jobDetail(String(req.path.dropFirst((StrimRoutes.jobs + "/").count)))
            }
        }
        server.addOpenRoute("DELETE", ControlRoutes.chatPrefix, prefix: true) { [self] req, r in
            await respond(r) {
                try ControlGuard.check(req, status: false, auth: auth)
                return try await chatClose(String(req.path.dropFirst(ControlRoutes.chatPrefix.count)))
            }
        }
    }

    private func add(_ server: StrimOpenAIServer, _ method: String, _ path: String, write: Bool,
                     _ h: @escaping @Sendable (StrimControlPlane, Request) async throws -> Reply) {
        let status = path == StrimRoutes.status && method == "GET"
        server.addOpenRoute(method, path) { [self] (req: Request, r: Responder) async throws -> Void in
            await respond(r) {
                try ControlGuard.check(req, status: status, auth: auth)
                if write { try ControlGuard.jsonBody(req, maxBytes: options.maxBodyBytes) }
                return try await h(self, req)
            }
        }
    }

    // MARK: response plumbing

    func respond(_ r: Responder, _ body: () async throws -> Reply) async {
        do {
            let reply = try await body()
            try await r.json(reply.status, reply.body)
        } catch let e as HTTPServerError {
            _ = e   // peer went away; nothing to answer
        } catch {
            await send(error, r)
        }
    }

    func send(_ error: Error, _ r: Responder) async {
        let ce = Self.controlError(error)
        guard let data = try? ControlJSON.encode(APIErrorEnvelope(error: ce.error)) else { return }
        var h = HTTPHeaders()
        if ce.status == 401 { h.append(name: "WWW-Authenticate", value: "Bearer") }
        try? await r.json(ce.status, data, headers: h)
    }

    static func controlError(_ error: Error) -> ControlError {
        switch error {
        case let e as ControlError: return e
        case let e as EngineSlotError:
            switch e {
            case .loading, .alreadyLoaded, .busy, .unloading: return .conflict("\(e)")
            case .loadFailed: return .internalError("\(e)")
            }
        case let e as ChatForbidden: return .forbidden(e.message)
        case let e as ChatError: return ControlMapping.error(e)
        case JobError.notFound(let id): return .notFound("no job \(id)")
        case JobError.notAwaitingApproval(let id): return .conflict("job \(id) is not awaiting approval")
        default:
            FileHandle.standardError.write(Data("control: internal error: \(Sanitize.text("\(error)", limit: 500))\n".utf8))
            return .internalError("internal error")   // detail stays in the log
        }
    }

    // MARK: status

    func hostStatus() async -> HostStatus {
        let s = await slot.status()
        let m = slot.meter.snapshot()
        let es = slot.client.stats()
        let records = (try? await store.list()) ?? []
        let budget = Double(es.budgetBytes)
        let memory = MemoryStats(
            weightsGB: Double(s.weightsBytes) / ControlMapping.gib,
            prefixTrieGB: Double(es.trieBytes) / ControlMapping.gib,
            mlxCacheGB: Double(es.mlxCacheBytes) / ControlMapping.gib,
            headroomGB: max(0, budget - Double(es.mlxActiveBytes)) / ControlMapping.gib)
        var st = HostStatus(
            state: ControlMapping.hostState(s.state), model: s.model.map { ($0 as NSString).lastPathComponent }, mtp: s.mtp.map { ($0 as NSString).lastPathComponent }, loadProgress: s.progress, memory: memory,
            decodeTPS: m.decodeTPS, prefillTPS: m.prefillTPS, mtpAcceptance: m.mtpAcceptance, mtpDepth: m.mtpDepth,
            prefixHitRate: m.prefixHitRate, savedPrefillSeconds: m.savedPrefillSeconds,
            activeJobs: records.filter { ControlMapping.isActive($0.status) }.count,
            queuedJobs: records.filter { $0.status == .queued }.count,
            tokensToday: m.tokensToday, localTokensGenerated: m.completionTokens,
            uptimeSeconds: Date().timeIntervalSince(startedAt))
        if s.state == .error { st.lastCrash = s.errorMessage }
        return st
    }

    // MARK: load / unload

    func load(_ req: Request) async throws -> Reply {
        let b = try ControlJSON.decode(LoadRequest.self, from: req.body)
        guard !b.model.isEmpty, b.model.utf8.count <= 4096, !b.model.contains("\0"),
              (b.mtp?.utf8.count ?? 0) <= 4096, !(b.mtp?.contains("\0") ?? false) else {
            throw ControlError.badRequest("model must be a non-empty path")
        }
        try checkModelPath(b.model)
        if let m = b.mtp { try checkModelPath(m) }
        try await slot.beginLoad(model: b.model, mtp: b.mtp)
        return try .json(await hostStatus(), status: 202)
    }

    /// Absolute path, canonical (symlinks resolved), inside one of `options.modelRoots`.
    func checkModelPath(_ path: String) throws {
        guard path.hasPrefix("/") else { throw ControlError.badRequest("model paths must be absolute") }
        guard !options.modelRoots.isEmpty else { throw ControlError.forbidden("loading models over the API is disabled (no model roots configured)") }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !comps.contains("..") else { throw ControlError.forbidden("model path may not contain '..'") }
        func canon(_ p: String) -> String {
            var url = URL(fileURLWithPath: p).standardizedFileURL
            var rest: [String] = []
            while url.path != "/" {
                if let r = PatchApplier.realPath(url.path) { return rest.reversed().reduce(r) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 } }
                rest.append(url.lastPathComponent); url = url.deletingLastPathComponent()
            }
            return "/" + rest.reversed().joined(separator: "/")
        }
        let real = canon(path)
        let ok = options.modelRoots.contains { root in
            let r = canon(root)
            return real == r || real.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
        guard ok else { throw ControlError.forbidden("model path is outside the allowed model directories") }
    }

    func unload() async throws -> Reply {
        try await slot.unload()
        return try .json(await hostStatus())
    }

    // MARK: jobs

    func listJobs() async throws -> Reply {
        let records = ((try? await store.list()) ?? []).sorted { ($0.startedAt ?? $0.createdAt) > ($1.startedAt ?? $1.createdAt) }
        return try .json(records.map(ControlMapping.summary))
    }

    func record(_ id: String) async throws -> JobRecord {
        guard ControlMapping.isValidJobID(id) else { throw ControlError.badRequest("malformed job id") }
        guard let r = try? await store.load(id) else { throw ControlError.notFound("no job \(id)") }
        return r
    }

    func jobDetail(_ id: String) async throws -> Reply {
        let r = try await record(id)
        return try await detailReply(r)
    }

    /// `JobDetail` plus `patch_sha256` (SHA-256 of the stored patch bytes; the digest `approve` must echo).
    func detailReply(_ r: JobRecord, status: Int = 200) async throws -> Reply {
        let bytes = await patchBytes(r)
        let shown = bytes.flatMap { $0.count > 1_048_576 ? nil : String(decoding: $0, as: UTF8.self) }
        return try Self.detailReply(ControlMapping.detail(r, patch: shown), digest: bytes.map(Self.sha256), status: status)
    }

    static func detailReply(_ d: JobDetail, digest: String?, status: Int = 200) throws -> Reply {
        var obj = (try JSONSerialization.jsonObject(with: try ControlJSON.encode(d))) as? [String: Any] ?? [:]
        if let digest { obj["patch_sha256"] = digest }
        return Reply(status: status, body: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// The patch bytes of a job: the live session diff for an open chat, else `patch.diff` under the job dir, else inline.
    /// Read once per call; callers hash and apply these same bytes.
    func patchBytes(_ r: JobRecord, fresh: Bool = false) async -> Data? {
        var data: Data?
        if r.profile != nil, !r.status.isTerminal {
            // A live `git diff` of the session worktree: cached briefly for detail reads, never for approve.
            if !fresh, let c = patchCache.withLock({ $0[r.id] }), Date().timeIntervalSince(c.at) < options.patchCacheTTL {
                data = c.data
            } else {
                data = (try? await currentPatch?(r.id)).map { Data($0.utf8) }
                patchCache.withLock { $0[r.id] = (Date(), data) }
            }
        } else if let path = r.result?.patchPath, let d = readUnderJobs(path, id: r.id) {
            data = d
        } else {
            data = r.result?.patch.map { Data($0.utf8) }
        }
        guard let d = data, !d.isEmpty else { return nil }
        return d
    }

    private func readUnderJobs(_ path: String, id: String) -> Data? {
        guard let real = PatchApplier.realPath(path), let root = PatchApplier.realPath(jobsRoot.path),
              real.hasPrefix(root + "/" + id + "/") else { return nil }
        guard let d = FileManager.default.contents(atPath: real), d.count <= PatchApplier.maxPatchBytes else { return nil }
        return d
    }

    func approve(_ req: Request) async throws -> Reply {
        let a = try ControlJSON.decode(ApprovalBody.self, from: req.body)
        let r = try await record(a.jobID)
        guard applying.withLock({ $0.insert(a.jobID).inserted }) else { throw ControlError.conflict("an approval for this job is running") }
        defer { applying.withLock { _ = $0.remove(a.jobID) } }

        // Not started yet (host requires approval to run): approving means "run it".
        let live = try? await jobs.status(r.id, waitS: 0)   // the store may lag the manager by a write
        if r.status == .awaitingApproval || live?.status == .awaitingApproval {
            if a.action == .apply { try await jobs.approve(r.id) } else { try await jobs.reject(r.id) }
            return try await detailReply(try await record(r.id))
        }
        let marker = jobsRoot.appendingPathComponent(r.id).appendingPathComponent("decision.json")
        let openChat = r.profile != nil && !r.status.isTerminal
        if !openChat, FileManager.default.fileExists(atPath: marker.path) { throw ControlError.conflict("a decision was already recorded for this job") }
        if !openChat, !r.status.isTerminal { throw ControlError.conflict("job has not finished") }

        if a.action == .reject {
            if !openChat { try writeMarker(marker, "reject") }
            return try await detailReply(r)
        }
        // Bind the approval to the reviewed content: hash the bytes once, compare, and apply those very bytes.
        guard let want = a.patchSHA256?.lowercased(), !want.isEmpty else {
            throw ControlError.badRequest("patch_sha256 is required to apply (take it from the job detail)")
        }
        guard let patch = await patchBytes(r, fresh: true) else { throw ControlError.conflict("job has no patch to apply") }
        guard Self.sha256(patch) == want else {
            throw ControlError(409, "patch_changed", "the patch no longer matches the reviewed digest; reload the job and review again")
        }
        afterPatchHash.withLock { $0 }?()
        // The job's own recorded access: a read-only host must not apply an older write job.
        if let v = policy.violation(access: r.access.rawValue, cwd: r.cwd) { throw ControlError.forbidden(v) }
        try await applier.apply(patch: patch, cwd: r.cwd)
        if !openChat { try writeMarker(marker, "apply") }
        return try await detailReply(r)
    }

    private func writeMarker(_ url: URL, _ action: String) throws {
        let body = Data("{\"action\":\"\(action)\",\"at\":\(Date().timeIntervalSince1970)}".utf8)
        guard FileManager.default.createFile(atPath: url.path, contents: body, attributes: [.posixPermissions: 0o600]) else {
            throw ControlError.internalError("cannot record the decision")
        }
    }
}

/// `PatchApproval` plus the digest (decoded here so this lane does not depend on the StrimAPI field landing first).
struct ApprovalBody: Decodable {
    var jobID: String
    var action: ApprovalAction
    var patchSHA256: String?
    enum CodingKeys: String, CodingKey { case jobID = "job_id", action, patchSHA256 = "patch_sha256" }
}

/// Small lock-protected value.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}
