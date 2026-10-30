# S4 measurement protocol

Base engine: archive of a112d0d16895d5612a3f86811ca9a368ca96ddaf into `/tmp/s4/src`.
Dependency: copy of `/tmp/strim-build-e2e/checkouts/mlx-swift`, tag 0.32.3
(19601207e9a0de51e03ee6ec0c3c5f3784275075; MLX submodule
1f8e74e3f12f31365464a6867c6579f0e9b29d85). The copied package's broken Git
alternate was repointed to the existing warm repository, without modifying that repository.
Only local scratch manifests use path dependencies (including the resolved swift-numerics
1.1.1 copy); the real repository's dependency remains pinned and unchanged.

Both arms are release builds under `/tmp/s4/build`, with the same experiment harness
and the same default-off scratch Swift fusion. Base binary was saved before the C++ edit;
the second binary differs only by the tile-cap patch. Metal resource bundles are copied
beside both binaries. No Python, servers, ports, GUI actions, forks, pushes or commits.
Models are read from `~/.strim/models` and never modified. Every GPU invocation is a child
of `lockf -k /tmp/strim-bench.lock`; lock acquisition waits without a timeout or lock removal.
The other agent can acquire the lock between blocks. Cap and fusion have independent ABBA
sequences and run separately with mutually exclusive flags under that lock.

For each part: two ABBA cycles, each block a fresh process per workload, one excluded
full-workload warmup (rep -1), then three measured repetitions (rep 0..2). Prefill also
warms a 1024-token chunk first. All timed boundaries use monotonic nanoseconds and force
GPU completion. Model loading, projection-cache construction and initial prefill are
excluded from decode/verify timing. Fusion materializes the four concatenated quantized
matrices once per layer and drops originals, mirroring existing MLP fusion, rather than
copying weights inside each timed call.

- Decode: real distinct chat-formatted bench prompts, one prompt per sequence (the first
  c keys in sorted order); prefill individually with 1024-token chunks, then 64 greedy
  lockstep decode steps at c=1/4/8 from snapshots of the same initial state. c=1 uses the
  ordinary QwenModel path; c>1 uses BatchModel. Aggregate decode tok/s = c*64/time;
  per-request decode tok/s = 64/time. This is in-process batched decode, not HTTP
  total-request throughput or a scheduler/admission test. EoS does not truncate a run.
- Verify: real code-prompt state, then 12 fixed-state target verification passes per rep,
  with `beginVerify()` and all logits materialized, at widths 3, 5 and 8. Widths 3/5
  represent depth-2/depth-4 MTP verification; 8 probes the changed tile. This isolates
  the verify step, excluding drafting/head replay, and is not full MTP emitted tok/s.
- Prefill: cold state, 4096/16384-token prompts made by repeating the concatenated eight
  chat-formatted bench prompts, fixed 1024-token chunks, last-token-only lm_head. Measures
  target prefill only, not head seeding or HTTP TTFT. S4b uses the **unpatched** cap-5 binary
  with STRIM_S4_FUSE=0/1; S4a always leaves fusion off.
- Quality: all eight `bench/ab_prompts.json` prompts, same disabled-thinking chat wrapper,
  64 greedy tokens each. SHA-256 is over the raw Int32 token bytes. Additionally compare
  eight complete vocab logit rows per prompt (initial row and seven decoded rows) as
  float32 values and bit patterns, teacher-forcing the reference tokens for valid comparisons.
  Report teacher-forced argmax agreement over all 64 steps and independent 64-token greedy
  output equality. Reference safetensors live under `/tmp/s4/quality/base`; summary
  measurements, hashes and token sequences are retained in raw results rather than large
  redundant logit tensor files. Decode and verify timing rows also retain output hashes.

Aggregation: median of measured repetitions within each block, then median of the four
block medians per arm. Each ABBA cycle also reports the ratio of geometric arm means,
which cancels linear drift in log performance. Same-arm noise/drift = maximum absolute
change between the two A medians or the two B medians within that cycle, reported rather
than assuming a 0.3% resolution. `raw/analysis.json` retains every sample and block median.
The S2 shared-machine control showed about 7% TTFT / 7.7% decode drift; fresh S4 controls
are used to judge the small effects here. No confidence claim below the observed drift.

S4a clarification: `get_qmv_batch_limit` is unchanged (13/25/33 on this device path).
The cap of five is in `qmv_wide`'s `n_tiles` calculation. The candidate uses a cap of eight
only for architecture generation >=17 and size != 'd', matching the M5 Max dispatch path;
other devices keep five. At M=8 this changes two four-vector tiles to one eight-vector tile;
M<=5 is unchanged. The intended proof is greedy-output identity, not an unmeasured claim
that every floating-point intermediate is bit-identical.

S4b concatenates qkv (10240), z (6144), b (48), a (48) quantized rows into 16480 rows,
validates equal QuantSpec, executes one quantizedMatmul and slices the output. The current
reference b/a prefill projection uses split-K (8 at M=1024,N=48), whereas the fused wide
projection does not, so exactness must be measured. The experiment is scratch-only until
both its speed and quality gates pass; near-identical promotion additionally needs the
existing checkbatchparity and agentbench gates, per PLAN-SPEED-WAVE2.
