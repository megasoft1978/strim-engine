# Strim wave-2 quick check (indicative: Strim fresh vs rivals from the earlier run, not interleaved, not for publication)

Scope (owner decision): rival rerun cancelled. Strim only, 1 pass, loss cells only. Rival numbers are copied from bench/results/h2h-final-20261028/summary.md (same machine, protocol, cells; median of its 2 passes). Not ABBA, not same-time: machine load was 4-11 (other CPU work running) so deltas under ~3% are noise. Rival engines unchanged (rapid-mlx 0.15.7, mlx-vlm 0.7.10; not started).

Build: Strim 0.1.0 at commit f808432a (f8084320235f4c85d7924eb7f10492fc550eb334), git archive snapshot, release, pristine MLX, scratch /tmp/strim-build-h2h. Flags as before (`serve qwen38-4bit qwen38-mtp-4bit --no-auth`). Cells run via bench/h2h/pass.sh (w3, w3_32k, w4s; warmup first); greedy agreement 8 prompts also run (agree.json, not compared). Watchdog 5 s: no aborts, swap growth 0.
Verdict: WIN/TIE/LOSS vs best rival, TIE = within 2% (unchanged threshold).

| cell | unit | Strim now | prev Strim | delta | best rival (prev run) | ratio | verdict |
|---|---|---|---|---|---|---|---|
| cold 4K prefill | tok/s | 989.5 | 980.1 | +1.0% | mlx-vlm 998.6 | 0.99x | TIE |
| cold 16K prefill | tok/s | 953.9 | 950.7 | +0.3% | mlx-vlm 980.1 | 0.97x | LOSS (-2.7%) |
| cold 16K TTFT | s | 17.19 | 17.24 | -0.3% | mlx-vlm 16.73 | 1.03x | LOSS |
| cold 32K prefill | tok/s | 880.6 | 879.6 | +0.1% | mlx-vlm 906.6 | 0.97x | LOSS (-2.9%) |
| cold 32K TTFT | s | 37.23 | 37.26 | -0.1% | mlx-vlm 36.16 | 1.03x | LOSS |
| c=4 512-tok aggregate | tok/s | 67.21 | 60.42 | +11.2% | rapid-mlx 70.64 | 0.95x | LOSS (-4.9%) |
| c=4 512-tok p50 TTFT | s | 1.511 | 1.825 | -17.2% | mlx-vlm 2.321 | 0.65x | WIN |
| c=4 512-tok p95 TTFT | s | 2.312 | 2.832 | -18.4% | mlx-vlm 2.321 | 1.00x | TIE |
| c=8 512-tok aggregate | tok/s | 76.07 | 67.37 | +12.9% | mlx-vlm 74.31 | 1.02x | WIN (+2.4%, marginal) |
| c=8 512-tok p50 TTFT | s | 2.681 | 3.288 | -18.5% | mlx-vlm 4.358 | 0.62x | WIN |
| c=8 512-tok p95 TTFT | s | 4.623 | 5.701 | -18.9% | mlx-vlm 4.359 | 1.06x | LOSS (+6.1%) |

Side numbers (not verdict cells): decode 4K 73.2 tok/s (prev 67.1, +9%), 16K 63.8 (prev 56.5, +13%), 32K 43.6 (prev 52.1, -16%; 32K decode is a 128-token run with high previous-run spread, check before trusting; was the only regression, needs a rerun under quiet load).

## Peak phys_footprint (Strim, MB)
w3 (4K,16K) 23028; w3_32k 28783 (prev 28172, +0.6 GB); w4s 19965 (prev 26209); warmup 18358. Max in this check 28.8 GB, within the previous-peak +1 GB rule (prev whole-run peak 30.8 GB came from w4 4K concurrency, not rerun here). Swap growth 0.

## Remaining gaps, ranked (drives next speed lanes)
1. Concurrent aggregate c=4 512-tok: -4.9% vs rapid-mlx (was -14%). Largest remaining loss; batched decode lane (L-batched) should close it.
2. c=8 512-tok p95 TTFT: +6.1% vs mlx-vlm (was +31%). Tail of staggered admission; rivals' p50==p95 (batch-synchronous), so the last request defines p95.
3. Cold prefill 32K: -2.9% (37.2 s vs 36.2 s); 16K: -2.7%. Unchanged by wave 2 (+0.1-0.3%); needs a prefill-path lane (dispatch/chunking), same gap as before.
4. Near-parity or ahead now: c=4 p95 TTFT TIE (-0.4%), c=8 aggregate marginal WIN, cold 4K TIE.
5. Not rechecked (still LOSS/TIE in the previous run, wave 2 effect unknown): c=4/8 agent and 4K prompts aggregate and p95, W5, replay.

## Caveats
1 pass, 1 rep, machine load 4-11 during the run, rivals not rerun (their numbers from an earlier quiet-ish run), so small deltas are noise. Do not publish. The 32K decode drop needs a quiet rerun.
