# HTTP head-to-head: strim serve vs rapid-mlx (2026-10-26)

Method: each arm served alone over HTTP (no ABAB interleave), Qwen3.8-27B 4-bit + MTP, thinking off.
strim = `strim serve` (main a797890) with `STRIM_PREFIX_CACHE_MB=4096 STRIM_MEM_BUDGET_GB=32`; rapid-mlx per bench/screen.py.
n = reps (scoreboard strim 3, rapid cache-on 3, rapid cache-off 2; replay 2). Medians. Raw data beside this file.

## Scoreboard (medians)

| workload | metric | strim | rapid-mlx |
|---|---|---|---|
| W1 greedy-64 | decode tok/s | 65.4 | 50.3 |
| W1 greedy-64 | TTFT s | 0.108 | 0.264 |
| W1 greedy-256 | decode tok/s | 70.7 | 50.5 |
| W2 temp0.6-256 | decode tok/s | 70.3 | 52.0 |
| W3 4K cold | decode tok/s / TTFT s | 64.0 / 4.19 | 47.6 / 4.10 |
| W3 16K cold | decode tok/s / TTFT s | 49.2 / 17.4 | 44.0 / 16.9 |
| W3 32K cold | decode tok/s / TTFT s | 45.6 / 37.4 | 41.3 / 36.1 |
| W4 c2 | aggregate tok/s | 11.6 | 11.9 |
| W4 c4 | aggregate tok/s | 12.6 | 13.1 |
| W5 4x16K shared prefix | aggregate tok/s / TTFT s | 3.35 / 46.4 | 3.33 / 73.7 |

W4 per-request decode: strim 17.2 (c2) / 7.1 (c4) vs rapid 29.4 / 24.4. Aggregates are equal, so per-request decode is not a fair comparison there
(strim prefills serially and its per-request clock includes waiting); rapid batches decode faster. Rapid W5 cache hits were not reported, so the W5 TTFT gap is not attributable to the cache.

## Agent replay (synthetic 8 turns, prompts 4.1K to 40.8K)

| arm | prefill sum s | TTFT T1 / T8 s | cached frac T8 |
|---|---|---|---|
| strim cache-on | 91.7 | 4.1 / 27.6 | 47.6% |
| strim cache-off | 201.7 | 4.1 / 48.3 | 0% |
| rapid cache-on | 49.5 | 4.2 / 7.3 | 87.2% |
| rapid cache-off | 195.4 | 4.1 / 46.4 | unknown |

Strim cached tokens plateau at 19456 (=19 nodes x 1024): this is the run's own setting `STRIM_PREFIX_CACHE_MB=4096` (4096/215 MiB per node), not an engine limit.
The default budget is 12288 MB (about 57 nodes). Re-run with the default budget (replay-strim-on-default): prefill sum 54.0 s, T8 cached 85.2% (34816/40840), T8 TTFT 8.5 s, vs rapid cache-on 49.5 s / 87.2% / 7.3 s.

## Sampled decode (temp 1.0, top_p 0.95, top_k 20, seed 1234, 256 tokens)

strim 50.7 / 52.5 / 52.5 (median 52.5) tok/s; rapid 48.4 / 48.4 / 48.0 (median 48.4). Params sent; honoring of top_p/top_k/seed not verified.

## Caveats

- rapid ignored `ignore_eos` on 15 scoreboard rows and replay turns 3-8; those rows are excluded from decode (missing, not slow).
- rapid completion counts varied across reps of the same turn; strim was always 48.
- Replay ran through an in-process no-think wrapper (scratchpad), bench file unmodified. TTFT counts delta.content only.
- rapid's persisted cache (~/.cache/rapid-mlx) was restored on the cache-on launch.
- rapid W3/W4 n=2 (time cap). The 4-way 1K burst was not run. No ABAB interleave; load not controlled.
- Replay sends recorded assistant turns, so strim's token ledger / hot-session reuse does not apply.
