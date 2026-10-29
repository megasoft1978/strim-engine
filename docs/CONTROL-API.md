| `STRIM_MTP_POLICY` | ewma | Draft-depth controller. Default: cost-per-token policy (`DepthPolicy` in SpecStream.swift): starts at depth 3, keeps an EWMA of P(accepted prefix >= i), picks the depth with the best (1 + sum P) / fitted-pass-ms, moves only after 8 rounds and for a > 5% rate gain, ceiling 3. `legacy` restores the old threshold controller (climb at EWMA > 0.82, fall at < 0.60, ceiling 4). `STRIM_MTP_FIXED=1` still disables adaptation. |
| `STRIM_MTP_DEPTH` | 2 (engine) | Bench knob: overrides the draft depth (the starting depth when adaptive, the fixed depth with `STRIM_MTP_FIXED=1`); 0 disables drafting. |
| `STRIM_MTP_MAX_DEPTH` | 3 (4 with `legacy`) | Depth ceiling for the adaptive controller; setting it explicitly lifts the policy ceiling to that value. |
| `STRIM_TIMING` | off | Set (any value) prints the per-pass time split at the end of a one-shot run; `trace` instead prints one stderr line per speculative round (`TRACE ctx= d= acc= ms=`) with no extra device syncs. |
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
| POST | `/v1/strim/chat/open` | yes | `ChatOpenRequest {cwd, profile, enable_thinking?}` | `ChatSession` |
| POST | `/v1/strim/chat/append` | yes | `ChatAppendRequest {session_id, text, enable_thinking?}` | 202, empty; output arrives as `chat_delta` events |
| POST | `/v1/strim/chat/cancel` | yes | `ChatCancelRequest {session_id}` | 200, empty |
| POST | `/v1/strim/pause` | yes | `PauseRequest {cancel_running?}` (body optional) | 200, `JobsPauseState {paused, queued, running, cancelled}` |
| POST | `/v1/strim/resume` | yes | - | 200, `JobsPauseState` |
| POST | `/v1/strim/jobs/cancel` | yes | `JobCancelRequest {job_id}` | 200, `JobCancelResult {job_id, status, cancelled}` |
| GET | `/v1/strim/models` | no | - | `ModelList {models: [LocalModel {name, path, size_gb?, kind}]}` |
| GET | `/v1/strim/pack` | no | - | `PackInfo {active_fingerprint?, pack_count, last_evolve?}` |

Write-capable routes (all POST) change host state or the parent tree (`approve` with `apply` runs plain `git apply`, never `--3way`; it is the only way the parent tree is written by the app). GET routes are read-only.

`GET /v1/strim/status` (`HostStatus`) carries `quant_fingerprint`: `<model>/<head>`, the hash of each loaded model's per-tensor quantization spec (global spec plus every per-module override of its `config.json` `quantization` block). `none` means that config has no quant block, `-` means no MTP head. It is set only while the host is ready (`null` when stopped, loading, or from an older host). The on-disk prefix cache hashes the same quant specs into its directory key, so a prefix cached under another quantization is never reused.

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
- Pause, cancel (product routes). `pause` stops admitting background (delegated) jobs: queued jobs stay queued, an approved job waits before it takes its admission slot, running jobs finish unless `cancel_running` is true (they are then cancelled and counted in `cancelled`). Chat sessions are interactive and never blocked. `status.jobs_paused` shows the flag (it is in memory and resets to false on a host restart). `resume` admits queued jobs again; both are idempotent. `jobs/cancel` is idempotent: a queued, preparing, running, paused_interactive, awaiting_approval or finalizing job becomes `cancelled` (`cancelled: true`); a finished job (done, failed, cancelled, limit, declined) is returned unchanged with `cancelled: false`; an open chat session is closed as cancelled. Unknown id: 404, malformed id: 400. The API/MCP token is refused (403) on all of these.
- `models`: directories that contain a `config.json`, up to two levels under the configured model roots (`--model-dir`, `~/models`, ...). `path` is canonical and is accepted by `load` as is; `kind` is `mtp` when the name contains "mtp". Selecting a model in the app only records it; the host switches on an explicit `load` (and `unload` first if another model is loaded).
- `pack`: read-only view of `~/.strim/packs` as written by `strim evolve`: the `ACTIVE` fingerprint (ignored unless it names an existing pack directory), the number of packs, and the newest `provenance.jsonl` record by `createdAt` (`fingerprint`, `parent`, `round`, `val_gain_pp`, `dry_run`, `created_at`). `active_fingerprint` and `last_evolve` are absent (and `pack_count` is 0) on a host that never evolved.
- `enable_thinking` on `chat/open` and `chat/append` is forwarded to the chat backend (`ChatBackend.setThinking`). The default no-op keeps older backends working; the harness chat backend must implement `setThinking` for it to change the template flag (pending in StrimHarness). The app also reads per-turn token usage from the existing `harness_event` frames of kind `usage` (`prompt/cached/completion`).

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
| `STRIM_PREFILL_GAP_MS` | 3000 | Inter-token gap cap: while a new prompt prefills, a decode step is forced once prefill time since the last decode step plus the predicted next prefill chunk reaches this many ms. Trade-off: running streams can pause up to about this long (plus one decode step, ~45 ms; measured max 3.04 s) when a long prompt arrives (legacy `0`/`off`: max about 1.55 s). In exchange, 512-token c=4/c=8 p95 TTFT is about 8-9% lower and aggregate throughput is 4-6% higher; p95 pause for running streams is lower (1.20 s vs 1.53 s). `0` or `off` restores the legacy one prefill chunk then one decode step |
| `STRIM_PREFILL_BURST` | unlimited | Optional extra bound: max consecutive prefill chunks before a decode step while a stream is decoding. Ignored when the gap cap is `0`/`off` |
| `STRIM_PREFIX_TAIL_FLOOR` | 128 | Tail merge: a prompt of at most `STRIM_PREFIX_TAIL_MAX` tokens whose last prefix cut (normally the `<\|im_start\|>assistant` generation prompt) would leave fewer than this many tokens is prefilled as one chunk instead of body + tiny tail (saves one ~66 ms weight-streaming pass per short request). Such a prompt stores no trie node at that cut, so a follow-up turn reuses nothing from it (it recomputes at most `STRIM_PREFIX_TAIL_MAX` tokens). Longer prompts are unchanged. `0` restores the old split (as does `STRIM_PREFIX_CUTS=fixed`) |
| `STRIM_PREFIX_TAIL_MAX` | 768 | Largest prompt (tokens) the tail merge applies to; clamped to the max block size |
| `STRIM_MTP_PREFILL` | auto | `always` runs the MTP head during cold prefill for every request. Default: a request that will not speculate (sampled with `STRIM_SAMPLED_DEPTH0=1`, or draft depth 0) skips the head (~2.8% of prefill); prefetch always runs it |
| `STRIM_MTP_WINDOW` | 0 (see summary) | Cold prefill runs the MTP head only over the last N tokens of prompts longer than N (head KV is windowed via `MTPState.base`; trie head blocks before the window are absent and lookups degrade to a shorter head window). `0` = whole prompt |
| `STRIM_KV_PREALLOC` | off | `1` sizes the attention KV buffers once to the prompt length (rounded to 256) at the first cold-prefill chunk instead of regrowing per chunk. Measured +0.15% / -0.3% / -2.2% (16K/32K/4K): killed, off. |
| `STRIM_PREFILL_PIPE` | off | `1` submits non-final cold chunks with asyncEval (trie insert copies async, at most two chunks in flight). Measured +0.2% / +0.9% / +0.75% (4K/16K/32K), peak +2.2%: killed, off. |
| `STRIM_SERVER_LOG` | off | Also prints `[phase]` lines (template+tokenize, queue, per-chunk build/head/eval/insert, finish to first emit). |
| `STRIM_SPEC_DEVICEFEED` | unset | `1` keeps greedy draft tokens on the device and reads drafts and verify predictions in one host read per round (exact; measured 0.1-1.2 ms/pass, below the adoption gate) |
| `STRIM_PIPE_LAYERS` | 4 | Pipelined graph build: `asyncEval` after every N-th decoder layer of a decode, verify (M <= 8 rows) or batched-decode pass so the GPU starts while the host builds the rest (hides ~3 ms of host build per pass). `0` = off. Exact (bit-identical logits and ids); measured +9% decode at 4K-16K, +5..7% at c=4/8. Draft-chain / MTP-head / reseed graphs are 1 layer and flushed by the next verify pass, so they have no knob |
| `STRIM_WIRED_LIMIT_GB` | unset (off) | Opt-in MLX wired (residency-set) limit in GiB, applied once before the first weight load via a `WiredMemoryManager` ticket (the system `iogpu.wired_limit_mb` is never touched). Measured neutral to slightly negative (decode -0.5..-3%, prefill/TTFT +-1%, c=4/8 -0.6..-1.9%, post-idle first token not better; footprint and swap unchanged), so it stays off. Wired pages cannot be reclaimed under memory pressure: do not enable on a machine shared with other apps |
| `STRIM_PIPE_PREFILL_LAYERS` | 0 | Same for prefill chunks (> 8 rows). Default off: prefill is GPU-bound and measured neutral (1041 vs 1045 tok/s at 4K) |

| `STRIM_PREFIX_DISK` | unset (off) | `1` spills prefix-trie nodes to disk and falls back to them on a memory miss (also `strim serve --prefix-disk`). Zero overhead and no files when off. See `docs/PREFIX-DISK-2026-10-28.md` |
| `STRIM_PREFIX_DISK_DIR` | `~/.strim/cache` | Cache root (`--prefix-disk-dir DIR`, implies on); one 0700 subdirectory per model fingerprint, files 0600 |
| `STRIM_PREFIX_DISK_GB` | 20 | Byte budget of the disk cache; LRU leaves are evicted past it |
| `STRIM_PREFIX_DISK_FLOOR_GB` | 20 | Free space that must remain after a write; below it LRU files are evicted, then writes are skipped |

Disk prefix cache privacy: files hold KV/GDN/MTP tensors and a SHA-256 hash chain only, never token ids or text. They are still derived from prompts and readable by anyone with your user account: `strim cache clear [--dir DIR]` deletes them all, `strim cache stats` shows the size. Corrupt or mismatched files are ignored and deleted.

Fixed caps: `stop` at most 16 sequences of 1024 bytes; MCP JSON-RPC batches at most 16 requests; unfinished delegated jobs at most 64 (`JobManager.maxPending`, submit fails with `queueFull`).

Priority: the server grants every API-token holder the class `ServerConfig.apiPriority` (default `interactive`). `x-strim-priority`/`priority` can only lower a request (to `background`), never raise it above that class. `/health` returns only `{status, engine}`; the unhealthy reason is on the guarded `/metrics`.

- Reasoning delimiters never reach `content`: the shared output parser (`ToolCallParser`) drops a stray `</think>` with no open block (the model sometimes re-emits it after its answer), opens a new reasoning block on a later `<think>`, and keeps both literal inside code fences, inline code and tool arguments.
