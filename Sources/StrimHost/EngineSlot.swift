import Foundation
import StrimEngine

/// Why a slot operation was refused. All of them leave the slot unchanged.
public enum EngineSlotError: Error, Equatable, CustomStringConvertible, Sendable {
    /// `load` while a load is running (also `unload` while loading).
    case loading
    /// `load` of another model/head while one is resident: unload first.
    case alreadyLoaded(model: String)
    /// `unload` with work in flight; retry when idle or pass `force`.
    case busy(activeWork: Int)
    /// Another `unload` is already running.
    case unloading
    /// The factory failed; the slot is in `.error` and `load` may be retried.
    case loadFailed(String)

    public var description: String {
        switch self {
        case .loading: return "a load is in progress"
        case let .alreadyLoaded(m): return "model \(m) is already loaded; unload it first"
        case .unloading: return "an unload is already in progress"
        case let .busy(n): return "\(n) job(s)/request(s) still running; wait for them or cancel them first"
        case let .loadFailed(m): return "load failed: \(m)"
        }
    }
}

/// Same cases and raw values as `StrimAPI.HostState` (StrimControl maps 1:1; StrimHost does not depend on StrimAPI).
public enum SlotState: String, Sendable, Equatable, CaseIterable {
    case stopped, loading, ready, busy, error
}

public struct EngineSlotStatus: Sendable, Equatable {
    public var state: SlotState
    public var model: String?
    public var mtp: String?
    /// 0...1 while loading.
    public var progress: Double?
    /// Last load failure (set in `.error`, kept until the next successful load).
    public var errorMessage: String?
    public var loadedAt: Date?
    /// MLX active bytes right after the load finished (weights + kernels, no sessions).
    public var weightsBytes: Int
}

/// Owns the one resident engine. Everything that needs the engine goes through `client` (a proxy that
/// answers `EngineError.unhealthy` while nothing is loaded), so `unload` can really drop the last reference.
///
/// Concurrency contract (all refusals are typed `EngineSlotError`, never a wait):
/// - `load` while loading: refused (`.loading`). While ready with the same model+head: no-op. Ready with
///   another model: refused (`.alreadyLoaded`). From `.stopped`/`.error`: runs.
/// - `unload` while loading: refused. While work is running (`busyProbe() > 0`): refused (`.busy`) unless
///   `force`. While stopped: no-op; from `.error`: back to `.stopped`.
/// - A failed load leaves `.error` with the message and does not block a retry.
/// - New sessions are refused as soon as an unload starts, so an unload cannot be raced by fresh work.
public actor EngineSlot {
    public typealias Factory = @Sendable (_ model: String, _ mtp: String?, _ progress: @escaping @Sendable (Double) -> Void) async throws -> any EngineClient

    /// The engine proxy to hand to the server, harness and anything else; stable for the slot's lifetime.
    public nonisolated let client: SlotEngineClient
    public nonisolated let meter: EngineMeter

    private enum Phase { case stopped, loading, ready, error }
    private let factory: Factory
    private let release: @Sendable (any EngineClient) async -> Void
    private let busyProbe: @Sendable () async -> Int
    private var phase: Phase = .stopped
    private var model: String?
    private var mtp: String?
    private var progress: Double?
    private var errorMessage: String?
    private var loadedAt: Date?
    private var weightsBytes = 0
    private var loadTask: Task<Void, Never>?
    private var unloading = false
    private var subscribers: [UUID: @Sendable (EngineSlotStatus) -> Void] = [:]

    /// - factory: builds a ready engine (tests: a fake).
    /// - release: called with the engine on unload, before the last reference is dropped (e.g. `LocalEngineClient.shutdown`).
    /// - busyProbe: running jobs/requests beyond the engine's own in-flight count.
    public init(factory: @escaping Factory,
                release: @escaping @Sendable (any EngineClient) async -> Void = { _ in },
                busyProbe: @escaping @Sendable () async -> Int = { 0 },
                meter: EngineMeter = EngineMeter()) {
        self.factory = factory; self.release = release; self.busyProbe = busyProbe
        self.meter = meter
        self.client = SlotEngineClient(meter: meter)
    }

    // MARK: state

    /// `.busy` is derived: a ready slot with work in flight.
    public func status() async -> EngineSlotStatus {
        var s = snapshot()
        if phase == .ready, await activeWork() > 0 { s.state = .busy }
        return s
    }

    private func snapshot() -> EngineSlotStatus {
        let state: SlotState
        switch phase {
        case .stopped: state = .stopped
        case .loading: state = .loading
        case .ready: state = .ready
        case .error: state = .error
        }
        return EngineSlotStatus(state: state, model: phase == .stopped ? nil : model, mtp: phase == .stopped ? nil : mtp,
                                progress: phase == .loading ? progress : nil, errorMessage: errorMessage,
                                loadedAt: phase == .ready ? loadedAt : nil, weightsBytes: phase == .ready ? weightsBytes : 0)
    }

    private func activeWork() async -> Int {
        let probed = await busyProbe()
        return max(probed, client.activeRequests)
    }

    /// Calls `body` on every state change (loading, ready, error, stopped). Returns a cancel token.
    public func observe(_ body: @escaping @Sendable (EngineSlotStatus) -> Void) -> UUID {
        let id = UUID(); subscribers[id] = body; return id
    }
    public func stopObserving(_ id: UUID) { subscribers[id] = nil }
    private func notify() {
        let s = snapshot()
        for b in subscribers.values { b(s) }
    }

    // MARK: adopt

    /// Takes an already running engine (the one `strim serve` started before the HTTP server existed).
    public func adopt(_ engine: any EngineClient, model: String, mtp: String?) {
        client.install(engine)
        phase = .ready; self.model = model; self.mtp = mtp; progress = nil; errorMessage = nil
        loadedAt = Date(); weightsBytes = engine.stats().mlxActiveBytes
        notify()
    }

    // MARK: load

    /// Loads and returns when the engine is ready (or throws; the slot is then in `.error`).
    public func load(model: String, mtp: String? = nil) async throws {
        if try begin(model: model, mtp: mtp) { return }
        try await runLoad(model: model, mtp: mtp)
    }

    /// Validates and enters `.loading`, then loads in the background (HTTP 202 semantics). Failures show up
    /// as `.error` in `status()`.
    public func beginLoad(model: String, mtp: String? = nil) throws {
        if try begin(model: model, mtp: mtp) { return }
        loadTask = Task { [weak self] in try? await self?.runLoad(model: model, mtp: mtp) }
    }

    /// Waits for a background load started with `beginLoad` (tests).
    public func waitForLoad() async { await loadTask?.value }

    /// True: nothing to do (already loaded with the same arguments). Otherwise the slot is now `.loading`.
    private func begin(model: String, mtp: String?) throws -> Bool {
        switch phase {
        case .loading: throw EngineSlotError.loading
        case .ready:
            if self.model == model, self.mtp == mtp { return true }
            throw EngineSlotError.alreadyLoaded(model: self.model ?? "?")
        case .stopped, .error: break
        }
        phase = .loading; self.model = model; self.mtp = mtp; progress = 0; errorMessage = nil
        notify()
        return false
    }

    private func runLoad(model: String, mtp: String?) async throws {
        do {
            let engine = try await factory(model, mtp) { [weak self] p in
                Task { await self?.setProgress(p) }
            }
            client.install(engine)
            weightsBytes = engine.stats().mlxActiveBytes
            phase = .ready; progress = nil; loadedAt = Date()
            notify()
        } catch {
            let msg = String(describing: error)
            phase = .error; progress = nil; errorMessage = msg
            notify()
            throw EngineSlotError.loadFailed(msg)
        }
    }

    private func setProgress(_ p: Double) {
        guard phase == .loading else { return }
        progress = min(max(p, 0), 1)
        notify()
    }

    // MARK: unload

    public func unload(force: Bool = false) async throws {
        switch phase {
        case .loading: throw EngineSlotError.loading
        case .stopped: return
        case .error:
            phase = .stopped; model = nil; mtp = nil; errorMessage = nil
            notify(); return
        case .ready: break
        }
        // One unload at a time: only the holder may toggle the draining flag.
        guard !unloading else { throw EngineSlotError.unloading }
        unloading = true
        defer { unloading = false }
        client.setDraining(true)                       // no new sessions from here on
        let n = await activeWork()
        guard phase == .ready else { client.setDraining(false); return }
        if n > 0, !force {
            client.setDraining(false)
            throw EngineSlotError.busy(activeWork: n)
        }
        let engine = client.uninstall()
        phase = .stopped; model = nil; mtp = nil; loadedAt = nil; weightsBytes = 0
        notify()
        if let engine { await release(engine) }
    }
}
