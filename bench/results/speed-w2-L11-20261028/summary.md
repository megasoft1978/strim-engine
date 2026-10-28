# L11: wired limit and batched decode attention (2026-10-28) - both KILLED

Same binary for every arm (HEAD snapshot + this slice's knob, built in /tmp/strim-snap-l11); the knob is unset in arm A and in all committed defaults. Load average 2.5-12 from other workers' CPU builds and short GPU runs; treat < 3% as noise. Raw in `raw/`; scripts: `srv_abab.sh`, `idle.sh`, `agg.py`, `gates.sh`, `gates_rest.sh`, `wd_run.sh`.

## A. Wired limit (`STRIM_WIRED_LIMIT_GB`, new, default off)
- API: mlx-swift `WiredMemoryManager` ticket (`WiredSumPolicy`, `.active`, size N GiB) started once before the first `WeightStore` init (`WiredLimit.applyFromEnvOnce`, Model.swift; call in Weights.swift). A `.reservation` ticket applies 0, so `.active` is required. Engine log line: "wired limit: requested 40 GiB, applied 40960 MiB". System `iogpu.wired_limit_mb` is 57344 here and was not touched.
- Cells: 3 sessions per arm, ABABAB, 40 GiB vs unset (server path, `bench/h2h/pass.sh` cells w3, w3_32k, w4s, 5 s watchdog).

| cell | A (wired off) | B (wired on) | median A | median B | delta |
|---|---|---|---|---|---|
| ctx-16384 decode_tps | 63.11 / 62.99 / 63.13 | 62.14 / 62.8 / 62.87 | 63.11 | 62.80 | -0.5% |
| ctx-16384 ttft_s | 17.14 / 17.02 / 17.14 | 17.03 / 17.0 / 17.0 | 17.14 | 17.00 | -0.8% |
| ctx-32768 decode_tps | 49.57 / 51.15 / 50.74 | 50.57 / 48.8 / 54.57 | 50.74 | 50.57 | -0.3% |
| ctx-32768 ttft_s | 36.91 / 36.92 / 37.0 | 36.7 / 37.29 / 37.4 | 36.92 | 37.29 | +1.0% |
| ctx-4096 decode_tps | 71.0 / 56.77 / 67.99 / 57.01 / 68.97 / 53.62 | 63.65 / 56.48 / 67.62 / 53.34 / 74.18 / 57.05 | 62.50 | 60.35 | -3.4% |
| ctx-4096 ttft_s | 4.142 / 4.157 / 4.119 / 4.144 / 4.151 / 4.179 | 4.156 / 4.136 / 4.144 / 4.123 / 4.123 / 4.118 | 4.15 | 4.13 | -0.4% |
| distinct-c4 aggregate_tps | 68.51 / 68.82 / 68.94 | 68.39 / 66.33 / 67.69 | 68.82 | 67.69 | -1.6% |
| distinct-c4 decode_tps | 21.38 / 21.47 / 21.5 | 21.59 / 20.55 / 21.06 | 21.47 | 21.06 | -1.9% |
| distinct-c4 ttft_s | 1.506 / 1.497 / 1.493 | 1.583 / 1.516 / 1.513 | 1.50 | 1.52 | +1.3% |
| distinct-c8 aggregate_tps | 74.79 / 76.36 / 76.28 | 76.55 / 75.42 / 75.86 | 76.28 | 75.86 | -0.6% |
| distinct-c8 decode_tps | 11.65 / 11.94 / 11.94 | 11.93 / 11.76 / 11.83 | 11.94 | 11.83 | -0.9% |
| distinct-c8 ttft_s | 2.687 / 2.681 / 2.695 | 2.66 / 2.688 / 2.692 | 2.69 | 2.69 | +0.0% |
A peak footprint MB, swap growth MB per session: [(28223, 0), (28715, 0), (28687, 0)]
B peak footprint MB, swap growth MB per session: [(28663, 0), (28611, 0), (28215, 0)]

Delta = B vs A median; for ttft_s lower is better. No cell improved >= 2% (4K decode -3.4% is noise-dominated: per-session range 53-74 tok/s in both arms; 16K/32K decode, c=4, c=8 all -0.3..-1.9%). Peak footprint and swap growth unchanged (28.2-28.7 GB, 0 MB growth, no watchdog aborts).
- First token after idle (90 s idle, 1-token chat request, A/B/A sessions): post-idle 0.156 s (A), 0.244 s (B), 0.171 s (A); warm 0.113 s in all. Wiring did not help page-in (system was not under memory pressure, so this is a floor).
- Verdict: KILL. Knob stays off (opt-in, documented in docs/CONTROL-API.md). gen16 ids identical with the knob on (19 ids, same as off).
- Risk note: wired pages are not reclaimable by the VM under pressure. A fixed 40 GiB residency request on a 64 GB machine shared with other apps (swap was 6.9-13.6 GB used by other processes during this slice) could starve them; the memory plan would need to cap it at weights + KV budget + slack and release on idle. Not worth it for 0%.

## B. Batched decode attention (microbench only, not implemented)
`strim benchbatchattn [reps]` (Cmd_BatchAttnMicro.swift, dispatch line in Commands.swift): 16 attention layers chained serially (layer i+1's query depends on layer i), ragged lengths len_b = ctx*(0.55..1.0), RoPE + append + SDPA only (projections identical in every variant). looped = today's per-sequence loop; batched = one array-offset RoPE, in-place row appends, one SDPA over padded [B,..,maxLen] KV with an array mask; batched-equal = equal lengths, no mask (lower bound).

| B | ctx | looped ms (run1/run2) | batched masked ms | saving ms (run1/run2) | max abs diff vs looped |
|---|---|---|---|---|---|
| 4 | 1K | 3.91 / 2.50 | 2.79 / 2.04 | +1.12 / +0.46 | 2.4e-4 |
| 8 | 1K | 6.96 / 4.67 | 5.30 / 4.47 | +1.66 / +0.20 | 4.9e-4 |
| 4 | 4K | 7.28 / 6.95 | 6.55 / 6.44 | +0.74 / +0.51 | 0 |
| 8 | 4K | 14.14 / 14.38 | 12.87 / 13.39 | +1.27 / +0.99 | 0 |
| 4 | 16K | 23.54 / 24.01 | 23.38 / 23.78 | +0.16 / +0.23 | 0 |
| 8 | 16K | 46.89 / 48.08 | 48.10 / 48.69 | -1.20 / -0.61 | 0 |

Run 1 was under heavier load (inflated looped times at short ctx); run 2 is the cleaner one. Saving at B=8 is <= 1.0 ms at 4K and negative at 16K (padding reads maxLen for every row and the masked path loses the per-row exact length), B=4 <= 0.5 ms. Threshold was >= 1.5 ms at B=8 or B=4: not met on a repeatable cell. Kill: no Batch.swift change. The mask/padded path is also not bit-identical at 1K (2e-4..5e-4), so it would have been opt-in anyway. A ragged-length SDPA kernel (mlx-vlm style) is the only variant that could beat the equal-length bound (saving ~1.3-3.2 ms at B=8 across 1K-4K, ~0 at 16K), i.e. at most ~2-4% of a 72 ms B=8 step; not pursued.

## Gates (binary with knob unset; code path identical to HEAD apart from an env check)
gen16 ids identical to L10; depth-0 benchspec EXACT (123 tokens); checkprefix 4096 and 8192 +MTP ALL PASS; checkprefixcuts ALL PASS; checkbatchparity B=4 1 mismatch (127/128), B=8 4 mismatches (252/256), all margins <= 0.125 (reference met). One watchdog abort (checkprefix8192, swap growth > 2 GB caused by other workers, not the engine) was rerun clean via `gates_rest.sh`. d1 spec "parity MISMATCH" at the 4K prompt is the pre-existing one noted in L10.
