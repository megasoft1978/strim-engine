import Foundation
import StrimAdmission
import StrimEngine
import StrimTemplate

/// The `finish(summary, status)` tool. The loop reads `status` itself (ToolResult has no status field).
public struct FinishTool: HarnessTool {
    public init() {}
    public var name: String { "finish" }
    public var spec: ToolSpec {
        ToolSpec(name: "finish",
                 description: "Call when the task is complete (or cannot be completed). Give a short summary of what was done. "
                    + "If the task is unsuitable or too vague, call it at once with declined=true and a reason.",
                 parameters: .ordered([
                    ("type", .string("object")),
                    ("properties", .ordered([
                        ("summary", .ordered([("type", .string("string")), ("description", .string("What was done and the outcome."))])),
                        ("status", .ordered([("type", .string("string")), ("enum", .array([.string("done"), .string("failed")])),
                                             ("description", .string("done if the task is complete, failed if it could not be completed."))])),
                        ("declined", .ordered([("type", .string("boolean")), ("description", .string("true to refuse the task."))])),
                        ("reason", .ordered([("type", .string("string")), ("description", .string("Why it was declined."))])),
                    ])),
                    ("required", .array([.string("summary")])),
                 ]))
    }
    public func run(_ args: [String: OrderedJSON], context: ToolContext) async throws -> ToolResult {
        let s = args["summary"]?.stringValue ?? ""
        return ToolResult(output: "finished", finishSummary: s)
    }
}

/// Single-session agent loop over an `EngineClient`. Tools carry their own dependencies.
public final class AgentLoop: Sendable {
    let engine: EngineClient
    let tools: [HarnessTool]
    let systemPrompt: String
    let limits: HarnessLimits
    let date: String
    let clock: @Sendable () -> Date
    let compactionThreshold: Int
    let priority: Priority
    let maxTurnTokens: Int
    let requireFinish: Bool
    let verbatimTail: Int
    let knobs: HarnessKnobs

    /// - date: value for the env block (injected for determinism).
    /// - compactionThreshold: estimated prompt tokens above which a new session with a summary replaces the old.
    /// - requireFinish: a prose-only reply (no tool call) is not completion: nudge once to call `finish`, then end
    ///   the run as `.limit` with a `no_finish` summary. Off for chat, where prose ends the user turn.
    /// - verbatimTail: how many of the latest assistant/tool exchanges survive a compaction verbatim (0 = log only).
    /// - knobs: pack knobs (result cap, compaction threshold and guidance, thinking policy, temperature, seed). The
    ///   default value is today's behaviour exactly; a set `compactionThreshold` knob overrides `compactionThreshold`.
    public init(engine: EngineClient, tools: [HarnessTool], systemPrompt: String, limits: HarnessLimits = HarnessLimits(),
                date: String = "", clock: @escaping @Sendable () -> Date = { Date() },
                compactionThreshold: Int = 28_000, priority: Priority = .background, maxTurnTokens: Int = 4096,
                requireFinish: Bool = false, verbatimTail: Int = 4, knobs: HarnessKnobs = HarnessKnobs()) {
        self.engine = engine
        self.tools = tools.contains { $0.name == "finish" } ? tools : tools + [FinishTool()]
        self.systemPrompt = systemPrompt
        self.limits = limits
        self.date = date
        self.clock = clock
        self.knobs = knobs
        self.compactionThreshold = knobs.compactionThreshold == nil && knobs.context == .standard ? compactionThreshold : knobs.compactionTokens
        self.priority = priority
        self.maxTurnTokens = maxTurnTokens
        self.requireFinish = requireFinish
        self.verbatimTail = max(0, verbatimTail)
    }

    fileprivate final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var id: SessionID?
        func set(_ s: SessionID?) { lock.withLock { id = s } }
        func get() -> SessionID? { lock.withLock { id } }
    }

    private struct PendingCall {
        var name: String
        var args: [OrderedJSON.Member] = []
    }

    private struct TurnOutput {
        var text = ""
        var reasoning = ""
        var toolCallError: String?
        var calls: [PendingCall] = []
        var usage: Usage?
        var reason: FinishReason?
        var idCount = 0
    }

    private struct Outcome {
        var status: HarnessStatus
        var summary: String
    }

    public func run(spec: HarnessJobSpec, workspace: Workspace,
                    onEvent: @Sendable (HarnessEvent) -> Void) async -> HarnessJobResult {
        let box = SessionBox()
        var usage = HarnessUsage()
        var commands: [CommandRecord] = []
        let outcome = await withTaskCancellationHandler {
            await self.loop(spec: spec, workspace: workspace, box: box, usage: &usage, commands: &commands, onEvent: onEvent)
        } onCancel: {
            if let s = box.get() { let e = engine; Task { await e.cancel(s) } }
        }
        if let s = box.get() { await engine.close(s) }
        onEvent(.finished(outcome.status))
        return HarnessJobResult(status: outcome.status, summary: String(Redactor.redact(outcome.summary).prefix(1500)),
                                base: workspace.base, commands: commands, usage: usage)
    }

    private func envBlock(spec: HarnessJobSpec, workspace: Workspace) -> String {
        var s = "<environment>\nworking_directory: \(workspace.root)\naccess: \(spec.access.rawValue)\n"
        if !date.isEmpty { s += "date: \(date)\n" }
        s += "</environment>\n\n# Task\n\(spec.task)"
        if !spec.files.isEmpty { s += "\n\n# Relevant files\n" + spec.files.map { "- \($0)" }.joined(separator: "\n") }
        if let c = spec.context, !c.isEmpty { s += "\n\n# Context\n\(c)" }
        return s
    }

    /// Resumable loop state: what survives between user turns of a conversation (the delegated path runs one drive).
    fileprivate struct LoopState {
        var session: SessionID
        var baseTokens = 0      // prompt+completion reported by the engine for the latest turn
        var charsSince = 0      // chars appended since baseTokens was taken
        var entries: [Compaction.Entry] = []
        var tail: [Compaction.Exchange] = []   // last `verbatimTail` exchanges, whole steps only
        /// The engine session was opened with thinking on for its next generation.
        var thinking = false
        /// Whether this conversation's configured policy/explicit chat request enables thinking after compaction.
        var thinkingEnabled = false
        /// Rebuild transcript for a thinking session, including generated reasoning.
        var transcript: [Message] = []
    }

    private var sessionConfig: SessionConfig { config(thinking: false) }

    private var thinkingPolicyOn: Bool { knobs.thinking == .firstPlanningTurn || knobs.thinking == .allTurns }

    /// Thinking off is today's config. Thinking on differs only in the generation prompt (`<think>\n` instead of
    /// `<think>\n\n</think>\n\n`): effort "medium" adds no reasoning instruction, so the system block, tools block and
    /// every rendered message are byte-identical to the thinking-off render (see docs/EVOLVE.md, Prefix cache).
    private func config(thinking: Bool) -> SessionConfig {
        var config = thinking
            ? SessionConfig(tools: tools.map(\.spec), reasoningPolicy: .templateDefault, enableThinking: true, reasoningEffort: knobs.reasoningEffort)
            : SessionConfig(tools: tools.map(\.spec), reasoningPolicy: .disableWhenTools)
        // nil retains the historical template default; on explicitly preserves reasoning even across user turns.
        if knobs.preserve_thinking == .on { config.preserveThinking = true }
        return config
    }

    /// Replaces a thinking session by a thinking-off one holding the same conversation, including reasoning
    /// content, then `extra`. The old session is closed after the new one is recorded in `box`.
    private func leaveThinking(from old: SessionID, transcript: [Message], extra: [Message], box: SessionBox) async throws -> SessionID {
        let fresh = try await engine.openSession(config(thinking: false))
        do { _ = try await engine.append(fresh, .history(transcript + extra)) } catch {
            await engine.close(fresh)
            throw error
        }
        box.set(fresh)
        await engine.close(old)
        return fresh
    }

    private func loop(spec: HarnessJobSpec, workspace: Workspace, box: SessionBox, usage: inout HarnessUsage,
                      commands: inout [CommandRecord], onEvent: @Sendable (HarnessEvent) -> Void) async -> Outcome {
        let config = sessionConfig
        let firstUser = envBlock(spec: spec, workspace: workspace)
        let fixedChars = systemPrompt.count + config.tools.reduce(0) { $0 + $1.json.serialized().count }
        var state: LoopState
        do {
            let session = try await engine.openSession(self.config(thinking: thinkingPolicyOn))
            box.set(session)
            state = LoopState(session: session, charsSince: fixedChars + firstUser.count)
            if thinkingPolicyOn { state.thinking = true; state.thinkingEnabled = true }
            if thinkingPolicyOn || knobs.thinking == .onStall || knobs.preserve_thinking == .on {
                state.transcript = [.system(systemPrompt), .user(firstUser)]
            }
            _ = try await engine.append(session, .messages([.system(systemPrompt), .user(firstUser)]))
        } catch {
            return Outcome(status: Task.isCancelled ? .cancelled : .failed, summary: "engine error: \(error)")
        }
        return await drive(spec: spec, workspace: workspace, history: [], state: &state, box: box, usage: &usage,
                           commands: &commands, onEvent: onEvent)
    }

    /// The agent loop proper: generate, run tools, compact, until the model finishes or a limit hits. Limits
    /// (turns, wall clock, generated tokens) are counted per drive, i.e. per user turn in a conversation.
    private func drive(spec: HarnessJobSpec, workspace: Workspace, history: [String], state: inout LoopState,
                       box: SessionBox, usage: inout HarnessUsage, commands: inout [CommandRecord],
                       onEvent: @Sendable (HarnessEvent) -> Void) async -> Outcome {
        let lim = spec.limits
        let start = clock()
        func timeUp() -> Bool { clock().timeIntervalSince(start) >= lim.maxSeconds }
        let config = sessionConfig
        let toolByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let validNames = tools.map(\.name).joined(separator: ", ")
        let ctx = ToolContext(root: workspace.root, access: spec.access)
        let firstUser = envBlock(spec: spec, workspace: workspace)
        let fixedChars = systemPrompt.count + config.tools.reduce(0) { $0 + $1.json.serialized().count }

        var session = state.session
        var baseTokens = state.baseTokens
        var charsSince = state.charsSince
        var entries = state.entries
        var tail = state.tail
        var thinking = state.thinking
        var thinkingEnabled = state.thinkingEnabled
        var transcript = state.transcript
        defer {
            state.session = session; state.baseTokens = baseTokens; state.charsSince = charsSince
            state.entries = entries; state.tail = tail
            state.thinking = thinking; state.thinkingEnabled = thinkingEnabled
            state.transcript = transcript
        }

        /// Appends to the session; a thinking session is first swapped for a thinking-off one (turn 2 onward).
        func appendMessages(_ msgs: [Message]) async throws {
            if thinking {
                if knobs.thinking == .firstPlanningTurn || knobs.thinking == .onStall {
                    session = try await leaveThinking(from: session, transcript: transcript, extra: msgs, box: box)
                    thinking = false
                    transcript = (knobs.thinking == .onStall || knobs.preserve_thinking == .on) ? transcript + msgs : []
                } else {
                    _ = try await engine.append(session, .messages(msgs))
                    transcript.append(contentsOf: msgs)
                }
            } else {
                _ = try await engine.append(session, .messages(msgs))
                if knobs.thinking == .onStall || knobs.preserve_thinking == .on { transcript.append(contentsOf: msgs) }
            }
        }

        var turn = 0
        var generated = 0
        var lastText = ""
        var lastCall: String?
        var lastResultHash = 0
        var sameResultRun = 0   // consecutive executions of `lastCall` that returned the identical result
        var nudged = false
        var finishNudged = false
        var consecutiveErrors = 0
        var compactions = 0
        var stallTracker = StallTracker()
        var pendingNudge: String?
        var progress = TestProgress()
        let tracksProgress = knobs.progress_gate == .on || knobs.thinking == .onStall
        let trackedFiles = tracksProgress ? await TrackedFileSnapshot.load(root: workspace.root) : TrackedFileSnapshot(root: workspace.root, paths: [])

        while true {
            if Task.isCancelled { return Outcome(status: .cancelled, summary: "cancelled") }
            if turn >= lim.maxTurns { return Outcome(status: .limit, summary: "turn limit (\(lim.maxTurns)) reached. " + lastText) }
            if timeUp() { return Outcome(status: .limit, summary: "time limit (\(Int(lim.maxSeconds))s) reached. " + lastText) }
            if generated >= lim.maxGeneratedTokens {
                return Outcome(status: .limit, summary: "generated-token limit (\(lim.maxGeneratedTokens)) reached. " + lastText)
            }
            // Turn boundary (not before the first turn): a delegated run may give its admission slot to interactive
            // work here. Unbound (chat, tests) this is a no-op; cancellation while queued ends the run.
            if turn > 0 {
                do { try await AdmissionCheckpoint.wait() } catch {
                    return Outcome(status: Task.isCancelled ? .cancelled : .failed,
                                   summary: Task.isCancelled ? "cancelled" : "admission: \(error)")
                }
            }
            turn += 1
            usage.turns = turn
            onEvent(.turn(turn))

            // Compaction: continue on a new session with the identical system prefix.
            if compactions < 8, !entries.isEmpty,
               baseTokens + Compaction.estimateTokens(chars: charsSince) > compactionThreshold {
                let tailCalls = tail.reduce(0) { $0 + $1.calls.count }
                let summary = Compaction.summary(entries: entries, omitLast: tailCalls)
                let recent = Compaction.recent(tail)
                var user = firstUser
                if !history.isEmpty {
                    user += "\n\n# Conversation so far (earlier context was compacted)\n" + Compaction.conversation(history)
                }
                user += "\n\n# Progress so far (earlier context was compacted)\n" + summary
                    + (recent.isEmpty ? "" : "\n\n# Latest steps (verbatim)\n" + recent)
                    + (knobs.compactionSummaryPrompt.map {
                        "\n\n# Progress-note format (use it for any notes you write; do not stop to summarize)\n" + $0
                    } ?? "")
                    + (history.isEmpty ? "\n\nContinue the task above from here; do not redo finished work."
                                       : "\n\nContinue from the latest user message; do not redo finished work.")
                // Earlier reasoning is not carried over: it would defeat the compaction, and a bare reasoning-only
                // assistant message after the user turn renders as an empty finished turn. The summary carries progress.
                let rebuilt = [Message.system(systemPrompt), .user(user)]
                // The fresh session is closed on every path where it is not adopted; the old one is closed
                // exactly once, after the fresh one is recorded in `box` (so run() never closes it twice).
                let fresh: SessionID
                do {
                    fresh = try await engine.openSession(self.config(thinking: thinkingEnabled))
                } catch {
                    return Outcome(status: Task.isCancelled ? .cancelled : .failed, summary: "compaction failed: \(error)")
                }
                do {
                    _ = try await engine.append(fresh, .messages(rebuilt))
                } catch {
                    await engine.close(fresh)
                    return Outcome(status: Task.isCancelled ? .cancelled : .failed, summary: "compaction failed: \(error)")
                }
                box.set(fresh)
                await engine.close(session)
                session = fresh
                compactions += 1
                baseTokens = 0
                charsSince = fixedChars + user.count
                thinking = thinkingEnabled
                transcript = (thinkingEnabled || knobs.thinking == .onStall || knobs.preserve_thinking == .on) ? rebuilt : []
                onEvent(.toolResult(name: "_compaction", output: Compaction.brief(summary, 200), isError: false))
            }

            if let n = pendingNudge {
                pendingNudge = nil
                charsSince += n.count
                do { try await appendMessages([.user(n)]) } catch {
                    return Outcome(status: Task.isCancelled ? .cancelled : .failed, summary: "engine error: \(error)")
                }
            }

            // Recovery thinking lasts exactly one assistant generation. Replay on a fresh immutable-config session.
            if knobs.thinking == .onStall, progress.takeThinkingTurn(), !thinking {
                do {
                    let fresh = try await engine.openSession(self.config(thinking: true))
                    do { _ = try await engine.append(fresh, .history(transcript)) }
                    catch { await engine.close(fresh); throw error }
                    box.set(fresh)
                    await engine.close(session)
                    session = fresh
                    thinking = true
                } catch {
                    return Outcome(status: Task.isCancelled ? .cancelled : .failed, summary: "engine error: \(error)")
                }
            }

            // Generate.
            var out = TurnOutput()
            var timedOut = false
            do {
                let promptTokens = baseTokens + Compaction.estimateTokens(chars: charsSince)
                if knobs.context != .standard, promptTokens >= knobs.context.tokens {
                    return Outcome(status: .failed, summary: "blocked: context budget exceeded after compaction")
                }
                let turnCap = knobs.outputCap(thinking: thinking, promptTokens: promptTokens,
                                              turnCap: maxTurnTokens, background: priority == .background)
                let sampling = knobs.samplingValues(thinking: thinking)
                let params = GenParams(maxTokens: max(1, min(turnCap, lim.maxGeneratedTokens - generated)),
                                       temperature: sampling.temperature,
                                       topP: sampling.topP,
                                       topK: sampling.topK,
                                       seed: knobs.seed(forGeneration: turn), priority: priority)
                var cur: PendingCall?
                for try await ev in engine.generate(session, params) {
                    switch ev {
                    case let .tokens(ids, text):
                        out.idCount += ids.count
                        if !text.isEmpty { out.text += text; onEvent(.textDelta(text)) }
                    case let .reasoning(t):
                        out.reasoning += t
                        onEvent(.reasoningDelta(t))
                    case let .toolCallBegin(name):
                        cur = PendingCall(name: name)
                    case let .toolCallError(message):
                        out.toolCallError = message
                        cur = nil
                    case let .toolCallArg(key, value):
                        cur?.args.append(.init(key, value))
                    case .toolCallEnd:
                        if let c = cur { out.calls.append(c); cur = nil }
                    case let .finished(reason, u):
                        out.reason = reason; out.usage = u
                    }
                    if timeUp() && !timedOut { timedOut = true; await engine.cancel(session) }
                }
            } catch {
                if Task.isCancelled { return Outcome(status: .cancelled, summary: "cancelled") }
                return Outcome(status: .failed, summary: "engine error: \(error)")
            }
            if Task.isCancelled || out.reason == .cancelled && !timedOut {
                return Outcome(status: .cancelled, summary: "cancelled")
            }
            if let u = out.usage {
                usage.promptTokens += u.promptTokens
                usage.cachedTokens += u.cachedTokens
                usage.completionTokens += u.completionTokens
                usage.seconds += u.prefillSeconds + u.decodeSeconds
                generated += max(u.completionTokens, out.idCount)
                if u.promptTokens > 0 { baseTokens = u.promptTokens + u.completionTokens; charsSince = 0 }
                else { charsSince += out.text.count + (knobs.preserve_thinking == .on ? out.reasoning.count : 0) }
                onEvent(.usage(u))
            } else {
                generated += out.idCount
                charsSince += out.text.count + (knobs.preserve_thinking == .on ? out.reasoning.count : 0)
            }
            if timedOut { return Outcome(status: .limit, summary: "time limit (\(Int(lim.maxSeconds))s) reached. " + lastText) }
            let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lastText = text }
            if thinking || knobs.thinking == .onStall || knobs.preserve_thinking == .on {
                transcript.append(.assistant(out.text.isEmpty && !out.calls.isEmpty ? nil : out.text,
                                             reasoning: out.reasoning.isEmpty ? nil : out.reasoning,
                                             toolCalls: out.calls.map { ToolCall(name: $0.name, arguments: $0.args) }))
            }

            if out.calls.isEmpty {
                if out.toolCallError == nil && !text.isEmpty && out.reason != .length {
                    guard requireFinish else { return Outcome(status: .done, summary: text) }
                    // Prose without `finish` is not proof of completion: nudge once, then end as no_finish.
                    if finishNudged { return Outcome(status: .limit, summary: "no_finish: model replied without calling finish. " + text) }
                    finishNudged = true
                    pendingNudge = "Call finish with a summary, or continue with tools."
                    continue
                }
                // Empty or cut-off reply: nudge once per occurrence, counted as an error.
                consecutiveErrors += 1
                if consecutiveErrors >= lim.maxConsecutiveErrors {
                    return Outcome(status: .failed, summary: "model produced no usable action. " + lastText)
                }
                pendingNudge = out.toolCallError ?? (out.reason == .length
                    ? "Your last reply was cut off. Continue with a tool call, or call finish."
                    : "Reply with a tool call, or call finish with a summary.")
                continue
            }

            // Execute tool calls sequentially.
            finishNudged = false
            var results: [String] = []
            var stepCalls: [Compaction.Exchange.Call] = []
            for call in out.calls {
                if Task.isCancelled { return Outcome(status: .cancelled, summary: "cancelled") }
                let argsDict = Dictionary(call.args.map { ($0.key, $0.value) }, uniquingKeysWith: { _, b in b })
                let argsJSON = OrderedJSON.object(call.args).serialized()
                onEvent(.toolCall(name: call.name, args: Redactor.redact(argsJSON)))

                let command = call.name == "bash" ? argsDict["command"]?.stringValue : nil
                let testRun = (tracksProgress || knobs.test_status == .structured)
                    && (command.map { TestCommand.isTest($0, verify: spec.verify) } ?? false)
                let shellBefore = tracksProgress && command != nil && !testRun ? trackedFiles.capture() : nil
                let key = call.name + "\u{0}" + argsJSON
                var result: ToolResult
                var guarded = false
                // Repetition guard: the same call that already returned the same result `max - 1` times in a row.
                if !(knobs.progress_gate == .on && testRun), key == lastCall, sameResultRun >= lim.maxRepeatedCalls - 1 {
                    if nudged {
                        return Outcome(status: .limit, summary: "aborted: identical \(call.name) call repeated. " + lastText)
                    }
                    nudged = true
                    guarded = true
                    result = ToolResult(output: "You have made this exact call \(sameResultRun + 1) times with the same result. Do not repeat it; change approach or call finish.")
                } else if let tool = toolByName[call.name] {
                    do {
                        if let bash = tool as? BashTool, testRun, knobs.test_status == .structured {
                            result = try await bash.run(argsDict, context: ctx, structuredTest: true)
                        } else {
                            result = try await tool.run(argsDict, context: ctx)
                        }
                    } catch is CancellationError {
                        return Outcome(status: .cancelled, summary: "cancelled")
                    } catch {
                        result = ToolResult(output: "tool error: \(error)", isError: true)
                    }
                } else {
                    result = ToolResult(output: "Unknown tool '\(Compaction.sanitize(call.name, max: 80))'. Valid tools: \(validNames)", isError: true)
                }
                let refused = call.name == "bash" && result.output.hasPrefix("bash: refused:")
                if tracksProgress, !guarded, !refused {
                    if !result.isError, call.name == "edit_file" || call.name == "write_file" { progress.edited() }
                    if !result.isError, call.name == "read_file", let path = argsDict["path"]?.stringValue { progress.read(path: path) }
                    if let before = shellBefore, before != trackedFiles.capture() { progress.edited() }
                }
                // Redact every result before it is capped, emitted or appended to the session.
                let output = Redactor.redact(result.output)
                if !guarded {
                    let h = output.hashValue
                    if key == lastCall, h == lastResultHash { sameResultRun += 1 } else { lastCall = key; lastResultHash = h; sameResultRun = 1 }
                }
                let bashExit = call.name == "bash" ? Compaction.exitCode(output: output, isError: result.isError) : 0
                var shown = FailureFeedback.shape(output, tool: call.name, exitCode: bashExit,
                                                 shape: knobs.result_shape, cap: knobs.toolOutputCap)
                let evidence = testRun && !guarded && !refused ? TestEvidence(output: output, exit: bashExit) : nil
                if knobs.test_status == .structured, let evidence { shown = evidence.digest + "\n\n" + shown }
                var blocked: String?
                if tracksProgress, !guarded, let evidence {
                    let decision = progress.record(evidence, gate: knobs.progress_gate == .on, sourcePaths: spec.files + trackedFiles.paths)
                    if let note = decision.note { shown += "\n\n" + note }
                    blocked = decision.blocked
                }
                if knobs.stall_nudge == .on, !guarded, !refused {
                    if !result.isError, call.name == "edit_file" || call.name == "write_file" { stallTracker.edited() }
                    if call.name == "bash",
                       let note = stallTracker.note(signature: FailureFeedback.signature(output: output, exitCode: bashExit), turn: turn) {
                        // Append metadata after shaping; raw output, exit extraction and repetition hashes stay untouched.
                        shown += "\n\n" + note
                        if knobs.thinking == .onStall { progress.stallNudged() }
                    }
                }
                onEvent(.toolResult(name: call.name, output: shown, isError: result.isError))
                var exit: Int32?
                if call.name == "bash", let cmd = argsDict["command"]?.stringValue {
                    exit = Compaction.exitCode(output: output, isError: result.isError)
                    commands.append(CommandRecord(cmd: Redactor.redact(cmd), exit: exit!))
                }
                if let blocked { return Outcome(status: .failed, summary: blocked) }
                let strArgs = argsDict.compactMapValues(\.stringValue)
                entries.append(.init(name: call.name, head: Compaction.headFor(tool: call.name, args: strArgs),
                                     isError: result.isError, exit: exit, path: argsDict["path"]?.stringValue))

                if let summary = result.finishSummary, out.toolCallError == nil {
                    var declined = false
                    switch argsDict["declined"] {
                    case .bool(true)?: declined = true
                    case let .string(v)?: declined = v.lowercased() == "true"
                    default: break
                    }
                    if declined {
                        let why = argsDict["reason"]?.stringValue ?? ""
                        return Outcome(status: .declined, summary: Redactor.redact(why.isEmpty ? summary : why))
                    }
                    let failed = argsDict["status"]?.stringValue == "failed"
                    return Outcome(status: failed ? .failed : .done, summary: Redactor.redact(summary))
                }
                consecutiveErrors = result.isError ? consecutiveErrors + 1 : 0
                if consecutiveErrors >= lim.maxConsecutiveErrors {
                    return Outcome(status: .failed, summary: "\(consecutiveErrors) consecutive tool errors. Last: \(Compaction.brief(shown, 300))")
                }
                results.append(shown)
                stepCalls.append(.init(name: call.name, args: Redactor.redact(argsJSON), output: shown, isError: result.isError))
                if timeUp() { return Outcome(status: .limit, summary: "time limit (\(Int(lim.maxSeconds))s) reached. " + lastText) }
            }

            if verbatimTail > 0 {
                tail.append(.init(text: Redactor.redact(text), calls: stepCalls))
                if tail.count > verbatimTail { tail.removeFirst(tail.count - verbatimTail) }
            }
            charsSince += results.reduce(0) { $0 + $1.count }
            var appended = results.map { Message.tool($0) }
            if let syntaxError = out.toolCallError {
                consecutiveErrors += 1
                if consecutiveErrors >= lim.maxConsecutiveErrors {
                    return Outcome(status: .failed, summary: "model returned an incomplete tool call repeatedly. " + lastText)
                }
                charsSince += syntaxError.count
                appended.append(.user(syntaxError))
            }
            do { try await appendMessages(appended) } catch {
                return Outcome(status: Task.isCancelled ? .cancelled : .failed, summary: "engine error: \(error)")
            }
        }
    }
}

// MARK: - Multi-turn conversations

/// A long-lived engine session driven one user turn at a time by the same loop, tool set and prompt as a delegated
/// job. The transcript is append-only (user turn, assistant steps, tool results), so the engine's prefix cache is
/// reused turn after turn; compaction replaces the engine session only when the context grows past the threshold.
/// Not thread-safe: the owner (HarnessRunner) runs one turn at a time.
public final class LoopConversation: @unchecked Sendable {
    fileprivate let box = AgentLoop.SessionBox()
    fileprivate var state: AgentLoop.LoopState?
    fileprivate var spec: HarnessJobSpec
    fileprivate let workspace: Workspace
    fileprivate var history: [String] = []
    fileprivate var closed = false
    /// Tokens and tool commands of the whole conversation so far.
    public fileprivate(set) var totalUsage = HarnessUsage()
    public fileprivate(set) var commands: [CommandRecord] = []
    /// User turns run so far.
    public fileprivate(set) var userTurns = 0
    /// Thinking requested for the engine session when it opens (first turn); nil = the thinking knob.
    var thinking: Bool?

    init(spec: HarnessJobSpec, workspace: Workspace) { self.spec = spec; self.workspace = workspace }
}

extension AgentLoop {
    /// Prepares a conversation. The engine session opens lazily with the first user turn (whose text becomes the task).
    public func openConversation(spec: HarnessJobSpec, workspace: Workspace) -> LoopConversation {
        LoopConversation(spec: spec, workspace: workspace)
    }

    /// Runs one user turn to its end (the model finishes, answers in plain text, errors, or a per-turn limit hits).
    /// Cancelling the calling task cancels the engine generation. The conversation stays usable afterwards.
    public func runUserTurn(_ c: LoopConversation, text: String,
                            onEvent: @Sendable (HarnessEvent) -> Void) async -> HarnessJobResult {
        guard !c.closed else { return HarnessJobResult(status: .failed, summary: "conversation closed") }
        var usage = HarnessUsage()
        var commands: [CommandRecord] = []
        let outcome: Outcome = await withTaskCancellationHandler {
            await self.userTurn(c, text: text, usage: &usage, commands: &commands, onEvent: onEvent)
        } onCancel: {
            if let s = c.box.get() { let e = engine; Task { await e.cancel(s) } }
        }
        c.userTurns += 1
        c.history.append("user: " + Compaction.sanitize(text, max: 500))
        c.history.append("assistant (\(outcome.status.rawValue)): " + Compaction.sanitize(outcome.summary, max: 300))
        if c.history.count > 48 { c.history.removeFirst(c.history.count - 48) }
        c.totalUsage.promptTokens += usage.promptTokens
        c.totalUsage.cachedTokens += usage.cachedTokens
        c.totalUsage.completionTokens += usage.completionTokens
        c.totalUsage.turns += usage.turns
        c.totalUsage.seconds += usage.seconds
        c.commands += commands
        onEvent(.finished(outcome.status))
        return HarnessJobResult(status: outcome.status, summary: String(Redactor.redact(outcome.summary).prefix(1500)),
                                base: c.workspace.base, commands: commands, usage: usage)
    }

    private func userTurn(_ c: LoopConversation, text: String, usage: inout HarnessUsage,
                          commands: inout [CommandRecord], onEvent: @Sendable (HarnessEvent) -> Void) async -> Outcome {
        do {
            if var st = c.state {
                if st.thinking {
                    if knobs.thinking == .firstPlanningTurn || knobs.thinking == .onStall {
                        st.session = try await leaveThinking(from: st.session, transcript: st.transcript, extra: [.user(text)], box: c.box)
                        st.thinking = false
                        st.transcript = (knobs.thinking == .onStall || knobs.preserve_thinking == .on) ? st.transcript + [.user(text)] : []
                    } else {
                        _ = try await engine.append(st.session, .messages([.user(text)]))
                        st.transcript.append(.user(text))
                    }
                } else {
                    _ = try await engine.append(st.session, .messages([.user(text)]))
                    if knobs.thinking == .onStall || knobs.preserve_thinking == .on { st.transcript.append(.user(text)) }
                }
                st.charsSince += text.count
                c.state = st
            } else {
                c.spec.task = text
                let config = sessionConfig
                let firstUser = envBlock(spec: c.spec, workspace: c.workspace)
                let fixedChars = systemPrompt.count + config.tools.reduce(0) { $0 + $1.json.serialized().count }
                let thinkingNow = c.thinking ?? thinkingPolicyOn
                let session = try await engine.openSession(self.config(thinking: thinkingNow))
                c.box.set(session)
                var fresh = LoopState(session: session, charsSince: fixedChars + firstUser.count)
                if thinkingNow { fresh.thinking = true; fresh.thinkingEnabled = true }
                if thinkingNow || knobs.thinking == .onStall || knobs.preserve_thinking == .on {
                    fresh.transcript = [.system(systemPrompt), .user(firstUser)]
                }
                c.state = fresh
                _ = try await engine.append(session, .messages([.system(systemPrompt), .user(firstUser)]))
            }
        } catch {
            return Outcome(status: Task.isCancelled ? .cancelled : .failed, summary: "engine error: \(error)")
        }
        guard var st = c.state else { return Outcome(status: .failed, summary: "no session") }
        // The first user turn is the task in the env block; later ones must survive a compaction inside this turn.
        var hist = c.history
        if c.userTurns > 0 { hist.append("user: " + Compaction.sanitize(text, max: 500)) }
        let outcome = await drive(spec: c.spec, workspace: c.workspace, history: hist, state: &st, box: c.box,
                                  usage: &usage, commands: &commands, onEvent: onEvent)
        if st.entries.count > 120 { st.entries.removeFirst(st.entries.count - 120) }
        c.state = st
        return outcome
    }

    /// Closes the engine session exactly once.
    public func closeConversation(_ c: LoopConversation) async {
        guard !c.closed else { return }
        c.closed = true
        if let s = c.state?.session ?? c.box.get() { await engine.close(s) }
    }
}
