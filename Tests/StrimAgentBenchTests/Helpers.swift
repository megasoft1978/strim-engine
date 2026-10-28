import Foundation
@testable import StrimAgentBench

func tempDir(_ name: String = "t") -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentbench-test-\(name)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func write(_ url: URL, _ s: String) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! s.write(to: url, atomically: true, encoding: .utf8)
}

func repoRoot() -> URL {
    var u = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { u.deleteLastPathComponent() }
    return u
}

func row(_ id: String, _ cls: String, _ arm: Arm, rep: Int = 1, ok: Bool = true, cost: Double? = nil) -> LedgerRow {
    var r = LedgerRow(taskId: id, taskClass: cls, arm: arm, rep: rep, success: ok)
    r.parentCostUsd = cost
    if cost != nil { r.parentTotal = 1000 }
    r.wallS = 10
    return r
}

/// Task dir with a tiny snapshot dir: tests/ (oracle) and src.txt.
func makeTask(_ root: URL, id: String = "t-01", verify: String = "grep -q fixed src.txt && test -f tests/check.txt",
              noEdit: Bool = false) -> LoadedTask {
    let dir = root.appendingPathComponent("tasks/\(id)")
    write(dir.appendingPathComponent("snapshot/src.txt"), "broken\n")
    write(dir.appendingPathComponent("snapshot/tests/check.txt"), "oracle\n")
    var spec = TaskSpec(id: id, taskClass: "test-fix", prompt: "fix it", verifyCmd: verify, testPaths: ["tests"], noEdit: noEdit)
    spec.snapshot = "snapshot"
    return LoadedTask(spec: spec, dir: dir)
}

final class ScriptExecutor: ArmExecutor {
    var calls = 0
    let body: (RunContext) -> ArmOutcome
    init(_ body: @escaping (RunContext) -> ArmOutcome) { self.body = body }
    func execute(_ ctx: RunContext) -> ArmOutcome { calls += 1; return body(ctx) }
}
