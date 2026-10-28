# Security review: strim serve HTTP surface (2026-10-28)

Read-only review of HEAD 5fd9716 (source read from the shared working tree; where it differs from HEAD this is stated). Reviewer lane: sec-scan-server-auth.


## Findings


Severity key: Critical / High / Medium / Low / Info. "Verified" = reproduced or read to the exact line; "Unverified" = reasoned from code only.

### F1 (High, verified in isolation) Integer overflow trap from client-controlled `max_tokens` kills the host
- Sources/StrimServer/ChatRequest.swift:~139 (`max_tokens`/`max_completion_tokens` accepted for any Int >= 1; `.int` JSON values up to Int64 pass `intValue`), consumed at Sources/StrimEngine/EngineCore.swift:416 -> Sources/StrimEngine/Admission.swift:62-63 (`tokens * (65536 + 4096) + 147 MiB`, unchecked-by-hand Swift Int multiply).
- Exploit: any holder of the API token (or anyone, with `--no-auth`) POSTs `{"messages":[{"role":"user","content":"x"}],"max_tokens":200000000000000}` to /v1/chat/completions (also /v1/messages, /v1/responses). 2e14 * 69632 > Int64.max, Swift traps (SIGTRAP), the whole `strim serve` process dies (model unloaded, all jobs lost; launchd KeepAlive restarts after 30 s so it is repeatable). `9223372036854775807` traps earlier on `newTokens + maxTokens`.
- Verified: replicated the exact arithmetic in a standalone `swiftc -O` binary; `max_tokens=1000000` prints 69793103872, `2e14` and `Int.max` exit 133 (SIGTRAP). The full-server crash was not run (no GPU workloads); the call chain was read, no clamp exists between parse and `requestBytes` (grep of StrimEngine/StrimServer/StrimHost for any context/max clamp found none).
- Fix: clamp in `ChatRequest.parse` (and the Anthropic/Responses parsers) to a server cap, e.g. `min(n, 1 << 20)` or the model context; and use `multipliedReportingOverflow`/saturating math in `MemoryModel.requestBytes`, rejecting with `insufficientMemory`.

### F2 (Medium, verified by reading) No cap on concurrent connections, no header/body read timeout, no idle timeout (slowloris, fd/memory exhaustion)
- Sources/StrimHTTP/HTTPServer.swift:130-139 (`accept` unconditionally registers every connection), HTTPConnection.swift:109-147 (`receive` waits forever; nothing times out a half-sent head or a body that stops after Content-Length: 16777216), HTTPRequestParser.swift:58 (waits for contentLength bytes).
- Exploit: a local process (or a browser page with a loopback Origin, see F11) opens thousands of connections and trickles one byte per minute; each holds a Task, a parser buffer (up to 16 MiB body + head) and an fd. With 16 MiB x N this is a memory DoS of the host that also hosts the model. Unauthenticated: the auth check happens only after a full request is parsed, so the attacker needs no token. Host/Origin checks also run post-parse.
- Fix: cap open connections (e.g. 64) in `accept` (cancel the NWConnection beyond), add a head-read deadline (10 s) and a body inactivity timeout (30 s) and a keep-alive idle timeout (60 s) in `readLoop`; reject based on `Content-Length` before buffering for routes that allow small bodies (control: 1 MiB, MCP: 1 MiB; only chat needs 16 MiB).

### F3 (Medium, verified by reading) Pipelining flood defeats `maxBuffered`; unbounded request queue per connection
- Sources/StrimHTTP/HTTPRequestParser.swift:30,37 vs HTTPConnection.swift:93-94,120-123: the parser drains its buffer into `AsyncStream<Item>` (default unbounded buffering) while `handle` runs strictly in order. A client that pipelines thousands of 16 MiB-bodied requests behind one slow request (e.g. a long SSE generation) keeps all of them in memory; `maxBuffered` only bounds the unparsed remainder, not the parsed queue.
- Fix: make the stream `.bufferingOldest(8)`-bounded and stop calling `receive()` while the queue is full (back-pressure), or close the connection when more than N requests are pending.

### F4 (Low, verified by reading) Unauthenticated `/health` leaks engine state; no rate limit on failed auth
- Sources/StrimServer/StrimOpenAIServer.swift:96,158-166: `/health` is registered without `guarded`; on failure it returns `unhealthy_reason` (free text from the engine, may include model paths or error text). Host/Origin checks still apply (HTTPServer.dispatch), so it is reachable only by local processes. Severity Low in practice; listed here because the release notes advertise it as a public liveness endpoint.
- No throttling of 401s: a local process can brute-force, but the token is 256-bit hex (TokenStore.swift:30-34) so this is infeasible. Info.
- Fix: return only `{status}` on /health, log the reason locally.

### F5 (Medium at HEAD, verified by reading; partly fixed in an uncommitted working tree) API/MCP token holder can reach the control token
- At HEAD: Sources/StrimHost/Host.swift:133 registers only `paths.token` with `Redactor`; Sources/StrimHarness/Sandbox.swift:36 `secretLiterals = [".strim/token", ".netrc"]` omits `.strim/control-token`; Sources/StrimMCP/Tools.swift `checkProjectDir` blocks only `/`, home and ancestors of home; Sources/StrimHarness/GitWorktree.swift `isSecretPath`/`validateCloneSource` (non-git cwd is `cp -R` cloned) had no `control-token` rule; `allowedRoots` is empty by default.
- Exploit: MCP client sends `strim_task {cwd:"~/.strim" (absolute), access:"read", task:"cat control-token"}`. The directory is cloned into the job worktree (readable by the sandbox, which only denies `.strim/token`), the agent prints the control token, `Redactor` does not know it, and the text returns to the MCP client. The API/MCP token thereby upgrades to the control token (load/unload models, approve and apply patches, open chat sessions), defeating the scoping promised in Sources/StrimControl/ControlPlane.swift:18-19 and docs/CONTROL-API.md. Same shape for `~/.config/gh`, `~/.docker`, `~/.kube`, `~/Library` clones.
- Status: `git status` shows an uncommitted change by another lane adding `Sources/StrimHarness/SensitiveDirs.swift` (refuses `~/.strim`, `~/.ssh`, `~/.config`, `~/Library`, `~/.claude*`, ... in `Tools.swift`, `GitWorktree.validateCloneSource`, `HarnessRunner`, `HostPolicy.violation`) and a `control-token` rule in `isSecretPath`. That closes the cwd route; it must be committed before release. NOT verified by running.
- Remaining fix after that lands: also register the control token with `Redactor` (Host.swift:133 and CLI Cmd_Serve.swift), and add `.strim` (whole directory) to `SandboxProfile.secretSubpaths` so a future cwd bug cannot expose it.

### F6 (Medium, verified by reading) `ResponseStore` retains up to 256 full conversations (count-bounded, not byte-bounded)
- Sources/StrimServer/ResponsesAdapter.swift:8-24 (`capacity: 256`, each entry is the whole message list of a /v1/responses request, `store` defaults to true as in the OpenAI API). Request bodies may be 16 MiB (HTTPLimits.maxBodyBytes).
- Exploit: an API client posts 256 distinct 16 MiB responses; the parsed OrderedJSON tree is several times larger than the text, so several GiB stay resident until evicted, competing with the model's memory budget (the engine budget does not count this heap). 
- Fix: bound by total bytes (e.g. 64 MiB, evict oldest), and/or lower the body limit for /v1/* to 4 MiB.

### F7 (Medium, verified by reading) Admission: unbounded waiter queue, no wall-clock deadline, self-declared priority
- Sources/StrimAdmission/PriorityGate.swift:82-98 (waiters dictionary has no cap), Sources/StrimServer/AdapterRuntime.swift:37-45 and StrimOpenAIServer.swift:220-224 (slot held for the whole generation), ChatRequest.swift:~74-82 (`x-strim-priority` / body `priority` chosen by the client; default is `interactive`), `ignore_eos` also client-controlled (ChatRequest.swift:~145).
- Scenario: one API client sends `max_tokens` near the memory limit with `ignore_eos:true` on `maxInflight` connections and holds every slot for as long as the engine can decode; there is no per-request deadline and no per-client fairness, so other clients (and background jobs, after the 8-pass starvation boost) wait indefinitely behind it. Opening thousands of queued connections costs memory (F2/F3) because nothing bounds `waiters`. The engine memory budget (Sources/StrimEngine/Admission.swift `decide`) does reject oversize requests with `insufficientMemory` rather than OOM, which is good, but only after F1 is fixed.
- Cancel/disconnect cleanup is correct (checked: `responder.onClose { wait.cancel() }`, `cancelWaiter` releases core state, `slot.release()` on every error path, generation `Task` cancelled on close).
- Fix: cap waiters (e.g. 4 x maxInflight, 429 beyond), add a max request duration (e.g. 15 min) cancelling the engine request, clamp `max_tokens` (F1), and let only the control/MCP path select `background`.

### F8 (Low-Medium, verified by reading) MCP and job queue growth: no cap on queued jobs or JSON-RPC batch size
- Sources/StrimJobs/JobManager.swift:94-107 (`submit` always appends and persists; no queue limit; `maxConcurrent` defaults to 1), Sources/StrimMCP/MCPRoute.swift:70-90 (a 1 MiB batch may contain tens of thousands of `tools/call`, each processed sequentially, each submit writes a job record and each waits up to `wait_s` <= 25 s).
- Exploit: a token holder queues thousands of 36 KB jobs (task 20 000 chars + context 16 000) filling disk under ~/.strim/jobs and delaying legitimate jobs; one HTTP handler is pinned for hours. Retention (`retentionCount`) trims only finished jobs.
- Fix: reject `submit` when queued >= 64 (JobError.queueFull -> MCP isError), cap batch length at 16.

### F9 (Low, design) Permissive defaults for the MCP/API token
- Sources/StrimHost/HostConfig.swift:27-30: `requireApproval=false`, `maxAccess=.write`, `allowedRoots=[]`. Holding the bearer token is therefore equal to running a sandboxed (no-network, home-read-denied, writes confined to a worktree) coding agent on any directory except the sensitive ones, producing patches. Containment is good, but nothing prompts the user. `--no-auth` (Cmd_Serve.swift:34,98) removes even the token: any local process or other local user can call /mcp and /v1/*; the control plane still needs the control token (verified in ControlGuard.check: `.none` only passes for `status` when `!apiRequired`).
- Fix: document in README/SECURITY.md; consider printing a one-line warning when `allowedRoots` is empty, and refuse `--no-auth` unless `STRIM_ALLOW_NO_AUTH=1`.

### F10 (Low, verified by reading) TokenStore hardening gaps
- Sources/StrimServer/TokenStore.swift:16-37: (a) `open(path, O_WRONLY|O_CREAT|O_TRUNC, 0o600)` without `O_NOFOLLOW`/`O_EXCL`: a pre-planted symlink at `~/.strim/token` (needs write access to ~/.strim, so same-uid only) is followed; (b) an existing parent directory keeps its mode (0700 applied only when created), so a `--token-file /some/shared/dir/token` is not protected; (c) existing token files are chmod'ed to 0600 only after being read, and any non-empty string (e.g. `abc`) is accepted as the bearer token; (d) no check that the file is owned by the current user. Control token shares this code.
- Fix: `O_NOFOLLOW|O_EXCL` for creation, `lstat` check (regular file, uid == getuid(), mode & 077 == 0, else fail), require >= 32 chars, `chmod 700` of the parent only if created by us, warn otherwise.

### F11 (Info, verified by reading) CORS echo for any loopback origin
- Sources/StrimHTTP/HTTPServer.swift:148-170, Responder.swift:165: any page served from `http://localhost:<any port>` or `127.0.0.1` gets `Access-Control-Allow-Origin` echo and a preflight 204 with requested headers. It cannot authenticate without the token, but it can read the unauthenticated `/health` body and see 401s. A compromised dev server on another loopback port is the realistic source. No `Allow-Credentials` is sent, so cookies are not involved (the API does not use cookies).
- Fix (optional): no CORS headers unless `STRIM_CORS_ORIGINS` lists the origin.

### F12 (Low, verified by reading the SBPL generator; not executed) Sandbox reads everything outside /Users and /Volumes
- Sources/StrimHarness/Sandbox.swift:176-196: deny-read only for `/Users`, `/Volumes` and the real home; `/tmp`, `/private/var/folders/**` (the user's TMPDIR with other tools' caches and sockets), `/Applications`, `/opt/homebrew`, `/private/etc` are readable. A prompt-injected agent can read another tool's temp file and return its content to the MCP client (no network, so no direct exfiltration; the data goes back through the job result, where the Redactor catches only known token shapes). 
- Fix: deny `/private/var/folders` and `/private/tmp` (re-allow the job tmp), or run the job under its own TMPDIR subtree only.

### F13 (Info) MCP registration commands place the token in argv and in client config
- Sources/StrimHost/McpConfig.swift, Sources/StrimAppCore/Services.swift:`McpTemplate`: `claude mcp add ... -H "Authorization: Bearer $(cat ~/.strim/token)"` expands the token on the command line (visible to `ps` for same-uid processes during execution, stored in plaintext in the client's config, e.g. ~/.claude.json). Codex variant uses `--bearer-token-env-var`, which is better. Document it; prefer the env-var form for Claude too if the client supports it.

### F14 (Info) Residual risk, patch apply
- The apply path is strong (see "Checked and fine"). Remaining human-factor risk: an injected agent can add `.github/workflows`, `package.json` scripts, Makefile, pre-commit config, `.envrc` lines in a patch; they take effect when the user later builds or enters the directory. `touchedSensitive` flags such paths only for verify status. Surface touched build/CI/script paths in the approval UI (`ControlMapping.detail`) as a warning, not just in verify.
- `.git` check covers case-folding via `lowercased()`; HFS-ignorable unicode variants (e.g. `.g\u{200C}it`) rely on git's own `core.protectHFS` default on macOS: unverified.

## Checked and found fine
- Bind address: `requiredLocalEndpoint = 127.0.0.1` only (HTTPServer.swift:79); no flag to bind 0.0.0.0 exists (`serve` options enumerated in Cmd_Serve.swift:34-45; `--host` is not accepted, unknown `--` options fail). IPv6 loopback is not bound (so `[::1]` Host is accepted but unreachable: harmless).
- DNS rebinding: `dispatch` rejects any non-loopback `Host` and any non-loopback `Origin` before auth and routing (HTTPServer.swift:174-182); HTTP/1.1 requires exactly one `Host` (HTTPRequestParser.swift:135-138); control routes re-check Host, Origin and `Sec-Fetch-Site: cross-site` (ControlSupport.swift:65-80). Origin `null` is rejected.
- Request parsing: head 64 KiB, body 16 MiB, duplicate/conflicting Content-Length rejected, Transfer-Encoding rejected (no smuggling), obsolete folding and control chars rejected, request line strictness, JSON depth capped at 512 (OrderedJSON.swift:305,324); MCP/control bodies capped at 1 MiB; headers `Authorization` compared in constant time (length not hidden, acceptable for 256-bit tokens).
- Token scoping: control routes use `ControlAuth` with SHA-256 digests compared in constant time; the API/MCP token unlocks only `GET /v1/strim/status` (ControlSupport.swift:71-79); `addOpenRoute` handlers all call `ControlGuard.check` (events, chat/append, jobs/{id}, chat DELETE verified); the control token is not accepted on `/v1/*` or `/mcp` (guarded() compares only the API token). Tokens are 32 random bytes from `SecRandomCopyBytes`, files 0600, dir 0700 on creation. No token in URLs (query tokens not read anywhere), none printed (`Cmd_Serve` prints paths only; `strim control-token` prints a path), `STRIM_SERVER_LOG` logs ids and timings only, `APIError.from` returns engine error text but never request headers; the app's `TokenReader` refuses symlinks, wrong owner, outside-home paths and modes with group/other bits and never logs.
- SSE: control `/events` capped at 8 subscribers with 429, per-subscriber buffer `.bufferingNewest(2000)`, ping, one shared poller that stops with the last subscriber; chat SSE uses back-pressured `send` (slow reader stalls the handler, not memory), client disconnect cancels generation (`onClose { work.cancel() }`) and chat turns (`orphanTurnGrace` watchdog).
- Memory: engine admission (`Admission.decide`) accounts prompt + `maxTokens` KV per request against a budget and rejects with `insufficientMemory`; sessions pooled by LRU (`maxSessions` 8, STRIM_MAX_SESSIONS); chat sessions capped by `maxChatSessions`; ResponseStore is capped by count (but see F6).
- MCP tool arguments: strict property allow-list, length caps (task 20 000, context 16 000, verify `maxVerifyCommandChars`), NUL checks, cwd absolute and `..`-free and a directory, home/root/ancestors refused, `files` repo-relative without `..`/`~`/absolute (max 20), `access` enum, `wait_s` clamped to 25 s; `HostPolicy` re-checks `access` and canonical (symlink-resolved) `cwd` against `allowedRoots` both at call time and again in the executor.
- verify command: not injectable beyond what the token holder can already do, because it runs through the same `sandbox-exec` runner (no network, writes confined to the worktree and job tmp, fresh HOME/TMPDIR, agent processes killed first, caches purged, dependency-dir and test-file changes downgrade `verified` to `verified_modified_tests`). The agent never sees an editable copy of the command.
- Sandbox: `(deny network*)` (no AF_INET/AF_UNIX connect), signals and process-info limited to the sandbox, mach-lookup/shm/iokit denied, home read-denied except the workspace, secret denies placed last (`.ssh .aws .gnupg .codex Library/Keychains .config/gh .strim/token .netrc ~/.claude*`), git `hooks/ info/ config refs HEAD index` write-denied case-insensitively, git binary resolved to a trusted path (not the xcrun shim), environment scrubbed (`env: [:]`).
- Prompt injection: repo-provided AGENTS.md and skill index are wrapped as `untrusted` data with the closing tag escaped (PackLoader.swift:63-74), redacted before truncation; tool surface is bash (sandboxed), file tools with `WorkspacePolicy` (symlink-resolving, deny list for `.env`, `.ssh`, `.pem`, `.git/config`, hooks), no network tool, so an injected README cannot exfiltrate over the network or write outside the worktree; its only channel is the returned summary/patch, which a human reviews.
- Redactor: Aho-Corasick over registered secrets (plain, base64, percent-encoded forms) plus PEM, bearer, AWS, URL-credential and `password=` patterns; applied to commands, bash output, verify output and MCP error text (BashTool.swift:59,70; HarnessRunner.swift:244; Tools.swift:`errorResult`). Gap: control token not registered (F5).
- Patch apply: validated twice (own header parse plus `git apply --numstat -z`), `.git`/absolute/`..`/quoted/control-char paths, symlink and submodule modes refused, every path confined to the recorded cwd after resolving the deepest existing ancestor, `RepoSafety` refuses filter/merge/diff/include/url config, `config.worktree`, `info/attributes` and risky `.gitattributes`, `git apply` without `--3way/--index`, hardened `-c` flags and scrubbed env, 60 s timeout with process-group kill, approval bound to `patch_sha256` over the very bytes applied (TOCTOU closed), per-job apply lock and decision marker, and the job's own recorded access re-checked.
- Model loading: `load` accepts only absolute canonical paths under configured roots (`~/models`, the started model's parent, `--model-dir`), no `..`, NUL-free.
- LaunchAgent: label validated, binary must be a real executable regular file outside temp dirs, not group/world-writable, no world-writable ancestor; plist (0644) contains no secrets (token only by path); runs as the logged-in user in the `gui/<uid>` domain; log dir 0700; `ThrottleInterval 30`; installer never runs `launchctl`. Host lock uses `O_NOFOLLOW` 0600 + `flock`. OrphanSweep kills only same-uid processes carrying the `STRIM_JOB=` marker while holding the host lock.
- Menu-bar app: `host_url` restricted to plain loopback http with a port, no userinfo/path/query; redirects refused (`NoRedirectDelegate`); host spawned from a validated binary with output to a 0600 `~/.strim/host.log`; token read only via `TokenReader`. No auto-update framework (Sparkle etc.) and no `.entitlements` file exist in this repo for StrimApp, so there is no update channel or entitlement to review; if a signed `.app` is shipped, enable hardened runtime and keep entitlements empty.

## Not done / unverified
- No live-server test was run (no GPU workloads, no build): F1 is verified only for the arithmetic; F2/F3 are read-only conclusions (no slowloris client run); F12 and F5's fix are not executed under `sandbox-exec`.
- Not reviewed: StrimEngine internals beyond admission, StrimTokenizer/Template parsing fuzzing, StrimSite, bench targets (StrimBenchHTTP, StrimSoak), and the other lane's overlapping review (docs/ commit b6fae73, process launches).

## Summary
Critical 0, High 1 (F1), Medium 5 (F2, F3, F5, F6, F7), Low/Low-Medium 4 (F8, F9, F10, F12), Info 4 (F4 low, F11, F13, F14).
Top 5: F1 max_tokens overflow crash; F5 control token reachable via cwd=~/.strim (unredacted); F2/F3 no connection/read-timeout/pipeline limits; F7 unbounded admission waiters and no request deadline; F6 ResponseStore memory.

## Fix status (lane sec-fix-server-f1-f8)

| Finding | Status | Commit | Notes |
|---|---|---|---|
| F1 | Fixed | c76f18f | Output tokens clamped in `ChatRequest.parse` (shared by chat, Anthropic, Responses); `requestBytes`, `Admission.decide`, `EngineCore` sizing saturate. Also bounded: `stop` (16 x 1024 B), default `top_k` file value. `n` must be 1, `top_k`/`seed` are not used in arithmetic. Regression: `AdmissionOverflowTests` (old code: SIGTRAP), `ServerHardeningTests`. |
| F2 | Fixed | b793f4f | Connection cap, head (10 s), body (30 s inactivity + rate-based total), idle (120 s) deadlines, all before auth. Residual: no per-route body limit (16 MiB stays for all routes). |
| F3 | Fixed | b793f4f | At most 8 queued pipelined requests, then 429 and close. Residual: worst case per connection is still 8 x 16 MiB parsed bodies. |
| F4 | Fixed | c76f18f | `/health` returns `{status, engine}` only; reason stays on guarded `/metrics`. |
| F5 | Other lane | - | Skipped by assignment. |
| F6 | Fixed | c76f18f | `ResponseStore` bounded by 256 entries and `STRIM_RESPONSE_STORE_MB` (64) of serialized size; larger single conversations are not stored. |
| F7 | Fixed (partly) | c76f18f | Waiter cap (`STRIM_MAX_QUEUE`, 429), queue deadline (`STRIM_QUEUE_TIMEOUT_S`, 503), priority ceiling `ServerConfig.apiPriority`, background output cap. Residual: no wall-clock limit on a running generation (output length is bounded by `STRIM_MAX_OUTPUT_TOKENS` instead); one API token means one class, so per-client fairness is not added. |
| F8 | Fixed | 58b3396 | `JobManager.maxPending` (64) -> `JobError.queueFull`; MCP batch <= 16. |
| F9 | Residual | - | Policy/documentation change, not trivial. |
| F10 | Residual | - | Needs TokenStore rework (O_NOFOLLOW/O_EXCL, lstat checks); same-uid only. |
| F11 | Residual | - | Optional. |
| F12 | Other lane | - | Skipped by assignment. |
| F13, F14 | Residual | - | Info. |

Limits and defaults: docs/CONTROL-API.md, "Server limits".
