# Control API (v1)

Served by `StrimControl` on the same HTTP server as `/v1/chat/completions`. Types and route constants live in `Sources/StrimAPI` (`StrimRoutes`, Codable DTOs; JSON keys snake_case, fixed by CodingKeys). Clients code against `StrimControlClient`; tests use `FakeControlClient`.

## Auth
Two secrets, both 0600 files under `~/.strim` (hex, 32 random bytes):
- `~/.strim/token`: the API/MCP token (OpenAI, Anthropic, Responses, `/mcp`). On `/v1/strim/*` it unlocks ONLY `GET /v1/strim/status`; every other control route answers 403 `forbidden` ("this credential is not valid for this route").
- `~/.strim/control-token`: the control token, created by `strim serve` at start when missing (rotate: delete the file and restart). Accepted ONLY on `/v1/strim/*` (all control routes, including approve, load, unload, chat, events); it is refused (401) on `/v1/*` and `/mcp`. `strim control-token` prints the file path, never the token.
- Missing or unknown credentials: 401 `unauthorized` with one fixed message, so the answer never says which token would be valid. Tokens are compared as fixed-length SHA-256 digests in constant time.
- With `strim serve --no-auth` the API side is open: `GET status` needs no credentials, all other control routes still need the control token.
- `strim serve` runs priority admission by default (`--max-inflight N`, `--max-background N`, `--no-admission`; see docs/ADMISSION.md). Generation requests and chat turns take an interactive slot; delegated jobs take a background slot.
- Loopback `Host` and (if present) `Origin` are re-checked per route; `Sec-Fetch-Site: cross-site` is refused (403). Write bodies must be `application/json`, at most 1 MiB.

## Routes
| Method | Path | Write | Body | Response |
|---|---|---|---|---|
| GET | `/v1/strim/status` | no | - | `HostStatus` |
| GET | `/v1/strim/events` | no | - | SSE stream of `StrimEvent` |
| POST | `/v1/strim/load` | yes | `LoadRequest {model, mtp?}` | 202, `HostStatus` |
| POST | `/v1/strim/unload` | yes | - | 200, `HostStatus` |
| GET | `/v1/strim/jobs` | no | - | `[JobSummary]` |
| GET | `/v1/strim/jobs/{id}` | no | - | `JobDetail` |
| POST | `/v1/strim/jobs/approve` | yes | `PatchApproval {job_id, action: apply\|reject, patch_sha256?}` | 200, `JobDetail` |
| POST | `/v1/strim/chat/open` | yes | `ChatOpenRequest {cwd, profile}` | `ChatSession` |
| POST | `/v1/strim/chat/append` | yes | `ChatAppendRequest {session_id, text}` | 202, empty; output arrives as `chat_delta` events |
| POST | `/v1/strim/chat/cancel` | yes | `ChatCancelRequest {session_id}` | 200, empty |

Write-capable routes (all POST) change host state or the parent tree (`approve` with `apply` runs `git apply --3way`; it is the only way the parent tree is written by the app). GET routes are read-only.

`patch_sha256` (lowercase hex SHA-256 over the exact UTF-8 bytes of the patch the user reviewed) is optional on the wire for backward compatibility but REQUIRED for `action=apply`: the server must refuse the apply (409 `conflict`) when it is missing or differs from the digest of the stored patch. `JobDetail` carries the same `patch_sha256` of its `patch` when known. Clients bind approval to reviewed content: if a fresh `JobDetail` has a different digest, the earlier review no longer counts.

## SSE format
`Content-Type: text/event-stream`. One frame per event:

```
event: <type>
data: {"type":"<type>","data":{...}}

```
`type` is one of `status`, `job_event`, `harness_event`, `chat_delta`, `error`. The JSON `data` payload is the DTO (`HostStatus`, `JobEvent`, `HarnessEvent`, `ChatDelta`, `APIError`). A `status` frame is sent on connect and on every state change; a comment line `: ping` is sent every 15 s. Clients reconnect on close and re-fetch `/status` and `/jobs`.

## Errors
Any non-2xx returns JSON `{"error":{"code":"<snake_case>","message":"<text>"}}` (`APIErrorEnvelope`). Codes: `unauthorized` (401), `forbidden` (403), `not_found` (404), `bad_request` (400), `conflict` (409, e.g. load while loading), `unavailable` (503, engine not ready), `internal` (500).


## Implementation notes (StrimControl)
- `POST /load` answers 202 at once (state `loading`); a failed load leaves `state: error` with `last_crash` = message, and `load` may be retried. `load` while loading, a different model while one is loaded, and `unload` while loading are 409 `conflict`. `unload` is 409 while jobs run or a chat session is open (nothing is waited for or force-cancelled over HTTP). Unload drops the last engine reference; sessions of the old engine are refused afterwards.
- `status` fields wired: state, model/mtp (last path component), load_progress (0 while loading; the real loader reports no finer progress), memory (weights = MLX active bytes right after load; prefix_trie, mlx_cache from engine stats; headroom = admission budget minus MLX active), decode/prefill tps, mtp_acceptance, mtp_depth (tokens per verify pass), prefix_hit_rate, saved_prefill_seconds (EWMA/cumulative from per-request Usage, since host start), active/queued jobs, tokens_today (since local midnight, not persisted), local_tokens_generated, uptime_seconds, last_crash (last load failure only). Not wired: `parent_tokens_saved_estimate`, per-job `verify_output` beyond the 600-char tail, job `source` other than `mcp`/`chat`.
- `events`: `status` on connect and every second, `job_event` on job status changes, `harness_event` for job progress, chat output published by `chat/append`, `: ping` every 15 s.
- `jobs/{id}` adds `patch_sha256` (SHA-256 of the stored patch bytes). `jobs/approve` with `apply` REQUIRES `patch_sha256` (400 if missing), refuses 409 `patch_changed` when it differs, and applies exactly the hashed bytes with plain `git apply` (`--check` first; NO `--3way`, whose fallback consults repo-controlled merge drivers) from the repo top, after checking every path (own header parse plus `git apply --numstat -z`) is inside the job's recorded cwd, not `.git`, not a symlink/submodule. Unsafe patch: 400 `unsafe_patch`. A repo whose local `.git/config` sets `filter.*`, `merge.*`, `diff.*`, `include*`, `core.fsmonitor|hooksPath|sshCommand|pager|editor|askPass|attributesFile`, `protocol*` or `url.*` is refused: 400 `risky_repo_config` (apply by hand). A patch that does not apply cleanly: 409 `apply_conflict` (tree untouched). Git runs in its own process group with a 60 s timeout; on timeout the group is killed and the error (500 `apply_timeout`) states whether the tree is clean; a crash by signal is 500 `apply_crashed`/`internal`. A job already decided: 409. `reject` needs no digest. For a job waiting for pre-run approval (`requireApproval`), `apply` means "run it".
- Chat: `chat/open` (profile `interactive`), `chat/append` (default 202 and output as `chat_delta`/`harness_event` on `/events`; a turn with no `/events` listener for 30 s is cancelled; with `Accept: text/event-stream` the frames stream in the response and a disconnect cancels the turn), `chat/cancel`, `chat/close` or `DELETE /v1/strim/chat/{session_id}`. ChatError codes map per docs/CHAT-CORE.md (409 conflict for turn_in_progress/max_sessions/session_closed/idle_timeout, 404, 400, 500). Chat open is checked against `mcp.allowedRoots`/`mcp.maxAccess` (403); a read-only host opens read-only sessions. `requireApproval` has no effect on chat (patches are applied only by explicit approval anyway). Extra error codes: `not_implemented` (501), `unsafe_patch` (400), `patch_changed` (409).

## Server limits (env, defaults)

Abuse limits of `strim serve` (all pre-auth unless noted). Defaults keep 4-8 concurrent clients, 32K prompts and 16 MiB bodies working.

| Variable | Default | Effect |
|---|---|---|
| `STRIM_HTTP_MAX_CONNECTIONS` | 128 | Open connections; extra ones are closed at accept |
| `STRIM_HTTP_HEAD_TIMEOUT_S` | 10 | Total time to receive a request line + headers |
| `STRIM_HTTP_BODY_TIMEOUT_S` | 30 | Body inactivity limit; total body deadline is this + length / 64 KiB/s |
| `STRIM_HTTP_IDLE_TIMEOUT_S` | 120 | Keep-alive connection with no request in flight |
| `STRIM_HTTP_MAX_PIPELINED` | 8 | Requests queued behind the running one; more closes the connection (429) |
| `STRIM_MAX_OUTPUT_TOKENS` | 1048576 | `max_tokens`/`max_completion_tokens`/`max_output_tokens` are clamped to this |
| `STRIM_BACKGROUND_MAX_TOKENS` | 32768 | Output cap for background-class requests (also with `ignore_eos`) |
| `STRIM_MAX_QUEUE` | 64 | Requests waiting for an admission slot; more get 429 + `Retry-After` |
| `STRIM_QUEUE_TIMEOUT_S` | 600 | Longest slot wait; then 503 + `Retry-After` |
| `STRIM_RESPONSE_STORE_MB` | 64 | Byte budget of the `/v1/responses` conversation store (plus 256 entries) |

Fixed caps: `stop` at most 16 sequences of 1024 bytes; MCP JSON-RPC batches at most 16 requests; unfinished delegated jobs at most 64 (`JobManager.maxPending`, submit fails with `queueFull`).

Priority: the server grants every API-token holder the class `ServerConfig.apiPriority` (default `interactive`). `x-strim-priority`/`priority` can only lower a request (to `background`), never raise it above that class. `/health` returns only `{status, engine}`; the unhealthy reason is on the guarded `/metrics`.
