# Handoff: Strim Swift engine (2026-10-26)

> Read first. Strim is a Swift-only, single-process local engine for Qwen3.8-27B (dense, 4-bit) with MTP
> speculation. `strim serve` runs the engine and the OpenAI / Anthropic / Responses HTTP front in one process.
> Architecture: `docs/ARCHITECTURE.md`. Gates and baselines below are copied from result files, not re-run
> in this pass (no GPU use while the soak test owns it). Anything not re-measured on HEAD is marked **unverified**.

HEAD at writing: `e55af50`. Local untracked run output from an earlier head-to-head pass is not part of the repo and is not cited here.

---

## 0. TL;DR

- Machine: Apple M5 Max, 64 GB, macOS 27.0.1. Package: swift-tools 6.0, platform macOS 14, MLX Swift 0.32.3 (exact).
- Models: `models/qwen38-4bit` (target) + `models/qwen38-mtp-4bit` (MTP head). Served model id = directory name `qwen38-4bit`.
- Serving path: `strim serve`. The Python `service/strimd.py` is legacy and not on the serving path.
- Corrected history (see section 5.1): the blocked-GDN prefill launch bug invalidated every earlier Swift
  prefill timing at S >= 512. The old "878-915 tok/s" and "4K near-tie flip caused by the kernel" explanations
  are superseded. Use only post-fix numbers.
- Post-fix prefill (in-process, cold, 4K): **1019 and 1012 tok/s** (two run medians) (`bench/results/screen-20261026b/summary.md`, S2).
- Decode corpus (8 prompts x 64 tok, depth-2 MTP): **55.1 decode-only**, 7/8 EXACT, prose MISMATCH at token 53
  (`corpus.log` (local run log, not committed)).
- Concurrency: default decode policy `auto` (time-sliced MTP vs plain batch). Greedy code B=2 aggregate
  73.7 tok/s vs 48.9 plain batch (`bench/results/rr-wave3/concurrent-decode.txt`).
- Memory: default prefix trie budget 12 GiB, accounted at ~215 MiB per 1024-token node. The pre-fix real cost was
  ~1.18 GiB per node; two retention fixes landed (section 5.5). **Post-fix real per-node cost: unverified.**
- Not done: SwiftUI chat app, MCP endpoint, disk-persisted prefix cache, forced `tool_choice`, images,
  Swift-native Qwen3.6-35B-A3B MoE (section 8).

---

## 1. Start here

```bash
cd path/to/strim-engine                                    # run from repo root (draft vocab path is cwd-relative)
swift build -c release --disable-sandbox                    # .build/release/strim
swift test --disable-sandbox                                # not run in this pass; test count unverified
```

Serve (token lives in `~/.strim/token`, 0600, created if missing; never print it):

```bash
.build/release/strim serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8203
# prints: engine ready ... / strim serve: http://127.0.0.1:8203 / auth: bearer token required; token file: ...
```

Options: `--port N` (default 8203), `--token-file PATH`, `--no-auth` (loopback dev only). Routes: `docs/ARCHITECTURE.md` section 5.
All `STRIM_*` variables with defaults: `docs/ARCHITECTURE.md` section 15. CLI command list: section 16.

Claude Code (argv and env mirror `SoakArgvs.claudeArgv` / `claudeEnv` in `Sources/StrimSoak/SoakClients.swift`):

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:8203 \
ANTHROPIC_AUTH_TOKEN="$(cat ~/.strim/token)" \
claude -p "<prompt>" --model qwen38-4bit --output-format json --permission-mode dontAsk \
  --tools Read,Edit,Write,Glob,Grep,Bash
# full allow/deny lists and isolated CLAUDE_CONFIG_DIR: Sources/StrimSoak/SoakClients.swift
```

Codex (custom responses provider; mirrors `SoakArgvs.codexArgv` in `Sources/StrimSoak/SoakClients.swift`):

```bash
STRIM_SOAK_TOKEN="$(cat ~/.strim/token)" codex exec --json --ephemeral --ignore-user-config --skip-git-repo-check \
  -C <repo> -s workspace-write -m qwen38-4bit \
  -c 'model_provider="strim"' \
  -c 'model_providers.strim={name="strim", base_url="http://127.0.0.1:8203/v1", env_key="STRIM_SOAK_TOKEN", wire_api="responses"}' \
  -c 'approval_policy="never"' -- "<prompt>"
```

Background priority: send `x-strim-priority: background` (Claude: `ANTHROPIC_CUSTOM_HEADERS`; Codex: `http_headers`).
Default is interactive.

Soak harness (owns the GPU while running; take the lock, do not run gates concurrently):

```bash
lockf -k /tmp/strim-bench.lock .build/release/strim soak --duration 45
```

### Gates (run on HEAD before any merge that touches Sources/)

```bash
B=.build/release/strim; M=models/qwen38-4bit; H=models/qwen38-mtp-4bit
$B gen $M 16                                  # ids must equal bench/results/ab-20261026-131238/gen16-swift.txt
$B benchspec $M $H 64 0 "$IDS"                # depth 0: parity EXACT (IDS = ids of a prompt, see below)
$B checkprefix $M 4096 3 $H                   # ALL PASS
$B checkprefix $M 8192 3 $H                   # ALL PASS
$B enginebench $M $H --only=concurrent-decode # ALL PASS
swift test --disable-sandbox                  # all targets
```

Prompt ids: `bench/ab_prompts.json` tokenized with `strim tokenize --model models/qwen38-4bit --text FILE` (Python tokenizer removed 2026-10-27). Write ids as comma-separated text to a scratch file and pass `"$(cat file)"`.

Gate status (recorded, not re-run in this pass):

| gate | recorded result | file | commit date of file |
|---|---|---|---|
| gen16 ids | identical to `gen16-swift.txt` (diffed) | `ab-20261026-131238/gen16-{reference,swift}.txt`, `mem-20261026/gen16-check.txt` | 13:23 (before all GDN fixes; prompt is short, so blocked path not used) |
| benchspec depth 0 | EXACT, 5/5 reps, 123 tokens | raw file not published | 13:23 (before all GDN fixes) |
| checkprefix 4096 (no MTP) | ALL PASS | `prefix-cache-exact-20261026/checkprefix-4096.log` | 17:48 (before conv and parent fixes) |
| checkprefix 4096 + MTP | ALL PASS | `dec-wave3-20261026/checkprefix-4096-mtp.log` | 18:33 (before conv and parent fixes) |
| checkprefix 8192 + MTP | ALL PASS | `dec-wave3-20261026/checkprefix-8192-mtp.log` | after 18:33 (before conv and parent fixes) |
| enginebench concurrent-decode | ALL PASS | `rr-wave3/concurrent-decode.txt` | 22:18 |
| swift test | **unverified this pass** | - | - |

Re-run checkprefix and gen16 on HEAD: the MTP checkprefix logs predate the conv-state and parent-link fixes (19:56, 19:58).

---

## 2. Objective and status

Objective: beat same-machine local engines on Qwen3.8-27B for single-stream and 2-4 concurrent prefill/decode, with
exact tokens. Keep gen16 and depth-0 EXACT.

Status: **active, not complete.** Current picture (post-fix results only):

| dimension | Strim (post-fix) | best same-machine competitor (same screen run) | source |
|---|---:|---:|---|
| S1 decode, 64 tok, in-process | **63.6** | rapid-mlx 45.8 (HTTP) | screen-20261026b S1 |
| S2 cold 4K prefill, in-process | **1019 / 1012** (two run medians) | rapid-mlx 995.9 (HTTP) | screen-20261026b S2 |
| S3 4 x 1K cold, aggregate | 23.3 | rapid-mlx 22.8 | screen-20261026b S3 |
| HTTP greedy-64 decode | 65.4 | rapid-mlx 50.3 | h2h-20261026 W1 |
| HTTP 4 x 16K shared prefix, aggregate | 3.35 (TTFT 46.4 s) | rapid-mlx 3.33 (TTFT 73.7 s) | h2h-20261026 W5 |
| HTTP c4 aggregate decode | 12.6 | rapid-mlx 13.1 | h2h-20261026 W4 |

Caveats: the in-process rows and HTTP rows are different methods (screen marks Strim rows REFERENCE). The h2h run cites
`strim serve` at commit `a797890`, which is **not in this repo** (`git cat-file` fails), so h2h Strim numbers are
unverified against HEAD. Under the default prefix budget, the agent replay (8 turns, 4.1K to 40.8K) gave prefill sum
54.0 s and T8 TTFT 8.5 s vs rapid cache-on 49.5 s and 7.3 s (h2h-20261026/summary.md).

---

## 3. Environment

- macOS 27.0.1 (26A434), Metal 4. Swift tools 6.0. MLX Swift 0.32.3. Python removed 2026-10-27; tokenization via `strim tokenize`.
- Models present in `models/`: `qwen38-4bit`, `qwen38-mtp-4bit`, `qwen38-mtp-8bit`, `qwen38-6bit`, `qwen38-8bit`,
  `qwen38-oq4e-mtp`, `qwen38-dflash2` (drafter, not default), `qwen36-a3b-4bit` (Qwen3.6-35B-A3B, `model_type: qwen3_5_moe`;
  4 shards present, download logs show completed; **no MoE code in Sources**, see section 8).
- `vendor/` (gitignored) holds cloned competitor sources. `bench/draft_vocab_48k.json` is the default truncated
  draft vocab (MTP drafting only; verify always uses the full lm_head). Regenerate with `strim draft-vocab` (run from the repo root; flags in `docs/ARCHITECTURE.md` section 7).

---

## 4. Code map

| area | path |
|---|---|
| targets and dependency graph | `Package.swift`; see `docs/ARCHITECTURE.md` section 1 |
| model, layers, GDN, MTP, spec decode | `Sources/StrimCore/` (`QwenModel.swift`, `Layer.swift`, `Attention.swift`, `GDN.swift`, `GDNMetal.swift`, `MTP.swift`, `SpecStream.swift`, `SpecSampling.swift`) |
| caches | `Sources/StrimCore/Cache.swift`, `Batch.swift` (per-sequence KV), `PrefixCache.swift` (exact trie) |
| weights | `Sources/StrimCore/Weights.swift` (draft vocab, MTP prefix/dense fallback) |
| tokenizer, template, prompt ledger | `Sources/StrimTokenizer/`, `Sources/StrimTemplate/`, `Sources/StrimPrompt/` |
| engine thread, scheduler, admission | `Sources/StrimEngine/` (`EngineCore.swift`, `Scheduler.swift`, `Admission.swift`, `EngineAPI.swift`, `LocalEngineClient.swift`) |
| HTTP and API adapters | `Sources/StrimHTTP/`, `Sources/StrimServer/` |
| CLI | `Sources/StrimCLI/main.swift` (`args[1]` dispatch), `Commands.swift`, `Cmd_*.swift`, `BenchServe.swift` |
| menu-bar app | `Sources/StrimApp/main.swift` (targets legacy `strimd` endpoints, see section 8) |
| soak harness | `strim soak` (`Sources/StrimSoak`), `bench/soak/README.md` |
| legacy Python service and harness | `service/strimd.py`, `harness/qwen/`, `integrations/harness2/` (current status **unverified**) |

---

## 5. Results

### 5.1 Corrected history (read before using old numbers)

- The blocked GDN prefill kernel (`GDNMetal.runBlocked`, used for S >= 512) was dispatched with `grid: (4, Hv, B)`.
  Metal counts threads, so this launched 4 threads instead of 4 threadgroups. **Fixed in `b0d9ca1` (17:20, Oct 26)**
  with `grid: (4 * 256, Hv, B)` and a serial-parity test. (The old note names `a7e9c45`; that hash does not exist in this repo.)
- Consequence: every Swift prefill timing for S >= 512 taken before `b0d9ca1` is invalid. This includes
  `bench/results/prefill-20261026/*`, `ab-20261026-131238` benchprefill rows (855-923 tok/s), `BLOCKED-GDN-PREFILL-2026-10-26.md`
  tables, and the older "878-915 tok/s" and "890-920 tok/s" figures in earlier handoffs.
- The "4K first token differs (105883 vs 27745)" explanation (f32 reduction order) is superseded. Post-fix runs still show
  4K near-tie divergence between the default path and the serial path, but the cause is not isolated (section 6).
- Post-fix 4K cold prefill (in-process, screen S2): medians 1019 and 1012 tok/s, row range 1008-1023 (binary built 17:50, after the fix).

### 5.2 Decode and MTP

- Speculative greedy decode, `SpecStream`, exact rollback. Start depth 2. Adaptive climb: depth 2 to 3 at EWMA acceptance
  > 0.82, 3 to 4 at > 0.84, fall back at < 0.60; floor 2, ceiling `STRIM_MTP_MAX_DEPTH` (default 4). `STRIM_MTP_FIXED=1` disables adaptivity.
- Decode corpus (`corpus.log` (local run log, not committed), run date not in file): mean 55.11 decode-only, 54.95 end-to-end.
  Per prompt: natural 41.5, code 64.9, sql 62.5, rust 59.0, csvpy 53.5, prose 37.5, math 62.0, json 58.7 tok/s.
  Parity EXACT on 7 of 8; prose MISMATCH, first diff at generated token 53 (spec 561, greedy 8169).
- Gen16 and depth-0 EXACT are the hard gates. Depth-2 spec vs greedy is **not** a hard gate (near-tie baseline).

### 5.3 Batching, scheduler, decode policy

- Default `STRIM_DECODE_POLICY=auto`: time-sliced MTP (round-robin) vs plain batch, chosen from measured tables with
  hysteresis. `batch` and `roundrobin` are the fixed modes (`Scheduler.swift`).
- `rr-wave3/concurrent-decode.txt` (aggregate tok/s, B=2 / B=4):
  - greedy code: batch 48.9 / 75.6; roundrobin 74.2 / 70.7; auto 73.7 / 74.8.
  - greedy prose: batch 49.0 / 75.8; roundrobin 44.2 / 47.2; auto 47.7 / 73.7.
  - sampled code B=2: batch 47.7; auto 74.1.
  - Roundrobin sequences are bitwise identical to single-stream: `[PASS]` on every greedy row; sampled roundrobin
    16/16 identical-to-solo. Batch and auto: sampled 0/16 identical-to-solo. enginebench: ALL PASS.
- In-batch MTP: **NO-GO** for general use (`docs/BATCH-MTP-2026-10-26.md`). Verify cost grows steeply with B and S; prose
  gains at B >= 2 are <= 1.25x at best before draft cost.
- `benchbatchprefill` / `BatchModel.prefill` remain experimental; not serving (`docs/BATCH-PREFILL-2026-10-26.md`, numbers pre-fix).
- Per-sequence preallocated KV landed in `e4a40dd` (17:49), replacing copy-on-append. The old "4K batch decode 2-3 tok/s/req"
  figure predates it: **unverified on HEAD**.

### 5.4 Exact prefix cache

- Prefill runs in chunks at absolute multiples of 1024 tokens (`PrefixPrefill.chunk`). Each trie node is one block and holds
  KV, GDN state, conv state and the MTP head block for that block. Hit and miss run identical arithmetic per chunk.
- `checkprefix` (see section 1): hit == miss for logit hash and 16 greedy tokens; eviction keeps parity; unrelated prompts miss.
  4K: miss 3.994 s, hit 1.022 s (3.91x) (`prefix-cache-exact-20261026/checkprefix-4096.log`). 8K with MTP: miss 22.906 s, hit 6.084 s (3.76x).
- Hot-continue (`checkprefix` section h): tokens identical over 20 tokens in both MTP logs, but append logits are **not
  bitwise** (max |hot - cold| 0.1875). Treat as a near-tie baseline.
- The older shared-prefix benchserve prototype (41.9 tok/s aggregate at 4K) is **superseded** and was not token-exact.
  Do not cite it as a Strim result.
- Not implemented: disk persistence, LCP or radix matching across different prefixes, multi-prefix eviction policy beyond LRU.

### 5.5 Memory

- Default budgets: prefix trie 12288 MiB (`PrefixStore.defaultBudgetMB`, about 57 nodes); admission budget 70% of RAM
  (44.8 GiB on 64 GB); MLX buffer-cache limit 4 GiB; `STRIM_MAX_SESSIONS` 8; `STRIM_HOT_SESSIONS` 2.
- Admission (`Admission.swift`): fixed = 0.95 x weight bytes + trie budget + MLX cache limit; plus 800 MiB chunk transient;
  per request: tokens x 64 KiB (+4 KiB if MTP) + 147 MiB GDN state; evicts oldest hot sessions, else rejects.
- Pre-fix measurement (`docs/MEMORY-2026-10-26.md`): each trie node really cost ~1,175-1,184 MiB while accounted at 215 MiB,
  because the GDN conv state was a view into the whole `convIn` buffer, and `Node.parent` was strong (retain cycle leaked dropped tries).
  Fixes: `f5c0ce3` (owned 3-row conv buffer, 19:56), `3321082` (weak parent, 19:58), `4020c52` (admission formula, 20:01).
  The memory doc's "proposal, not applied" items P1 and P2 are now applied; its budget recommendations are superseded.
- **Unverified:** post-fix real memory per node, leak closure in a full run, and the 40K-session eviction behaviour.
  Re-measure with `STRIM_MEM_TRACE=1` before relying on the 12 GiB default.

### 5.6 Quality and checkpoints

- Quantization A/B (oQ4e-mtp, 6-bit, 8-bit): see `docs/MODEL-VARIANTS-2026-10-26.md` and `docs/QUANTIZATION-2026-10-25.md`.
  Prior handoff summary: oQ4e not better on code PPL and slower; standard 4-bit kept. **Re-verified in this pass: no.**

### 5.7 Harness and MCP

- Local Codex + Qwen works through `/v1/responses` (legacy `strimd.py`). The Swift server implements Responses with
  function tools, but `tool_choice: required` is **not enforced** (no constrained decoding).
- No MCP endpoint exists in `Sources/` (no MCP code found). The "mcp__strim" failure in old notes refers to the legacy service.

---

## 6. Known baselines (near-tie, not bugs unless the gate says so)

| case | recorded | source |
|---|---|---|
| depth-2 spec vs greedy, corpus prose | MISMATCH, first diff at token 53 (other depth-2 rows in the unpublished raw file ab-20261026-131238, lines 103-123 also MISMATCH, prompt not attributed) | `corpus.log` (local run log, not committed), raw file (not published) |
| depth-2 spec vs greedy, prose 17-53 | range from earlier notes; only 53 verified | - |
| 4K spec vs greedy (post-fix) | MISMATCH at generated token 14 (p4k_a) and 18 (p4k_c); "Not EXACT at 4K (2/2)" | `longctx-validate-20261026/summary.md` |
| 4K greedy-16, default vs serial path | 16/16, 16/16, 16/16, 6/16, 4/16 over five 4K prompts; margins 0.000-0.125 at divergence | same |
| hot-continue vs cold | tokens identical 20/20; logits not bitwise | `dec-wave3-20261026/checkprefix-*-mtp.log` |
| batch vs solo (sampled) | not bitwise; roundrobin bitwise | `rr-wave3/concurrent-decode.txt` |
| batched qmm tiling | logits drift 0.15-0.45 vs B=1 | `docs/BATCH-MTP-2026-10-26.md` |

---

## 7. Failed or stopped experiments (do not repeat blindly)

- GDN qkv+z (or qkv+z+b+a) fusion for prefill: slower; reverted (previous handoff; not found in `docs/SWIFT-NEXT.md`, so unverified).
- Batched prefill for 4K: slower and token-mismatched; 1K gains only 1.04-1.14x (pre-fix numbers; `docs/BATCH-PREFILL-2026-10-26.md`).
- In-batch MTP for B >= 3 or prose: NO-GO (`docs/BATCH-MTP-2026-10-26.md`).
- 8-bit MTP head: higher acceptance but pass time dominated; rejected.
- Fixed depth 4 at high load: regresses; adaptive controller now gates it.
- ANE prefill (oMLX path, 718 tok/s at 4K on 128 GB): slower than GPU path here.
- macOS 26.2 deployment target for NAX: no measured change; reverted.
- `STRIM_GDN_BATCH_METAL=1` (per-sequence Metal recurrence for batched decode): opt-in only, default off (near-tie flip in
  benchserve; see `GDN.swift` comment and `docs/BATCH-MTP-2026-10-26.md`).
- Trusting competitor 15.9 / 61 tok/s numbers without checking prefix-cache hits: do not.

---

## 8. Known gaps and risks

1. Near-tie non-exactness is accepted only where the gate says so (section 6). Long-context token parity beyond the gates is not guaranteed.
2. Not implemented: SwiftUI chat app; MCP endpoint; disk-persisted prefix cache; forced `tool_choice`; image, video and document
   input (rejected with 400 at every adapter); crash-recovery journal (`EngineStats.lastHeartbeat` is set; no recovery path reads it).
3. Swift-native Qwen3.6-35B-A3B (`qwen3_5_moe`, MoE with shared expert): **no MoE, router or expert code in `Sources/`**. The
   speed-mode A3B number in `docs/COMPETITORS-2026-10-25.md` (127-129 tok/s) is a competitor (mlx-vlm) measurement, not Strim.
   Support status: unsupported in Swift; weights on disk only.
4. `StrimApp` (menu-bar) calls `/v1/strim/status` and `/v1/strim/switch` on `STRIM_URL` (default `http://127.0.0.1:8200`).
   Those endpoints belong to the legacy `strimd.py`; `strim serve` does not implement them.
5. `DraftVocab` lookup is cwd-relative (`bench/draft_vocab_48k.json`). Run from the repo root or set `STRIM_DRAFT_VOCAB`.
6. Machine load varies a lot (Chrome, UTM VM). Record `uptime` and load in every log; interleave arms for comparisons.
7. Benchmarks with old numbers: see section 5.1 before comparing anything.

---

## 9. Next steps (ranked)

1. Re-run the gates on HEAD (section 1); re-run checkprefix with MTP after `f5c0ce3` and `3321082`.
2. Measure post-fix trie memory per node and a 40K-token multi-turn session with `STRIM_MEM_TRACE=1`. Confirm or revise the 12 GiB default.
3. Matched post-fix prefill and decode runs against rapid-mlx over HTTP (same `strim serve` build, same load). Acceptance: prefill >= rapid at matched load.
4. Disk-persisted prefix cache, LCP/radix matching, and an eviction test for multi-prefix workloads.
5. Forced `tool_choice` via constrained decoding (or explicit rejection of `required`).
6. Qwen3.6-35B-A3B: decide whether to implement MoE in Swift or leave it as a competitor-only speed mode. Do not claim it until the code exists.
7. SwiftUI chat app and MCP endpoint: not started.

---

## 10. Raw logs and result directories

- `bench/results/ab-20261026-131238/`: gen16 reference and swift ids, depth-0 and depth-2 parity (pre-fix benchprefill rows in the unpublished raw file).
- `corpus.log` (local run log, not committed): decode corpus, 55.1 decode-only.
- `bench/results/screen-20261026b/`: four-engine screen (S1 decode, S2 4K prefill, S3 4 x 1K); post-fix Strim rows.
- `bench/results/h2h-20261026/`: HTTP head-to-head vs rapid-mlx (cites commit `a797890`, not in repo).
- `bench/results/prefix-cache-exact-20261026/`, `dec-wave3-20261026/`: `checkprefix` logs (4K, 8K, with and without MTP).
- `bench/results/longctx-validate-20261026/`: 4K and 1K greedy-16 agreement, spec parity.
- `bench/results/rr-wave3/concurrent-decode.txt`: decode policy comparison, enginebench ALL PASS.
- `bench/results/mem-20261026/`: pre-fix memory traces (r7-full, e1/e2 ablations). Accounting claims superseded; see 5.5.
- `bench/results/prefill-20261026/`, `batchprefill-20261026/`, `batchsplit-20261026/`: pre-fix or experimental; do not cite prefill numbers from them.
- `bench/soak/results/<timestamp>/`: local soak runs (git-ignored); committed summaries are in `bench/results/soak-20261027/`: `summary.txt`, `tasks.jsonl`, `server.jsonl`.
- Docs: `MEMORY-2026-10-26.md`, `BATCH-MTP-2026-10-26.md`, `BATCH-PREFILL-2026-10-26.md`, `BLOCKED-GDN-PREFILL-2026-10-26.md`
  (pre-fix tables), `PREFIX-CACHE-2026-10-26.md` (superseded prototype), `MATCHED-2026-10-26.md`, `COMPETITORS-2026-10-25.md`.

---

## 11. Practical warnings

- Any change to prefill, GDN, or the prefix cache: re-run gen16, depth-0 benchspec, and both checkprefix runs. Any batch or decode-policy change: re-run `enginebench --only=concurrent-decode`.
- Benchmarks are load-sensitive. State `uptime` and whether the prefix cache was warm.
- Compare decode-only with decode-only. `SpecStats` reports prefill seconds separately.
- `STRIM_GDN_BLOCKED=0` restores the serial fused kernel (A/B only). `STRIM_GDN_TENSOR=1` forces the reference TF32 recurrence.
- `vendor/` and `models/` are gitignored. Do not commit model files or clones.
- The token is read from `~/.strim/token`. Never paste it into logs, argv or results.

---

## 12. Unverified in this pass

- `swift build` and `swift test` on HEAD; current test count.
- Gate re-runs on HEAD (all gate rows in section 1 are from logs).
- Post-fix real memory per trie node; leak closure in a full run; 40K-token session behaviour.
- Post-fix 4K decode and batched 4K decode numbers (only the old 2-3 tok/s/req figure exists).
- h2h Strim numbers (built from commit `a797890`, not in repo).
- Quality table (oQ4e, 6-bit, 8-bit PPL), oQ4e adoption decision, and the competitor tables in section 6 of the old handoff.
- Legacy harness status (`harness/qwen`, `integrations/harness2`, Codex 0.164 MCP behaviour).
- Qwen3.6-35B-A3B load status in Swift (no code path found; not tested).
- Exact contents of the exactness contract labels "C1-C3" referenced in the brief: not in `strim_architecture_decisions.md`.

---

*If you pick this up: section 1 gates first, then section 5.1 before touching any prefill number.*

## 13. Removed Python references

independent Python MLX reference removed 2026-10-27; the serial (non-speculative) path is the in-repo reference; old references in the history bundle.
