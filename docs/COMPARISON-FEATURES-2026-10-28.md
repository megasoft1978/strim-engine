# Functionality comparison (2026-10-28)

Scope: Strim (0.1.0, repo HEAD) vs rapid-mlx 0.15.7 and mlx-vlm 0.7.10 (both benchmarked in bench/results/h2h-final-20261028). oMLX 0.4.5.dev1 and mlx-lm 0.31.2 were only benchmarked/installed in older form (oMLX in docs/COMPETITORS-2026-10-25.md; it is NOT the 0.7.x release), so they appear only where `--help` proves a flag. Every cell is verified from the installed package, its `--help`, its bundled README, or this repo. Unknown = not verified; absence of a grep hit is reported as "no evidence found", not as proof of absence.

Sources. RM = /opt/homebrew/Cellar/rapid-mlx/0.15.7_1 (libexec/.../site-packages/rapid_mlx, README.md, `rapid-mlx serve --help`). MV = .venv-sprint/lib/python*/site-packages/mlx_vlm (0.7.10, METADATA, server/*.py, `mlx_vlm.server --help`). OM = `omlx serve --help` (0.4.5.dev1). ML = `mlx_lm.server --help` (0.31.2, global python). Strim = README.md, docs/STATUS.md, docs/CONTROL-API.md, docs/MCP.md, docs/ADMISSION.md, docs/ARCHITECTURE.md, docs/APP.md.

| Row | Strim | rapid-mlx 0.15.7 | mlx-vlm 0.7.10 | oMLX 0.4.5.dev1 / mlx-lm 0.31.2 |
|---|---|---|---|---|
| Language / processes | Yes: Swift, one process, one binary (README.md l.3; Package.swift deps only mlx-swift 0.32.3) | Python (RM METADATA: Requires-Python >=3.10, fastapi/uvicorn); process count Unknown (has `--listen-fd`, `--watchdog-ppid`) | Python (MV METADATA); single uvicorn server | Python (both; `omlx` and `mlx_lm.server` are Python entry points) |
| Install footprint | 34 MB release binary (.build/release/strim) + weights; no interpreter | 159 MB brew keg (RM, `du`) plus Python deps in its libexec | 256 MB venv (.venv-sprint, `du`, includes mlx, transformers, opencv) | Unknown |
| MTP speculative decoding | Yes: default, adaptive depth 2-4 (docs/STATUS.md) | Yes: `--speculative-config '{"method":"mtp",...}'` (RM help; used in h2h) | Partial: `--draft-kind {dflash,eagle3,mtp}` exists (MV help); not enabled in h2h, "defaults: no MTP" (README l.213) | mlx-lm: draft-model speculation (`--draft-model`, ML help), not MTP; oMLX: Unknown |
| Cross-request prefix/KV cache | Yes: exact trie of 1,024-token chunks, KV+GDN+MTP state, LRU byte budget, hit == miss bitwise, memory only (README l.131, l.168) | Yes: radix or hash index (`--prefix-cache-index`), hybrid-state snapshots, disk save on shutdown (RM README l.57, help `--disable-disk-caches`); exactness Unknown | Yes in code: APC hash-block cache + SSD tier (MV apc.py header, "APC itself is exact"); but h2h showed cached=0 with server defaults (h2h-final summary), so opt-in via env | oMLX: paged SSD cache (`--paged-ssd-cache-dir`); mlx-lm: `--prompt-cache-size`/`-bytes` |
| Continuous / concurrent batching | Yes: batched decode, join/leave (docs/STATUS.md; README W5) | Yes (`--max-num-seqs`, RM README) | Yes (`--max-num-seqs`; MV app.py "continuous batching enabled") | Yes: oMLX `--max-concurrent-requests`; mlx-lm `--decode-concurrency` |
| Priority / fair admission | Yes: interactive vs background classes, memory-based admission (docs/ADMISSION.md, STATUS.md) | Partial: `--scheduling-policy {fcfs,shortest_validated_tail}` + deferral cap (RM help); no priority classes found | No evidence found in server/*.py | Unknown |
| Chunked prefill | Yes: 1,024-token chunks interleaved with decode, `STRIM_PREFILL_GAP_MS` (docs/MEMORY-2026-10-26.md, CONTROL-API.md) | Yes: `--prefill-step-size`, `--prefill-batch-size` (RM help) | Yes: `--prefill-step-size` (MV help) | Yes: both expose `--prefill-step-size`/prompt concurrency (ML help); oMLX Unknown |
| OpenAI Chat API | Yes (README l.79 area, docs/STATUS.md) | Yes (`/v1/chat/completions`) | Yes (`/chat/completions`, MV app routes) | Yes (servers) |
| Responses API | Yes `/v1/responses` with store (README, CONTROL-API.md `STRIM_RESPONSE_STORE_MB`) | Yes `/v1/responses` (RM routes) | Yes: `/responses` incl. compact, input_items (MV routes) | Unknown |
| Anthropic Messages | Yes `/v1/messages`, count_tokens (STATUS.md) | Yes `/v1/messages`, `/anthropic/v1/messages` | Yes `/messages`, `/messages/count_tokens` | Unknown |
| Tool calling | Yes: built-in streaming Qwen parser (docs/ARCHITECTURE.md StrimTemplate); `tool_choice=required` NOT enforced | Yes: many parsers incl. `qwen_tool_parser.py`, `qwen3coder_tool_parser.py` (RM tool_parsers/); `--tool-call-parser` | Yes: tool parser inferred from processor (MV server/__init__.py) | Unknown |
| Reasoning/thinking separation | Partial: template renders thinking, forced off when tools declared (ARCHITECTURE.md l.113); separate `reasoning_content` in output not verified | Yes: `--reasoning-parser {qwen3,deepseek_r1,...}` (RM help) | Yes: `reasoning_content` handling, `--thinking-budget` (MV openai.py, help) | Unknown |
| Structured output | No: no `response_format`/constrained decoding in Sources/StrimServer (grep); ARCHITECTURE.md l.226 lists it as missing | Likely Yes: llguidance dep + json_schema in server.py (not exercised) | Yes: `response_format` in schemas.py, structured.py, llguidance dep (not exercised) | Unknown |
| Streaming | Yes (SSE) | Yes | Yes | Yes |
| Server auth token | Yes by default: bearer from ~/.strim/token, separate control token, constant-time compare (CONTROL-API.md) | Optional: `--api-key` (RM help); default loopback bind | Optional: `--api-key` (MV help); default host 0.0.0.0 (MV help) | Optional: oMLX `--api-key`; mlx-lm: no flag (ML help), default 127.0.0.1 |
| Memory budget planner / swap protection | Partial: admission by memory budget (80% RAM default), headroom in status (MEMORY-2026-10-26.md, CONTROL-API.md); no OS swap guard found | Yes: `--gpu-memory-utilization`, `--resident-memory-limit-gb`, `--cache-memory-percent`, disk preflight (RM help); swap behaviour beyond h2h (0 MB growth) Unknown | Partial: `--max-kv-size`, `--expert-cache-gb`; no budget planner found | oMLX: `--memory-guard {safe,balanced,aggressive}` (OM help); mlx-lm: none |
| Built-in agent harness / sandbox | Yes: sandbox-exec worktree jobs, harness-run verify, SHA-256 patch approval (README l.136; Sources/StrimHarness/ClaudeSandbox.swift). Reviewed, not live-fuzzed (README l.146) | Partial: `agents <name> --setup` configures external agents, `/v1/agent`, computer-use API (RM help/routes); local-model sandboxed job runner not found | No evidence found | No evidence found |
| MCP | Yes: MCP server at `/mcp`, 4 tools (README l.107, docs/MCP.md) | Partial: MCP client side `--mcp-config`, `/v1/mcp/*` routes (RM); acting as MCP server Unknown | No evidence found | oMLX has `--mcp-config` (OM help); mlx-lm none |
| Menu-bar app | Partial: SwiftUI MenuBarExtra app builds (docs/APP.md), "a shell" (STATUS.md); README roadmap l.179 still lists it as pending, reconcile before publishing | Partial: "Rapid-MLX Desktop (macOS app)" (RM README l.55); menu-bar form Unknown | No | oMLX: its own README (quoted in RM README) says menu-bar app, not checked locally |
| License | MIT (LICENSE) | Apache-2.0 (RM METADATA) | MIT (MV METADATA) | Unknown |

## What we can claim honestly

Verifiably true of Strim and not (verified) of the others:
1. Single-process, single-binary Swift engine, 34 MB, no Python runtime (rivals: Python, 159-256 MB).
2. Exact prefix cache: a hit equals a miss bitwise (chunk-aligned, README l.51). No rival documents exactness in what we checked (mlx-vlm APC claims exact for K/V only, hybrid caveats Unknown).
3. Interactive vs background priority classes with memory-based admission (docs/ADMISSION.md); rapid-mlx has only fcfs/shortest-tail, mlx-vlm none found.
4. Built-in sandboxed worktree agent harness with harness-run verify and SHA-256 patch approval, plus an MCP delegation endpoint.
5. Token auth on by default, with a separate control token; rivals bind to loopback or all interfaces and auth is opt-in.
6. MTP + prefix trie + batching tested together in one engine: 2.7-2.9x aggregate with 4 agents on a shared 16K prefix, 24-41% decode lead over rapid-mlx (h2h-final-20261028, 64 GB M5 Max, Qwen3.8-27B 4-bit only).

Where rivals are ahead:
- Model breadth: Strim runs one model only (README l.152); both rivals run many models, plus vision, audio, embeddings, images.
- Structured output (json_schema): both rivals have it; Strim has none, and `tool_choice=required` is unenforced.
- Reasoning-parser coverage and tool-parser coverage across model families (rapid-mlx), `--thinking-budget` (mlx-vlm).
- Disk-persisted prefix cache (rapid-mlx on shutdown, mlx-vlm SSD tier): closed 2026-10-28 as opt-in `STRIM_PREFIX_DISK=1`, exact (bitwise-verified incl. MTP), checksummed, 20 GB LRU budget; see `docs/PREFIX-DISK-2026-10-28.md`.
- Memory controls: rapid-mlx has richer knobs; oMLX has `--memory-guard`.
- Desktop app maturity and agent ecosystem wiring (rapid-mlx `agents --setup`, 12 agents wire-verified per its README, not re-verified by us).
- Platform support: Strim is tested only on a 64 GB M5 Max.

Not verified here: oMLX 0.7.x, any rival's exact-cache claim, live json_schema behaviour of either rival, process counts of rapid-mlx.
