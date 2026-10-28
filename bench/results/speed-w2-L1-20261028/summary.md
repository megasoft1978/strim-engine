# Speed wave 2, lane L1: prefill-burst scheduler (2026-10-28)

Verdict (after owner follow-up, section 5): **default OFF, opt-in `STRIM_PREFILL_GAP_MS=3000`**. Gap 3000 meets the 512-token p95 gate (-8.3% c=4, -9.3% c=8, same session). Its measured max token gap for running streams is 3.04 s against a 3.00 s cap (cap plus one decode step), so per the owner rule it is not the default. Sections 1-4 are the first pass (gap 3000 without the predicted-unit rule, and a 2.8K/4K shortfall of -3..-4%).
Checkbatchparity: identical margins to the baseline with batch decode on/off (section 5).

## 1. Trace (step 1): where the c=4 / c=8 512-token TTFT goes

Method: `STRIM_ENGINE_TRACE=1` unit trace (read-only, EngineCore untouched), stderr timestamped with `perl Time::HiRes`, one W4 run per concurrency under `lockf`. Files: `trace-c4/`, `trace-c8/` (`server.trace`, `units-window.txt`, `w4c*/raw.jsonl`), analysis `tools/analyze.pl`.

- Engine-side first-token times match client TTFT (c=4: 0.72 / 1.47 / 2.21 / 2.97 s engine and client). HTTP and admission add nothing measurable.
- Each 512-token prompt is 523 tokens, split at the trie block boundary into a 512-token chunk (593 ms) and an 11-token tail chunk (66 ms). The tail costs a near-fixed ~66 ms per request.
- Prefills are serial. The last of 4 starts after ~3 x 0.66 s of other prefills. This is most of the p95.
- Decode units inside the prefill phase: c=4 has 6 solo decode units x ~43 ms before the last first token (~0.26 s, ~9% of p95). c=8 has ~16 units (~0.7 s, ~11% of p95). This is the part a scheduler can remove. It is the hypothesis this lane tested.
- Not a scheduler lever: the 11-token tail chunk (~0.26 s at c=4, ~0.5 s at c=8, ~9-10% of p95). It lives in `EngineCore.coldChunk` / `PrefixPrefill.blockEnd` (owned by the other worker). Suggested: fold a final partial block into the last chunk.

## 2. Policy (step 2): `Sources/StrimEngine/Scheduler.swift`

- `PrefillBurst`: `STRIM_PREFILL_BURST=N` (max consecutive prefill units while a decoder is pending), `STRIM_PREFILL_GAP_MS=ms` (inter-token gap cap: prefill wall time since the last decode unit that forces a decode unit). Unset = legacy 1:1 alternation. Both are read when `Scheduler()` is created; no EngineCore edit.
- Gap time comes from an injectable `clock` read at each `pick()`. Prefill time with no decoder waiting is not charged.
- Tests (`PrefillBurstTests`, 6 tests): ordering `PPPDPPPD` (burst 3), gap cap `PPDPPD`, arrival rule, cap invariant, legacy `PDPDPD`, env parsing. Mutation check (burst ignored in a snapshot copy): `burstRunsN...` and `gapCap...` FAIL on the old behavior; the rest pass. Existing `SchedulerTests` and `DecodePolicyTests` unchanged and passing. `swift test --filter StrimEngineTests`: 48 tests in 9 suites passed.
- Not implemented: "adaptive K". Only the fixed unit cap plus time-based gap cap exists.

## 3. A/B (step 3)

Build: one release binary from snapshot `/tmp/strim-build-l1` (new code). Arm A = flag unset (= legacy policy; verified by `legacyDefaultAlternatesOneToOne`). Arm B = `STRIM_PREFILL_GAP_MS=3000` (burst unlimited, gap cap 3 s). Order ABABAB (3 reps each), `bench/h2h/pass.sh` under `lockf /tmp/strim-bench.lock`, cells w4s (512 tok, c=4/8), w6 (2.8K agent, c=4/8), w4 (4K, c=4/8), w3 (single stream 4K/16K). Medians of 3 passes. Raw: `ab/arm{A,B}/strim/pass{1,2,3}/`, table `ab/table.tsv`.

| cell | metric | A (flag off) | B (gap 3 s) | change | gate |
|---|---|---|---|---|---|
| 512 c=4 | p50 TTFT s | 1.445 | 1.352 | -6.4% | ok |
| 512 c=4 | **p95 TTFT s** | 2.945 | 2.680 | **-9.0%** | ok (>=8%) |
| 512 c=4 | agg tok/s | 60.98 | 62.07 | +1.8% | ok (>=-1%) |
| 512 c=8 | p50 TTFT s | 2.930 | 2.660 | -9.2% | ok |
| 512 c=8 | **p95 TTFT s** | 6.067 | 5.391 | **-11.1%** | ok |
| 512 c=8 | agg tok/s | 68.10 | 69.18 | +1.6% | ok |
| 2.8K agent c=4 | p50 / p95 s | 6.397 / 13.81 | 6.174 / 13.35 | -3.5% / -3.4% | **p95 short** |
| 2.8K agent c=8 | p50 / p95 s | 11.72 / 24.71 | 11.15 / 23.68 | -4.8% / -4.2% | **p95 short** |
| 2.8K agent c=4/8 | agg tok/s | 26.28 / 29.89 | 26.74 / 30.35 | +1.8% / +1.5% | ok |
| 4K c=4 | p50 / p95 s | 8.61 / 17.40 | 8.40 / 16.90 | -2.5% / -2.9% | **p95 short** |
| 4K c=8 | p50 / p95 s | 17.48 / 35.43 | 16.92 / 33.97 | -3.2% / -4.1% | **p95 short** |
| 4K c=4/8 | agg tok/s | 12.69 / 12.92 | 12.78 / 13.02 | +0.7% / +0.8% | ok |
| single stream 4K | decode tok/s | 68.23 | 66.37 | -2.7% | within 3%, see note |
| single stream 16K | decode tok/s | 58.23 | 58.74 | +0.9% | ok |
| per-request decode tok/s (concurrent) | 512 c=4 / c=8 | 19.72 / 11.11 | 19.53 / 10.88 | -1% / -2% | info (includes stall) |
| per-request decode tok/s (concurrent) | 4K c=4 / c=8 | 7.29 / 3.29 | 6.99 / 3.15 | -4% / -4% | info (includes stall) |

Memory: peak phys_footprint (watchdog, 5 s) A 29.6 GB median (30.1/29.6/29.7), B 28.8 GB (28.5/28.8/29.6). Swap growth 0 in all sessions. Watchdog aborts 0. Peak did not rise.

Notes:
- Single-stream path has no decoder during prefill, so the new code runs the same unit sequence. The 4K single-stream gap (-2.7%) is run-to-run noise, not policy (pass-1 A 68.92 vs B 65.69; passes 2-3 B equal or higher).
- Cost: decode stalls. Gap cap 3 s means the first decoder can wait ~3 s + one unit while later prompts prefill. Per-request decode tok/s at 4K drops about 4%. ITL was not measured separately; this is an inter-token stall, not a tok/s loss.
- 1.5 s gap was scouted once on 512 c=4/8 (p95 -6% / -11%). Not repeated.

Verdict vs gate: 512-token cells pass every criterion. 2.8K and 4K reach -3..-4% p95, under the -8% bar, so the change is not accepted. Default stays OFF (`STRIM_PREFILL_GAP_MS` unset). Remaining gap to mlx-vlm p95 at 512 tokens: c=4 2.68 vs 2.32 s (was 2.83), c=8 5.39 vs 4.36 s (was 5.70).

## 4. Checks

- Unit: `swift test --filter StrimEngineTests` 48 tests, passed (snapshot build).
- Release build: `swift build -c release` in the snapshot, complete.
- Checkbatchparity: not run (not accepted).

## Scouting (raw): `scout/` runs, single pass each, 512 c=4/8 cell: base p95 c4 2.92 / c8 6.08; gap 1500 ms 2.74 / 5.43; gap 3000 ms 2.66 / 5.38; burst unlimited 2.66 / 5.30.

Paths scrubbed to /Users/user. No tokens in these files (only the control-token file path).

## 5. Follow-up (owner request): checkbatchparity, ITL, gap choice, default

**checkbatchparity** (`strim checkbatchparity models/qwen38-4bit 512 B 32`, batch decode on vs off; `parity/`):
| B | batch decode off | on | baseline `conc-batch-20261027/checkbatchparity.txt` |
|---|---|---|---|
| 4 | 128/128, max logit diff 2.13 | 127/128, margin 0.125, max diff 2.23 | identical |
| 8 | 254/256, margins <= 0.0625, max diff 4.91 | 252/256, margins <= 0.125, max diff 5.53 | identical |
The gap policy is not in this code path (no Scheduler), so flag on/off cannot change it. Margins match the baseline exactly: no worse.

**ITL of running streams** (`itl/`, two 700-token streams decode; a 512-token then a ~4K streamed request arrives; `tools/itl.sh`, `tools/itl_an.pl`; one session per arm):
| arm | running-stream token gap, whole run p95 / max | during 512 arrival max | during 4K arrival p95 / max | 512 arrival TTFT | 4K arrival TTFT |
|---|---|---|---|---|---|
| off | 0.042 / 1.55 s | 0.63 s | 1.53 / 1.55 s | 0.79 s | 4.40 s |
| gap 1500 | 0.040 / 1.55 s | 0.71 s | 1.54 / 1.55 s | 0.76 s | 4.38 s |
| gap 3000 | 0.040 / 3.04 s | 0.71 s | 1.20 / 3.04 s | 0.78 s | 4.30 s |
The gap cap bounds prefill time before a decode step (predicted-chunk rule). The observed token gap is cap + one decode step (~45 ms): 1.55 s for the 1500 arm, 3.04 s for 3000. Off already stalls about 1.5 s on a 4K arrival, because one 1024-token chunk takes ~1 s under load.

**TTFT, same session, 512-token c=4/c=8** (`ab3/`, `w4s` cell only, 3 passes each, medians): 
| arm | c=4 p50 / p95 s | c=4 agg tok/s | c=8 p50 / p95 s | c=8 agg tok/s | peak footprint |
|---|---|---|---|---|---|
| off | 1.429 / 2.914 | 61.22 | 2.902 / 5.891 | 67.42 | 22.2 GB |
| gap 1500 | 1.344 (-5.9%) / 2.721 (-6.6%) | 61.21 (0%) | 2.706 (-6.8%) / 5.447 (-7.5%) | 68.20 (+1.2%) | 22.2 GB |
| gap 3000 | 1.348 (-5.6%) / 2.671 (-8.3%) | 63.41 (+3.6%) | 2.639 (-9.1%) / 5.341 (-9.3%) | 71.21 (+5.6%) | 22.3 GB |

**TTFT ABAB 1500 vs 3000, 3 passes** (`ab2/`, cells w4s + w6 (2.8K agent) + w3 (single stream), medians):
| cell | gap 1500 | gap 3000 |
|---|---|---|
| 512 c=4 p95 | 2.728 | 2.668 (1500 is 2.2% worse) |
| 512 c=8 p95 | 5.474 | 5.373 (1500 is 1.9% worse) |
| 2.8K agent c=4 p95 / agg | 13.62 / 26.69 | 13.31 / 26.86 |
| 2.8K agent c=8 p95 | 24.10 | 23.68 |
| single stream 4K / 16K decode tok/s | 67.3 / 59.0 | 68.9 / 58.3 |
Peak footprint 28.4-29.1 GB (1500) vs 28.4-29.3 GB (3000); swap growth 0, no watchdog aborts.

**Decision.**
- Gap 1500 keeps only 6.6-7.5% p95 on the 512 cells (below 8%), so it is not chosen.
- Gap 3000 clears 8% (8.3% c=4, 9.3% c=8), but its measured max token gap (3.04 s) is above the 3.00 s cap by one decode step. Per the owner rule, the default stays OFF.
- Shipped opt-in: `STRIM_PREFILL_GAP_MS=3000`. Unset or `0`/`off` = legacy path (single-stream and all other paths are then identical to HEAD policy; the single-stream 4K/16K data above is within run-to-run noise, roughly 3%).
- Owner call: to make it default, accept "stall <= cap + one decode step" (~45 ms overshoot) and set `defaultGap` in `Scheduler.swift`.

**Checks:** `swift test --filter StrimEngineTests` 48 tests passed (after the default change). `BatchStateTests` and the legacy `decodeNeverWaits` test now set `burst = .legacy` explicitly (they pin the 1:1 alternation). New predicted-unit cap test in `PrefillBurstTests`.

## 6. Default ON (owner decision), trade-off, single-stream check

**Default:** `STRIM_PREFILL_GAP_MS` unset = gap cap 3000 ms. `0` or `off` = legacy (the opt-out). Owner accepted "stall <= cap + one decode step" (measured 3.04 s for a 3.00 s cap).

**Trade-off, stated plainly:** when a long prompt (4K) arrives, running streams can pause up to about 3 s (max token gap 3.04 s; p95 1.20 s) against 1.55 s max with the legacy path (p95 1.53 s). A 512-token arrival stalls them at most 0.7 s in every arm. In exchange, 512-token p95 TTFT is -8.3% (c=4) and -9.3% (c=8), and aggregate throughput is +3.6% / +5.6% (same-session medians, section 5).

**Single-stream 4K/16K decode, ABAB, 3 passes, same build** (`single/on` = default, `single/off` = `STRIM_PREFILL_GAP_MS=0`; cell `w3`):
| cell | on (median) | off (median) | change | on range | off range |
|---|---|---|---|---|---|
| 4K decode tok/s | 64.76 | 64.71 | +0.1% | 56.5-67.1 | 59.1-68.8 |
| 16K decode tok/s | 58.69 | 55.84 | +5.1% | 56.3-59.0 | 54.6-57.4 |
Peak footprint: on 23.5-24.0 GB, off 22.9-23.4 GB (+0.6 GB at median; within the +1 GB rule, but not the 0 seen in the multi-cell A/B). No decoder exists during a single prefill, so the scheduler decisions are identical by construction; the spread (about +/-10% across passes) is run-to-run noise on this machine. Zero regression is shown by the medians, not by an exact match.

**Checks:** `swift test --filter StrimEngineTests`: 48 tests passed on the default-on build. The env test covers default on, `0` and `off` opt-out, `BURST` only, and both knobs. The legacy-path tests pin `burst = .legacy` explicitly.
