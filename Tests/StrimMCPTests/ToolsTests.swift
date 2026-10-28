import Foundation
import Testing
import StrimHarness
import StrimJobs
import StrimTemplate
@testable import StrimMCP

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.lock(); isOpen = true; lock.unlock() }
    var opened: Bool { lock.lock(); defer { lock.unlock() }; return isOpen }
}

private let tmpDir: String = mkdir("strim-mcp-tests")
private let projDir: String = mkdir("strim-mcp-tests/proj")
private let spaceDir: String = mkdir("strim-mcp-tests/my proj")
private func mkdir(_ name: String) -> String {
    let p = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

private let fakeSecret = "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"

private func make(gate: Gate = Gate(), maxInline: Int = 8192, askSeconds: Int = 40)
    -> (StrimMCPToolProvider, JobManager, Gate) {
    let exec: JobExecutor = { spec, _, onEvent in
        let t = spec.task
        if t.contains("block") {
            onEvent(.turn(1))
            while !gate.opened {
                if Task.isCancelled { return HarnessJobResult(status: .cancelled, summary: "stopped") }
                try? await Task.sleep(for: .milliseconds(3))
            }
            return HarnessJobResult(status: .done, summary: "unblocked")
        }
        if t.contains("secret") {
            return HarnessJobResult(status: .done, summary: "found key \(fakeSecret) in env",
                                    filesChanged: [FileChange(path: "a.txt", added: 1, removed: 0)],
                                    patch: "+key = \(fakeSecret)\n", patchPath: "/jobs/x/patch.diff")
        }
        if t.contains("patchy") {
            return HarnessJobResult(status: .done, summary: "patched",
                                    filesChanged: [FileChange(path: "a.txt", added: 2, removed: 1)],
                                    patch: "+" + String(repeating: "x", count: 600) + "\n",
                                    patchPath: "/jobs/x/patch.diff", base: "abc123",
                                    commands: [CommandRecord(cmd: "swift test", exit: 0)])
        }
        if t.contains("limited") {
            return HarnessJobResult(status: .limit, summary: "turn limit reached", patchPath: "/jobs/x/patch.diff")
        }
        if t.contains("verified-task") {
            return HarnessJobResult(status: .done, summary: "saw verify=\(spec.verify ?? "nil")",
                                    verify: VerifyResult(status: spec.verify == nil ? .unverified : .verified, exitCode: spec.verify == nil ? nil : 0, outputTail: "ok"))
        }
        if t.contains("failed-verify") {
            return HarnessJobResult(status: .done, summary: "edited",
                                    verify: VerifyResult(status: .failed, exitCode: 1, outputTail: "FAIL"))
        }
        if t.contains("declineme") { return HarnessJobResult(status: .declined, summary: "needs design; " + String(repeating: "r", count: 400)) }
        if t.contains("failing") { return HarnessJobResult(status: .failed, summary: "engine exploded") }
        return HarnessJobResult(status: .done, summary: "ok: \(t.prefix(20))")
    }
    let jm = JobManager(executor: exec, pollInterval: .milliseconds(5))
    return (StrimMCPToolProvider(jobs: jm, maxInlinePatchBytes: maxInline, askSeconds: askSeconds), jm, gate)
}

private func obj(_ pairs: [(String, OrderedJSON)]) -> OrderedJSON { .ordered(pairs) }
private func call(_ p: StrimMCPToolProvider, _ name: String, _ args: OrderedJSON) async -> MCPToolResult {
    await p.call(name: name, arguments: args, progress: { _, _ in })
}
private func jobID(_ r: MCPToolResult) -> String {
    r.text.split(separator: " ").dropFirst(2).first.map { String($0.dropLast()) } ?? ""
}

@Suite struct ToolsTests {
    @Test func symlinkToHomeRejected() async {
        let link = (tmpDir as NSString).appendingPathComponent("homelink")
        try? FileManager.default.removeItem(atPath: link)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: NSHomeDirectory())
        let r = await call(make().0, "strim_task", obj([("task", .string("t")), ("cwd", .string(link))]))
        #expect(r.isError)
        #expect(r.text.contains("invalid field cwd"))
    }

    /// Claude Code forwards only structuredContent when present, so results must carry none: the text is the whole result.
    @Test func noStructuredContentAndTextIsComplete() async {
        let r = await call(make().0, "strim_task", obj([("task", .string("patchy")), ("cwd", .string(tmpDir)), ("wait_s", .int(5))]))
        #expect(r.structured == nil)
        #expect(r.text.contains("patched"))
        #expect(r.text.contains("apply: git -C"))
        #expect(r.text.contains("```diff"))
    }

    @Test func annotationsAndTitles() {
        let defs = Dictionary(uniqueKeysWithValues: make().0.definitions().map { ($0.name, $0) })
        for d in defs.values {
            #expect(d.title != nil)
            #expect(d.annotations?["openWorldHint"] == .bool(false))
        }
        #expect(defs["strim_ask"]?.annotations?["readOnlyHint"] == .bool(true))
        #expect(defs["strim_job"]?.annotations?["readOnlyHint"] == .bool(true))
        #expect(defs["strim_task"]?.annotations?["readOnlyHint"] == .bool(false))
        #expect(defs["strim_task"]?.annotations?["destructiveHint"] == .bool(false))
        #expect(defs["strim_cancel"]?.annotations?["idempotentHint"] == .bool(true))
        #expect(defs["strim_cancel"]?.annotations?["destructiveHint"] == .bool(false))
        #expect(defs["strim_task"]?.description.contains("If the reply starts with DONE, do not call strim_job.") == true)
    }

    @Test func definitionsShape() {
        let defs = make().0.definitions()
        #expect(defs.map(\.name) == ["strim_task", "strim_job", "strim_cancel", "strim_ask"])
        for d in defs {
            #expect(d.description.split(separator: " ").count <= 95, "\(d.name) description too long")
            #expect(d.inputSchema["additionalProperties"] == .bool(false))
            #expect(d.inputSchema["required"] != nil)
        }
        #expect(defs[0].inputSchema["required"] == .array([.string("task"), .string("cwd")]))
    }

    @Test func schemaGolden() {
        let text = make().0.definitions().map { "\($0.name)\n\($0.description)\n\($0.inputSchema.serialized())\n\($0.title ?? "")\n\($0.annotations?.serialized() ?? "")" }
            .joined(separator: "\n--\n")
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        // Updated deliberately: added titles, annotations and the DONE sentence; then the optional `verify` arg of strim_task. Schemas cost the parent's tokens every session. Update this hash deliberately when the surface changes.
        #expect(String(h, radix: 16) == "e6e74b18979440c4", "schema hash is \(String(h, radix: 16))")
    }

    /// tools/list payload (name, description, schema, title, annotations). Before `verify` it was 3315 bytes;
    /// the `verify` property added 188. Raise this bound only deliberately: it is re-read on every parent turn.
    @Test func toolsListSizeStaysBounded() {
        let bytes = make().0.definitions().map {
            "\($0.name)\($0.description)\($0.inputSchema.serialized())\($0.title ?? "")\($0.annotations?.serialized() ?? "")"
        }.joined().utf8.count
        #expect(bytes <= 3315 + 200, "tools/list is \(bytes) bytes")
        let verifyDesc = make().0.definitions()[0].inputSchema["properties"]?["verify"]?["description"]?.stringValue ?? ""
        #expect(verifyDesc.split(separator: " ").count <= 25)
    }

    @Test func verifyArgIsValidatedAndPassedThrough() async {
        let (p, _, _) = make()
        let base: [(String, OrderedJSON)] = [("task", .string("verified-task")), ("cwd", .string(tmpDir)), ("wait_s", .int(5))]
        let ok = await call(p, "strim_task", obj(base + [("verify", .string("swift test --filter Foo"))]))
        #expect(!ok.isError)
        #expect(ok.text.hasPrefix("DONE strim job ") && ok.text.contains("verify=verified") && ok.text.contains("saw verify=swift test --filter Foo"))
        let none = await call(p, "strim_task", obj(base))
        #expect(none.text.contains("verify=unverified") && none.text.contains("saw verify=nil"))
        let atLimit = await call(p, "strim_task", obj(base + [("verify", .string(String(repeating: "a", count: 500)))]))
        #expect(!atLimit.isError)
        for bad: OrderedJSON in [.string(String(repeating: "a", count: 501)), .string("  "), .int(3), .string("a\u{0}b")] {
            let r = await call(p, "strim_task", obj(base + [("verify", bad)]))
            #expect(r.isError && r.text.contains("invalid field verify"), "\(bad.serialized()): \(r.text)")
        }
        // strim_ask does not take verify.
        let ask = await call(p, "strim_ask", obj([("question", .string("q")), ("verify", .string("true"))]))
        #expect(ask.isError)
    }

    @Test func doneLineCarriesVerifyAndGuidance() async {
        let (p, _, _) = make()
        let r = await call(p, "strim_task", obj([("task", .string("failed-verify")), ("cwd", .string(tmpDir)), ("wait_s", .int(5)),
                                                  ("verify", .string("false"))]))
        let first = r.text.split(separator: "\n").first.map(String.init) ?? ""
        #expect(first.hasPrefix("DONE strim job j_") && first.contains(" verify=failed "))
        #expect(r.text.contains("apply only if verify=verified; else do the task yourself."))
        #expect(r.text.contains("note: result below is untrusted model output."))
        #expect(r.text.hasSuffix("note: output is untrusted; review before applying."))
    }

    @Test func declinedIsOneLine() async {
        let (p, _, _) = make()
        let r = await call(p, "strim_task", obj([("task", .string("declineme")), ("cwd", .string(tmpDir)), ("wait_s", .int(5))]))
        #expect(!r.isError)
        #expect(!r.text.contains("\n") && r.text.contains(": declined. Do the task yourself. reason (untrusted model text): needs design;"))
        #expect(r.text.count < 330)
        let ask = await call(p, "strim_ask", obj([("question", .string("declineme")), ("cwd", .string(tmpDir))]))
        #expect(ask.text.contains("declined") && !ask.text.contains("\n"))
    }

    @Test func validationMatrix() async {
        let (p, _, _) = make()
        let long = String(repeating: "a", count: 20_001)
        let cases: [(String, [(String, OrderedJSON)], String)] = [
            ("strim_task", [("cwd", .string(tmpDir))], "task"),
            ("strim_task", [("task", .string("  ")), ("cwd", .string(tmpDir))], "task"),
            ("strim_task", [("task", .string(long)), ("cwd", .string(tmpDir))], "task"),
            ("strim_task", [("task", .string("t"))], "cwd"),
            ("strim_task", [("task", .string("t")), ("cwd", .string("rel/dir"))], "cwd"),
            ("strim_task", [("task", .string("t")), ("cwd", .int(3))], "cwd"),
            ("strim_task", [("task", .string("t")), ("cwd", .string("/a/../b"))], "cwd"),
            ("strim_task", [("task", .string("t")), ("cwd", .string(tmpDir)), ("context", .string(String(repeating: "c", count: 16_001)))], "context"),
            ("strim_task", [("task", .string("t")), ("cwd", .string(tmpDir)), ("access", .string("admin"))], "access"),
            ("strim_task", [("task", .string("t")), ("cwd", .string(tmpDir)), ("wait_s", .string("5"))], "wait_s"),
            ("strim_task", [("task", .string("t")), ("cwd", .string(tmpDir)), ("files", .string("a"))], "files"),
            ("strim_task", [("task", .string("t")), ("cwd", .string(tmpDir)), ("files", .array([.string("/etc/passwd")]))], "files"),
            ("strim_task", [("task", .string("t")), ("cwd", .string(tmpDir)), ("files", .array([.string("../x")]))], "files"),
            ("strim_task", [("task", .string("t")), ("cwd", .string(tmpDir)), ("files", .array([.string("a/../../x")]))], "files"),
            ("strim_task", [("task", .string("t")), ("cwd", .string(tmpDir)), ("files", .array((0..<21).map { .string("f\($0)") }))], "files"),
            ("strim_task", [("task", .string("t")), ("cwd", .string(tmpDir)), ("bogus", .int(1))], "bogus"),
            ("strim_task", [("task", .string("t")), ("cwd", .string(NSHomeDirectory()))], "cwd"),
            ("strim_task", [("task", .string("t")), ("cwd", .string("/"))], "cwd"),
            ("strim_task", [("task", .string("t")), ("cwd", .string((NSHomeDirectory() as NSString).deletingLastPathComponent))], "cwd"),
            ("strim_task", [("task", .string("t")), ("cwd", .string("/definitely/not/here"))], "cwd"),
            ("strim_task", [("task", .string("t")), ("cwd", .string("/etc/hosts"))], "cwd"),
            ("strim_ask", [("question", .string("q")), ("cwd", .string(NSHomeDirectory()))], "cwd"),
            ("strim_ask", [("question", .string("q")), ("cwd", .string("/"))], "cwd"),
            ("strim_ask", [("question", .string("q")), ("cwd", .string("/definitely/not/here"))], "cwd"),
            ("strim_job", [], "job_id"),
            ("strim_job", [("job_id", .string("x")), ("events_since", .int(-1))], "events_since"),
            ("strim_job", [("job_id", .string("x")), ("wait_s", .bool(true))], "wait_s"),
            ("strim_cancel", [("job_id", .int(1))], "job_id"),
            ("strim_ask", [], "question"),
            ("strim_ask", [("question", .string("q")), ("cwd", .string("nope"))], "cwd"),
            ("strim_ask", [("question", .string("q")), ("files", .array([.string("../a")]))], "files"),
        ]
        for (tool, args, field) in cases {
            let r = await call(p, tool, obj(args))
            #expect(r.isError, "\(tool) \(field) should fail")
            #expect(r.text.contains("invalid field \(field)"), "\(tool): \(r.text)")
            #expect(!r.text.contains("\n"))
        }
        let nonObject = await call(p, "strim_task", .string("x"))
        #expect(nonObject.isError)
        let unknownTool = await call(p, "nope", obj([]))
        #expect(unknownTool.isError)
    }

    @Test func taskFinishesWithinWait() async {
        let (p, _, _) = make()
        let r = await call(p, "strim_task", obj([("task", .string("do it")), ("cwd", .string(projDir)), ("wait_s", .int(5))]))
        #expect(!r.isError)
        #expect(r.text.hasPrefix("DONE strim job "))
        #expect(r.text.contains("ok: do it"))
        #expect(r.structured == nil)
    }

    @Test func taskNotDoneIsOneShortLine() async {
        let (p, jm, gate) = make()
        let r = await call(p, "strim_task", obj([("task", .string("block")), ("cwd", .string(tmpDir)), ("wait_s", .int(0))]))
        #expect(!r.isError)
        #expect(r.text.count < 200)
        #expect(!r.text.contains("\n"))
        #expect(r.text.hasPrefix("strim job "))
        #expect(r.text.contains("turn "))
        #expect(r.structured == nil)
        gate.open()
        let id = jobID(r)
        let done = await call(p, "strim_job", obj([("job_id", .string(id)), ("wait_s", .int(5))]))
        #expect(done.text.hasPrefix("DONE"))
        _ = jm
    }

    @Test func negativeWaitClampsToZero() async {
        let (p, _, gate) = make()
        let t0 = Date()
        let r = await call(p, "strim_task", obj([("task", .string("block")), ("cwd", .string(tmpDir)), ("wait_s", .int(-5))]))
        #expect(Date().timeIntervalSince(t0) < 3)
        #expect(r.text.count < 200)
        gate.open()
    }

    @Test func progressReportedEveryPoll() async {
        let (p, _, gate) = make()
        let calls = Box2<[String]>([])
        let task = Task {
            await p.call(name: "strim_task", arguments: obj([("task", .string("block")), ("cwd", .string(tmpDir)), ("wait_s", .int(2))]),
                         progress: { _, m in calls.mutate { $0.append(m) } })
        }
        try? await Task.sleep(for: .milliseconds(100))
        gate.open()
        let r = await task.value
        #expect(r.text.hasPrefix("DONE"))
        #expect(!calls.value.isEmpty)
        #expect(calls.value.allSatisfy { $0.hasPrefix("turn ") && $0.contains("/40") })
    }

    @Test func jobUnknownAndEvents() async {
        let (p, _, gate) = make()
        let unknown = await call(p, "strim_job", obj([("job_id", .string("nope")), ("wait_s", .int(0))]))
        #expect(unknown.isError)
        #expect(unknown.text == "unknown job: nope")
        let cancelUnknown = await call(p, "strim_cancel", obj([("job_id", .string("nope"))]))
        #expect(cancelUnknown.isError)

        let t = await call(p, "strim_task", obj([("task", .string("block")), ("cwd", .string(tmpDir)), ("wait_s", .int(0))]))
        let id = jobID(t)
        try? await Task.sleep(for: .milliseconds(150))
        let ev = await call(p, "strim_job", obj([("job_id", .string(id)), ("wait_s", .int(0)), ("events_since", .int(0))]))
        #expect(ev.text.contains("#0"))
        let plain = await call(p, "strim_job", obj([("job_id", .string(id)), ("wait_s", .int(0))]))
        #expect(!plain.text.contains("#0"))
        #expect(!plain.text.contains("\n"))
        gate.open()
    }

    @Test func cancelJob() async {
        let (p, jm, _) = make()
        let t = await call(p, "strim_task", obj([("task", .string("block")), ("cwd", .string(tmpDir)), ("wait_s", .int(0))]))
        let id = jobID(t)
        let c = await call(p, "strim_cancel", obj([("job_id", .string(id))]))
        #expect(!c.isError)
        #expect(c.text.contains("cancelled"))
        let snap = try? await jm.status(id, waitS: 0)
        #expect(snap?.status == .cancelled)
    }

    @Test func failedAndLimitRenderPlainly() async {
        let (p, _, _) = make()
        let f = await call(p, "strim_task", obj([("task", .string("failing")), ("cwd", .string(tmpDir)), ("wait_s", .int(5))]))
        #expect(f.text.contains(": failed"))
        #expect(f.text.contains("engine exploded"))
        #expect(f.text.split(separator: "\n").count <= 3)
        let l = await call(p, "strim_task", obj([("task", .string("limited")), ("cwd", .string(tmpDir)), ("wait_s", .int(5))]))
        #expect(l.text.contains(": limit"))
        #expect(l.text.contains("partial patch: /jobs/x/patch.diff"))
        #expect(!l.text.contains("apply:"))
    }

    @Test func doneRenderWithPatchCap() async {
        let args = obj([("task", .string("patchy")), ("cwd", .string(spaceDir)), ("wait_s", .int(5)), ("access", .string("write"))])
        let big = await call(make(maxInline: 100).0, "strim_task", args)
        #expect(big.text.contains("apply: git -C '\(spaceDir)' apply /jobs/x/patch.diff"))
        #expect(!big.text.contains("```diff"))
        #expect(big.structured == nil)
        #expect(big.text.count < 1200)
        let small = await call(make(maxInline: 8192).0, "strim_task", args)
        #expect(small.text.contains("```diff"))
        #expect(small.structured?["patch"] == nil)
        #expect(small.text.contains("files: a.txt +2/-1"))
        #expect(small.text.contains("swift test -> 0"))
        #expect(small.text.contains("untrusted"))
    }

    @Test func redactsSecrets() async {
        let (p, _, _) = make()
        let r = await call(p, "strim_task", obj([("task", .string("secret")), ("cwd", .string(tmpDir)), ("wait_s", .int(5))]))
        #expect(r.text.contains("[REDACTED]"))
        #expect(!r.text.contains(fakeSecret))
        let ser = r.structured?.serialized() ?? ""
        #expect(ser.contains(fakeSecret) == false)
    }

    @Test func askCompletes() async {
        let (p, _, _) = make()
        let r = await call(p, "strim_ask", obj([("question", .string("where is main?")), ("cwd", .string(tmpDir))]))
        #expect(!r.isError)
        #expect(r.text.contains("ok:"))
        #expect(r.structured == nil)
    }

    @Test func askOverrunBecomesJob() async {
        let (p, _, gate) = make(askSeconds: 1)
        // A running job occupies the single slot, so the ask stays queued past its wait.
        let t = await call(p, "strim_task", obj([("task", .string("block")), ("cwd", .string(tmpDir)), ("wait_s", .int(0))]))
        #expect(!t.isError)
        let r = await call(p, "strim_ask", obj([("question", .string("what is this?")), ("cwd", .string(tmpDir))]))
        #expect(!r.isError)
        #expect(r.text.hasPrefix("strim job "))
        #expect(r.text.contains(": queued"))
        #expect(r.text.count < 200)
        gate.open()
        let done = await call(p, "strim_job", obj([("job_id", .string(jobID(r))), ("wait_s", .int(5))]))
        #expect(done.text.contains("ok:"))
    }

    @Test func askUsesReadOnlyLimits() async {
        let seen = Box2<[HarnessJobSpec]>([])
        let exec: JobExecutor = { spec, _, _ in seen.mutate { $0.append(spec) }; return HarnessJobResult(status: .done, summary: "a") }
        let jm = JobManager(executor: exec, pollInterval: .milliseconds(5))
        let p = StrimMCPToolProvider(jobs: jm, askTurnLimit: 3, askSeconds: 7)
        _ = await call(p, "strim_ask", obj([("question", .string("q")), ("cwd", .string(tmpDir))]))
        _ = await call(p, "strim_task", obj([("task", .string("t")), ("cwd", .string(tmpDir)), ("wait_s", .int(3))]))
        let specs = seen.value
        #expect(specs.count == 2)
        #expect(specs[0].access == .read && specs[0].limits.maxTurns == 3)
        #expect(specs[1].access == .read && specs[1].limits.maxTurns == 40 && specs[1].limits.maxGeneratedTokens == 60_000)
    }
}

final class Box2<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

@Suite struct ToolsSensitiveCwdTests {
    @Test func checkProjectDirRefusesCredentialDirsUnderHome() throws {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("fakehome-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: h) }
        try FileManager.default.createDirectory(atPath: h + "/.strim", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: h + "/proj", withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try StrimMCPToolProvider.checkProjectDir("strim_ask", h + "/.strim", home: h) }
        #expect(throws: Never.self) { try StrimMCPToolProvider.checkProjectDir("strim_ask", h + "/proj", home: h) }
    }
}
