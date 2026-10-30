# S5: long-context decode (2026-10-30)

**PARTIAL — paired decode measurement blocked by the shared GPU lock.** An unowned Evolve search (PID 70044, --budget-minutes 720) holds the lock for its whole search. S5 completed the implementation and quality gates, but only the first two default timing cells ran. The queued S5 process was stopped to satisfy cleanup; no unowned process was signalled. The fusion remains opt-in, default OFF, with no validated speed claim and no default proposal.

## Scope and implementation

HEAD `a03dc65fa6dbd916400b2264210a132cae018dc0`, MLX fork `0.32.3-strim.1`, M5 Max. Models are read-only from `~/.strim/models/qwen38-4bit` and `qwen38-mtp-4bit`. No commit or default change.

**(a) Multi-query verify SDPA: SKIP, already implemented.** `SpecStream.step` passes the whole `[pending, draft1, …]` array into `QwenModel.forwardAll`. `Attention.forwardRange` retains S queries in `[B,24,S,256]`, appends S keys/values to the cache, and calls `MLXFast.scaledDotProductAttention` once with bottom-right causal masking. Widths 3/5/8 already share one call per attention layer. No replacement kernel, per-query split benchmark, or rejected batched-attention experiment was repeated.

**(b) Pre-recurrence GDN fusion — KEEP provisionally as an opt-in experiment; speed unvalidated:** one custom Metal dispatch combines four-tap convolution, bf16 SiLU, Q/K RMS normalization, threefold head replication, V extraction, beta and g. The four existing projections and the recurrence are unchanged. `STRIM_GDN_PRE_FUSE=1` opts in; unset/0 stays on the reference path. Eligibility is bf16 and 1–8 tokens, with the existing Metal path enabled; `STRIM_CONV_TENSOR` and the B>1 batch-decode opt-out preserve their reference paths. Convolution rollback views still come from the original concatenated projection history.

## Microbench and advance/kill decisions

Part (a) has no changed path to benchmark: the requested batching already exists. Part (b) advanced provisionally because the simple 16K projection crossed +1.5% in loaded runs; a lower-noise width-3 sample was below that threshold. This uncertainty is retained rather than claiming an unambiguous microbench pass.

The width-3 B=1 table uses one fresh 16K depth-2 control median of 45.17 ms/round (90 measured rounds, 43.78 ms minimum). Projection is `45.17/(45.17 - saved_eval_ms)-1`, assuming unchanged acceptance and all micrograph savings on the critical path. It is a projection, not observed decode throughput. Host construction savings are recorded separately in raw data because pipelining can hide them.

| Micro run | A eval ms/48 | Fused eval ms/48 | Saved ms | Simple projected decode gain | Same-arm micro noise |
|---|---:|---:|---:|---:|---:|
| 2 | 3.354 | 1.853 | 1.501 | 3.44% | 15.49% |
| 3 | 1.357 | 0.863 | 0.495 | 1.11% | 2.29% |
| 4 | 2.475 | 1.544 | 0.931 | 2.11% | 39.23% |

Run 1 included graph construction and a different dependency chain; it is exploratory only. Run 2 began at 1-minute load 179.6; run 3 ended at 48.3; run 4 began at 22.0 and experienced further load variation. All four runs, all B/S shapes, parity probes, samples, block loads, and build/eval splits are retained in raw. Synthetic Q/K/V/beta were equal on every tested shape; g differed by at most 2.98e-8. Real-model drift is much larger and is reported below.

## Decode ABBA results

| Context | c | Default aggregate tok/s | Opt-in aggregate tok/s | Change | Cycle 1 | Cycle 2 | Same-arm noise | Output-mismatch reps |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4096 | 1 | 83.28 (A1 only) | pending | — | — | — | unmeasured | — |
| 4096 | 4 | 80.20 (A1 only) | pending | — | — | — | unmeasured | — |
| 16384 | 1 | pending | pending | — | — | — | unmeasured | — |
| 16384 | 4 | pending | pending | — | — | — | unmeasured | — |
| 32768 | 1 | pending | pending | — | — | — | unmeasured | — |
| 32768 | 4 | pending | pending | — | — | — | unmeasured | — |

These are partial baseline cells, **not** ABBA estimates. No candidate decode sample completed. The +2% at 16K c=1 beyond-noise gate cannot be assessed. After GPU availability is resolved, rerun the entire schedule with `bash /tmp/s5/abba.sh` (or the retained raw script); it intentionally restarts at A1.

c=4 is four concurrent MTP streams under round-robin, not a batched plain-decode claim. Per-request rates, samples, load/swap snapshots, acceptance, pass counts and token IDs/hashes are in raw; aggregate rates are the metric above. A timing row with changed output/acceptance is not evidence of a like-for-like kernel speedup.

## Quality results

| Gate | Result |
|---|---|
| gen16, default 3-token prompt | Identical token IDs |
| checkprefix 4096 + MTP | Both internal ALL PASS; reported reference hash/16 IDs and MTP first 8 IDs match |
| checkprefix 8192 + MTP | Both internal ALL PASS; reported reference fields compared in result.json |
| Informational hot continuation, both prefix checks | FAIL: default hot/cold identical over 20 tokens; opt-in first diverges at index 6 (2064 vs 40, cold margin 0.125) |
| Verify widths 3/5/8, 16K | FAIL full-logit hashes; all 16 top-1 choices agree |
| Eight 4K prompts, independent greedy16 | 6/8 identical; csvpy and sql differ |
| Teacher-forced stress top-1 | 126/128 rows agree |

Prefix ALL PASS is an internal cache-consistency verdict, not proof of cross-arm bit identity. The full MTP reference arrays are not printed by that existing command; only its reported deterministic fields are compared across arms. Timed MTP generations provide additional complete output hashes. The hot-continuation divergence is not dismissed as the pre-existing sampled B>1 issue.

| 4K prompt | Max abs logit drift | Mean abs drift | Mean KL(ref || flag), nats | Top-1 agreement | Independent greedy16 identical |
|---|---:|---:|---:|---:|---|
| code | 2.672852 | 0.086170 | 0.000002407 | 16/16 | yes |
| csvpy | 16.593750 | 0.178716 | 0.012091528 | 15/16 | no |
| json | 0.343750 | 0.027941 | 0.000622313 | 16/16 | yes |
| math | 4.828125 | 0.146675 | 0.007845790 | 16/16 | yes |
| natural | 17.375000 | 0.340998 | 0.040842144 | 16/16 | yes |
| prose | 10.078125 | 0.252028 | 0.001038915 | 16/16 | yes |
| rust | 0.750000 | 0.031432 | 0.000273278 | 16/16 | yes |
| sql | 12.171875 | 0.163753 | 0.038693547 | 15/16 | no |

| Verify width at 16K | Max abs drift | Mean abs drift | Mean KL(ref || flag), nats | Top-1 agreement | Different float32 bit patterns |
|---:|---:|---:|---:|---:|---:|
| 3 | 0.187500 | 0.022571 | 0.000604549 | 3/3 | 627801/744960 |
| 5 | 0.156250 | 0.013752 | 0.000090806 | 5/5 | 773910/1241600 |
| 8 | 0.187500 | 0.020031 | 0.000274329 | 8/8 | 1602530/1986560 |

All full-vocabulary comparisons use the same reference token history. The stress corpus samples 31,784,960 float32 values; verify samples 3,973,120. Bit equality is checked without a tolerance. Large `.safetensors` remain in `/tmp/s5/quality`, not the repository.

## Protocol

- Scratch spike first under `/tmp/s5/micro-src`; no engine edits until the microbench supported advancing a candidate. Seed: `cp -cR /tmp/s4/build-int /tmp/s5/build`.
- Real-tree release build: `nice -n 19 swift build -c release --scratch-path /tmp/s5/build`. Source and binary SHA-256 files are in `raw/`.
- `benchsdpa gdn N` compares 48 dependent pre-recurrence chains, B=1/4 and S=1/3/5/8, ABBA twice. Warmup excluded. Exploratory micro1 includes graph construction in timing; micro2 onward separately records graph construction and eval wall time. All outputs remain live; Q links the next layer. The chains include common dependency operations. These are wall timings of micrographs, not device timestamp measurements or observed whole-model speedups.
- Microbench load varied sharply. All four runs are retained, including the stable-width-3 low estimate; no claim of a settled microbench noise floor. The marginal projection advanced to a full-model comparison because higher-load estimates exceeded +1.5%, rather than treating a noisy low estimate as a safe kill.
- Decode command: `strim benchsdpa s5decode MODEL HEAD CTX C 3 64`. Fresh process per block/cell. Each of C distinct code prompts is primed into a hot session, then one excluded warmup and three measured generations of 64 tokens continue the sessions. Nominal context is 4096/16384/32768; the measured repetitions start approximately 65/129/193 tokens beyond the primed context. Major prefill and model loading are excluded.
- Both arms force `STRIM_DECODE_POLICY=roundrobin`: all concurrent requests retain MTP, whereas auto can permanently switch to plain batched decoding. Every row requires full output length and nonzero MTP passes for every request. Aggregate decode rate is `C*(64-1)/(last output event - first output event)` across the hot concurrent group, following the harness completion-minus-one convention. Per-request usage decode rates and MTP acceptance/pass counts are retained.
- Schedule: A B B A / A B B A, A=flag off and B=flag on, same release binary. Cell estimates are medians of four block medians per arm. Cycle effects use ratios of geometric means of the two block medians per arm. Same-arm noise is the maximum absolute within-cycle block change for either arm, as in S4; also compare with the prior 0.34% noise, without assuming it applies to this loaded run.
- Quality: plain CLI gen16; checkprefix 4096 and 8192 with MTP; full-vocabulary verify hashes/logits at width 3/5/8 and 16K context; 16 full-vocabulary teacher-forced rows plus independent greedy16 for each of the eight corpus prompts repeated to 4096 tokens. Report maximum/mean absolute drift, mean KL(reference || flag), and top-1 agreement. Large float tensors stay under `/tmp/s5/quality`.
- Every GPU process holds `/tmp/strim-bench.lock` (internal `GPULock` or `lockf -k`); it is retained. No servers, ports, GUI sessions, credentials, Python, unowned-process signals, or recursive deletion. Scratch/state stays under `/tmp/s5`. `Sources/StrimEvolve/**` and `docs/EVOLVE.md` are untouched by this slice.

## Tests

Release CLI build passed. Release test preparation encountered module-resolution errors; a debug focused test build succeeded, then its first GPU invocation failed to locate the scratch metallib. The final focused rerun uses an unchanged copy of the built `default.metallib` colocated as `mlx.metallib` inside the scratch StrimCoreTests bundle. Final headless focused rerun: **2 passed, zero failures**, 0.204 s. GUI checks were outside this slice. No oracle, threshold, skip or golden was changed.

## Known baseline issue

S4 records sampled B>1 run-to-run nondeterminism. This S5 run is greedy and explicitly uses MTP round-robin. Any observed output mismatch is reported directly; the pre-existing sampled issue is not used to explain it away.
