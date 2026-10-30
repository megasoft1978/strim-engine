import Foundation
import Testing
@testable import StrimAgentBench

let bunInstalled = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
    FileManager.default.isExecutableFile(atPath: "\($0)/bun")
}

@Suite struct RunLayoutSandboxTests {
    /// Benchmark run dirs are `$TMPDIR/strim-agentbench-<pid>/runs/<name>`: two levels below the temp root, unlike `tempDir`.
    @Test func listingGrantCoversRunDirAncestorsOnly() {
        let root = tempDir("sbx-list")
        let wroot = root.appendingPathComponent("strim-agentbench-1")
        let work = wroot.appendingPathComponent("runs/rx-01-H-1")
        try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let rules = Verifier.listingRules(work: work.path, home: NSHomeDirectory())
        #expect(rules.hasPrefix("(allow file-read-data"))
        #expect(rules.contains("(literal \"\(wroot.path)/runs\")"), "\(rules)")
        #expect(rules.contains("(literal \"\(wroot.path)\")"), "\(rules)")
        #expect(!rules.contains("(literal \"\(work.path)\")"), "the work dir itself is readable through its subpath rule")
        let tempRoot = String(NSTemporaryDirectory().dropLast())
        #expect(!rules.contains("(literal \"\(tempRoot)\")"), "the temp root is never listed")
        #expect(!rules.contains(NSHomeDirectory()), "the home is never listed")
        // No file reads are granted by the listing rule.
        #expect(!rules.contains("file-read*"))
    }

    @Test func listingGrantEmptyOutsideTempRoots() {
        let home = NSHomeDirectory()
        #expect(Verifier.listingRules(work: home + "/Desktop/proj/work", home: home) == "")
    }

    @Test(.enabled(if: bunInstalled)) func bunTestRunsInsideRunLayout() {
        let root = tempDir("sbx-bun")
        let work = root.appendingPathComponent("strim-agentbench-2/runs/t-01-H-1")
        let scratch = root.appendingPathComponent("out/runs/t-01-H-1/verify")
        let base = root.appendingPathComponent("base")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        write(work.appendingPathComponent("package.json"), "{}\n")
        write(work.appendingPathComponent("zz.test.js"),
              "import { test, expect } from 'bun:test';\ntest('ok', () => expect(1).toBe(1));\n")
        let spec = TaskSpec(id: "t-01", taskClass: "test-fix", prompt: "p", verifyCmd: "bun test")
        let v = Verifier.verify(task: spec, base: base, work: work, answer: nil, scratch: scratch)
        #expect(v.success, "\(v.note)")
        #expect(!v.note.contains("PermissionDenied"), "\(v.note)")
    }
}
