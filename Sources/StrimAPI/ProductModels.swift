import Foundation

/// Additive control-API DTOs (jobs pause/cancel, local models, pack fingerprint). Keys are stable snake_case.

public extension StrimRoutes {
    static let pause = "/v1/strim/pause"          // POST (write): stop admitting background jobs
    static let resume = "/v1/strim/resume"        // POST (write)
    static let jobCancel = "/v1/strim/jobs/cancel" // POST (write)
    static let models = "/v1/strim/models"        // GET: local model directories under the allowed roots
    static let pack = "/v1/strim/pack"            // GET: active pack fingerprint + last evolve summary
}

/// `POST pause` body (optional, `{}` is fine).
public struct PauseRequest: Codable, Sendable, Equatable {
    /// Also cancel background jobs that are running now. Default false: running jobs finish.
    public var cancelRunning: Bool
    public init(cancelRunning: Bool = false) { self.cancelRunning = cancelRunning }
    enum CodingKeys: String, CodingKey { case cancelRunning = "cancel_running" }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        cancelRunning = try c.decodeIfPresent(Bool.self, forKey: .cancelRunning) ?? false
    }
}

/// Reply of `pause` / `resume`.
public struct JobsPauseState: Codable, Sendable, Equatable {
    /// Background jobs are not admitted while true. Chat (interactive) is never blocked.
    public var paused: Bool
    public var queued: Int
    public var running: Int
    /// Jobs cancelled by this call (`pause` with `cancel_running`).
    public var cancelled: Int
    public init(paused: Bool, queued: Int = 0, running: Int = 0, cancelled: Int = 0) {
        self.paused = paused; self.queued = queued; self.running = running; self.cancelled = cancelled
    }
}

/// `POST jobs/cancel` body.
public struct JobCancelRequest: Codable, Sendable, Equatable {
    public var jobID: String
    public init(jobID: String) { self.jobID = jobID }
    enum CodingKeys: String, CodingKey { case jobID = "job_id" }
}

/// Reply of `jobs/cancel`: the job after the call. `cancelled` is false when it was already finished (idempotent).
public struct JobCancelResult: Codable, Sendable, Equatable {
    public var jobID: String
    public var status: JobStatusDTO
    public var cancelled: Bool
    public init(jobID: String, status: JobStatusDTO, cancelled: Bool) {
        self.jobID = jobID; self.status = status; self.cancelled = cancelled
    }
    enum CodingKeys: String, CodingKey { case jobID = "job_id", status, cancelled }
}

/// One local model directory the host would accept for `load`.
public struct LocalModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var name: String
    /// Absolute, canonical path (what `load` expects).
    public var path: String
    public var sizeGB: Double?
    /// "model" or "mtp" (a speculative head, guessed from the directory name).
    public var kind: String
    public init(name: String, path: String, sizeGB: Double? = nil, kind: String = "model") {
        self.name = name; self.path = path; self.sizeGB = sizeGB; self.kind = kind
    }
    enum CodingKeys: String, CodingKey { case name, path, sizeGB = "size_gb", kind }
}

public struct ModelList: Codable, Sendable, Equatable {
    public var models: [LocalModel]
    public init(models: [LocalModel]) { self.models = models }
}

/// Summary of the most recent `strim evolve` run found in the pack store (read-only).
public struct EvolveSummary: Codable, Sendable, Equatable {
    public var fingerprint: String
    public var parent: String?
    public var round: Int?
    /// Validation gain in percentage points, when recorded.
    public var valGainPP: Double?
    public var dryRun: Bool
    public var createdAt: String
    public var source: String?
    public init(fingerprint: String, parent: String? = nil, round: Int? = nil, valGainPP: Double? = nil,
                dryRun: Bool = false, createdAt: String, source: String? = nil) {
        self.fingerprint = fingerprint; self.parent = parent; self.round = round; self.valGainPP = valGainPP
        self.dryRun = dryRun; self.createdAt = createdAt; self.source = source
    }
    enum CodingKeys: String, CodingKey {
        case fingerprint, parent, round, dryRun = "dry_run", createdAt = "created_at", source
        case valGainPP = "val_gain_pp"
    }
}

/// `GET pack`: the adopted pack and the last evolve result. Both are nil on a host that never evolved.
public struct PackInfo: Codable, Sendable, Equatable {
    public var activeFingerprint: String?
    public var packCount: Int
    public var lastEvolve: EvolveSummary?
    public init(activeFingerprint: String? = nil, packCount: Int = 0, lastEvolve: EvolveSummary? = nil) {
        self.activeFingerprint = activeFingerprint; self.packCount = packCount; self.lastEvolve = lastEvolve
    }
    enum CodingKeys: String, CodingKey {
        case activeFingerprint = "active_fingerprint", packCount = "pack_count", lastEvolve = "last_evolve"
    }
}
