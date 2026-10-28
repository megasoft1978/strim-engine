# Speed wave 2, L5 (GDN prefill kernel + qk fold): MERGED, default ON (owner-overruled gate: +1.2-1.3% prefill, bit-identical, memory-neutral)

Machine/method as L0: M5 Max, `models/qwen38-4bit`, chunk 1024, all GPU runs under `/tmp/strim-bench.lock` with the memory watchdog (`wd_run.sh`, no aborts). A = HEAD build, B = HEAD + the L5 patch, snapshot builds, ABABAB.

## 1. GDN non-GEMM split (from the L0 OpTimer table, `../speed-w2-L0-20261028/table4k.md`)
4K prefill, plain wall 4074 ms: recurrence 185.5 ms (4.55%), conv+silu 29.8 (0.73%), norm+gate 16.3 (0.40%), qknorm+betaG 15.3 (0.38%), b/a GEMVs 21.6 (0.53%). Total 6.6%; 16K: 6.2%. Elementwise glue outside the recurrence is only ~1.5%.

## 2. Recurrence kernel sweep (`GDNSweep.swift.txt`, snapshot-only harness: interleaved min-of-8, S=1024/4096, raw in `raw/sweep*.txt`)
Every variant below is bit-identical (y and final state, `.!=` count 0) to the shipped kernel on random tensors (S=1,3,47,49,512,777 B=2,1000,1024,2048,4096) and on tensors captured from a real 4K prefill (layers 0/30/45 incl. non-zero state).
- DB=16 (2x TGs): 0.5x. DB=64: 0.93x. TB 16/24/32 with bf16 staging: 0.93-1.00x. f32 k/q staging (state-free conversion hoist): 0.89-0.96x. So TB/DB and f32 staging are a local optimum: no win.
- What helped (all keep the f32 tree): 16-byte staging loads/stores (+5%), xor-butterfly for the kv reduction (adds are commutative; lane 0's tree unchanged, one shuffle fewer) (+5%), y staged in tgmem and flushed coalesced (+3%), together 1.14-1.16x; plus **2 value rows per thread** (k/q tgmem reads shared, two shuffle chains overlap): TB=40/DB=32/128 threads **1.24-1.26x at S=1024 (0.85 -> 0.68 ms), 1.28-1.36x at S=4096**. 4 rows/thread spills (0.27x). Deferred out-reduction, unroll, prefetch registers: no further gain.
- v is read through its own strides (kernel with `ensureRowContiguous: false`), removing the 12.6 MB contiguous copy of the conv-output slice.

## 3. Elementwise fusion
- q/k scales folded into the RMS-norm weight (`rmsNorm(x, w=scale)` is bit-identical to `rmsNorm(x, ones) * scale`, unit-tested): removes 2 passes per layer.
- 4-channels-per-thread conv+silu (amortised index division): **2x slower** (0.31 vs 0.153 ms pipelined, `raw/opmicro.txt`): rejected and removed.
- norm+gate / betaG fusion not attempted: rmsNorm's reduction order is MLX-internal, matching it bit-for-bit is not worth <=0.4%.

## 4. End to end (benchprefill, chunk 1024, tok/s per rep)
| ctx | A (HEAD) | B (patch) | gain |
|---|---|---|---:|
| 4K (3 reps x 3) | 1013 1017 1013 / 989 1013 1002 / 1007 1017 1016 | 1029 1024 / 1017 1029 1029 / 1017 1028 1026 | +1.3% |
| 16K (2 reps x 3) | 958 963 / 961 959 / 962 963 | 974 976 / 970 976 / 970 972 | +1.2% |
Peak footprint: 4K 17336 -> 17300 MB, 16K 25324 -> 25301 MB (memory neutral, slightly lower). Recurrence alone 4.5% x ~25% = ~1.0%, glue ~0.2-0.3%.

## Verdict and gates (coordinator overrode the 1.5% gate)
Bit-identical and memory-neutral, +1.3% (4K) / +1.2% (16K), so merged default ON (no env). Code: `GDNMetal.blockedKernel` (2 rows/thread, TB=40, 128 threads, 16-byte staging, xor kv reduction, y staged, strided v, `ensureRowContiguous: false`), `GDN.qScaleBf16/kScaleBf16` (scale folded into the RMS-norm weight), tests in `GDNBlockedTests` (bit-identity vs a verbatim copy of the old kernel incl. B>1, tails, strided/contiguous v; q/k fold; guarded with `.enabled(if: metalReady)`, skip without a metallib). Conv change was dropped (2x slower).

Gates run old (HEAD b18297c+L5 notes, `/tmp/strim-build-l5h`) vs new (`l5f`), `gates.sh`, raw in `raw/gates-{h,f}`, all under the lock + watchdog (peaks equal to within 0.4 GB, no aborts):
| gate | old | new |
|---|---|---|
| gen 16 ids | - | identical (diff clean) |
| benchspec depth 0 | EXACT 123 | EXACT 123 |
| checkprefix 4096 / 8192 +MTP | ALL PASS | ALL PASS |
| checkprefixcuts | ALL PASS | ALL PASS (cold 5K 1010, 16K 969 tok/s) |
| checkbatchparity B=4 | 127/128 margin 0.125 | 127/128 margin 0.125 (same as L1) |
| checkbatchparity B=8 | 252/256 margins <= 0.125 | 252/256 margins <= 0.125 (same as L1) |
| decode B=1 (benchspec depth 2, ms/pass, 3 reps) | 52.2 51.1 50.5 | 49.6 49.2 49.5 |
| decode B=4 (benchbatch 512 24 4, batched s) | 1.019 | 0.999 |
| c=4 512 cell (w4s) agg tok/s / TTFT | 64.07 / 1.666 s | 63.91 / 1.667 s (neutral) |
`d1` returns rc=2 on both builds (pre-existing spec-vs-greedy mismatch of the 3-token synthetic prompt, identical output; see L0 summary section 4). Tests: 4 GDN tests pass under `swift test --filter` in the snapshot.
