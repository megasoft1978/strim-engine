import Foundation

public struct AdmissionTicket: Sendable, Equatable {
    public let id: Int
    public let cls: AdmissionClass
}

/// Admission control shared by the HTTP layer (chat requests) and the job layer (delegated jobs, chat turns).
///
/// ENGINE HOOK: this is admission priority plus turn-boundary yielding, not mid-token preemption. A scheduler that
/// wants to honour the classes itself can implement this protocol (or read `AdmissionClass.rawValue`, identical to
/// `StrimEngine.Priority`) and be injected in place of `PriorityGate`; callers do not change.
public protocol AdmissionControlling: Sendable {
    /// Waits for a slot. Cancelling the task removes the waiter and throws `CancellationError`.
    func acquire(_ cls: AdmissionClass) async throws -> AdmissionTicket
    /// Frees the slot (or drops a waiter). Idempotent.
    func release(_ ticket: AdmissionTicket) async
    /// Turn boundary of a background holder: if interactive work is present, give the slot up and re-queue as
    /// background, returning the new ticket once re-admitted. Interactive tickets return unchanged.
    func checkpoint(_ ticket: AdmissionTicket) async throws -> AdmissionTicket
    func interactivePresent() async -> Bool
    func stats() async -> AdmissionStats
}

public extension AdmissionControlling {
    /// A held slot that follows the ticket across checkpoints.
    func lease(_ cls: AdmissionClass) async throws -> AdmissionLease {
        AdmissionLease(gate: self, ticket: try await acquire(cls))
    }

    func withSlot<T: Sendable>(_ cls: AdmissionClass, _ body: @Sendable () async throws -> T) async throws -> T {
        let l = try await lease(cls)
        do { let v = try await body(); await l.release(); return v } catch { await l.release(); throw error }
    }
}

public actor AdmissionLease {
    private let gate: any AdmissionControlling
    private var ticket: AdmissionTicket
    private var released = false
    public init(gate: any AdmissionControlling, ticket: AdmissionTicket) { self.gate = gate; self.ticket = ticket }
    public var cls: AdmissionClass { ticket.cls }
    public var isReleased: Bool { released }

    public func checkpoint() async throws {
        guard !released else { return }
        let t = try await gate.checkpoint(ticket)
        if released { await gate.release(t) } else { ticket = t }
    }

    public func release() async {
        guard !released else { return }
        released = true
        await gate.release(ticket)
    }
}

/// Task-local turn-boundary hook. `JobManager` binds it around a background job's executor; the agent loop calls
/// `await AdmissionCheckpoint.wait()` between model turns (never mid-token). No-op when unbound.
public enum AdmissionCheckpoint {
    @TaskLocal public static var current: (@Sendable () async throws -> Void)?
    public static func wait() async throws { try await current?() }
}

public actor PriorityGate: AdmissionControlling {
    private struct Waiter { var cont: CheckedContinuation<AdmissionTicket, Error>; var cls: AdmissionClass; var since: Double }
    private var core: AdmissionCore
    private var waiters: [Int: Waiter] = [:]
    private var nextID = 0
    private var st = AdmissionStats()
    private let clock: @Sendable () -> Double

    /// `clock` returns seconds (injected for deterministic wait statistics).
    public init(limits: AdmissionLimits = AdmissionLimits(), clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        core = AdmissionCore(limits: limits); self.clock = clock
    }

    public init(maxInflight: Int, maxBackground: Int = 1, starvationLimit: Int = 8) {
        self.init(limits: AdmissionLimits(maxInflight: maxInflight, maxBackground: maxBackground, starvationLimit: starvationLimit))
    }

    public func acquire(_ cls: AdmissionClass) async throws -> AdmissionTicket {
        try await acquire(cls, parked: false)
    }

    private func acquire(_ cls: AdmissionClass, parked: Bool) async throws -> AdmissionTicket {
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AdmissionTicket, Error>) in
                if Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                waiters[id] = Waiter(cont: cont, cls: cls, since: clock())
                dispatch(core.enqueue(id, cls, parked: parked))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release(_ ticket: AdmissionTicket) {
        guard core.state(of: ticket.id) != .gone else { return }
        dispatch(core.release(ticket.id))
    }

    public func checkpoint(_ ticket: AdmissionTicket) async throws -> AdmissionTicket {
        guard ticket.cls == .background, core.interactivePresent else { return ticket }
        st.backgroundYields += 1
        release(ticket)
        return try await acquire(.background, parked: true)
    }

    public func interactivePresent() -> Bool { core.interactivePresent }

    public func stats() -> AdmissionStats {
        var s = st
        s.activeInteractive = core.activeInteractive; s.activeBackground = core.activeBackground
        s.waitingInteractive = core.waitingInteractive.count; s.waitingBackground = core.waitingBackground.count
        s.admittedInteractive = core.admitted[.interactive] ?? 0; s.admittedBackground = core.admitted[.background] ?? 0
        return s
    }

    private func cancelWaiter(_ id: Int) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        dispatch(core.release(id))
        w.cont.resume(throwing: CancellationError())
    }

    private func dispatch(_ granted: [Int]) {
        let t = clock()
        for id in granted {
            guard let w = waiters.removeValue(forKey: id) else { continue }
            if w.cls == .interactive { st.totalWaitInteractive += t - w.since } else { st.totalWaitBackground += t - w.since }
            w.cont.resume(returning: AdmissionTicket(id: id, cls: w.cls))
        }
    }
}
