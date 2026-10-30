# S3: dequantize to bf16 at M=4096

Base: 22a79871dfc46a3780cc0ab22f15370f3d4778b6. MLX fork 0.32.3-strim.1
(d881bd905948fb3e5e46864dc47cf29a8b19fde4), MLX submodule
575068a4fa263b16ac08921751e8a5257f3e80b9. Apple M5 Max, 64 GB.

## Preregistered sequence and gates

1. Real-weight Swift microbenchmark. A: four quantized matmuls at M=1024.
   B: one fresh dequantization to bf16, then dense bf16 matmul at M=4096.
   Kill if projected cold-prefill throughput improvement is below +1.5%.
2. Only if promising: implement opt-in engine macro-chunks; default OFF.
   Projections/MLP at 4096, recurrence/SDPA in original 1024 sub-ranges.
3. Cold 4K/16K/32K served prefill: two ABBA cycles, load average and memory.
   Existing cold-prefill noise floor: +/-1.5% (speed-w2-L0-20261028/summary.md).
4. Near-exact quality: report bench-prompt logit max/mean abs diff, top-1/top-5
   agreement and KL; greedy gen16/checkprefix; then paired arm H, same seed,
   default knobs, on the 21 verified tasks in align-thinking-20261029.
   Task gate: only-default <= only-flag AND at most one pass-to-fail drop.
   This criterion is stated before any task-level run.
5. Keep only if cold prefill improves >=2% at BOTH 16K and 32K, memory increase
   <=1.5 GB, and quality passes. Propose default adoption; never flip default.

## Microbenchmark

All source modifications for the spike are in `/tmp/s3/micro-src`, a copy of
Sources, Tests, Package.swift, Package.resolved. The real engine tree is unchanged
before the first gate. Scratch seeded using `cp -cR /tmp/s4/build-int /tmp/s3/build`.
Build, from `/tmp/s3/micro-src`:

```
nice -n 19 swift build -c release --scratch-path /tmp/s3/build
/tmp/s3/build/out/Products/Release/strim benchmacrogemm ~/.strim/models/qwen38-4bit 3 4
```

The command acquires the existing GPULock on `/tmp/strim-bench.lock` before
model loading, input initialization or any GPU operation, and holds it through
the entire run. Models are read only. No server, ports, GUI, or Python.

Actual quantized checkpoint tensors are rotated over four layers per shape
(GDN/MLP: 0,1,2,4; attention: 3,7,11,15). MLP uses the existing fused gate/up
weights. All relevant projections are included, including narrow GDN b/a and
separate attention k/v. Activations are seeded bf16 normal *0.1. A consumes the
four contiguous 1024-row slices of the exact same 4096-row input consumed by B.
A has four outputs, without an artificial concatenate. B constructs a fresh
dequantization graph for each weight use and does not cache any dense weight.
Each layer's outputs are evaluated before moving to the next layer. Each arm
gets an excluded warm-up over all four weights. Two ABBA cycles per shape;
three samples per block; each sample averages the four weights. Timings include
Swift graph construction, dispatch and synchronization, and include the entire
dequantization in B. TF/s counts useful matmul FLOPs only, 2*M*N*K, divided by
inclusive wall. This is not a full engine or cache-cold benchmark.

Block medians -> geometric mean per arm. Per-cycle effect and maximum absolute
within-cycle same-arm block drift are retained. Load averages at each block.
Separate dequant-only measurements are informational; never subtracted from B.
Peak probes outside timing clear the MLX allocator cache and reset peak stats,
retaining the same weights and inputs for each arm. Record baseline live bytes,
peak live bytes, incremental peak, and end cache. MLX active peak is not RSS or
a measured full-engine peak.

Projection uses the pipelined per-region milliseconds in the L0 table16k and
plain wall 17335 ms. Apply each measured B/A ratio to its matching GEMM region;
split grouped gdn.proj and attn.proj cost in proportion to GEMM FLOPs. Leave
other work, MTP, SDPA and recurrence unchanged. Predicted saved milliseconds =
sum(region_ms * (1-B/A)); throughput change = old/(old-saved)-1. No macro
scheduling, concat, or extra activation cost is added, so this is favorable to
S3 rather than a promise of end-to-end speed. Also retain the raw microbench
projection for four macro-chunks through all 64 main layers at 16K.

## Opt-in implementation and engine measurements

The confirmation microbenchmark (9 repetitions/block, four real weights) cleared
step 1 before any real-tree source edit. `STRIM_PREFILL_MACRO_BF16=1` enables
transient dense bf16 projections/MLP for full 4096-row chunks. OFF remains default.
Flag ON uses fixed 4096-token prefix-cache cuts; the cut policy is part of the
disk-cache fingerprint. GDN conv/recurrence/norm-gate and attention RoPE/append/SDPA
run in <=1024-row sub-ranges; input and output projections span the macro.
Incomplete macro tails retain quantized matmuls; mixing still splits at 1024.
Decode/verify widths and unrotated non-4-bit GEMMs retain quantized dispatch.

The actual default served engine uses role-aware cuts with maximum 1536, rather
than the fixed-1024 anatomy benchmark in the plan. A compares against that real
unchanged default. B is the new fixed-4096 chunk policy; this distinction is
included in the quality scope, rather than silently altering baseline knobs.

`benchmacroprefill` uses LocalEngineClient through normal sessions/generate,
including EngineCore.coldChunk, default MTP seeding, prefix snapshots and admission.
It measures Usage.prefillSeconds, not HTTP transport. Both model and MTP head are
loaded from ~/.strim/models. One excluded 4096-token warm-up per fresh process;
two measured repetitions per size (4K,16K,32K). Natural bench-corpus token IDs
are repeated to the exact lengths with a fixed per-repetition rotation. Prefix
cache is reset and a fresh session is opened for every request; cached_tokens
must be zero. Generate 16 greedy tokens with seed 20261027 and ignoreEOS, to
retain the default MTP behavior. The same prompt is used for each arm/rep/size.
Each sample clears MLX allocator cache and resets its peak immediately before
request generation. End-of-request peak includes decode, snapshots and head.
The command itself holds GPULock throughout; independent fresh processes run
ABBA ABBA. The script records start/end uptime and swap; JSON rows record load.
Block median is the mean of the two samples. Aggregate effect uses geometric
means of four block medians per arm; per-cycle effects and same-arm drift retained.

Quality command `checkmacroquality` compares full-vocabulary last-position logits
and greedy gen16 on all eight original bench prompts AND 4096-token repetitions
of each prompt, to ensure the changed path is exercised. Paired reference uses
the default policy. Top-5 reports both exact set equality and intersection / 5;
KL is full-vocabulary KL(default || flag) in double precision on CPU.

Task corpus is copied read-only in meaning (no task edits) from the archived
`/tmp/align1/bench/corpus` to `/tmp/s3/corpus`. The selected IDs are exactly the
21 pairs verifiable in both thinking-study arms, excluding hd-rx-02, hd2-rx-01,
rx-01. Same original seed 20261027 and default H knobs, without a head as in the
original thinking study. Agentbench state/output and TMPDIR are under /tmp/s3.

The live `MacroPrefillTests` exercised real GDN layer 0 and attention layer 3 at
4096 rows, replacing all tokens after row 1023 and requiring bit-identical output
for rows 0...1023. Both pass. A separate flag-unset invocation verifies that
opt-in is disabled and the 1024 diagnostic chunk constant is unchanged.

`checkprefix` is run with `STRIM_PREFIX_CUTS=fixed`, since that diagnostic asserts
fixed `PrefixPrefill.chunk` boundary counts; the real default is role-aware 1536.
This fixed-cut diagnostic is separate from actual-default logit and speed A/B.

### Existing prefix-diagnostic eviction assumption

The first baseline `checkprefix` at 16K, fixed cuts, default GDN thinning passed
all hash/token parity checks, but its `budget respected` assertion also requires
`evictions > 0`. Thinning made the store fit (1904 MiB < 2023 MiB budget) with
zero evictions, so the unchanged diagnostic exited 2. This is retained as a
baseline failure; the assertion is not edited or weakened. For the forced-eviction
diagnostic both arms use the existing `STRIM_PREFIX_GDN_STRIDE=1` knob, disabling
thinning and forcing node eviction under the same small-budget test. This knob
is NOT used for the speed measurements or paired agentbench, which use defaults.

During the run, another writer advanced the shared repository from 22a7987 to
f70f4ec9 (`0.1.7`), changing only RELEASE_NOTES.md, Sources/StrimAPI/Version.swift
and VERSION. This experiment made no commit. The measured binary was not rebuilt;
its SHA-256 and every S3 source/test hash still match the frozen pre-run record
(`raw/frozen-source-check.txt`). All S3 engine edits remain uncommitted.
