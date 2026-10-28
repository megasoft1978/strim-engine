import Foundation

public enum SplitName: String, Codable, Sendable, CaseIterable { case train, val, test }

/// Deterministic 60/20/20 split, stratified by task class. Within a class tasks are ordered by SHA-256 of the id
/// (not by name) and cut: first 60% train, next 20% val, last 20% test. Adding tasks can move boundaries, so the
/// split is persisted once (`split.json`) and a later mismatch of the test ids is refused.
public struct CorpusSplit: Codable, Equatable, Sendable {
    public var train: [String]
    public var val: [String]
    public var test: [String]

    public static func make(_ tasks: [(id: String, taskClass: String)]) -> CorpusSplit {
        var s = CorpusSplit(train: [], val: [], test: [])
        let byClass = Dictionary(grouping: tasks, by: \.taskClass)
        for cls in byClass.keys.sorted() {
            let ordered = byClass[cls]!.map(\.id).sorted { (key($0), $0) < (key($1), $1) }
            let n = ordered.count
            let nVal = Int((Double(n) * 0.2).rounded()), nTest = nVal
            let nTrain = n - nVal - nTest
            s.train += ordered.prefix(nTrain)
            s.val += ordered.dropFirst(nTrain).prefix(nVal)
            s.test += ordered.dropFirst(nTrain + nVal)
        }
        s.train.sort(); s.val.sort(); s.test.sort()
        return s
    }

    static func key(_ id: String) -> UInt64 {
        Canonical.sha256Hex(id).prefix(16).reduce(UInt64(0)) { $0 << 4 | UInt64(String($1), radix: 16)! }
    }

    /// Search-only reduction for a cheap first run: keeps the first `perClass` ids (sorted by id) of each class in
    /// train and val. The test split is returned unchanged. Not persisted: `split.json` keeps the full assignment.
    public func limited(perClass n: Int, classOf: [String: String]) -> CorpusSplit {
        func cut(_ ids: [String]) -> [String] {
            Dictionary(grouping: ids.sorted(), by: { classOf[$0] ?? "" })
                .flatMap { $0.value.prefix(max(0, n)) }
                .sorted()
        }
        return CorpusSplit(train: cut(train), val: cut(val), test: test)
    }

    public func ids(_ n: SplitName) -> [String] { switch n { case .train: train; case .val: val; case .test: test } }
    public func name(of id: String) -> SplitName? { SplitName.allCases.first { ids($0).contains(id) } }

    public static let fileName = "split.json"

    public func write(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func read(from dir: URL) -> CorpusSplit? {
        (try? Data(contentsOf: dir.appendingPathComponent(fileName))).flatMap { try? JSONDecoder().decode(CorpusSplit.self, from: $0) }
    }

    /// Persisted split wins; the corpus may only differ in ids that were never assigned (new tasks are ignored, not
    /// silently moved into train). A change in an assigned test id is an error.
    public static func frozen(dir: URL, tasks: [(id: String, taskClass: String)]) throws -> CorpusSplit {
        let fresh = make(tasks)
        guard let saved = read(from: dir) else { try fresh.write(to: dir); return fresh }
        let known = Set(saved.train + saved.val + saved.test)
        let current = Set(tasks.map(\.id))
        if !known.isSubset(of: current) {
            throw EvolveError.splitChanged("tasks in \(fileName) are missing from the corpus: \(known.subtracting(current).sorted().joined(separator: ","))")
        }
        return saved
    }
}

public enum EvolveError: Error, CustomStringConvertible {
    case testSplitFrozen
    case splitChanged(String)
    case usage(String)
    case refused(String)
    public var description: String {
        switch self {
        case .testSplitFrozen: return "the test split is frozen: evaluating it needs --release-eval"
        case .splitChanged(let s), .usage(let s), .refused(let s): return s
        }
    }
}

public enum SplitGuard {
    /// The single gate every code path that would touch the test split goes through.
    public static func check(_ split: SplitName, releaseEval: Bool) throws {
        if split == .test && !releaseEval { throw EvolveError.testSplitFrozen }
    }
}
