import Foundation
@testable import StrimEvolve

func repoRoot() -> URL {
    var u = URL(fileURLWithPath: #filePath)
    while u.path != "/" { u.deleteLastPathComponent(); if FileManager.default.fileExists(atPath: u.appendingPathComponent("Package.swift").path) { return u } }
    return u
}

func tempDir(_ name: String = "evolve") -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("strim-evolve-test-\(name)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Synthetic split: 3 classes x 10 tasks -> 18 train, 6 val, 6 test.
func syntheticTasks() -> [(id: String, taskClass: String)] {
    var t: [(String, String)] = []
    for (p, c) in [("tf", "test-fix"), ("qa", "repo-qa"), ("me", "mechanical-edit")] {
        for i in 1...10 { t.append((String(format: "%@-%02d", p, i), c)) }
    }
    return t.map { (id: $0.0, taskClass: $0.1) }
}

func mkRow(_ fp: String, _ split: SplitName, _ task: String, rep: Int = 1, pass: Bool, falseDone: Bool = false,
           tokens: Int = 1000, wall: Double = 10, phase: Phase = .search, infra: Bool = false) -> FitnessRow {
    var r = FitnessRow(candidate: fp, split: split, taskId: task, taskClass: "x", rep: rep, pass: pass, falseDone: falseDone)
    r.localTokens = tokens; r.wallS = wall; r.phase = phase; r.infraError = infra
    return r
}

/// Rows for `fp` on the given ids: passes where `passIds` contains the id (same outcome for every rep).
func mkRows(_ fp: String, _ split: SplitName, ids: [String], reps: Int, passIds: Set<String>, falseDoneIds: Set<String> = [],
            tokens: Int = 1000, wall: Double = 10) -> [FitnessRow] {
    ids.flatMap { id in (1...reps).map { mkRow(fp, split, id, rep: $0, pass: passIds.contains(id), falseDone: falseDoneIds.contains(id), tokens: tokens, wall: wall) } }
}
