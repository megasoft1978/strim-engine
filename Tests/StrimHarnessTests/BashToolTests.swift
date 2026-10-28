import Testing
import Foundation
import StrimTemplate
@testable import StrimHarness

@Suite struct BashToolTests {
    private struct Env {
        let base: String, work: String, tmp: String
        let tool: BashTool
        var ctx: ToolContext
    }

    private func make(access: AccessLevel = .write, sandboxed: Bool = true) throws -> Env {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("strim-bt-\(UUID().uuidString)").path
        let work = base + "/work", tmp = base + "/tmp"
        for d in [work, tmp] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let runner = BashTool.makeRunner(workspaceRoot: work, access: access, jobTmp: tmp, sandboxed: sandboxed)
        return Env(base: base, work: work, tmp: tmp, tool: BashTool(runner: runner), ctx: ToolContext(root: work, access: access))
    }

    private func run(_ e: Env, _ cmd: String, timeout: Int? = nil) async throws -> ToolResult {
        var args: [String: OrderedJSON] = ["command": .string(cmd)]
        if let timeout { args["timeout_s"] = .int(timeout) }
        return try await e.tool.run(args, context: e.ctx)
    }

    @Test func alwaysEndsWithExitCodeLine() async throws {
        let e = try make(); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let ok = try await run(e, "echo hi")
        #expect(ok.output == "hi\n[exit code: 0]" && !ok.isError)
        let bad = try await run(e, "echo oops; exit 3")
        #expect(bad.output.hasSuffix("[exit code: 3]") && bad.isError)
        let silent = try await run(e, "true")
        #expect(silent.output == "[exit code: 0]")
        // The loop parses the exit code out of the text.
        #expect(Compaction.exitCode(output: bad.output, isError: bad.isError) == 3)
    }

    @Test func timeoutMarker() async throws {
        let e = try make(); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let t0 = Date()
        let r = try await run(e, "echo start; sleep 20", timeout: 1)
        #expect(Date().timeIntervalSince(t0) < 10)
        #expect(r.output.contains("[timed out]") && r.output.contains("start"))
        #expect(r.output.hasSuffix("]") && r.output.split(separator: "\n").last!.hasPrefix("[exit code:"))
        #expect(r.isError)
    }

    @Test func truncationMarkerAndCap() async throws {
        let e = try make(); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let r = try await run(e, "yes 'some output line' | head -n 20000")
        #expect(r.output.contains("[output truncated]"))
        #expect(r.output.utf8.count < BashTool.outputCap + 200)
        #expect(r.output.hasSuffix("[exit code: 0]"))
    }

    @Test func hostEnvironmentIsNotVisible() async throws {
        let e = try make(); defer { try? FileManager.default.removeItem(atPath: e.base) }
        setenv("STRIM_BT_HOST_VAR", "leaky-host-value", 1)
        defer { unsetenv("STRIM_BT_HOST_VAR") }
        let r = try await run(e, "env")
        #expect(!r.output.contains("leaky-host-value") && !r.output.contains("STRIM_BT_HOST_VAR"))
        #expect(r.output.contains("HOME=" + e.tmp + "/home"))
    }

    @Test func commandAndOutputAreRedacted() async throws {
        let e = try make(); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let token = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"
        // Output built at run time so only the output (not the command text) contains the token.
        let r = try await run(e, "printf 'ghp_%s' a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8")
        #expect(!r.output.contains(token) && r.output.contains("[REDACTED]"))
        // A secret typed into the command is scrubbed before it runs.
        let r2 = try await run(e, "echo \(token)")
        #expect(!r2.output.contains(token))
    }

    @Test func writeAccessWritesWorkspaceOnly() async throws {
        let e = try make(access: .write); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let r = try await run(e, "echo a > f.txt && echo b > \(e.tmp)/t.txt && echo c > \(e.base)/outside.txt")
        #expect(r.isError)
        #expect(FileManager.default.fileExists(atPath: e.work + "/f.txt"))
        #expect(FileManager.default.fileExists(atPath: e.tmp + "/t.txt"))
        #expect(!FileManager.default.fileExists(atPath: e.base + "/outside.txt"))
    }

    @Test func readAccessCannotWriteWorkspace() async throws {
        let e = try make(access: .read); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let r = try await run(e, "echo a > f.txt")
        #expect(r.isError && !FileManager.default.fileExists(atPath: e.work + "/f.txt"))
        let r2 = try await run(e, "echo a > \(e.tmp)/ok.txt")
        #expect(!r2.isError && FileManager.default.fileExists(atPath: e.tmp + "/ok.txt"))
    }

    @Test func emptyCommandIsError() async throws {
        let e = try make(sandboxed: false); defer { try? FileManager.default.removeItem(atPath: e.base) }
        let r = try await e.tool.run(["command": .string("  ")], context: e.ctx)
        #expect(r.isError)
        let r2 = try await e.tool.run([:], context: e.ctx)
        #expect(r2.isError)
    }

    @Test func timeoutParsingClamps() {
        #expect(BashTool.timeout(from: nil) == 120)
        #expect(BashTool.timeout(from: .int(5)) == 5)
        #expect(BashTool.timeout(from: .int(100_000)) == 600)
        #expect(BashTool.timeout(from: .int(0)) == 120)
        #expect(BashTool.timeout(from: .int(-4)) == 120)
        #expect(BashTool.timeout(from: .double(2.5)) == 2.5)
        #expect(BashTool.timeout(from: .string("30")) == 30)
        #expect(BashTool.timeout(from: .string("abc")) == 120)
    }
}
