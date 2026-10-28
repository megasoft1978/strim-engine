import Foundation

public enum BudgetError: Error, CustomStringConvertible, Equatable {
    case paidNotAllowed(Arm)
    case missingMax
    public var description: String {
        switch self {
        case .paidNotAllowed(let a): return "arm \(a.rawValue) uses the paid Claude subscription: refused without --allow-paid"
        case .missingMax: return "paid arms (P, M) require --max-parent-runs N (N >= 1) as a hard budget"
        }
    }
}

/// Hard cap on paid parent runs (arms P and M). Existing ledger rows count against the cap.
public struct BudgetGuard: Sendable, Equatable {
    public let limit: Int
    public private(set) var used: Int

    public static func validate(arms: [Arm], allowPaid: Bool, maxParentRuns: Int?) throws {
        guard let paid = arms.first(where: \.isPaid) else { return }
        guard allowPaid else { throw BudgetError.paidNotAllowed(paid) }
        guard let n = maxParentRuns, n >= 1 else { throw BudgetError.missingMax }
    }

    public init(limit: Int, alreadyUsed: Int) { self.limit = limit; self.used = alreadyUsed }

    public var exhausted: Bool { used >= limit }

    /// Reserves one paid run. False once the cap is reached.
    public mutating func reserve() -> Bool {
        guard used < limit else { return false }
        used += 1
        return true
    }
}
