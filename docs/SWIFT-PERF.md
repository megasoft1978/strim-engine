# Swift decode performance — measurements and plan

Measured 2026-10-25 on M5 Max 64 GB, Qwen3.8-27B 4-bit + MTP head, **release build**
(`swift build -c release --disable-sandbox`). Numbers drift with GPU thermals; the ranges below
are from repeated runs.

## Corrected baseline

The earlier note in this file said the Swift pass was ~120 ms and 3.8× slower than rapid-mlx.
That number does not reproduce: it was taken from the debug build / a cold process. On the same
machine, same day, release build:

| Item | Measured |
|---|---:|
| Swift 64-layer pass, S=1, warm cache | **37–40 ms** (25–27 tok/s) |
| rapid-mlx quality mode (MTP on), same model | 24.4 ms/output token (**48.2 tok/s**) |
| streaming-read ceiling (`mx.sum` over 4 GB) | **530 GB/s** |

So the real gap to rapid-mlx is **~1.25× on the pass**, not 3.8×. The pass moves ~13 GB of weights in
~39 ms ≈ 330 GB/s, i.e. 62% of the measured streaming ceiling. The remaining gap is not one bad
kernel; it is dispatch/latency across ~64 layers of small ops plus the dependent GDN recurrence.

### Where the pass time goes (S=1, 10 passes each)

| Component | Cost |
|---|---:|
| MLP (3 quantized GEMVs per layer, 64 layers) | 20.3 ms |
| GDN (48 layers, projections + recurrence) | 14.8 ms |
| Gated attention (16 layers) | 3.2 ms |
| embed + final norm + lm_head | ~1.5 ms |

Per-op throughput (queued, no per-call sync): MLP `gate_proj` 655 GB/s, `down_proj` 784 GB/s,
GDN `qkv` 221 GB/s, `in_proj_z` 236 GB/s, `o_proj` 526 GB/s, lm_head 350 GB/s. The narrow GDN
projections are the least efficient part of the pass.

## What was implemented (this session)

1. **Exact cache rollback** — `ModelCache.beginVerify()` / `rollback(drop:)`:
   attention KV is sliced on the time axis; GDN keeps a per-token `(conv, ssm)` history produced by
   the compiled recurrence, so a rejected draft suffix is dropped exactly with no re-forward.
   (The old loop re-forwarded the accepted token on every rejection — a full extra pass.)
2. **Stateful MTP drafter** (`MTPState`): the head keeps its own KV cache over the *shifted* stream,
   is seeded from the target's post-norm hidden, replays verified tokens with the target's hiddens
   after each round, and chains deeper drafts on its own post-norm hidden. This follows
   `mlx_vlm/speculative/drafters/qwen3_5_mtp`. Before this the head was invoked statelessly with the
   pre-norm hidden, which accepted 14–50%.
3. **Speculative loop** (`strim genmtp`, depth 1–3): one target pass feeds `[b, d1, ..., dk]`;
   acceptance is the longest matching prefix; emitted tokens are the accepted prefix plus the target's
   own next token from the same pass. No token is ever re-forwarded.
4. **Depth-0 exactness** — the GDN step now uses one graph in both the plain and the verify path, so a
   non-speculative spec loop is bit-identical to `strim gen` (verified: 107/107 tokens).

### Results

Natural prompt (277-token prompt, 48 new tokens):

| Depth | tok/pass | Draft acceptance | ms/pass | tok/s | Parity |
|---:|---:|---:|---:|---:|---|
| 0 (no spec) | 1.00 | — | 45.4 | 22.0 | exact |
| 1 | 1.55 | 55% | 59.6 | 26.0 | exact |
| 2 | 1.92 | 46% | 72.6 | 26.5 | exact |
| 3 | 2.09 | 36% | 82.8 | 25.2 | exact |

Reproduce with `scripts/bench_swift.sh` (builds the prompt from the model tokenizer, prints this
table plus the pass and component split).

Degenerate 3-token prompt, 64 tokens, depth 2: **2.83 tok/pass, 91% acceptance, 48 tok/s** — inflated
by the repetitive text; not representative.

Each extra token in the verify pass costs **8–12 ms** (GDN recurrence × per-token ops + 3× MLP
compute), which is why depth >2 stops paying off: tokens/pass grows slower than pass time.

## What did not work

- **Per-layer `mx.compile`** (GDN step, then GDN recurrence): 0–11% on the isolated op, neutral to
  slightly negative on the full pass. We keep the compiled recurrence only because it returns the
  per-token state stack needed for exact rollback.
- **Hand-written 4-bit GEMV** (`Sources/StrimCore/QGEMV.swift`, `strim qgemv`): warp-per-row with
  `uint4` loads and `simd_shuffle` reduction, correct to bf16 noise (max 0.06 vs MLX). Throughput
  150–390 GB/s, i.e. **below** MLX's `quantizedMatmul` on the same tensors (221–784 GB/s), so it is
  not wired into the decoder. MLX's kernel is already better tuned than a one-day kernel; a real win
  would need a fused GDN (projections + depthwise conv + recurrence) kernel, not a standalone GEMV.
- **Grouped `conv1d`** for the depthwise conv was replaced by four broadcast taps (same result, no
  measurable time change; it removes a 0.2 ms/call outlier from microbenchmarks).
- **Fused GDN recurrence kernel** (`Sources/StrimCore/GDNMetal.swift`, `strim checkmetal`): one
  threadgroup per `(head, value-dim)` row keeps the 128-wide state in registers and loops the step's
  tokens inside the kernel, writing the per-token stack for rollback. Numerically it matches the
  tensor path (S=1 exact, layer0 parity unchanged: max 0.0625, mean 1.6e-4), but it is **slower**:
  50 ms/pass versus 38 ms. Each row is only 128 MACs, so 6144 tiny threadgroups are launch/scheduling
  bound and the per-call overhead of custom kernels dominates; MLX's large elementwise kernels
  saturate the memory system better. Not wired in.

## Where the remaining 2× is

1. ~~**Whole-model `mx.compile` with `inputs:`/`outputs:` state and async eval**~~ — **refuted by
   measurement** (see the last section of this file): `compile` caches the traced graph, it does not
   fuse or speed up kernels, so its ceiling is graph-construction time. A compiled 64-layer step
   measured −3.1 ms on 36.3 ms (−9%), not the ~13 ms this item predicted.
2. **Fused GDN kernel** — one Metal kernel for `qkv/z/b/a → depthwise conv → gated-delta recurrence`
   would remove the dependent small-op chain that makes GDN 15 ms for 2.7 GB (180 GB/s).
3. **Verify cost** — now the largest measured lever: S=3 streams the same 12.6 GB as S=1 but costs
   47.1 ms vs 35.4 (after the matmul recurrence landed). Re-measure depth 2–3 after cutting it; if the per-token verify cost falls below
   ~4 ms, depth 2 should clear 50 tok/s at ~50% acceptance.

Two of the three "hand-written kernel" candidates (4-bit GEMV, fused GDN recurrence) were built,
validated against the tensor path, and measured slower than MLX; the numbers are above. That is
itself the answer to "is MLX the blocker?": at this batch size MLX's kernels are not the problem —
the dependency structure and per-pass bandwidth efficiency are.

Until then the Swift runtime is **not** the default backend: at 25–28 tok/s it is slower than the
rapid-mlx path the product uses (48.2 tok/s), so `strimd` still serves rapid-mlx.

## Second session (2026-10-25): the compile lever measured, and it is small

The plan above assumed a whole-model compiled step would recover most of the dispatch gap. That was
tested directly, three ways, with new instruments (`strim benchbuild`, `strim benchcompile`,
`strim benchfuse`; details and the revised plan in `docs/SWIFT-NEXT.md`):

| Measurement | Result |
|---|---|
| Graph-construction time of one cached pass | **2.63 ms** of 37.72 ms (7%) |
| Whole 64-layer pass, eager vs `compile` | 36.33 → **33.23 ms** (−3.1 ms, −9%), bit-identical |
| 64-layer MLP stack, eager vs `compile` | 19.12 → 18.48 ms (−3%), bit-identical |
| S=1 vs S=2 pass (same kernel count) | 39.6 → 52.6 ms (+13.0 ms) |

`compile` caches the traced graph and does not fuse or accelerate kernels, so 2.6–3.1 ms is its
ceiling here; the +13.0 ms at identical kernel count confirms the pass is not dispatch-bound. A
compiled step would also break exact speculative rollback, because the GDN per-token state stack is
built by Swift-side appends during graph construction.

The pass is close to the sum of its quantized GEMVs (~12.6 GB at 334 GB/s), so there is little hidden
overhead left. The narrow GDN projections are the slowest ops (~225–242 GB/s vs 487–597 for the MLP's
17408-row GEMVs), but **fusing the four GDN projections into one qmv** — 1.73× faster in isolation
(425 vs 246 GB/s, bit-identical) — is worth only ~0.5 ms inside a pass (37.2 vs 37.7 ms, interleaved),
because the four independent calls already overlap. Not worth +2 GB of resident weights.

Consequence for the target: rapid-mlx's 48.2 tok/s is with MTP on, i.e. ~24.4 ms per *emitted* token,
which at 1.5–1.9 tokens/pass is roughly 36–46 ms per *pass* — our S=1 pass is already at parity. The
deficit is the verify path (S=3: 47.1 ms for the same bytes as a 35.4 ms S=1 pass) plus ~6.4 ms/pass of
MTP head work at depth 2. That, not the compiled step, is where the next run should go.

## Competitor baseline re-measured (2026-10-25, same session)

The 40.9 tok/s quoted throughout these notes was **stale**. Re-measured with the product's own stack
(mlx-vlm + the MTP draft head):

Historical: `bench/speed.py` was removed 2026-10-27 (Swift-only repo; no Swift port yet). Command as run:

```sh
# .venv-sprint/bin/python bench/speed.py --model models/qwen38-4bit \
#     --draft models/qwen38-mtp-4bit --kind mtp --context 128 --gen 256 --runs 2 --warmup 1
```

`decode_tps_median` = **48.2 tok/s** (runs 47.4, 48.9; 20.7 ms per output token), prefill 73.7 tok/s,
peak 17.12 GB. Two runs agree within 3%, so this is not thermal noise.

That makes the Swift engine **0.74×** rapid-mlx (35.6 vs 48.2), not the 0.87× the old number implied,
and it means the "45–50 tok/s" target is not an arbitrary stretch goal — it is roughly *parity with the
product backend*. Everything else in these notes that compares against 40.9 should be read as
comparing against 48.2.

## Like-for-like against the product backend (2026-10-25)

mlx-vlm on a code prompt: 43.0 tok/s, 2.86 tok/pass, 67.6 ms/round, 93.2% of drafts accepted.
This engine on the identical prompt, depth 2, fused recurrence: **52.1 tok/s**, 2.71 tok/pass, 52.0
ms/pass, 85% accept, `EXACT` (79-token parity). Our pass is 23% faster; rapid-mlx's higher acceptance is
what kept it ahead on prose (48.2 vs 34.4), where our drafter accepts only 46%.

Reproduce the competitor's own numbers:

    .venv-sprint/bin/python -m mlx_vlm generate --model models/qwen38-4bit \
        --prompt "Write a Python function that parses a CSV file and returns rows as dicts." \
        --max-tokens 64 --temperature 0 --verbose \
        --draft-model models/qwen38-mtp-4bit --draft-kind mtp

## MLX fork (2026-10-29)

The dependency is pinned to `megasoft1978/mlx-swift` tag `0.32.3-strim.1`
(`d881bd9`), based on upstream 0.32.3. Its MLX submodule pins
`575068a4fa263b16ac08921751e8a5257f3e80b9`, which raises the `qmv_wide`
tile cap from 5 to 8 on architecture generation >=17 with size != 'd'.
Other device paths, dispatch thresholds and Metal arithmetic are unchanged.
The S4 experiment measured +10.30% aggregate decode throughput at c=8 on
M5 Max with identical greedy outputs; c=1 was within measured noise.
See `bench/results/speed-s4-20261029/` for the patch and measurement scope,
and `bench/results/speed-s4-int-20261029/` for integration validation.
Other devices covered by the predicate remain unmeasured. Rollback: restore
`.package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3")`
and regenerate `Package.resolved` with `swift package resolve`.

