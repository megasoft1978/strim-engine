import Foundation
import StrimTemplate

/// The `bash` tool. Commands run through a `CommandRunner` (a sandboxed `ProcessRunner` in production),
/// never with the host environment. The output always ends with `[exit code: N]` because `AgentLoop`
/// derives command exit codes from the output text; `[timed out]` / `[output truncated]` precede it.
public struct BashTool: HarnessTool {
    public static let defaultTimeout: TimeInterval = 120
    public static let maxTimeout: TimeInterval = 600
    /// Raw output cap handed to the runner (head + tail kept); the loop then shows at most 8K chars.
    public static let outputCap = 64 * 1024

    private let runner: CommandRunner

    public init(runner: CommandRunner) { self.runner = runner }

    public var name: String { "bash" }

    public var spec: ToolSpec {
        ToolSpec(name: "bash",
                 description: "Run a shell command in the workspace root (no network, no stdin). Use it to build, run tests "
                    + "and inspect state; prefer read_file, grep and edit_file for files. Output is merged stdout and stderr "
                    + "and ends with [exit code: N]. Default timeout 120 s, maximum 600 s.",
                 parameters: .ordered([
                    ("type", .string("object")),
                    ("properties", .ordered([
                        ("command", .ordered([("type", .string("string")), ("description", .string("Shell command, run with bash -c."))])),
                        ("timeout_s", .ordered([("type", .string("integer")), ("description", .string("Timeout in seconds. Default 120, max 600."))])),
                    ])),
                    ("required", .array([.string("command")])),
                 ]))
    }

    /// Sandboxed runner for one job: `.write` makes the workspace root writable, `.read` only the job tmp.
    public static func makeRunner(workspaceRoot: String, access: AccessLevel, jobTmp: String,
                                  gitWritable: [String] = [], gitControlDirs: [String] = [],
                                  sandboxed: Bool = true) -> ProcessRunner {
        let profile = SandboxProfile(access: access, writableRoots: access == .write ? [workspaceRoot] : [],
                                     jobTmp: jobTmp, gitWritable: gitWritable, gitControlDirs: gitControlDirs)
        return ProcessRunner(profile: profile, sandboxed: sandboxed)
    }

    static func timeout(from v: OrderedJSON?) -> TimeInterval {
        var t: Double?
        switch v {
        case let .int(i)?: t = Double(i)
        case let .double(d)?: t = d
        case let .string(s)?: t = Double(s.trimmingCharacters(in: .whitespaces))
        default: break
        }
        guard let t, t.isFinite, t > 0 else { return defaultTimeout }
        return min(max(t, 1), maxTimeout)
    }

    public func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult {
        guard let raw = args["command"]?.stringValue, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(output: "error: 'command' must be a non-empty string", isError: true)
        }
        let command = Redactor.redact(raw)
        let timeout = Self.timeout(from: args["timeout_s"])
        let out: CommandOutput
        do {
            out = try await runner.run(command, cwd: context.root, env: [:], timeout: timeout, outputCap: Self.outputCap)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return ToolResult(output: Redactor.redact("error: could not run command: \(error)"), isError: true)
        }
        var text = Redactor.redact(out.output)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if out.timedOut { text += "[timed out]\n" }
        if out.truncated { text += "[output truncated]\n" }
        text += "[exit code: \(out.exitCode)]"
        return ToolResult(output: text, isError: out.exitCode != 0 || out.timedOut)
    }
}
