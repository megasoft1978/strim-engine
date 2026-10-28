import Foundation

public struct SplitMix64: Sendable {
    var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// FNV-1a (Swift's hashValue is randomized per process, which would break reproducible order).
func fnv1a(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return h
}

public struct PlanItem: Sendable, Equatable {
    public var taskId: String
    public var rep: Int
    public var arm: Arm
    public var key: RunKey { RunKey(taskId: taskId, arm: arm, rep: rep) }
}

public enum Planner {
    /// Per task, per rep: the arms in a seeded shuffled order. Same inputs and seed give the same plan.
    public static func plan(taskIds: [String], arms: [Arm], reps: Int, seed: UInt64) -> [PlanItem] {
        var out: [PlanItem] = []
        let base = Arm.allCases.filter { arms.contains($0) }
        for id in taskIds {
            for rep in 1...max(1, reps) {
                var rng = SplitMix64(seed: seed ^ fnv1a("\(id)#\(rep)"))
                var order = base
                if order.count > 1 {
                    for i in stride(from: order.count - 1, to: 0, by: -1) {
                        let j = Int(rng.next() % UInt64(i + 1))
                        order.swapAt(i, j)
                    }
                }
                for a in order { out.append(PlanItem(taskId: id, rep: rep, arm: a)) }
            }
        }
        return out
    }
}

public enum TaskLoader {
    /// Loads `<root>/tasks/<id>/task.json` (or `<root>/<id>/task.json`), sorted by id.
    public static func load(root: URL) -> [LoadedTask] {
        let fm = FileManager.default
        var bases = [root.appendingPathComponent("tasks"), root]
        bases = bases.filter { fm.fileExists(atPath: $0.path) }
        var out: [LoadedTask] = []
        var seen = Set<String>()
        for b in bases {
            let names = ((try? fm.contentsOfDirectory(atPath: b.path)) ?? []).sorted()
            for n in names {
                let dir = b.appendingPathComponent(n)
                let tj = dir.appendingPathComponent("task.json")
                guard let data = try? Data(contentsOf: tj),
                      let spec = try? JSONDecoder().decode(TaskSpec.self, from: data), !seen.contains(spec.id) else { continue }
                seen.insert(spec.id)
                out.append(LoadedTask(spec: spec, dir: dir))
            }
        }
        return out.sorted { $0.spec.id < $1.spec.id }
    }

    /// `limit` is a count PER CLASS (stratified): the first `limit` ids in sorted order within each class.
    /// `ids` and `classes` filter first. The result is sorted by id.
    public static func select(_ all: [LoadedTask], limit: Int?, ids: [String], classes: [String], languages: [String] = [], pilotPerLanguage: Int? = nil) -> [LoadedTask] {
        var t = all
        if !languages.isEmpty { t = t.filter { languages.contains($0.language ?? "") } }
        if !ids.isEmpty { t = t.filter { ids.contains($0.id) } }
        if !classes.isEmpty { t = t.filter { classes.contains($0.spec.taskClass) } }
        if let n = pilotPerLanguage { t = pilot(t, perLanguage: n) }
        if let l = limit {
            let byClass = Dictionary(grouping: t.sorted { $0.spec.id < $1.spec.id }, by: { $0.spec.taskClass })
            t = byClass.values.flatMap { $0.prefix(max(0, l)) }
        }
        return t.sorted { $0.spec.id < $1.spec.id }
    }
}

/// Balanced pilot set: per language the first `perLanguage` tasks, taking one task per class in turn (test-fix, feature-impl, repo-qa, mechanical-edit) so each language mixes test-fix / feature / QA tasks. Deterministic.
extension TaskLoader {
    public static func pilot(_ all: [LoadedTask], perLanguage n: Int) -> [LoadedTask] {
        var out: [LoadedTask] = []
        let byLang = Dictionary(grouping: all, by: { $0.language ?? "?" })
        for lang in byLang.keys.sorted() {
            let byClass = Dictionary(grouping: byLang[lang]!.sorted { $0.spec.id < $1.spec.id }, by: { $0.spec.taskClass })
            let order = ["test-fix", "feature-impl", "repo-qa", "mechanical-edit"]
            let classes = byClass.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            var queues = classes.map { byClass[$0]! }
            var picked: [LoadedTask] = []
            while picked.count < n, queues.contains(where: { !$0.isEmpty }) {
                for i in queues.indices where picked.count < n && !queues[i].isEmpty { picked.append(queues[i].removeFirst()) }
            }
            out += picked
        }
        return out.sorted { $0.spec.id < $1.spec.id }
    }
}

public enum PathArgs {
    /// Absolute, standardized path; relative paths resolve against `cwd` (the child server runs elsewhere).
    public static func absolute(_ p: String, cwd: String = FileManager.default.currentDirectoryPath) -> String {
        let expanded = (p as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        return (full as NSString).standardizingPath
    }
}
