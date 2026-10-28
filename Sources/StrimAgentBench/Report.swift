import Foundation

public func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// Parent cost of a run: Claude's `total_cost_usd`, else a token proxy (uncached + create + 0.1 x read + output).
public func parentCost(_ r: LedgerRow) -> Double? {
    if let c = r.parentCostUsd { return c }
    guard r.parentTotal != nil else { return nil }
    return Double(r.parentInUncached ?? 0) + Double(r.parentCacheCreate ?? 0) + 0.1 * Double(r.parentCacheRead ?? 0) + Double(r.parentOut ?? 0)
}

public struct ArmStats: Codable, Sendable, Equatable {
    public var n = 0
    public var passes = 0
    public var passRate = 0.0
    public var medianParentCost: Double?
    public var medianParentTokens: Double?
    public var medianWallS: Double?
    public var medianLocalTokens: Double?
    public var claimedDone = 0
    public var falseDone = 0
    /// falseDone / n
    public var falseDoneRate = 0.0
    public var delegations = 0
    public var redos = 0
    public var timeouts = 0
}

public struct NetSaving: Codable, Sendable, Equatable {
    public var pairs = 0
    /// Median over (task, rep) pairs of 1 - M/P, counting the cost of M exactly as billed (failed delegations and redo included).
    public var rawSaving: Double?
    /// Same, but a failed M run is charged its cost plus a full solo run (what it takes to finish the task properly).
    public var netSaving: Double?
    /// 1 - sum(adjusted M) / sum(P).
    public var aggregateSaving: Double?
    public var failedDelegations = 0
    public var redoRuns = 0
    public var mFailed = 0
    public var wallRatio: Double?
    public var passDeltaPP: Double?
}

public struct TaxEstimate: Codable, Sendable, Equatable {
    /// M runs that never delegated, paired with P.
    public var pairs = 0
    /// Median of M/P - 1 over those pairs.
    public var overheadPct: Double?
    /// Static: the four tool definitions re-read on every parent turn.
    public var toolSchemaTokensPerTurn = 1300
}

public struct ClassReport: Codable, Sendable, Equatable {
    public var taskClass: String
    public var tasks: Int
    public var repsPerArm: [String: Int]
    public var arms: [String: ArmStats]
    public var m_vs_p: NetSaving?
    public var tax: TaxEstimate?
    public var gate: [String]
}

/// How the harness's own verify verdict (arm H) compares with the independent judge.
public struct AgreementRow: Codable, Sendable, Equatable {
    public var harnessVerifyStatus: String
    public var n: Int
    public var judgePass: Int
    public var judgeFail: Int
    /// P(judge pass | this harness status)
    public var passRate: Double
    /// P(judge fail | this harness status); for `verified` this is the false-done rate.
    public var failRate: Double
}

public struct BenchReport: Codable, Sendable, Equatable {
    public var generatedAt: String
    public var rows: Int
    public var classes: [ClassReport]
    public var agreement: [AgreementRow] = []
}

public enum Reporter {
    public static func armStats(_ rows: [LedgerRow]) -> ArmStats {
        var s = ArmStats()
        s.n = rows.count
        s.passes = rows.filter(\.success).count
        s.passRate = rows.isEmpty ? 0 : Double(s.passes) / Double(rows.count)
        s.medianParentCost = median(rows.compactMap(parentCost))
        s.medianParentTokens = median(rows.compactMap { $0.parentTotal.map(Double.init) })
        s.medianWallS = median(rows.map(\.wallS))
        s.medianLocalTokens = median(rows.compactMap { r in
            r.localPromptTokens == nil && r.localCompletionTokens == nil ? nil : Double((r.localPromptTokens ?? 0) + (r.localCompletionTokens ?? 0))
        })
        s.claimedDone = rows.filter(\.claimedDone).count
        s.falseDone = rows.filter(\.falseDone).count
        s.falseDoneRate = rows.isEmpty ? 0 : Double(s.falseDone) / Double(rows.count)
        s.delegations = rows.reduce(0) { $0 + $1.delegations }
        s.redos = rows.filter(\.redo).count
        s.timeouts = rows.filter(\.timedOut).count
        return s
    }

    /// Paired by (task, rep). Needs parent cost on both sides.
    public static func netSaving(p: [LedgerRow], m: [LedgerRow]) -> NetSaving? {
        let pBy = Dictionary(p.map { ("\($0.taskId)#\($0.rep)", $0) }, uniquingKeysWith: { a, _ in a })
        var raw: [Double] = [], net: [Double] = [], wall: [Double] = []
        var sumP = 0.0, sumM = 0.0
        var out = NetSaving()
        var pPass = 0.0, mPass = 0.0
        for mr in m {
            guard let pr = pBy["\(mr.taskId)#\(mr.rep)"], let pc = parentCost(pr), pc > 0, let mc = parentCost(mr) else { continue }
            out.pairs += 1
            let adjusted = mc + (mr.success ? 0 : pc)
            raw.append(1 - mc / pc)
            net.append(1 - adjusted / pc)
            sumP += pc; sumM += adjusted
            if pr.wallS > 0 { wall.append(mr.wallS / pr.wallS) }
            pPass += pr.success ? 1 : 0; mPass += mr.success ? 1 : 0
            if mr.delegations > 0 && (!mr.success || mr.redo) { out.failedDelegations += 1 }
            if mr.redo { out.redoRuns += 1 }
            if !mr.success { out.mFailed += 1 }
        }
        guard out.pairs > 0 else { return nil }
        out.rawSaving = median(raw)
        out.netSaving = median(net)
        out.aggregateSaving = 1 - sumM / sumP
        out.wallRatio = median(wall)
        out.passDeltaPP = (mPass - pPass) / Double(out.pairs) * 100
        return out
    }

    public static func tax(p: [LedgerRow], m: [LedgerRow]) -> TaxEstimate? {
        let pBy = Dictionary(p.map { ("\($0.taskId)#\($0.rep)", $0) }, uniquingKeysWith: { a, _ in a })
        var over: [Double] = []
        for mr in m where mr.delegations == 0 {
            guard let pr = pBy["\(mr.taskId)#\(mr.rep)"], let pc = parentCost(pr), pc > 0, let mc = parentCost(mr) else { continue }
            over.append(mc / pc - 1)
        }
        guard !over.isEmpty else { return nil }
        var t = TaxEstimate()
        t.pairs = over.count
        t.overheadPct = median(over).map { $0 * 100 }
        return t
    }

    static let statusOrder = ["verified", "verified_modified_tests", "failed", "unverified", "declined", "none"]

    public static func agreement(_ rows: [LedgerRow]) -> [AgreementRow] {
        let h = rows.filter { $0.arm == .H && $0.harnessVerifyStatus != nil }
        let groups = Dictionary(grouping: h, by: { $0.harnessVerifyStatus! })
        let keys = groups.keys.sorted {
            (statusOrder.firstIndex(of: $0) ?? 99, $0) < (statusOrder.firstIndex(of: $1) ?? 99, $1)
        }
        return keys.map { k in
            let g = groups[k]!
            let pass = g.filter(\.success).count
            return AgreementRow(harnessVerifyStatus: k, n: g.count, judgePass: pass, judgeFail: g.count - pass,
                                passRate: Double(pass) / Double(g.count), failRate: Double(g.count - pass) / Double(g.count))
        }
    }

    public static func build(_ allRows: [LedgerRow], includeDryRun: Bool = false) -> BenchReport {
        let rows = allRows.filter { includeDryRun || !$0.dryRun }.filter { !$0.infraError }
        var classes: [ClassReport] = []
        for cls in Set(rows.map(\.taskClass)).sorted() {
            let cr = rows.filter { $0.taskClass == cls }
            var arms: [String: ArmStats] = [:]
            var reps: [String: Int] = [:]
            for a in Arm.allCases {
                let ar = cr.filter { $0.arm == a }
                guard !ar.isEmpty else { continue }
                arms[a.rawValue] = armStats(ar)
                reps[a.rawValue] = Dictionary(grouping: ar, by: \.taskId).values.map(\.count).min() ?? 0
            }
            let p = cr.filter { $0.arm == .P }, m = cr.filter { $0.arm == .M }
            let ns = netSaving(p: p, m: m)
            var gate: [String] = []
            if let ns {
                let tasks = Set(m.map(\.taskId)).count
                let minReps = reps["M"] ?? 0
                gate.append(String(format: "saving >= 40%%: %@ (%.0f%%)", (ns.netSaving ?? -1) >= 0.4 ? "yes" : "no", (ns.netSaving ?? 0) * 100))
                gate.append(String(format: "pass rate >= P - 5pp: %@ (%+.0fpp)", (ns.passDeltaPP ?? -100) >= -5 ? "yes" : "no", ns.passDeltaPP ?? 0))
                gate.append(String(format: "wall <= 2.5x P: %@ (%.2fx)", (ns.wallRatio ?? 99) <= 2.5 ? "yes" : "no", ns.wallRatio ?? 0))
                gate.append("n >= 10 tasks x 2 reps: \(tasks >= 10 && minReps >= 2 ? "yes" : "no") (\(tasks) tasks, \(minReps) reps)")
            }
            classes.append(ClassReport(taskClass: cls, tasks: Set(cr.map(\.taskId)).count, repsPerArm: reps, arms: arms,
                                       m_vs_p: ns, tax: tax(p: p, m: m), gate: gate))
        }
        return BenchReport(generatedAt: ISO8601DateFormatter().string(from: Date()), rows: rows.count, classes: classes,
                           agreement: agreement(rows))
    }

    // MARK: rendering

    static func pct(_ x: Double?) -> String { x.map { String(format: "%.0f%%", $0 * 100) } ?? "-" }
    static func usd(_ x: Double?) -> String { x.map { String(format: "$%.4f", $0) } ?? "-" }
    static func num(_ x: Double?) -> String { x.map { String(format: "%.0f", $0) } ?? "-" }

    public static func render(_ r: BenchReport) -> String {
        var out = "agentbench report: \(r.rows) runs\n"
        for c in r.classes {
            out += "\n== \(c.taskClass) (\(c.tasks) tasks) ==\n"
            let head = ["arm", "n", "pass", "med parent $", "med parent tok", "med local tok", "med wall s", "false-done", "redo"]
            var table: [[String]] = [head]
            for a in Arm.allCases {
                guard let s = c.arms[a.rawValue] else { continue }
                table.append([a.rawValue, "\(s.n)", "\(s.passes)/\(s.n) (\(pct(s.passRate)))", usd(s.medianParentCost),
                              num(s.medianParentTokens), num(s.medianLocalTokens), num(s.medianWallS),
                              "\(s.falseDone) (\(pct(s.falseDoneRate)))", "\(s.redos)"])
            }
            let widths = head.indices.map { i in table.map { $0[i].count }.max() ?? 0 }
            for row in table {
                out += row.indices.map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ") + "\n"
            }
            if let n = c.m_vs_p {
                out += "M vs P (\(n.pairs) pairs): net saving \(pct(n.netSaving)) (median, failed M runs charged a solo rerun), raw \(pct(n.rawSaving)), "
                out += "aggregate \(pct(n.aggregateSaving)); failed delegations \(n.failedDelegations), redo \(n.redoRuns), M failures \(n.mFailed)\n"
                out += String(format: "wall M/P %.2fx, pass delta %+.0fpp\n", n.wallRatio ?? 0, n.passDeltaPP ?? 0)
            } else if c.arms["M"] != nil || c.arms["P"] != nil {
                out += "M vs P: no paired runs with parent cost yet\n"
            }
            if let t = c.tax {
                out += String(format: "tax: M without delegating costs %+.1f%% vs P (%d pairs); tool schema ~%d tokens per parent turn\n",
                              t.overheadPct ?? 0, t.pairs, t.toolSchemaTokensPerTurn)
            }
            if !c.gate.isEmpty { out += "gate: " + c.gate.joined(separator: "; ") + "\n" }
        }
        if !r.agreement.isEmpty {
            out += "\n== harness verify vs judge (arm H) ==\n"
            out += "harness status".padding(toLength: 26, withPad: " ", startingAt: 0) + "n    judge pass  judge fail  P(pass|status)  P(fail|status)\n"
            for a in r.agreement {
                out += a.harnessVerifyStatus.padding(toLength: 26, withPad: " ", startingAt: 0)
                out += "\(a.n)".padding(toLength: 5, withPad: " ", startingAt: 0)
                out += "\(a.judgePass)".padding(toLength: 12, withPad: " ", startingAt: 0)
                out += "\(a.judgeFail)".padding(toLength: 12, withPad: " ", startingAt: 0)
                out += pct(a.passRate).padding(toLength: 16, withPad: " ", startingAt: 0) + pct(a.failRate)
                out += a.harnessVerifyStatus == "verified" ? "  <- false-done rate\n" : "\n"
            }
        }
        return out
    }
}
