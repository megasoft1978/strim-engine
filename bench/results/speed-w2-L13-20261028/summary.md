# Speed wave 2, L13 (served-path overhead): verdict, nothing adopted

Machine M5 Max, `models/qwen38-4bit` + `qwen38-mtp-4bit`, load 3-6, every run under `/tmp/strim-bench.lock` with the 5 s memory watchdog (no aborts). Sessions via `pass13.sh` (own engine + warm-up), ABAB x5 with one binary (`/tmp/strim-l13-bins/P`, HEAD + env-gated code) so build differences cannot leak in. Raw: `raw/`, tables `ab-results.txt`, scripts `abab.sh sumab.sh cellvals.sh pass13.sh`.

## Step 0: where the ms go (STRIM_SERVER_LOG phase lines, raw/step0/served)
| prompt | template+tokenize | queue | per-chunk host graph build | per-chunk `eval(live)` | trie insert | first emit after prefill | prefill unit |
|---|---|---|---|---|---|---|---|
| 523 | 0.2 ms | 0.1 ms | 4.8 ms | 0 | 0.1 ms | 0.1 ms | 593-606 ms |
| 4107 | 1.0-1.5 ms | 0.1 | 5-6 ms | 11-12 ms | 0.1-0.3 | 0.1 | 4134-4671 ms |
| 16395 | 4.1 ms | 0.1 | 4.5-6 ms | 8-21 ms | 0.8 -> 8 ms (grows with depth) | 0.1 | 17367 ms |
| 32779 | 7.4 ms | 0.1 | 5-7 ms | 10-25 ms | 1-7 ms | 0.1 | (36-37 s) |
Chunk = 1536 tokens (cut policy), ~1.45 s at depth 0 growing to ~1.65 s at 14K (attention). Non-GPU work per chunk is ~20-35 ms of ~1500 (1.5-2%), matching the "grows with length" part.
In-process `benchprefill` (chunk 1024, no trie/head): 4K 1028, 16K 957-967 tok/s. Served: 4K 991, 16K 944-955, 32K 882 tok/s.
**512-token fixed overhead does not exist**: in-process `benchprefill 523` = 0.59 s (884 tok/s, small-M GEMM efficiency), served prefill unit = 0.593-0.606 s incl. MTP head. The 0.52 s "4K rate" estimate is the wrong baseline. Tokenizer/template/queue are < 8 ms even at 32K (< 0.03%), so the tokenizer and overlap lanes were not built.

## A/B results (ABAB x5, median per arm, B vs A)
| change | 4K | 16K | 32K | peak | verdict |
|---|---|---|---|---|---|
| STRIM_PREFILL_PIPE=1 (cross-chunk asyncEval, async trie insert) | +0.23% | +0.93% | +0.75% | +2.2% | KILL (< 1%, peak higher) |
| STRIM_KV_PREALLOC=1 (one allocation, same capacity hit/miss) | -2.2% | +0.15% | -0.31% | -0.3% | KILL |
| STRIM_MTP_WINDOW=256 (512-token cells) | - | - | - | - | KILL: c1 p50 +2.5%, c4 p95 +0.45%, c8 p95 -0.03%, mtp_acc not lower (prompts < window, so no-op by design) |
| STRIM_PIPE_PREFILL_LAYERS=4 (512-token cells) | - | - | - | - | KILL: c4 p95 +1.2%, c8 p95 +0.1%, c1 p95 -2.7% (c1 agg -5%: noise) |
Gate was p95 >= 3% better (knobs) / >= 1% (fixes). Full tables in `ab-results.txt`.

## Outcome
Nothing adopted; defaults unchanged. The code stays committed default-off (STRIM_PREFILL_PIPE, STRIM_KV_PREALLOC, `[phase]` lines under STRIM_SERVER_LOG; rows in docs/CONTROL-API.md). Because no change was adopted the exact gates (gen16, benchspec, checkprefix*, checkbatchparity, PrefixDisk tests) were not run; they are required before anyone turns a flag on.
Conclusion: the served-vs-in-process 2-4% is not host overhead that can be hidden. Remaining non-GPU time is ~1.5% (build ~5 ms + eval sync 10-20 ms + insert) per chunk, and pipelining recovered under 1% of it. Not tried (bounded by the numbers above): first token emitted before the head prefill (<= ~10 ms, c=1 only).
