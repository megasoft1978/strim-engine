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
    /// Refuse language-runner command lines the paid arms' `runtests` grammar would refuse (`ToolchainGuard`).
    private let guardToolchains: Bool

    public init(runner: CommandRunner, guardToolchains: Bool = true) { self.runner = runner; self.guardToolchains = guardToolchains }

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
                                  sandboxed: Bool = true, home: String = NSHomeDirectory(),
                                  hostID: String = HostIdentity.id(for: HostIdentity.defaultRoot)) -> ProcessRunner {
        let profile = jobProfile(workspaceRoot: workspaceRoot, access: access, jobTmp: jobTmp, gitWritable: gitWritable,
                                 gitControlDirs: gitControlDirs, home: home)
        return ProcessRunner(profile: profile, sandboxed: sandboxed, toolchains: true, hostID: hostID)
    }

    /// The job sandbox profile: default-deny reads of the home, plus read-only access to the three version roots the language
    /// runners live in (`Toolchains.readable`: .nvm/versions, .rustup/toolchains, .rbenv/versions; never ~/.cargo, ~/.npmrc, caches or config).
    public static func jobProfile(workspaceRoot: String, access: AccessLevel, jobTmp: String, gitWritable: [String] = [],
                                  gitControlDirs: [String] = [], home: String = NSHomeDirectory()) -> SandboxProfile {
        SandboxProfile(access: access, writableRoots: access == .write ? [workspaceRoot] : [], jobTmp: jobTmp, home: home,
                       gitWritable: gitWritable, gitControlDirs: gitControlDirs, extraReadable: Toolchains.readable(home: home))
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
        if guardToolchains, let why = ToolchainGuard.check(command) {
            return ToolResult(output: "bash: refused: \(why)\n[exit code: 64]", isError: true)
        }
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
