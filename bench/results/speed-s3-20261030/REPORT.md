# S3 macro-chunk bf16 GEMM

**KEEP under the declared near-exact task gate; propose making the flag default on the measured M5 Max. Default remains OFF; no commit was made.**

Opt-in flag: `STRIM_PREFILL_MACRO_BF16=1`; default remains OFF. No commit.

Microbenchmark gate: **KEEP / implement**; projected cold-prefill gain **+3.94%**, threshold +1.5%. First, noisier pass projected +3.63%; longer confirmation is used below.

| Shape (K→N) | 4×QMM1024 ms | dequant+bf16 GEMM4096 ms | dequant-only ms | Q TF/s | B inclusive TF/s | Peak delta GB |
|---|---:|---:|---:|---:|---:|---:|
| mlp.gateup (5120→34816) | 25.757 | 24.153 | 1.071 | 56.69 | 60.46 | +0.357 |
| mlp.down (17408→5120) | 13.394 | 13.083 | 0.671 | 54.51 | 55.81 | +0.598 |
| gdn.qkv (5120→10240) | 7.586 | 7.217 | 0.506 | 56.62 | 59.51 | +0.105 |
| gdn.z (5120→6144) | 4.956 | 4.691 | 0.350 | 52.00 | 54.93 | +0.063 |
| gdn.out (6144→5120) | 4.936 | 4.911 | 0.306 | 52.20 | 52.48 | +0.063 |
| gdn.b (5120→48) | 0.408 | 0.255 | 0.128 | 4.93 | 7.90 | -0.003 |
| gdn.a (5120→48) | 0.391 | 0.255 | 0.126 | 5.15 | 7.90 | -0.003 |
| attn.q (5120→12288) | 9.096 | 8.632 | 0.480 | 56.66 | 59.71 | +0.126 |
| attn.k (5120→1024) | 1.127 | 1.107 | 0.871 | 38.09 | 38.81 | +0.008 |
| attn.v (5120→1024) | 2.016 | 2.514 | 0.953 | 21.30 | 17.08 | +0.010 |
| attn.o (6144→5120) | 6.910 | 6.966 | 0.297 | 37.29 | 36.99 | +0.126 |

Cold prefill through actual EngineCore sessions, including default MTP head work; HTTP transport excluded. Two ABBA cycles, fresh process/block, two samples/size/block, zero cached tokens. Real default has role-aware 1536 maximum; flag has fixed 4096.

| Tokens | Default tok/s | Flag tok/s | Gain | Cycle 1 | Cycle 2 | Same-arm drift | Default peak GB | Flag peak GB | Delta GB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4096 | 1024.3 | 1063.3 | +3.81% | +3.81% | +3.81% | 0.36% | 18.549 | 19.075 | +0.526 |
| 16384 | 964.4 | 999.0 | +3.58% | +3.70% | +3.47% | 0.38% | 21.597 | 21.584 | -0.013 |
| 32768 | 889.2 | 915.0 | +2.90% | +2.87% | +2.94% | 0.24% | 25.819 | 24.911 | -0.908 |

Existing cold-prefill noise floor: ±1.5%. Memory is peak live MLX allocations, including target, head, caches and decode; not RSS. Raw rows retain per-sample load averages, timings, memory and generated IDs.

Quality uses full-vocabulary final-position logits. Original bench prompts are included alongside 4K repetitions to exercise the new path; greedy checks generate 16 tokens.

| Prompt | max abs | mean abs | top-1 | top-5 overlap | KL(default‖flag) | Greedy matching positions /16 | Exact continuation |
|---|---:|---:|---|---:|---:|---:|---|
| code-93 | 0.000000 | 0.000000 | agree | 5/5 | 0.00000000 | 16/16 | yes |
| code-4096 | 0.593750 | 0.088540 | agree | 5/5 | 0.00000169 | 16/16 | yes |
| csvpy-26 | 0.000000 | 0.000000 | agree | 5/5 | 0.00000000 | 16/16 | yes |
| csvpy-4096 | 8.656250 | 0.953419 | agree | 4/5 | 0.23442100 | 1/16 | no |
| json-30 | 0.000000 | 0.000000 | agree | 5/5 | 0.00000000 | 16/16 | yes |
| json-4096 | 1.718750 | 0.248767 | agree | 5/5 | 0.00842594 | 12/16 | no |
| math-41 | 0.000000 | 0.000000 | agree | 5/5 | 0.00000000 | 16/16 | yes |
| math-4096 | 0.796875 | 0.075333 | agree | 4/5 | 0.00001551 | 16/16 | yes |
| natural-59 | 0.000000 | 0.000000 | agree | 5/5 | 0.00000000 | 16/16 | yes |
| natural-4096 | 1.479980 | 0.227541 | agree | 4/5 | 0.00000242 | 16/16 | yes |
| prose-51 | 0.000000 | 0.000000 | agree | 5/5 | 0.00000000 | 16/16 | yes |
| prose-4096 | 1.312500 | 0.193398 | agree | 5/5 | 0.00010968 | 16/16 | yes |
| rust-29 | 0.000000 | 0.000000 | agree | 5/5 | 0.00000000 | 16/16 | yes |
| rust-4096 | 10.640625 | 1.263450 | DIFFER | 3/5 | 6.21586858 | 0/16 | no |
| sql-33 | 0.000000 | 0.000000 | agree | 5/5 | 0.00000000 | 16/16 | yes |
| sql-4096 | 2.210938 | 0.234477 | agree | 5/5 | 0.00101091 | 1/16 | no |

Task-level predeclared gate: only-default ≤ only-flag AND at most one default pass→flag fail, with all 21 pairs verified. Same seed 20261027, arm H, default knobs, no MTP head (matching the prior study), exact archived task/snapshot hashes.

| Task | Default | Flag |
|---|---|---|
| hd-js-01 | PASS | FAIL |
| hd-ts-01 | PASS | PASS |
| hd2-fs-02 | PASS | PASS |
| hd2-js-01 | FAIL | PASS |
| hd2-ts-01 | FAIL | FAIL |
| js-01 | PASS | PASS |
| js-03 | PASS | PASS |
| jv-01 | PASS | PASS |
| jv-03 | PASS | PASS |
| me-06 | PASS | PASS |
| qa-01 | PASS | PASS |
| rb-01 | FAIL | PASS |
| rb-03 | FAIL | FAIL |
| rs-01 | PASS | PASS |
| rs-03 | PASS | PASS |
| rx-03 | PASS | PASS |
| tf-02 | FAIL | FAIL |
| tf-11 | PASS | PASS |
| tf-12 | PASS | PASS |
| ts-01 | PASS | PASS |
| ts-03 | PASS | PASS |

Task gate: pairs 21/21, infra pairs 0, only-default 1, only-flag 2; **PASS**.

Headless checks only; no GUI interaction. Live macro causality tests 2/2 pass; flag-unset check passes (live test skipped). See `method.md`, `result.json` and `raw/` for commands, complete samples and evidence.

## Gate decisions

| Step | Verdict |
|---|---|
| Microbench | KEEP, +3.94% projected versus +1.5% threshold |
| Opt-in implementation | Built and causality-tested; default OFF |
| Cold prefill | KEEP; both cycles >+2% at 16K/32K and memory within +1.5 GB |
| Original bench logits/gen16 | PASS; all eight bit-identical, 128/128 continuation tokens |
| CLI gen16 | PASS, 16/16 |
| Prefix exactness + forced eviction | PASS, both arms |
| Paired H tasks | PASS; default 16/21, flag 17/21; only-default 1, only-flag 2 |

The original prefix diagnostic's baseline eviction assertion failed because thinning kept the cache within budget without node eviction. All parity checks passed. The unchanged diagnostic then passed both arms with the existing thinning-disable knob, which forces eviction. No test/oracle was edited. Speed and paired task runs used default thinning.

**Additional 4K stress limitation:** only 4/8 repeated-prompt continuations are exact, top-1 agrees 7/8, and top-5 sets agree 4/8. Maximum logit delta is 10.640625 and maximum full-vocabulary KL is 6.215869 (repeated Rust prompt). This is material drift on repetitive inputs, not bit identity. The declared original-prompt and paired task gate passes only if the rows above say PASS; this extra stress table is disclosed separately and has no invented numerical cutoff. Any default-adoption review should retain this limitation.

Shared HEAD advanced to f70f4ec9 via another writer's version-only commit. Frozen binary and S3 source hashes remain unchanged; the measurement base is 22a7987. See `raw/frozen-source-check.txt`.

Changed files:

- `Sources/StrimCLI/Cmd_MacroGemm.swift`
- `Sources/StrimCLI/Commands.swift`
- `Sources/StrimCore/MacroPrefill.swift`
- `Sources/StrimCore/Weights.swift`
- `Sources/StrimCore/PrefixCache.swift`
- `Sources/StrimCore/GDN.swift`
- `Sources/StrimCore/Attention.swift`
- `Tests/StrimCoreTests/MacroPrefillTests.swift`
- `bench/results/speed-s3-20261030/`

All experiment-owned benchmark/server processes exited. Final checks found no
listeners on owned ports 8236/8237; see `raw/owned-processes-final.txt` and
`raw/ports-final.txt`. No GUI was used. No commit or default flip was performed.
