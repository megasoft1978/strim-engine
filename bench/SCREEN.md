# Engine screen (historical)

Short screen that dropped engines that were not real competitors before the deep benchmark.
Same checkpoint for all rows where possible: `models/qwen38-4bit` (+ `models/qwen38-mtp-4bit` for MTP).

The Python driver (`bench/screen.py`) was retired; it is in git history and the full-history backup. The final all-engine
benchmark (`strim bench http`, see `docs/BENCH.md`) supersedes it. Raw data stay under `bench/results/screen-20261026*/`
(`env.txt`, `<engine>/raw.jsonl`, `<engine>/fingerprint.md`, `<engine>/server-*.log`, `summary.md`; every row carries `uptime` and `loadavg`).
A second run of one engine was labeled with a tag suffix (e.g. `strim (last)`); `--s3-4k` ran only the 4x4K concurrency step.

## Engines (launch command, features claimed)

| engine | launch (`{port}` = 8651) | checkpoint | features claimed |
|---|---|---|---|
| strim | `.build/release/strim benchspec|benchprefill|benchserve` (in-process CLI, no HTTP) | same | MTP depth 2; 4-slot batched scheduler |
| rapid-mlx (MTP, cache default) | `rapid-mlx --no-telemetry serve models/qwen38-4bit --port {port} --max-num-seqs 4 --speculative-config '{"method":"mtp","model":"models/qwen38-mtp-4bit"}'` (= /tmp/rapid_quality.sh) | same | MTP, batching, prefix cache (S1, S4) |
| rapid-mlx (cache off) | same + `--disable-prefix-cache --hybrid-cache-entries 0` (the rapid_quality.sh command plus the two cache flags; rapid_nocache.sh's tool-parser flags are not used) | same | MTP, cache OFF (S2, S3) |
| mlx-lm | `mlx_lm.server --model models/qwen38-4bit --port {port} --decode-concurrency 4 --prompt-concurrency 4` | same | batching, prompt cache; no MTP |
| tensorfold | `tensorfold serve models/qwen38-4bit --port {port} --parallel 4 --no-update-check` | same | 4 slots, drafts on by default |
| mlx-vlm | `mlx_vlm.server --model models/qwen38-4bit --port {port}` | same | VLM server, text path |
| omlx | `env HOME=<scratch>/omlx-home omlx serve --model-dir <scratch>/omlx-models --port {port}` with `qwen38-oq4e-mtp` linked inside | NOT same (`qwen38-oq4e-mtp`) | oQ quant, MTP |
| llama.cpp / Ollama | not run unless a local Qwen3.8-27B GGUF exists (none found; no download) | GGUF | n/a |

## Steps (per engine, one server resident, one engine at a time)

0. Fingerprint: version, launch line, `--help` keyword lines, startup log keyword lines, vendor
   source path + keyword-hit file count, checkpoint quantization from `config.json`, time-to-ready,
   RSS idle/peak of the process tree. Unknowns are written as `unknown`.
1. Warm-up: one 16-token request on distinct text, discarded.
2. S1 decode: `ab_prompts.json` code, natural, json; 64 new tokens, greedy, `ignore_eos`; 2 reps,
   alternating order (rep 1: code, natural, json; rep 2: json, natural, code).
   decode tok/s = (n-1)/(t_last - t_first); TTFT = first output chunk. Output chunks are `delta.content`
   or `delta.reasoning(_content)`. HTTP requests send `chat_template_kwargs: {enable_thinking: false}`
   so every engine answers in the same non-thinking mode (default Qwen template = thinking on; see below).
   Decode is rejected (n/a) if the stream has fewer than 2 chunks or exceeds 400 tok/s (bursty timing).
   Strim: `benchspec models/qwen38-4bit models/qwen38-mtp-4bit 64 2 <ids> 2` per prompt
   (ids from `/tmp/ab_<key>_ids.txt`, raw ids, no chat template).
3. S2 cold prefill: 2 reps, each a DISTINCT ~4K-token prompt, 16 new tokens.
   Prefill reported two ways: plain = prompt_tokens / TTFT; adjusted = prompt_tokens / (TTFT - one decode
   step), one decode step = 1 / decode_tps of the same row. The verdict uses the adjusted rate.
   Each prompt head is a fresh uuid, so no run or rep shares a prefix. Strim:
   `benchprefill models/qwen38-4bit 4096 2` (synthetic 4K prompt, fresh ModelCache per rep; prefill time only).
4. S3 concurrency: 4 concurrent DISTINCT ~1K prompts, 32 new tokens, 1 run (barrier-started).
   Strim: `benchserve models/qwen38-4bit 4 32 4 0 1024 0` (4 slots, prefix mode off, distinct equal-length
   prompts). Per-request TTFT = arrival -> first generated token (all arrive together), parsed from the
   benchserve table (`ttft_s`); end-to-end latency is kept per request too (`end_s`). Strim's sequential
   baseline is not part of the S3 numbers.
   S3x4K (`--s3-4k`): same step with 4 x 4K prompts; rapid-mlx on the cache-OFF launch (zero cached tokens
   asserted when the server reports it), strim via benchserve ctx 4096.
5. S4 quality proxy: the 3 S1 prompts' rep-1 greedy text plus the S2 rep-1 text, compared pairwise between
   HTTP engines (common prefix length in characters). A pair is compared only if both outputs are valid
   (no error, not empty); otherwise it is reported as ERROR, never as identical. Self-determinism
   (rep 1 vs rep 2 per engine) is also listed. Cheap proxy only.

Cache evidence: `usage.prompt_tokens_details.cached_tokens` if present, else the server-log regex
from the scoreboard (now `strim bench http scoreboard`). A row with hits is labeled `warm` and excluded from S2 and TTFT medians.
Cold rows (S2, S3) carry a `cold_check`: `PASS cached_tokens=0`, or `PASS` without a usage field and with no
cache-hit log lines (flagged as unverified from usage), or `FAIL` (row becomes warm and is excluded).
Token check: HTTP engines must agree on prompt_tokens and completion_tokens for the same prompt; a
server without a usage block (mlx-vlm) gets completion counts by retokenizing its streamed text
(`retokenized`) and prompt counts stay unverified.

Watchdog: each engine has a 300 s wall budget including startup. A server must answer `/v1/models`
within 90 s; two tries, then the engine is skipped with the reason (log tail included). Requests get
`min(120 s, remaining budget)`; steps past the budget are recorded as `deadline`. Only the process
group of the PID the script started is killed (SIGTERM, then SIGKILL); the port is then checked
(`port_free_after`). Failed steps are not retried by the script.

## Verdict (screening only)

- CONTENDER: decode median >= 0.85 x best decode AND prefill median >= 0.85 x best prefill (best over
  all measured rows, Strim included). Both are required; being ahead of Strim on one axis is not enough.
- BEHIND: measured on S1 and S2 but the CONTENDER condition does not hold (BEHIND rows list the ahead-of-Strim
  axes as a note).
- NOT COMPARABLE: S1 or S2 missing/skipped/warm, or a different checkpoint (oMLX).
- REFERENCE: the Strim row itself (in-process).

## Caveats

- Strim is in-process via CLI, not HTTP: no HTTP/TTFT overhead, no chat template. Its rows are labeled
  with their method in `raw.jsonl`. Its S1 decode is the aggregate over 2 reps per prompt (n = 3).
- HTTP rows use chat completions (chat template). Strim S1 uses raw token ids. Text outputs are
  therefore not identical inputs, and S4 cannot compare Strim to HTTP engines.
- Engines measured in this screen: rapid-mlx, mlx-lm, tensorfold, mlx-vlm, omlx (oMLX on another checkpoint).
  llama.cpp / Ollama: no local Qwen3.8-27B GGUF, not run.
- Earlier attempts (not in the results) showed mlx-lm and tensorfold streaming reasoning deltas under the
  default thinking template (scoreboard reads `content` only, so every S1 request had no content chunk), and
  mlx-vlm failing on a relative/unknown model name (fixed: absolute path / checkpoint id in requests).
- rapid-mlx persists its prefix cache to ~/.cache/rapid-mlx on shutdown and restores it on start, so launch
  A (cache default) starts with persisted entries; S1 rows show that as `hit`. Launch B (S2/S3) runs with
  `--disable-prefix-cache --hybrid-cache-entries 0`; its usage block has no cached_tokens field, so the cold
  check is PASS-unverified (no hit lines in the log).
- tensorfold S2 rep 2 reports 3 cached tokens (chat-template header shared with rep 1); the rule excludes it
  as warm, leaving n = 1 for its prefill.
- S4 has no Strim text reference: the CLI prints greedy ids only on parity MISMATCH.
  Fix would be a CLI flag to print ids on EXACT too (not changed here; Sources/ is out of scope).
- rapid-mlx runs two launches (cache default for S1/S4, cache off for S2/S3); the 300 s budget covers
  both launches together.
- S2 prompts are distinct per rep and per run (run id in the salt), so disk-backed caches from an
  earlier run cannot hit.
- Single run per engine, one server resident. Numbers are for screening, not for publication.
