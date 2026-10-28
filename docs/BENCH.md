# HTTP benchmark harness (`strim bench http`)

Swift HTTP benchmark tools (they replaced a set of Python scripts, now removed; see git history). Any OpenAI-compatible `/v1/chat/completions` server can be measured
(Strim, rapid-mlx, mlx-lm, tensorfold, omlx, mlx-vlm, llama.cpp, Ollama). No third-party dependencies; HTTP is
`URLSession`, prompts are sized with `StrimTokenizer`, processes are spawned with `posix_spawn`.

Code: `Sources/StrimBenchHTTP/` (library), `Sources/StrimCLI/Cmd_Bench.swift` (CLI glue, supplies the tokenizer),
tests in `Tests/StrimBenchHTTPTests/`.

## Commands

```sh
strim bench http run --engine strim --pass 1 --sb-reps 2 --replay-reps 2     # one engine pass
strim bench http all                                                          # full ABAB schedule
strim bench http scoreboard --arm strim=http://127.0.0.1:8203,qwen38-4bit --workloads W1,W3 --reps 3 --out-dir DIR
strim bench http replay --fixture F --arm a=URL,MODEL --arm b=URL,MODEL,cache=off-by-nonce --out-dir DIR
strim bench http replay --make-synthetic-fixture bench/results/x/synthetic-8turn.json --synthetic-turns 8
strim bench http sampled URL MODEL LABEL OUT.jsonl [N=3] [TOKENS=256]
strim bench http aggregate --dir bench/results/final-20261026                 # summary.md + results.json
strim bench http report DIR... [--check]                                      # regenerate (or diff) per-run summary.md
strim bench http engines                                                      # expanded launch recipes
strim bench http needle --url URL --model M --tokenizer PATH [--lengths 16384,65536] [--token-file F] [--out DIR]
```

Run from the repo root (relative `bench/`, `models/`, `.build/` paths follow the recipes). `scoreboard --dry-run
[--prompt-sha]` prints the request plan without sending anything.

| Subcommand | What it does (replaced the Python tool of the same name, removed) |
|---|---|
| `run` | launch, readiness, warm-up, scoreboard, replay, sampled, kill exact pids |
| `all` | the full ABAB schedule: Strim and rapid-mlx twice, then each other engine once |
| `scoreboard` | W1-W5, ABAB, RSS sampling, cache evidence, `summary.md`) |
| `replay` | agent-turn replay (default = final-run semantics; `--classic` = the older content-only variant) |
| `sampled` | sampled-decode check |
| `aggregate` | raw files to `summary.md` + `results.json` |
| `report` | regenerate a scoreboard/replay `summary.md` from an existing `raw.jsonl` |

## Workloads

- W1: 8-prompt corpus (`bench/ab_prompts.json`), greedy, 64 and 256 tokens.
- W2: corpus, temperature 0.6, seed 1234, 256 tokens.
- W3: cold 4K / 16K / 32K prompts (distinct salt per run, rep and size), 128 tokens.
- W4: 2 and 4 concurrent distinct cold 4K prompts, 64 tokens, barrier-started.
- W5: 4 concurrent requests sharing a 16K prefix, unique 512-token suffix each, 64 tokens.
- Replay: 8-turn recorded agent session (`bench/results/final-20261026/synthetic-8turn.json`), 48 tokens/turn, temperature 0,
  per (arm, rep) session tag so every session starts cold; `cache=off-by-nonce` prepends a per-request nonce.
- Sampled: one fixed prompt, temp 1.0, top_p 0.95, top_k 20, seed 1234, 256 tokens.

Every request is streaming with `stream_options.include_usage` and `ignore_eos: true`; thinking is disabled with
`chat_template_kwargs.enable_thinking=false` (`--no-no-think` omits it for scoreboard).

## Timing and counting rules (unchanged from the Python tools)

- `ttft_s` = first output delta minus send time. Output delta: scoreboard and sampled count `content`, then
  `reasoning_content`, then `reasoning`; replay also counts `tool_calls`; `--classic` counts `content` only.
- `decode_tps` = (completion_tokens - 1) / (t_last - t_first), completion_tokens from `usage`; needs n >= 2 and t_last > t_first.
- No usage block: scoreboard recounts the streamed text with the tokenizer (`retokenized`); without a tokenizer the row is
  `no_usage`. Replay and sampled mark it `no_usage`.
- `ignore_eos` not honoured (completion_tokens < max_tokens): row flagged `short`, decode dropped, TTFT kept, and a concurrent
  group with any excluded row has no aggregate tok/s. The aggregator reports short rows and ignores their decode values.
- `aggregate_tps` = total tokens / (last end - first send) for W4/W5 groups.
- Cache evidence: `usage.prompt_tokens_details.cached_tokens`, else the sum of cache-hit numbers appended to the server log
  during the request (`cache[ _-]?hits?\D{0,40}?(\d+)`), else unknown (W4 rows without evidence are `unverified`).
- Row-level errors (HTTP 4xx/5xx, timeouts, malformed events, a stream cut before `[DONE]` with no usage) become `error` rows
  with whatever timing was captured; they are never retried and are excluded from medians.
- ABAB: odd reps run the arms in reverse order. Shared prompts are built once per (workload, rep) and sent to every arm.

## Engines and process management

Launch recipes are data: `EngineTableData.json` (JSON text embedded in `Sources/StrimBenchHTTP/EngineTableData.swift`;
SwiftPM resources would need a `Package.swift` declaration). Placeholders: `${ROOT}`, `${SCRATCH}`, `${MODEL}`, `${HEAD}`,
`${GGUF}`, `${PORT}`. Override with `--engines-file F`. Contains the nine engines of the final run (including the supplemental
`tensorfold-ctx64k`), Ollama's Modelfile template and `ollama create`/`rm`, omlx's model-dir symlink, and the ABAB
schedule. A test checks every recipe against the recorded `meta.json` of `bench/results/final-20261026`.

- The server is started with `posix_spawn` in its own session (clean signal state), stdout and stderr to `server.log`.
- Readiness: poll `/v1/models` (Ollama `/api/version`) every second up to `--start-timeout`; early exit is reported.
- Kill: SIGTERM, wait up to 30 s, SIGKILL, for exactly the pids recorded (server plus descendants collected before the kill).
  Nothing is killed by name or port.
- The port must be free before launch, else the pass is skipped (`SKIP: port N busy`, exit 3).
- GPU lock: `run` and `all` hold `flock(2)` on `/tmp/strim-bench.lock` for each pass (interoperates with `lockf -k`). Use
  `--no-lock` when already running under `lockf`, `--lock PATH` for another file.
- Hardening: the lock file is opened `O_NOFOLLOW|O_CLOEXEC`, mode 0600, and must be a regular file owned by the current user
  (`STRIM_BENCH_LOCK` overrides the default path). Signals go only to processes whose identity (pid + kernel start time)
  still matches the one recorded, so a recycled pid is never hit. The server log is opened `O_NOFOLLOW` 0600 and a symlink there
  is refused. Without `--scratch` the scratch dir is a fresh `mkdtemp` 0700 dir; an explicit one must be an own, non-group/world-writable
  real directory; the Modelfile is created `O_EXCL|O_NOFOLLOW` 0600.
- A pass writes `<out>/<engine>/pass<N>/{meta.json,steps.log,server.log,warmup/,scoreboard/,replay/,sampled.jsonl,*.stdout.log}`;
  `--deadline-min` (default 50) stops starting new work; `--steps warmup,scoreboard,replay,sampled` re-runs a subset.

## Aggregation

`aggregate` reads `<dir>/<engine>/pass*/` and `<dir>/notes.json` (hand-written intro, versions, skipped engines, caveats) and writes
`summary.md` and `results.json` (cell = median over reps of per-rep medians, all passes pooled; winners; load and cache tables).
`--out-dir` writes elsewhere, `--path-label` sets the recorded `meta.path`, `--generated-by` sets `meta.generated_by`
(default `strim bench http aggregate`).

## Equivalence with the (removed) Python tools

Verified once against the Python tools before they were deleted. The tests now run against frozen data only: the committed `bench/results/final-20261026` outputs and `Tests/StrimBenchHTTPTests/Goldens/` (the Ollama Modelfile template as it was in `final_run.py`).

`swift test` (suite `EquivalenceGateTests`) runs against the committed `bench/results/final-20261026`:

| Check | Result |
|---|---|
| `aggregate` on a copy of the raw files vs committed `summary.md` | byte-identical (19604 bytes) |
| same vs committed `results.json` | byte-identical; 1412 numeric leaves compared bit-exact, 0 differences |
| per-run scoreboard, warm-up and replay `summary.md` regenerated by `report --check` | 37/37 identical |
| `replay --make-synthetic-fixture ... --synthetic-turns 8` vs committed `synthetic-8turn.json` | byte-identical (Python MT19937 `random` reimplemented) |
| fixture sha256 | same as recorded in the replay runs |
| engine recipes vs recorded `meta.json` (`cmd`, `env`, `cache`, `quant`) | 9/9 |
| W3/W4/W5 prompts (`--dry-run --prompt-sha`, real tokenizer) vs the Python scoreboard's `build_groups` | 6/6 sha256 identical |

Intentional differences:

- `results.json` `meta.generated_by` defaults to `strim bench http aggregate` (the test passes the old value `bench/final_aggregate.py` to prove
  byte equality, and a second test asserts this is the only difference with the default).
- The Python scoreboard was called by the Python final run with `--server-log NAME=PATH`, but scoreboard read that option as a plain path, so the
  log fallback never fired. `strim bench http scoreboard --server-log` accepts both `NAME=PATH` and a plain path and the pass
  passes the real log, so engines without `cached_tokens` now get log-derived cache evidence (`cache_info: "log"`). Raw files
  of earlier runs are unaffected.
- A stream that ends without `[DONE]` and without usage is an error row (`IncompleteRead`); Python raised the same from
  `http.client` on a truncated chunked body, URLSession hides it. `meta.tokenizer_note` names the Strim tokenizer instead of
  `tokenizers`. Error message texts differ (`HTTPError: HTTP Error 500: ...` is kept, URLSession texts are used for transport errors).
- Per-engine `*.stdout.log` hold the in-process step log instead of a subprocess stdout.

## Removed, not ported

The Python benchmark drivers (`bench/final_run.py`, `final_replay.py`, `final_sampled.py`, `final_aggregate.py`, `final_all.sh`,
`scoreboard.py`, `agent_replay.py`, `screen.py`, `compare.py`) were deleted from the tree; they are in git history. Not ported:

- `screen.py`: the one-off 5-minute engine screen (S1-S4). Superseded by the final all-engine benchmark; its raw results and
  `bench/SCREEN.md` stay as a historical record.
- `compare.py`: early ad-hoc serial/concurrent tool; superseded by `scoreboard`.

`bench/needle.py` (ZX-4417 long-context check) is ported as `strim bench http needle`: same prompt construction and pass rule, sent to an
OpenAI-compatible endpoint. The Python run drove a local `mlx_vlm` process with an MTP drafter; that setup now belongs to the server.

Kept data: `bench/ab_prompts.json`, `bench/prompt_seed.txt` and `bench/results/final-20261026/` (raw files, `notes.json`, fixture).
