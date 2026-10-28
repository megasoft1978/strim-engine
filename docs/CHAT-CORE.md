# Chat core (L3)

A chat session is a long-lived job on the same core as an MCP job: one `AgentLoop`, one tool set (`ToolCatalog`), one prompt pack, one sandbox. `RunProfile` is the only difference.

## RunProfile (`StrimHarness/RunProfile.swift`)
| | `.delegated` (MCP, jobs) | `.interactive` (chat) |
|---|---|---|
| steps (model generations) | 40 | 80 per user turn |
| wall clock | 15 min | 30 min per user turn |
| generated tokens | 60k | 120k per user turn |
| engine priority | background | interactive |
| verify | required, run by the harness | not used |
| text/reasoning deltas | not streamed | streamed (redacted) |
| patch | returned in the job result | `patchReady` per turn, user approves; never auto-applied |

`RunProfile.limits(requested:)`: the default `HarnessLimits()` means "use the profile"; anything else is clamped to the profile ceilings. `RunProfile.named("interactive")` maps the wire name of `ChatOpenRequest.profile`. The delegated path (`HarnessRunner.run`, `JobManager.submit`) is unchanged; the finish tool spec, `tools/list` and the pack are not touched.

## API the control lane calls
`JobManager` (StrimJobs), constructed with `chat: <HarnessRunner>` (conforms to `ChatBackend`), `maxChatSessions` (default 2), `chatIdleTimeout` (default 1800 s):

| Call | Notes |
|---|---|
| `openSession(spec, profile) -> JobID` | spec: `cwd`, `access`, optional `files`/`context`; `task` and `verify` are ignored. The job id is the `session_id` and `job_id` of `ChatSession`. Status `running` until closed. Throws `ChatError.maxSessions`, `.openFailed` |
| `appendUserTurn(id, text) -> AsyncStream<ChatEvent>` | Starts one turn. Throws `.turnInProgress` (rejected, never queued), `.sessionNotFound`, `.sessionClosed`, `.idleTimeout`, `.emptyText`, `.textTooLong`. The stream ends after `.turnFinished`; dropping the stream cancels the turn |
| `cancelTurn(id)` | Returns when the turn has stopped; the engine generation is cancelled; the session stays open |
| `closeSession(id) -> JobSnapshot` | Cancels a running turn, closes the engine session, removes the worktree, job becomes `done` with the final patch |
| `cancel(id)` | Generic job cancel; for a chat job it closes the session as `cancelled` |
| `sweepIdleSessions()` | Closes sessions idle past the timeout (job `done`, reason `idle_timeout`). Each session also runs a monitor every `pollInterval` |
| `status(id)` | `JobSnapshot.profile`, `.turnActive`, `.lastActivityAt` are set for chat jobs |
| `hasActiveChatTurn` | Background jobs pause (`paused_interactive`) while any chat turn runs |
| `recover()` | A session open at host restart becomes `failed` with reason `host_restart` (worktrees of a dead host are not reattached) |

`HarnessRunner` (StrimHarness) has the same four calls plus `currentPatch(sessionID:)` (cumulative diff of the session workspace, for the diff view), `hasSession`, `isTurnActive`, `workspaceRoot` and `closeAllSessions()` (host shutdown).

Semantics:
- The first user turn becomes the task (env block + `# Task`); later turns are appended as plain user messages to the same engine session, so the transcript is append-only and the prefix cache is reused. Compaction (same threshold as jobs) opens a fresh engine session whose first message carries the task, the earlier user requests, short outcomes and the structured progress log (all sanitised, untrusted-wrapped), including the in-flight request.
- Limits are per user turn. Hitting one ends the turn with status `limit` (plus a `limit` event); the session stays usable.
- After every turn that is not cancelled or declined, a write session collects the cumulative patch against its base; if it changed, `patchReady` carries it (inline up to 16 KB, else `patchPath` = `<jobs>/<id>/patch.diff`).
- Cancelled turns keep the session. The next turn is appended after the partial transcript.
- Cleanup (engine session close, worktree removal) happens exactly once, on `closeSession`, idle timeout or `cancel`.
- Everything leaving the core is redacted: text and reasoning deltas go through a streaming redactor that holds back text until a safe cut (a newline, or whitespace when no secret-looking keyword precedes it), so a token split across deltas or `Bearer ` + token split at the space is still redacted; unterminated PEM blocks are held entirely. The cost is that prose is released per word group and key-looking text per line, never mid-secret. Tool call and result summaries are redacted, then truncated to 300 chars. `events.jsonl` is written through the existing coalescing sink.

## ChatEvent -> StrimAPI mapping
StrimHarness does not import StrimAPI. The control lane maps `ChatEvent` (neutral) as follows, with `session_id` = job id:

| ChatEvent | Wire |
|---|---|
| `textDelta(t)` | `chat_delta` `{kind: text, text: t}` |
| `reasoningDelta(t)` | `chat_delta` `{kind: reasoning, text: t}` |
| `toolCallStarted(name, summary)` | `chat_delta` `{kind: tool_call, text: "<name> <summary>"}` |
| `toolCallFinished(name, summary, isError)` | `chat_delta` `{kind: tool_result, text: "<name>[ ERROR]: <summary>"}` |
| `turnFinished(r)` | `chat_delta` `{kind: done, text: r.summary}`, then the stream ends |
| `stepStarted(n)` | `harness_event` `{job_id, kind: "turn", text: "n"}` |
| `usage` | `harness_event` kind `usage`, text `"prompt/cached/completion"` |
| `compaction(s)` | `harness_event` kind `compaction`, text `s` |
| `limit(s)` | `harness_event` kind `limit`, text `s` |
| `patchReady(p)` | `harness_event` kind `patch`, text = comma separated paths; the diff itself is read through the job detail / `currentPatch` |

Typed errors to API errors: `ChatError.code` is the stable `snake_case` name (`turn_in_progress` and `max_sessions` -> 409 `conflict`, `session_not_found` -> 404, `session_closed` / `idle_timeout` -> 409, `empty_text` / `text_too_long` / `unknown_profile` -> 400 `bad_request`, `open_failed` -> 500 or 503).

Applying a patch is not part of the core: the control lane runs `git apply --3way` on the parent only after an explicit UI approval.
