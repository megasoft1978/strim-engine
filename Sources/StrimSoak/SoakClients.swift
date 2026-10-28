import Foundation
import StrimAgentBench

/// One client run: which CLI, the prompt, the repo it works in, and where its output goes.
public struct ClientRequest: Sendable {
    public var client: String
    public var prompt: String
    public var repo: String
    public var background: Bool
    public var timeout: Double
    /// Output files are `<logBase>.stdout` and `<logBase>.stderr`.
    public var logBase: String
    /// Per-run scratch dir (client HOME, TMPDIR and sandbox write root). Created by the caller, outside the repo.
    public var scratch: String

    public init(client: String, prompt: String, repo: String, background: Bool, timeout: Double, logBase: String,
                scratch: String) {
        self.client = client; self.prompt = prompt; self.repo = repo; self.background = background
        self.timeout = timeout; self.logBase = logBase; self.scratch = scratch
    }
}

public struct ClientOutcome: Sendable {
    public var exitCode: Int32
    public var timedOut: Bool
    public var wall: Double
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, timedOut: Bool, wall: Double, stdout: String, stderr: String) {
        self.exitCode = exitCode; self.timedOut = timedOut; self.wall = wall; self.stdout = stdout; self.stderr = stderr
    }
}

/// Runs one client to completion (or the cap). The real implementation is `CLIClientLauncher`; tests use a stub.
public protocol ClientLauncher: Sendable {
    func launch(_ req: ClientRequest) throws -> ClientOutcome
}

public enum SoakArgvs {
    public static let priorityHeader = "x-strim-priority"  // read by strim serve: interactive (default) or background
    public static let tokenEnv = "STRIM_SOAK_TOKEN"

    /// Explicit client environment. Nothing is inherited from the host: no HOME, no credentials, no client config.
    public static func clientEnv(scratch: String, _ extra: [String: String]) -> [String: String] {
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "HOME": scratch + "/home",
            "TMPDIR": scratch + "/tmp",
            "LANG": "en_US.UTF-8",
        ]
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Claude Code, non-interactive, file tools only. There is deliberately no Bash tool: a prefix allowlist is not a
    /// boundary (`go test` runs arbitrary code, a writable .git/config runs code), so tests are run by the harness
    /// under its sandbox after the client finishes. The whole process also runs under sandbox-exec.
    public static func claudeArgv(prompt: String, modelId: String) -> [String] {
        [ "-p", prompt, "--model", modelId, "--output-format", "json",
          "--permission-mode", "dontAsk", "--no-session-persistence",
          "--tools", "Read,Edit,Write,Glob,Grep",
          "--allowedTools", "Read", "Edit", "Write", "Glob", "Grep",
          "--disallowedTools", "Bash", "WebFetch", "WebSearch", "Read(~/**)", "Edit(~/**)", "Write(~/**)"]
    }

    public static func claudeEnv(port: Int, configDir: String, token: String, background: Bool, scratch: String) -> [String: String] {
        var env = clientEnv(scratch: scratch, [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)",
            "ANTHROPIC_AUTH_TOKEN": token,
            "CLAUDE_CONFIG_DIR": configDir,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_AUTOUPDATER": "1",
            // Claude Code's scratch defaults to /tmp/claude-<uid>, which the sandbox denies: keep it inside the run scratch.
            ClaudeSandbox.claudeTmpEnvVar: scratch + "/claude-tmp",
        ])
        if background { env["ANTHROPIC_CUSTOM_HEADERS"] = "\(priorityHeader): background" }
        return env
    }

    /// Codex exec against a custom Responses provider pointing at strim serve. The shell tools are switched off, so
    /// the model edits through apply_patch only and cannot execute code. The token reaches the client by env only.
    public static func codexArgv(port: Int, repo: String, prompt: String, modelId: String, background: Bool) -> [String] {
        let headers = background ? ", http_headers={\"\(priorityHeader)\"=\"background\"}" : ""
        let prov = "model_providers.strim={name=\"strim\", base_url=\"http://127.0.0.1:\(port)/v1\", "
            + "env_key=\"\(tokenEnv)\", wire_api=\"responses\"\(headers)}"
        return ["exec", "--json", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check",
                "-C", repo, "-s", "workspace-write", "-m", modelId,
                "-c", "model_provider=\"strim\"", "-c", prov, "-c", "approval_policy=\"never\"",
                "-c", "features.shell_tool=false", "-c", "features.unified_exec=false",
                "--", prompt]
    }

    public static func codexEnv(codexHome: String, token: String, scratch: String) -> [String: String] {
        clientEnv(scratch: scratch, ["CODEX_HOME": codexHome, tokenEnv: token])
    }
}

/// Real launcher: spawns `claude -p` or `codex exec` in its own process group under sandbox-exec (writes only in the
/// task repo, the run scratch and the client's own isolated config dir; home and secret reads denied; network only
/// to the local strim serve port), with an explicit environment. Fails closed when sandbox-exec is missing.
public struct CLIClientLauncher: ClientLauncher {
    public let port: Int
    public let modelId: String
    public let claudeBin: String
    public let codexBin: String
    public let claudeConfigDir: String
    public let codexHome: String
    public let token: String
    public let home: String
    public let sandboxExec: String

    public init(port: Int, modelId: String, claudeBin: String, codexBin: String,
                claudeConfigDir: String, codexHome: String, token: String,
                home: String = NSHomeDirectory(), sandboxExec: String = Verifier.sandboxExec) {
        self.port = port; self.modelId = modelId; self.claudeBin = claudeBin; self.codexBin = codexBin
        self.claudeConfigDir = claudeConfigDir; self.codexHome = codexHome; self.token = token
        self.home = home; self.sandboxExec = sandboxExec
    }

    /// The run's own config dir inside its scratch. A fresh copy of the host-owned template per run: the template is
    /// never mounted, so a client cannot leave settings, hooks or credentials behind for the next run.
    func runConfigDir(_ req: ClientRequest) -> String {
        realPath(req.scratch) + (req.client == "claude" ? "/claude-config" : "/codex-home")
    }

    /// Copies the template into the run's config dir (replacing anything there). Returns the run dir.
    @discardableResult
    public func prepareConfig(_ req: ClientRequest) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: req.scratch, withIntermediateDirectories: true)
        let dest = runConfigDir(req)
        let template = req.client == "claude" ? claudeConfigDir : codexHome
        try? fm.removeItem(atPath: dest)
        if fm.fileExists(atPath: template) { try fm.copyItem(atPath: template, toPath: dest) }
        else { try fm.createDirectory(atPath: dest, withIntermediateDirectories: true) }
        return dest
    }

    /// Final argv, env and sandbox profile for a request.
    public func plan(_ req: ClientRequest) -> (argv: [String], env: [String: String], profile: String) {
        let isClaude = req.client == "claude"
        let bin = isClaude ? claudeBin : codexBin
        let cfg = runConfigDir(req)
        let inner: [String]
        let env: [String: String]
        if isClaude {
            inner = [claudeBin] + SoakArgvs.claudeArgv(prompt: req.prompt, modelId: modelId)
            env = SoakArgvs.claudeEnv(port: port, configDir: cfg, token: token, background: req.background, scratch: req.scratch)
        } else {
            inner = [codexBin] + SoakArgvs.codexArgv(port: port, repo: req.repo, prompt: req.prompt,
                                                    modelId: modelId, background: req.background)
            env = SoakArgvs.codexEnv(codexHome: cfg, token: token, scratch: req.scratch)
        }
        let profile = ClaudeSandbox.profile(workdir: req.repo, runDir: req.scratch, net: .loopback(port: UInt16(port)),
                                            claudeBin: bin, home: home, allowPrefsDaemon: !isClaude)
        return ([sandboxExec, "-p", profile] + inner, env, profile)
    }

    public func launch(_ req: ClientRequest) throws -> ClientOutcome {
        guard FileManager.default.isExecutableFile(atPath: sandboxExec) else {
            throw SoakError.io("sandbox-exec unavailable at \(sandboxExec): refusing to run a client unsandboxed")
        }
        for d in ["home", "tmp", "claude-tmp"] {
            try? FileManager.default.createDirectory(atPath: req.scratch + "/" + d, withIntermediateDirectories: true)
        }
        try prepareConfig(req)
        let p = plan(req)
        let t0 = Date()
        let child = try SoakChild.spawn(argv: p.argv, env: p.env, cwd: req.repo, stdoutPath: req.logBase + ".stdout",
                                        stderrPath: req.logBase + ".stderr", append: false)
        var timedOut = false
        var rc: Int32?
        while rc == nil {
            rc = child.poll()
            if rc != nil { break }
            // Cap reached or Ctrl-C: the whole group goes, so no client keeps working after the harness moved on.
            if Interrupt.requested { rc = child.kill(); break }
            if Date().timeIntervalSince(t0) > req.timeout { timedOut = true; rc = child.kill(); break }
            usleep(50_000)
        }
        let wall = Date().timeIntervalSince(t0)
        let out = (try? String(contentsOfFile: req.logBase + ".stdout", encoding: .utf8)) ?? ""
        let err = (try? String(contentsOfFile: req.logBase + ".stderr", encoding: .utf8)) ?? ""
        return ClientOutcome(exitCode: rc ?? -1, timedOut: timedOut, wall: wall, stdout: out, stderr: err)
    }
}

/// Parses a client's stdout into the row fields the summary reads (`client_turns`, `result_snippet`, ...).
public enum SoakClientOutput {
    public static func parse(client: String, stdout: String) -> [String: Any] {
        var info: [String: Any] = ["client_turns": NSNull(), "client_is_error": NSNull(),
                                   "client_subtype": NSNull(), "result_snippet": NSNull(),
                                   "client_error_events": [String]()]
        if client == "claude" {
            guard let data = stdout.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return info }
            info["client_turns"] = obj["num_turns"] ?? NSNull()
            info["client_is_error"] = obj["is_error"] ?? NSNull()
            info["client_subtype"] = obj["subtype"] ?? NSNull()
            // A non-string result is not expected from the CLI, so it is blank here.
            info["result_snippet"] = String(((obj["result"] as? String) ?? "").prefix(300))
            return info
        }
        var turns: Int?
        var errors: [String] = []
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let typ = ev["type"] as? String
            let item = ev["item"] as? [String: Any] ?? [:]
            if typ == "turn.completed" { turns = (turns ?? 0) + 1 }
            else if typ == "error" || typ == "turn.failed" { errors.append(String(String(line).prefix(200))) }
            else if typ == "item.completed", item["type"] as? String == "agent_message" {
                info["result_snippet"] = String(((item["text"] as? String) ?? "").prefix(300))
            }
        }
        info["client_turns"] = turns.map { $0 as Any } ?? NSNull()
        info["client_error_events"] = errors
        return info
    }
}

/// `str()`-style text for the JSON values the client outputs carry (strings verbatim, null as "None").
func pyStr(_ v: Any?) -> String {
    switch v {
    case nil, is NSNull: return "None"
    case let s as String: return s
    case let b as Bool: return b ? "True" : "False"
    case let n as NSNumber: return n.stringValue
    default: return String(describing: v!)
    }
}
