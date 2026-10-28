# Speed wave 2, L0 measurement (2026-10-28)

Machine: M5 Max 64 GB, model `models/qwen38-4bit` (+ `qwen38-mtp-4bit` head emulation), chunk 1024 (served path), load average 2.7-5.5 (another worker shared the machine; all GPU runs under `/tmp/strim-bench.lock`, memory watchdog on every run: peak footprint 17.3 GB at 4K, 26.5 GB at 16K, no aborts, no swap growth). Build: commit of this lane, snapshot build. Raw: `raw/`; scripts: `wd_run.sh abba.sh sweep.sh knob.sh table.awk model.awk`.

## 1. OpTimer and zero cost when off
`STRIM_OPTIME=1` enables region timing (`Sources/StrimCore/OpTimer.swift`; markers in Layer/GDN/Attention/QwenModel; report in `benchprefill`; `STRIM_OPTIME_MTP=<head dir>` adds the MTP head work of `coldChunk`; `STRIM_OPTIME_SWEEP=n` fences one region name at a time). Off path = one branch on a `static let`; flops/bytes/inputs are autoclosures.
ABBA `benchprefill 4096 4 1024` (reps 2-4), baseline HEAD build (A) vs instrumented build with STRIM_OPTIME unset (B): A 1025.5 tok/s, B 1025.9 tok/s (+0.04%, spread 1025-1026). Pass (< 0.3%). `OpTimerTests`: 5 tests pass; MLX-touching ones skip if the test bundle has no metallib.

## 2. Per-op share table (prefill, chunk 1024, MTP head on)
Method note (matters): fencing every region (eval per region) inflates GPU time. Isolated fenced totals were +27% (4K) / +20% (16K) over the plain wall, and a fence costs 0.13 ms for a tiny op but ~0.5-1 ms in-pipeline (sweep: `raw/sweep*.txt`). So the table prices each region at its PIPELINED cost: GEMM regions from the roofline microbench at the real shape (validated in the real model by an xctrace trace with `MLX_MAX_OPS_PER_BUFFER=1`: gateup cluster 6.25-6.5 ms vs 6.36 microbench, down 3.5-3.7 vs 3.46, qkv 1.92 vs 1.92), non-GEMM regions from `benchopmicro` (pipelined, + 0.136 ms/call for the blocked-GDN kernel's input copies, checked against the trace: 0.978 ms vs 0.83+0.14), MTP-head regions as raw minus fence. FLOP convention: 2*M*N*K per quantized matmul at its real shape (dense-equivalent), SDPA 4*Hq*D*causal pairs, GDN recurrence 6*Dk*Dv*Hv per token; the 4K count is 50.55 GFLOP/token (48.7 linear + attention/head/MTP), 16K 53.1.
Reconciliation (sum of estimated regions vs plain wall incl. MTP head work, from interleaved bases): 4K 4136 ms vs 4074 ms = +1.5%; 16K 17511 ms vs 17335 ms = +1.0%. Within 5%.
Full tables: `table4k.md`, `table16k.md` (calls, fenced raw, estimated ms, share, GFLOP, GB, TF/s and GB/s with % of 62.7 TF/s / 530 GB/s). Group shares of plain wall:

| group | 4K | 16K |
|---|---:|---:|
| MLP (gate/up 39%/37%, down 21%/20%) | 63.0% | 59.2% |
| GDN total (proj+out GEMMs ~19.4% at 4K) | 26.3% | 24.7% |
| GDN non-GEMM (rec, conv, qknorm/betaG, norm/gate, b/a) | 6.6% | 6.2% |
| of which recurrence alone | 4.5% | 4.3% |
| attention total (SDPA 1.9% / 7.1% of est.) | 8.2% | 13.1% |
| norm+resid+act+lm_head | 2.3% | 1.8% |
| MTP head (all) | 2.8% | 2.8% |

Achieved rates: gate/up 57.4 TF/s (92% of 62.7), GDN/attn projections 56.5-57.2 (90-91%), down 52.8 (84%), SDPA 42 TF/s (68%); elementwise ops run 500-1100 GB/s-equivalent effective (cache resident), GDN recurrence 42 GB/s and 5 TF/s (compute/latency-bound, far from either roof).

## 3. GEMM roofline microbench (`strim benchgemm`, raw/gemm.txt)
bf16 8192^3: 59.9 TF/s fenced (pipelined run is memory-pressured, 46.6 not meaningful). qmm4 pipelined TF/s at M=512/1024/4096: gate/up (N=34816,K=5120) 56.8/57.4/56.5; down (N=5120,K=17408) 54.1/52.8/52.7; qkv 57.3/55.9/56.3; z 55.5/57.5/56.2; out and o_proj 54-57; q_proj 56-57; k/v (N=1024) 52-56. bf16 at the same shapes (M=1024) 53-58, so 4-bit qmm is at 0.92-1.0 of dense; down proj is the only shape visibly below (52.8).

## 4. Free knob sweep (`knob.sh`, unmodified HEAD build, ABBA over 12 single-process cells, 3 internal reps)
| workload | default | ops50 | ops200 | ops500 | mb100 | mb400 |
|---|---:|---:|---:|---:|---:|---:|
| 4K prefill tok/s | 1025,1026 | 1026,1029 | 1026,1026 | 1023,1030 | 1023,1029 | 1032,1033 |
| B=1 MTP decode tok/s | 76.0,77.7 | 78.1,77.0 | 77.4,76.9 | 78.5,77.1 | 78.2,76.0 | 75.6,75.5 |
| B=4 batched 24 steps (s) | 1.041,1.018 | 1.024,1.027 | 1.014,1.011 | 1.006,1.042 | 1.017,1.016 | 1.023,1.025 |
No setting beats default by >= 2% beyond the +-1.5% noise (best: mb400 prefill +0.6%, ops500 B=1 +1.3% but mb400 B=1 -1.6%). Verdict: keep defaults. Side result: `MLX_MAX_OPS_PER_BUFFER=1` (a commit per op) costs only -5% (B=1) and -16% (B=4 step 43 -> 50 ms), so per-commit host cost is ~5 us/op: host commits are not a decode gap source. (benchspec reports a pre-existing spec-vs-greedy MISMATCH for the 3-token synthetic prompt at default settings too; unrelated to knobs.)

## 5. xctrace feasibility (30-minute test): YES for per-encoder, NO for named per-kernel
- `xcrun xctrace record --template "Metal System Trace" --attach <pid>` works and `xctrace export --xpath '/trace-toc/run[1]/data/table[@schema="metal-gpu-intervals"]'` gives start/duration per compute encoder for the target process. `--launch` gave no GPU rows for the strim process (use attach).
- Kernel names are not exported (labels are "Command Buffer N:Compute Command M"); shader-profiler tables are empty from the CLI. With default buffering one encoder = ~40 ops, so per-op durations need `MLX_MAX_OPS_PER_BUFFER=1` (about 1090 encoders per 1024-token chunk), which then identifies ops only by position/duration.
- Occupancy from the intervals undercounts (61% busy on a prefill that is ~100% GPU-bound), so wall minus interval sum is not a valid gap.

## 6. Decode gap estimate: NOT obtained from the trace (see 5)
Indirect numbers: B=4 batched step 43.4 ms (24 steps in 1.04 s) vs streaming floor ~28 ms (14.8 GB streamed weights / 530 GB/s); per-commit host cost ~5 us (ops=1 test), tiny-op host sync round trip 0.13 ms, graph build 2.6 ms/pass (plan). So a sync that serializes the next-pass graph build costs ~3 ms/pass (UNVERIFIED), consistent with L4's estimate; the rest of the B=4 gap to the floor is GPU-side.

## Verdict per lane
- L5 (GDN prefill kernel): gate "GDN non-GEMM >= 6% of prefill" PASSES, marginally: 6.6% at 4K, 6.2% at 16K (bottom-up range 5.9-6.6%; recurrence alone 4.3-4.5%). Ceiling: recurrence 2x faster = ~2.2%; plus fusing conv/qknorm/norm_gate copies maybe 1% more. Expect 1-3% as planned; do it only after L2/L3, small time-box.
- Dominant op vs mlx-vlm gap: GEMMs are 85-90% of prefill and already at 92% of the dense plateau (gate/up) and 84% (down). The 1-3% rival gap cannot come from GEMM tiles; candidates in order: GDN non-GEMM (6.2-6.6%), SDPA at long context (7% of 16K prefill, 68% of plateau), down proj (84%), MTP head (2.8%).
- L2 (fused projections): prefill ~0 confirmed (projections at 90-91% of plateau, M=1024 compute-bound; fusing qkv+z removes no work). Decode-only lane.
- L3 (MTP head in cold prefill): head costs 2.8% of prefill here (head GEMMs + attention + mtp_other 0.8%), so skipping it when MTP is unwanted can give up to ~2.8%, windowing 1.4-2.0%; the plan's 1.0-1.7% is plausible, slightly conservative.
- L4 (decode host syncs): host commit cost is negligible (5 us/op), a sync costs the next-pass graph build (~2.6 ms) plus restart latency; 2-5% decode is plausible but needs a direct A/B; no trace-based gap available.
- Knobs: no free win.
