# L9: decode anatomy (2026-10-28)

Investigation only; no engine changes. Command: `strim benchdecodeanatomy` (`Sources/StrimCLI/Cmd_DecodeAnatomy.swift`, commit f4f2ceb). Chained serial microbenches over all 64 layers with real weights (not cache-resident), GPU lock + memory watchdog (peak 33.9 GB, no aborts). Scripts: `ab_pipe.sh`, `ab_pipe_batch.sh`, `wd_run.sh`; raw output in this folder. The worker's draft tables are not preserved; the numbers below are its reported results.

## Where the time goes (4K context, M=1 decode pass)
- Wall 33.9 ms = 3.1 ms host graph build + 30.9 ms GPU. GPU time is 92% of the 530 GB/s roofline (15.0 GB per pass, 28.3 ms floor); wall is 83%.
- Projections 26.7 ms (96.8% of their own roofline).
- Everything else 4.2 ms: GDN glue 1.3, attention glue 1.0 (SDPA 0.8), norms 0.5, residual adds 0.3, swiglu 0.1, lm_head + argmax 1.3.
- Bottom-up chain sums reconcile with the real-code pass within 5% in all 10 cells (-1.0% at M=1, +4.5% at M=3). A real SpecStream round on synthetic caches: 43.1 ms vs bottom-up 42.4 (1.7%); with STRIM_TIMING 46.4 ms vs 47.2 in the real-prompt benchspec run.

## Verify pass, depth 2 (M=3)
GPU 37.3 ms + 3.1 ms host build, plus two MTP head steps of ~0.95 ms each. Extra vs M=1: projections +2.1 ms, recurrence state stack +0.8..1.4, SDPA 1.6 ms at 4K and 5.1 ms at 16K, and a 1.7 ms residual not attributed.

## Kernels and boundaries
- ~1530 kernels per pass (~24 per layer); each dependent tiny kernel costs 1.0-1.2 us fixed, so launch gaps total ~1.7 ms.
- A commit-and-wait boundary costs 120-155 us; an async commit costs 0-8 us with no GPU bubble.
- MLX's 50-op commit granularity hides nothing except the host build + encode before the first kernel (the 3.1 ms above).

## Removable cost, ranked
1. **Pipelined graph build** (`asyncEval(h)` every 8 layers): saves 2.7 ms at M=1 and 3.4-3.8 ms at M=3/5. Prototype only in a snapshot (STRIM_PIPE_LAYERS): logits bit-identical; end-to-end decode 45.5 -> 49.7 tok/s (+9.2%) at 4K depth 2 with identical output ids and the same memory; batched B=4/8 saves ~5% (2.2 and 3.9 ms).
2. **Verify SDPA for more than one query row** (multi-query kernel): 0.9 ms at 4K, 2.8 ms (6%) at 16K depth 2, up to 5 ms at 16K depth 4. Numerically different, high effort, stock-MLX alternatives all slower. Worth it only at 8K+.
3. Smaller: GDN pre-recurrence fusion ~0.5 ms (1.3%), stack-write dedupe 0.2-0.3 ms, residual+norm fusion 0.2-0.4 ms; MTP head steps already near bandwidth.

## Limits
M=1 reaches ~90% of the roofline in wall time after lane 1, i.e. its practical limit. Verify pass at depth 2-4 is at 62-78% of roofline; B=8 at 49-56% (L8 territory: MLX qmv_wide tile cap).

## Unresolved
M=3/5 residual of 0.6-1.7 ms unexplained; draft-chain and reseed graph pipelining (~0.3-0.5 ms) untested.
