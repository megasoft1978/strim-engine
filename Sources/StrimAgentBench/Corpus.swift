import Foundation

public struct ValidationResult: Sendable, Equatable {
    public var id: String
    public var taskClass: String
    public var broken: String
    public var solved: String
    public var ok: Bool
    public var note: String
    public var brokenSecs: Double = 0
    public var solvedSecs: Double = 0
}

/// Offline corpus checks (`strim agentbench validate|prepare`): replaces the old shell/Python tooling.
public enum Corpus {
    public static let verifyBudgetS: Double = 60

    /// test-fix / mechanical-edit: verify must FAIL on the snapshot and PASS once `solution.patch` is applied
    /// (tests restored and hash-checked by the verifier). repo-qa: `known_answer` accepted, `wrong_answer` and empty rejected.
    public static func validate(_ task: LoadedTask, scratch: URL, home: String = NSHomeDirectory()) -> ValidationResult {
        let t = task.spec
        var r = ValidationResult(id: t.id, taskClass: t.taskClass, broken: "-", solved: "-", ok: true, note: "")
        let fm = FileManager.default
        let base = scratch.appendingPathComponent("base")
        guard let src = task.snapshotSource() else { r.ok = false; r.note = "snapshot missing"; return r }
        do { try Verifier.extractSnapshot(src, into: base) } catch { r.ok = false; r.note = "\(error)"; return r }
        for (k, v) in t.testSha256 where Verifier.sha256(file: base.appendingPathComponent(k)) != v {
            r.ok = false; r.note = "test hash mismatch in snapshot: \(k)"; return r
        }
        func copy(_ name: String) throws -> URL {
            let w = scratch.appendingPathComponent(name)
            try fm.copyItem(at: base, to: w)
            return w
        }
        func run(_ w: URL, answer: String?, tag: String) -> (VerifyOutcome, Double) {
            let t0 = Date()
            let v = Verifier.verify(task: t, base: base, work: w, answer: answer, scratch: scratch.appendingPathComponent("v-\(tag)"),
                                    timeout: 180, home: home)
            return (v, Date().timeIntervalSince(t0))
        }
        do {
            if t.isAnswerTask {
                var accepted = false
                if let known = t.knownAnswer {
                    let (v, secs) = run(try copy("w-known"), answer: known, tag: "known")
                    accepted = v.success; r.solvedSecs = secs
                    r.solved = v.success ? "accept" : "REJECT-known"
                    if !v.success { r.ok = false; r.note += "known answer rejected: \(v.note) " }
                } else { r.ok = false; r.note += "no known_answer " }
                for (label, ans) in [("wrong", t.wrongAnswer ?? "not the answer"), ("empty", "")] {
                    let (v, secs) = run(try copy("w-\(label)"), answer: ans, tag: label)
                    r.brokenSecs = max(r.brokenSecs, secs)
                    if v.success { r.ok = false; r.note += "\(label) answer accepted " }
                }
                r.broken = accepted ? "rejects" : "-"
                return r
            }
            let b = try copy("w-broken")
            let (bv, bs) = run(b, answer: nil, tag: "broken")
            r.brokenSecs = bs
            r.broken = bv.success ? "PASSES(bad)" : "fails"
            if bv.success { r.ok = false; r.note += "unsolved snapshot passes verify " }
            if bv.infra { r.ok = false; r.note += bv.note + " " }
            let s = try copy("w-solved")
            guard let patch = task.solutionPatch() else { r.ok = false; r.note += "solution.patch missing"; return r }
            let ap = Proc.capture(["/usr/bin/git", "apply", "--whitespace=nowarn", patch.path], cwd: s.path, scratch: scratch)
            if ap.code != 0 { r.ok = false; r.note += "solution.patch does not apply: \(ap.text.prefix(120))"; return r }
            let (sv, ss) = run(s, answer: nil, tag: "solved")
            r.solvedSecs = ss
            r.solved = sv.success ? "passes" : "FAILS(bad)"
            if !sv.success { r.ok = false; r.note += "reference fix fails verify: \(sv.note.prefix(200)) " }
            if sv.testsTampered { r.ok = false; r.note += "reference fix edits test_paths " }
            for secs in [bs, ss] where secs > verifyBudgetS { r.note += String(format: "slow verify %.0fs ", secs); r.ok = false }
        } catch { r.ok = false; r.note += "\(error)" }
        return r
    }

    public static func render(_ rs: [ValidationResult]) -> String {
        func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
        var out = pad("ID", 9) + pad("CLASS", 17) + pad("BROKEN", 13) + pad("SOLVED", 13) + pad("SECS", 11) + "RESULT\n"
        for r in rs {
            out += pad(r.id, 9) + pad(r.taskClass, 17) + pad(r.broken, 13) + pad(r.solved, 13)
                + pad(String(format: "%.0f/%.0f", r.brokenSecs, r.solvedSecs), 11) + (r.ok ? "OK" : "BAD") + (r.note.isEmpty ? "" : "  " + r.note) + "\n"
        }
        out += "\(rs.filter(\.ok).count)/\(rs.count) ok\n"
        return out
    }

    // MARK: prepare

    /// Recomputes tree_sha256, test_sha256 (from test_paths) and snapshot_bytes in each task.json and regenerates
    /// manifest.json from the tasks present. With `write == false` only reports mismatches.
    public static func prepare(root: URL, tasks: [LoadedTask], write: Bool, scratch: URL) -> [String] {
        var report: [String] = []
        var manifestTasks: [[String: Any]] = []
        var counts: [String: Int] = [:], langs: [String: Int] = [:], balance: [String: [String: Int]] = [:]
        for t in tasks {
            let tj = t.dir.appendingPathComponent("task.json")
            guard let data = try? Data(contentsOf: tj), var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let src = t.snapshotSource() else { report.append("\(t.id): unreadable"); continue }
            let dst = scratch.appendingPathComponent(t.id)
            guard (try? Verifier.extractSnapshot(src, into: dst)) != nil else { report.append("\(t.id): cannot extract snapshot"); continue }
            let tree = Verifier.treeSha(dst)
            var tests: [String: String] = [:]
            let paths = t.spec.testPaths.compactMap(Verifier.safeRel)
            tests = Verifier.hashPaths(dst, paths)
            let size = ((try? FileManager.default.attributesOfItem(atPath: src.path)[.size]) as? NSNumber)?.intValue ?? 0
            if (obj["tree_sha256"] as? String) != tree { report.append("\(t.id): tree_sha256 \(write ? "updated" : "MISMATCH")") }
            if (obj["test_sha256"] as? [String: String] ?? [:]) != tests { report.append("\(t.id): test_sha256 \(write ? "updated" : "MISMATCH")") }
            if write {
                obj["tree_sha256"] = tree; obj["test_sha256"] = tests; obj["snapshot_bytes"] = size
                if obj["snapshot"] == nil { obj["snapshot"] = src.lastPathComponent }
                if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                    try? (d + Data("\n".utf8)).write(to: tj)
                }
            }
            counts[t.spec.taskClass, default: 0] += 1
            let lang = (obj["language"] as? String) ?? "?"
            langs[lang, default: 0] += 1
            balance[lang, default: [:]][t.spec.taskClass, default: 0] += 1
            manifestTasks.append(["id": t.id, "class": t.spec.taskClass, "language": lang, "license": obj["license"] ?? "",
                                  "repo": obj["repo"] ?? "", "base_commit": obj["base_commit"] ?? "", "tree_sha256": tree])
        }
        if write {
            let manifest: [String: Any] = ["version": 2, "counts": counts, "languages": langs, "balance": balance, "tasks": manifestTasks]
            if let d = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try? (d + Data("\n".utf8)).write(to: root.appendingPathComponent("manifest.json"))
            }
            report.append("manifest.json: \(tasks.count) tasks, classes \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")), languages \(langs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
        return report
    }
}
