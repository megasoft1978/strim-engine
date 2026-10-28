// Admission policy as a pure state machine (no concurrency, no clock): deterministic and property-testable.
// `PriorityGate` wraps it with continuations.

/// Priority class of a unit of work. Raw values equal `StrimEngine.Priority` (0 interactive, 1 background), so the
/// engine scheduler can honour the same classes: map with `Priority(rawValue: cls.rawValue)`.
public enum AdmissionClass: Int, Sendable, Comparable, CaseIterable {
    case interactive = 0
    case background = 1
    public static func < (a: AdmissionClass, b: AdmissionClass) -> Bool { a.rawValue < b.rawValue }
}

public struct AdmissionLimits: Sendable, Equatable {
    /// Total slots (interactive + background).
    public var maxInflight: Int
    /// Background cap. Clamped to `maxInflight - 1` (min 1) so an arriving interactive request always finds a free
    /// slot unless `maxInflight == 1` (a running decode cannot be preempted mid-token).
    public var maxBackground: Int
    /// Background is passed over at most this many times by later interactive admissions while it is eligible
    /// (a slot-and-cap-wise free background waiter); then it is admitted next.
    public var starvationLimit: Int

    public init(maxInflight: Int = 2, maxBackground: Int = 1, starvationLimit: Int = 8) {
        let inflight = max(1, maxInflight)
        self.maxInflight = inflight
        self.maxBackground = min(max(1, maxBackground), max(1, inflight - 1))
        self.starvationLimit = max(1, starvationLimit)
    }
}

/// Counters, in the shape of the old `strimd` `/priority` stats.
public struct AdmissionStats: Sendable, Equatable {
    public var activeInteractive = 0, activeBackground = 0
    public var waitingInteractive = 0, waitingBackground = 0
    public var admittedInteractive = 0, admittedBackground = 0
    /// Times a running background holder yielded its slot at a turn boundary.
    public var backgroundYields = 0
    public var totalWaitInteractive = 0.0, totalWaitBackground = 0.0
    public init() {}
}

public struct AdmissionCore: Sendable {
    public let limits: AdmissionLimits
    public private(set) var active: [Int: AdmissionClass] = [:]
    public private(set) var waitingInteractive: [Int] = []
    public private(set) var waitingBackground: [Int] = []
    public private(set) var passedOver = 0
    /// Background waiters that yielded at a turn boundary: they also wait out *active* interactive work (a fresh
    /// background request only yields to interactive *waiters*, as in the old Python gate).
    public private(set) var parked: Set<Int> = []
    public private(set) var admitted: [AdmissionClass: Int] = [.interactive: 0, .background: 0]

    public init(limits: AdmissionLimits = AdmissionLimits()) { self.limits = limits }

    public var activeInteractive: Int { active.values.filter { $0 == .interactive }.count }
    public var activeBackground: Int { active.values.filter { $0 == .background }.count }
    /// Interactive work is running or queued: background yields at its next turn boundary.
    public var interactivePresent: Bool { activeInteractive > 0 || !waitingInteractive.isEmpty }

    /// Queues `id`; returns ids admitted by this call (possibly `id` itself). `parked`: a background job resuming
    /// from a turn-boundary yield.
    public mutating func enqueue(_ id: Int, _ cls: AdmissionClass, parked isParked: Bool = false) -> [Int] {
        switch cls {
        case .interactive: waitingInteractive.append(id)
        case .background:
            waitingBackground.append(id)
            if isParked { parked.insert(id) }
        }
        return drain()
    }

    /// Frees an active slot or drops a waiter (cancel at any state); returns newly admitted ids. Idempotent.
    public mutating func release(_ id: Int) -> [Int] {
        active[id] = nil
        waitingInteractive.removeAll { $0 == id }
        waitingBackground.removeAll { $0 == id }
        parked.remove(id)
        return drain()
    }

    public func state(of id: Int) -> State {
        if let c = active[id] { return .active(c) }
        if waitingInteractive.contains(id) || waitingBackground.contains(id) { return .waiting }
        return .gone
    }
    public enum State: Equatable, Sendable { case waiting, active(AdmissionClass), gone }

    private mutating func drain() -> [Int] {
        var out: [Int] = []
        while active.count < limits.maxInflight {
            let bgEligible = !waitingBackground.isEmpty && activeBackground < limits.maxBackground
            let boosted = passedOver >= limits.starvationLimit
            let held = !boosted && activeInteractive > 0 && waitingBackground.first.map(parked.contains) == true
            if bgEligible, boosted || (waitingInteractive.isEmpty && !held) {
                let id = waitingBackground.removeFirst()
                parked.remove(id)
                active[id] = .background; admitted[.background, default: 0] += 1
                passedOver = 0; out.append(id)
            } else if !waitingInteractive.isEmpty {
                let id = waitingInteractive.removeFirst()
                active[id] = .interactive; admitted[.interactive, default: 0] += 1
                if bgEligible { passedOver += 1 }
                out.append(id)
            } else { break }
        }
        if waitingBackground.isEmpty { passedOver = 0 }
        return out
    }
}
