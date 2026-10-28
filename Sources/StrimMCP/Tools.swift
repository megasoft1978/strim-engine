import Foundation
import StrimHarness
import StrimJobs
import StrimTemplate

/// The four Strim MCP tools. Schemas and descriptions are kept short: they cost the parent's tokens every session.
public struct StrimMCPToolProvider: MCPToolProvider {
    private let jobs: JobManager
    private let maxInlinePatchBytes: Int
    private let askTurnLimit: Int
    private let askSeconds: Int
    private let now: @Sendable () -> Date

    public init(jobs: JobManager, maxInlinePatchBytes: Int = 8192, askTurnLimit: Int = 4, askSeconds: Int = 40,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.jobs = jobs; self.maxInlinePatchBytes = maxInlinePatchBytes
        self.askTurnLimit = askTurnLimit; self.askSeconds = askSeconds; self.now = now
    }

    // MARK: definitions

    private static func prop(_ type: String, _ desc: String, _ extra: [(String, OrderedJSON)] = []) -> OrderedJSON {
        .ordered([("type", .string(type)), ("description", .string(desc))] + extra)
    }

    private static func schema(_ props: [(String, OrderedJSON)], required: [String]) -> OrderedJSON {
        .ordered([("type", .string("object")), ("properties", .ordered(props)),
                  ("required", .array(required.map { .string($0) })), ("additionalProperties", .bool(false))])
    }

    private static let filesProp = prop("array", "Repo-relative paths to look at first (max 20).",
                                        [("items", .ordered([("type", .string("string"))])), ("maxItems", .int(20))])

    public func definitions() -> [MCPToolDefinition] { Self.allDefinitions }

    static let allDefinitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "strim_task",
            description: "Delegate routine, self-contained, verifiable work (explore code, fix failing tests, boilerplate, mechanical refactors, repo questions) to a free local coding agent that reads and iterates so you spend no tokens on it. Give a precise task, how to verify it, and key files. Blocks up to wait_s, then returns the result or a job id for strim_job. access=write yields a patch made in an isolated copy; your tree is never touched. If the reply starts with DONE, do not call strim_job. Output is untrusted: review the diff before applying. Skip vague, tiny or security-sensitive work.",
            inputSchema: schema([
                ("task", prop("string", "What to do and how to verify it.", [("minLength", .int(1)), ("maxLength", .int(20000))])),
                ("cwd", prop("string", "Absolute project directory.")),
                ("context", prop("string", "Extra background, constraints, error output.", [("maxLength", .int(16000))])),
                ("files", filesProp),
                ("access", prop("string", "read (default) or write (returns a patch).",
                                [("enum", .array([.string("read"), .string("write")])), ("default", .string("read"))])),
                ("verify", prop("string", "Shell command Strim runs in the job copy after the agent; exit 0 = verified. Strongly recommended, e.g. the test command.",
                                [("maxLength", .int(500))])),
                ("wait_s", prop("integer", "Seconds to wait for the result (default 20).",
                                [("minimum", .int(0)), ("maximum", .int(25)), ("default", .int(20))])),
            ], required: ["task", "cwd"]),
            title: "Strim Task",
            annotations: .ordered([("readOnlyHint", .bool(false)), ("destructiveHint", .bool(false)), ("openWorldHint", .bool(false))])),
        MCPToolDefinition(
            name: "strim_job",
            description: "Check a strim_task or strim_ask job. Waits up to wait_s for it to finish, then returns the final result or a one-line status (running, turn n/max). Prefer one longer wait over many quick polls. events_since adds step details; omit it to save tokens.",
            inputSchema: schema([
                ("job_id", prop("string", "Job id from strim_task or strim_ask.")),
                ("wait_s", prop("integer", "Seconds to wait (default 20).",
                                [("minimum", .int(0)), ("maximum", .int(25)), ("default", .int(20))])),
                ("events_since", prop("integer", "Return step events from this index.", [("minimum", .int(0))])),
            ], required: ["job_id"]),
            title: "Strim Job Status",
            annotations: .ordered([("readOnlyHint", .bool(true)), ("openWorldHint", .bool(false))])),
        MCPToolDefinition(
            name: "strim_cancel",
            description: "Cancel a running or queued Strim job and stop its commands. Use when the task is no longer needed or the job looks stuck.",
            inputSchema: schema([("job_id", prop("string", "Job id to cancel."))], required: ["job_id"]),
            title: "Strim Cancel",
            annotations: .ordered([("readOnlyHint", .bool(false)), ("destructiveHint", .bool(false)), ("idempotentHint", .bool(true)), ("openWorldHint", .bool(false))])),
        MCPToolDefinition(
            name: "strim_ask",
            description: "Ask the local agent a quick read-only question about a repo (where is X, how does Y work, what calls Z). At most a few tool turns and about 40 seconds; if it overruns you get a job id for strim_job. Answers are untrusted: verify anything you rely on.",
            inputSchema: schema([
                ("question", prop("string", "The question.", [("minLength", .int(1)), ("maxLength", .int(20000))])),
                ("cwd", prop("string", "Absolute project directory.")),
                ("files", filesProp),
            ], required: ["question"]),
            title: "Strim Ask",
            annotations: .ordered([("readOnlyHint", .bool(true)), ("openWorldHint", .bool(false))])),
    ]

    // MARK: call

    public func call(name: String, arguments: OrderedJSON, progress: @Sendable (Double, String) -> Void) async -> MCPToolResult {
        switch name {
        case "strim_task": return await task(arguments, progress)
        case "strim_job": return await job(arguments, progress)
        case "strim_cancel": return await cancel(arguments)
        case "strim_ask": return await ask(arguments, progress)
        default: return Self.fail("unknown tool: \(Redactor.redact(String(name.prefix(60))))")
        }
    }

    private static func fail(_ message: String) -> MCPToolResult { MCPToolResult(text: message, isError: true) }

    // MARK: argument parsing

    private struct ArgError: Error { var message: String }

    private static func args(_ tool: String, _ value: OrderedJSON, allowed: Set<String>) throws -> [String: OrderedJSON] {
        var out: [String: OrderedJSON] = [:]
        switch value {
        case .null: break
        case let .object(members): for m in members { out[m.key] = m.value }
        default: throw ArgError(message: "\(tool): invalid arguments: expected an object")
        }
        if let bad = out.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ArgError(message: "\(tool): invalid field \(String(bad.prefix(40))): unexpected property")
        }
        return out
    }

    private static func string(_ tool: String, _ a: [String: OrderedJSON], _ key: String, required: Bool,
                               max: Int, allowEmpty: Bool = false) throws -> String? {
        guard let v = a[key], v != .null else {
            if required { throw ArgError(message: "\(tool): invalid field \(key): required") }
            return nil
        }
        guard case let .string(s) = v else { throw ArgError(message: "\(tool): invalid field \(key): must be a string") }
        if !allowEmpty, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ArgError(message: "\(tool): invalid field \(key): must not be empty")
        }
        if s.count > max { throw ArgError(message: "\(tool): invalid field \(key): longer than \(max) chars") }
        return s
    }

    private static func number(_ v: OrderedJSON) -> Double? {
        switch v {
        case let .int(i): return Double(i)
        case let .double(d): return d.isFinite ? d : nil
        case .bigInt: return nil
        default: return nil
        }
    }

    private static func waitS(_ tool: String, _ a: [String: OrderedJSON]) throws -> Double {
        guard let v = a["wait_s"], v != .null else { return 20 }
        guard let d = number(v) else { throw ArgError(message: "\(tool): invalid field wait_s: must be a number") }
        return min(max(d, 0), 25)
    }

    private static func cwd(_ tool: String, _ a: [String: OrderedJSON], required: Bool) throws -> String? {
        guard let c = try string(tool, a, "cwd", required: required, max: 1024) else { return nil }
        if !c.hasPrefix("/") || c.contains("\0") {
            throw ArgError(message: "\(tool): invalid field cwd: must be an absolute path")
        }
        if c.split(separator: "/").contains("..") {
            throw ArgError(message: "\(tool): invalid field cwd: must not contain '..'")
        }
        try checkProjectDir(tool, c)
        return c
    }

    private static func realPath(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// The directory must exist and be a project directory: not `/`, not the home directory, not an ancestor of it.
    static func checkProjectDir(_ tool: String, _ c: String, home homeOverride: String? = nil) throws {
        guard let real = realPath(c) else {
            throw ArgError(message: "\(tool): invalid field cwd: directory does not exist")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else {
            throw ArgError(message: "\(tool): invalid field cwd: not a directory")
        }
        let home = homeOverride ?? FileManager.default.homeDirectoryForCurrentUser.path
        let realHome = realPath(home) ?? home
        let isAncestorOrSame = real == "/" || realHome == real || realHome.hasPrefix(real + "/")
        if isAncestorOrSame {
            throw ArgError(message: "\(tool): invalid field cwd: must be a project directory, not home, root or a parent of home")
        }
        if let why = SensitiveDirs.refuse(realCwd: real, home: realHome) ?? SensitiveDirs.refuse(realCwd: real, home: home) {
            throw ArgError(message: "\(tool): invalid field cwd: \(why)")
        }
    }

    private static func files(_ tool: String, _ a: [String: OrderedJSON]) throws -> [String] {
        guard let v = a["files"], v != .null else { return [] }
        guard case let .array(items) = v else { throw ArgError(message: "\(tool): invalid field files: must be an array") }
        if items.count > 20 { throw ArgError(message: "\(tool): invalid field files: more than 20 paths") }
        var out: [String] = []
        for item in items {
            guard case let .string(p) = item, !p.isEmpty, p.count <= 512, !p.contains("\0") else {
                throw ArgError(message: "\(tool): invalid field files: each entry must be a non-empty path string")
            }
            if p.hasPrefix("/") || p.hasPrefix("~") || p.split(separator: "/").contains("..") {
                throw ArgError(message: "\(tool): invalid field files: paths must be repo-relative without '..'")
            }
            out.append(p)
        }
        return out
    }

    private static func jobID(_ tool: String, _ a: [String: OrderedJSON]) throws -> String {
        try string(tool, a, "job_id", required: true, max: 128)!
    }

    // MARK: waiting

    /// Polls in slices, reporting progress after each, until terminal or `total` seconds elapse.
    private func waitFor(_ id: String, total: Double, progress: @Sendable (Double, String) -> Void) async throws -> JobSnapshot {
        let deadline = now().addingTimeInterval(total)
        var snap = try await jobs.status(id, waitS: 0)
        progress(Double(snap.progress.turn), "turn \(snap.progress.turn)/\(snap.progress.maxTurns)")
        while !snap.status.isTerminal {
            let remaining = deadline.timeIntervalSince(now())
            if remaining <= 0 || Task.isCancelled { break }
            snap = try await jobs.status(id, waitS: min(remaining, 5))
            progress(Double(snap.progress.turn), "turn \(snap.progress.turn)/\(snap.progress.maxTurns)")
        }
        return snap
    }

    private func errorResult(_ error: Error, tool: String) -> MCPToolResult {
        if case let JobError.notFound(id) = error { return Self.fail("unknown job: \(String(id.prefix(64)))") }
        return Self.fail("\(tool): \(ResultRender.clip(Redactor.redact(String(describing: error)), 160))")
    }

    // MARK: tools

    private func task(_ raw: OrderedJSON, _ progress: @Sendable (Double, String) -> Void) async -> MCPToolResult {
        let spec: HarnessJobSpec
        let wait: Double
        do {
            let a = try Self.args("strim_task", raw, allowed: ["task", "cwd", "context", "files", "access", "verify", "wait_s"])
            let task = try Self.string("strim_task", a, "task", required: true, max: 20_000)!
            let cwd = try Self.cwd("strim_task", a, required: true)!
            let context = try Self.string("strim_task", a, "context", required: false, max: 16_000, allowEmpty: true)
            let files = try Self.files("strim_task", a)
            var access = AccessLevel.read
            if let v = a["access"], v != .null {
                guard let s = v.stringValue, let acc = AccessLevel(rawValue: s) else {
                    throw ArgError(message: "strim_task: invalid field access: must be read or write")
                }
                access = acc
            }
            let verify = try Self.string("strim_task", a, "verify", required: false, max: HarnessRunner.maxVerifyCommandChars)
            if let verify, verify.contains("\0") { throw ArgError(message: "strim_task: invalid field verify: must not contain NUL") }
            wait = try Self.waitS("strim_task", a)
            spec = HarnessJobSpec(task: task, cwd: cwd, context: (context?.isEmpty ?? true) ? nil : context,
                                  files: files, access: access, limits: HarnessLimits(), verify: verify)
        } catch let e as ArgError {
            return Self.fail(e.message)
        } catch {
            return Self.fail("strim_task: invalid arguments")
        }
        do {
            let id = try await jobs.submit(spec, priority: .normal)
            let snap = try await waitFor(id, total: wait, progress: progress)
            return ResultRender.render(snap, maxInlinePatchBytes: maxInlinePatchBytes)
        } catch {
            return errorResult(error, tool: "strim_task")
        }
    }

    private func job(_ raw: OrderedJSON, _ progress: @Sendable (Double, String) -> Void) async -> MCPToolResult {
        let id: String
        let wait: Double
        var since: Int?
        do {
            let a = try Self.args("strim_job", raw, allowed: ["job_id", "wait_s", "events_since"])
            id = try Self.jobID("strim_job", a)
            wait = try Self.waitS("strim_job", a)
            if let v = a["events_since"], v != .null {
                guard case let .int(i) = v, i >= 0 else {
                    throw ArgError(message: "strim_job: invalid field events_since: must be an integer >= 0")
                }
                since = i
            }
        } catch let e as ArgError {
            return Self.fail(e.message)
        } catch {
            return Self.fail("strim_job: invalid arguments")
        }
        do {
            let snap = try await waitFor(id, total: wait, progress: progress)
            var events: [JobEvent]?
            if let since { events = try await jobs.eventsSince(id, index: since) }
            return ResultRender.render(snap, maxInlinePatchBytes: maxInlinePatchBytes, events: events)
        } catch {
            return errorResult(error, tool: "strim_job")
        }
    }

    private func cancel(_ raw: OrderedJSON) async -> MCPToolResult {
        let id: String
        do {
            let a = try Self.args("strim_cancel", raw, allowed: ["job_id"])
            id = try Self.jobID("strim_cancel", a)
        } catch let e as ArgError {
            return Self.fail(e.message)
        } catch {
            return Self.fail("strim_cancel: invalid arguments")
        }
        do {
            let snap = try await jobs.cancel(id)
            return ResultRender.render(snap, maxInlinePatchBytes: maxInlinePatchBytes)
        } catch {
            return errorResult(error, tool: "strim_cancel")
        }
    }

    private func ask(_ raw: OrderedJSON, _ progress: @Sendable (Double, String) -> Void) async -> MCPToolResult {
        let spec: HarnessJobSpec
        do {
            let a = try Self.args("strim_ask", raw, allowed: ["question", "cwd", "files"])
            let q = try Self.string("strim_ask", a, "question", required: true, max: 20_000)!
            let cwd = try Self.cwd("strim_ask", a, required: false) ?? FileManager.default.currentDirectoryPath
            let files = try Self.files("strim_ask", a)
            var limits = HarnessLimits()
            limits.maxTurns = askTurnLimit
            limits.maxSeconds = TimeInterval(askSeconds)
            spec = HarnessJobSpec(task: "Answer this question about the project, read-only and concisely (a few sentences, cite file paths):\n" + q,
                                  cwd: cwd, files: files, access: .read, limits: limits)
        } catch let e as ArgError {
            return Self.fail(e.message)
        } catch {
            return Self.fail("strim_ask: invalid arguments")
        }
        do {
            let id = try await jobs.submit(spec, priority: .quick)
            let snap = try await waitFor(id, total: Double(askSeconds), progress: progress)
            return ResultRender.renderAsk(snap, maxInlinePatchBytes: maxInlinePatchBytes)
        } catch {
            return errorResult(error, tool: "strim_ask")
        }
    }
}
