# Speed wave 2, lanes L1b (tail merge) and L3 (MTP head in cold prefill), 2026-10-28

Verdict: **L1b accepted, default ON** (512-token TTFT -10..-14%, one documented trade-off for short multi-turn chats).
**L3(a) accepted, default ON** (non-speculating requests skip the head: -1.8% at 4K, -2.2% at 16K prefill; no change for speculating requests).
**L3(b) windowed head: not implemented (blocked, see section 6).**
Builds: old = HEAD 6582248 snapshot, new = HEAD + changes, both release, `/tmp/strim-build-l1b{-old,}`. All runs under `lockf /tmp/strim-bench.lock`, 5 s watchdog (`bench/h2h/watchdog.sh`), swap growth 0 everywhere, no aborts. Load average 3-7 (other workers).

## 1. Why 523 tokens became 512 + 11
`CutPolicy.blockEnd` cuts before `<|im_start|>assistant` once the block is >= `assistantMin` (256) tokens, so that the next turn reuses the whole previous prompt as a trie node. A 523-token chat prompt is 512 body tokens plus the 11-token generation prompt (`<|im_start|>assistant\n<think>\n...`): cut at 512, tail chunk of 11. The tail is a full 64-layer pass that streams all weights (~66 ms for 11 tokens vs 593 ms for 512).

## 2. L1b change (`Sources/StrimCore/PrefixCache.swift`)
`CutPolicy.tailFloor` (128) / `tailMergeMax` (768): a prompt of at most 768 tokens (first block only, `pos == 0`) whose last cut would leave < 128 tokens is prefilled as ONE chunk (no cut, no trie node). Chunk <= 768 < max block 1536, so memory per chunk is lower than before. Lookup uses limit = count-1, the merge test is monotone in limit, so a lookup never walks to a node the chunk loop would not cut (hit == miss preserved). Longer prompts, later blocks and the cut policy are unchanged. Env: `STRIM_PREFIX_TAIL_FLOOR=0` or `STRIM_PREFIX_CUTS=fixed` restore the old split; `STRIM_PREFIX_TAIL_MAX`. Documented in `docs/CONTROL-API.md`.
Why not merge for longer prompts: the cut before the generation prompt is what makes turn n+1 reuse turn n (replay prefill sum 52.3 -> 49.7 s). Merging it for long prompts would lose that for ~66 ms.
Tests (`PrefixStoreTests`, 2 new): single chunk for 523-style prompt, floor/max/pos>0 untouched, lookup/loop monotonicity, defaults. Mutation (merge disabled): both FAIL; old code does not compile against them.

## 3. L1b A/B, ABAB x3 (`ab/`, `ab/table.tsv`, `ab/pct.tsv`), A = old, B = new, 3 passes each (pass values)
| cell (512-token prompts, W4s) | A | B | change |
|---|---|---|---|
| c=1 TTFT p50 s (5 reqs/pass) | 0.670 0.669 0.669 | 0.603 0.603 0.598 | **-10.1%** |
| c=4 p50 / p95 TTFT s | 1.463 1.440 1.467 / 2.964 2.929 2.965 | 1.277 1.273 1.272 / 2.568 2.558 2.558 | **-12.9% / -13.0%** |
| c=8 p50 / p95 TTFT s | 2.923 2.917 2.931 / 6.070 6.016 6.077 | 2.551 2.556 2.526 / 5.190 5.213 5.143 | **-12.7% / -14.2%** |
| c=4 / c=8 aggregate tok/s | 60.0 60.8 60.9 / 68.0 69.2 68.7 | 63.9 63.9 / 72.1 71.2 (3 passes in table.tsv) | +5% / +4% |
| cold 4K prefill (W3 ttft s) | 4.184 4.238 4.199 | 4.184 4.260 4.2xx | within noise (policy unchanged >768) |
| cold 16K (W3 ttft s) | 17.39 17.25 17.39 | 17.28 17.46 | within noise |
| W5 shared 16K c=4 ttft s | 21.08 21.12 20.78 | 20.97 21.12 | same; extra 3xABAB `ab-w5/`: 20.82 20.92 20.87 vs 20.79 20.92 20.82 |
| 8-turn replay (4K+ prompts) prefill sum s | 51.00 50.32 49.87 | 51.58 50.91 50.66 | +1.3%, policy unchanged for these prompts (all > 768): run-to-run drift, B always second in a pair |
| short 8-turn replay (`short-8turn.json`, prompts 490..2562) sum s | 3.659 3.621 3.639 | 4.143 4.120 4.123 | **+13%: worse** (see below) |

Short replay detail (`ab-short/`): turn 1 0.62 -> 0.555 s (-10%), but turn 2 0.43 -> 0.97 s (+0.54 s): turn 1 (490 tokens) left no trie node, so turn 2 recomputes everything (cached 0 vs 483). Turns 3+ identical. Trade-off: every short first turn saves ~65 ms; a conversation that continues pays ~0.5 s once at turn 2. Break-even is ~1 continued chat per 8 one-shot requests. Prompts > 768 tokens (agent prompts with tools) never hit this. `STRIM_PREFIX_TAIL_FLOOR=0` removes it. Owner may prefer a lower `STRIM_PREFIX_TAIL_MAX` or OFF for chat-heavy use.
Memory (peak phys_footprint per cell, `watch.csv`): w4s1 A 23.7 / B 22.0 GB, w4s 25.9 / 23.9, w3 23.3 / 23.4, replay 27.1 / 27.2; W5 peaks bimodal in BOTH arms (A 26.5-31.1, B 27.3-31.9 over 6 passes each; same chunking on 16K prompts). Swap growth 0. Memory +0 on the affected cells (lower). Gate (>= 5% TTFT on short cells, cold prefill within 1%, memory +0): **met**; replay gate met on the standard fixture, not on the short-chat fixture (documented).

## 4. Exactness (`parity/`)
- `checkprefix 4096`: ALL PASS (chunked vs one-shot -0.2%). `checkprefix 8192 +MTP`: ALL PASS (head KV, seed, 64 spec tokens, hot-continue identical; accept 88%, 3.56 tok/pass hit and miss), re-run on the final binary with L3 code: ALL PASS.
- `checkprefixcuts` (+MTP head): ALL PASS, plus new section (f): tail-merged vs old 512+tail split, max |dlogit| 0.125 (n=304), 0.125 (n=516), 0.109 (n=704), argmax unchanged in all; follow-up hit == miss logits for each. (Earlier cut-policy work accepted 0.13 at 16K; bf16 rounding scale.)
- `gen 16` old vs new: ids identical (`gen16-*.log`; 3-token prompt, chunking unchanged).

## 5. L3(a): skip the MTP head when it will not be used (`EngineCore.swift`)
`j.mtp` was created for every cold job when a head is loaded; `wantMTP` is false only for sampled requests with `STRIM_SAMPLED_DEPTH0=1` (default sampled requests DO speculate), and depth 0 never reads head state. New `PrefillJob.wantsHead`: head skipped for real requests with `!wantMTP || depth == 0`; prefetch always runs it (it exists to leave MTP blocks in the trie); lookups then use `requireMTP: j.mtp != nil`; the first token is sampled directly when the head is skipped; `finishPrefill` tolerates a nil job head (depth 0). `STRIM_MTP_PREFILL=always` restores the old behavior. Tests: `HeadPrefillTests` (5).
Default greedy/sampled-speculating requests are unchanged by construction (acceptance, decode tok/s, tokens identical: checkprefix 8192 +MTP accept 88% before and after). A/B (`l3/`, `l3.sh`, sampled temperature 0.7, `STRIM_SAMPLED_DEPTH0=1`, trie off, max_tokens 1, 4 reqs/size/pass, ABAB x3):
| prompt | A (head always) s | B (skip) s | change |
|---|---|---|---|
| 3968 tok | 3.99 3.99 3.99 | 3.93 3.93 3.91 | -1.8% |
| 15656 tok | 16.41 16.40 16.34 | 16.05 16.03 15.99 | -2.2% |
Peak footprint 18.9-19.2 GB both arms. Gate (>= 1% prefill) met for these requests only; no gain in the default configuration.

## 6. L3(b) windowed head: not done, needs files outside this slice
Running the head over only the last W tokens breaks `SpecStream.reseed` (hot-session continuation): it requires head position aligned with the target cache (`mtp.position >= p0 - 1`, `mtp.trim(to: p0 - 1)`, `SpecStream.swift:329-345`), otherwise `headStale` fails the request. Needs an `MTPState` base offset (MTP.swift) and SpecStream edits, plus `PrefixStore.lookup/restoreMTP` to accept chains whose early nodes carry no MTP block (PrefixCache, EngineCore). The head's K/V per entry depends only on that entry's own (token, hidden), and RoPE is relative, so a window is mathematically sound; potential gain ~2.8% x (1 - W/n): 1.4% at 4K/W=2K, ~2.1% at 16K/W=4K. Not started: acceptance gate unmeasured. Recommend a follow-up slice that owns MTP.swift + SpecStream.swift.

Raw: `ab*/`, `l3/`, `parity/`, scripts `pass.sh` (copy of bench/h2h/pass.sh with a 512 c=1 cell), `ab.sh`, `cli.sh`, `l3.sh`, `table.sh`. Paths scrubbed to /Users/user; no tokens.
