# L10: pipelined graph build, productionized (2026-10-28)

`QwenModel.pipe`: `asyncEval(h)` after every N-th decoder layer lets the GPU start while the host builds/encodes the remaining layers (hides the ~3 ms host build per pass found in L9). Default ON, `STRIM_PIPE_LAYERS=4` (0 = off); `STRIM_PIPE_PREFILL_LAYERS` (default 0) for chunks > 8 rows. Code: `Sources/StrimCore/QwenModel.swift` (`forward`, `forwardAll`, so decode M=1, verify M=3/5, reseed/replay passes), `Sources/StrimCore/Batch.swift` (batched decode B=2..8; batched prefill uses the prefill knob). Docs: `docs/CONTROL-API.md`. Tests: `Tests/StrimCoreTests/PipelinedGraphTests.swift` (env parsing; live: prefill + verify M=3 + rollback drop 2/0/1 + M=1 decode, bitwise logits/hidden/position equal for N in {0,1,8}; whole `generateSpec` ids identical depth 0/2/4; live tests ran and passed with `STRIM_LIVE=1`, 16 s).

Draft chain / MTP head / reseed graphs: 1 layer + lm_head, so no layer boundary to flush at; the next verify pass's first `asyncEval` flushes the chain, so they ride along (no knob).

## Sweep (benchspec 4K prompt, 128 tok, STRIM_MTP_FIXED=1, interleaved, 2 rounds x 2 reps, decode tok/s)
| N | M=1 (depth 0) | M=3 (depth 2) | M=5 (depth 4) | B=4 step ms | B=8 step ms |
|---|---|---|---|---|---|
| off | 26.0 / 26.9 | 45.4 / 44.8 | 43.5 / 44.9 | 43.7 / 43.8 | 76.7 / 75.1 |
| 2 | | | | 41.3 / 41.5 | 72.1 / 72.0 |
| 4 | 30.1 / 30.4 | 50.0 / 49.5 | 48.2 / 47.7 | 41.4 / 41.4 | 72.1 / 72.1 |
| 8 | 29.0 / 30.2 | 49.8 / 49.6 | 47.5 / 48.2 | 41.7 / 42.4 | 72.6 / 72.7 |
| 16 | 29.9 / 29.8 | 48.9 / 48.4 | 47.1 / 47.5 | 42.2 / 41.8 | 72.8 / 72.9 |
| 32 | 29.3 / 28.9 | 46.7 / 46.8 | 46.1 / 45.8 | | |

N=4 best or tied on every path: default 4 for all (M=1 +13%, M=3 +11%, M=5 +9%, B=4 -5.4%, B=8 -6.1% step time). Prefill (`benchprefill` 4K, chunk 2048, ABABAB, `STRIM_PIPE_PREFILL_LAYERS` 0 vs 8): 1041-1046 vs 1029-1046 tok/s, neutral, kept off.

## Server gates, new vs HEAD (ABABAB, `bench/h2h/pass.sh`; A = HEAD build, B = new build defaults; 3 each, median)
| cell | HEAD | new | delta |
|---|---|---|---|
| W3 4K decode (c=1) | 66.1 (66.1/63.9/67.7) | 72.3 (72.3/75.5/67.9) | +9% |
| W3 16K decode | 56.9 | 62.6 | +10% |
| W3 32K decode | 46.4 (39.5/47.2/46.4) | 54.4 (54.4/42.2/55.1) | +17%, noisy (CV ~10%) |
| W4 512-tok c=4 aggregate tok/s | 63.9 | 68.4 | +7% |
| W4 512-tok c=8 aggregate tok/s | 70.4 | 75.7 | +7% |
| c=4 TTFT p50 / p95 s | 1.20 / 2.40 | 1.20 / 2.41 | = |
| c=8 TTFT p50 / p95 s | 2.43 / 4.89 | 2.40 / 4.86 | = |
| cold prefill TTFT 4K / 16K / 32K s | 4.16 / 17.19 / 37.0 | 4.16 / 17.19 / 37.1 | = |
| peak footprint (watchdog, MB) | 28585 / 28428 / 28796 | 28384 / 28369 / 28229 | -0.2 GB (no growth) |

## Exact tier (new == HEAD)
gen 16 ids identical; depth-0 benchspec EXACT both; checkprefix 4096 and 8192 +MTP ALL PASS both; checkprefixcuts ALL PASS both; checkbatchparity B=4 127/128 (margin 0.125) and B=8 252/256 (margins <= 0.125) with identical mismatch lists in both builds; benchspec depth-2 outputs identical across builds (same token lists and parity lines); `benchbatch` B=4 tokens match; greedy agreement 8 prompts x 64 tokens: agree.json md5 identical in all 6 sessions (3 HEAD, 3 new). The 4K-prompt benchspec "parity MISMATCH" vs sequential greedy (spec 11 / greedy 8 at 4186) is pre-existing and identical in HEAD.

Verdict: ACCEPTED, default ON (N=4): decode +9..10% at 4K/16K single stream (gate was +4%), +7% at c=4/8, memory unchanged, prefill/TTFT unchanged.

Scripts: `sweep.sh`, `srv_abab.sh`, `gates.sh`, `wd_run.sh`; raw in `raw/` (`gates-new|head`, `srv-N-A|B`, `sweep-*`, `batch-*`, `prefill-4k-*`). HEAD arm = L9 snapshot build with its prototype knob unset (identical code path to HEAD 'ecbc459'). Paths scrubbed to /Users/user; no tokens.
