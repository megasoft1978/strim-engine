# Swift engine — next implementation step (handoff)

> **Verdict after six measured approaches (2026-10-25, second session): the 45–50 tok/s target is not
> reachable from the Swift/MLX-op level.** The depth-2 pass went 68 → 54 ms (26.5 → 35.6 tok/s) with
> one real change (the matmul recurrence); five other levers — compile, GDN projection fusion, fused
> reductions, lookup drafting, a batched hand GEMV — were each measured and rejected, with numbers
> below. Reaching 45 tok/s needs a kernel competitive with MLX's vectorised batched dequant, which has
> now lost four times. Read *What not to retry* before proposing anything, and note that sub-millisecond
> microbenchmarks on this machine vary by 2× — use whole-pass instruments only.

Status: the decode engine is correct and measured at **37–39 ms** per 64-layer pass (S=1, release,
idle) — 26 tok/s, against rapid-mlx's 48.2 tok/s. This note was rewritten on 2026-10-25 (second
session) after the previous plan's premise — "a whole-model compiled step recovers most of the gap" —
was measured and failed. Everything below is reproducible with commands in *Instruments*.

## The compiled-step plan is dead (measured)

MLX's `compile` caches a traced graph; it does not make kernels faster or fuse them. So its ceiling
is the *graph-construction* time of the pass, not the "960 dispatches" hypothesis. Measured:

| Test | Command | Result |
|---|---|---|
| Graph build vs GPU, cached pass | `strim benchbuild` | build **2.63 ms**, full **37.72 ms**, GPU 35.08 ms (7% build) |
| Whole 64-layer pass, eager vs one compiled fn | `strim benchcompile 8 model` | 36.33 → **33.23 ms** (−3.1 ms, −9%), bit-identical |
| 64-layer MLP stack, eager vs compiled | `strim benchcompile` | 19.12 → 18.48 ms (−3%), bit-identical |
| Same kernel count, 2 tokens (S=1 vs S=2) | `strim benchpassS` | 39.6 → 52.6 ms: **+13.0 ms for the same kernel count** |

Three independent measurements agree: at most ~3 ms of a 38 ms pass is construction/dispatch that a
compiled graph can remove. The 13 ms needed to reach 30 ms is GPU work, and compile does not touch
it. S=2 costing +13.0 ms with an identical kernel count rules out the dispatch-bound reading directly.

Do not land it. It would buy ~3 ms (~28.5 tok/s) and it **breaks exact speculative rollback**: the GDN
per-token state stack is built by Swift-side `history.append` during graph *construction*, so under
`compile` it would record tracers once instead of per token.

## Where the pass time actually goes

Per-op quantized GEMV throughput (`strim benchqmm`, idle):

| op | bytes | GB/s |
|---|---:|---:|
| GDN `qkv` (N=10240) | 26.2 MB | 242 |
| GDN `z` (N=6144) | 15.7 MB | 225 |
| GDN `out_proj` (N=5120) | 15.7 MB | 221 |
| GDN `b`/`a` (N=48) | 0.1 MB | 19 (pure latency) |
| MLP `gate_proj` (N=17408) | 44.6 MB | 487 |
| MLP `down_proj` (N=17408) | 44.6 MB | 597 |
| `lm_head` | 389 MB | 328 |

**Do not build on this table.** Sub-millisecond kernels measured in separate processes vary by up to
2×: the same binary and shapes gave `gate_proj` M=1 = 415 vs 536 GB/s and `qkv` M=3 = 241 vs 113 GB/s
across two idle-separated runs.

**Fixed for kernel work:** variants must be measured *interleaved inside one process*, min-of-8 each,
so thermal drift hits both equally — `benchgvS` now does exactly that and repeats to ~2–5%
(`gate_proj` M=3: 484 vs 479 GB/s across two runs). Whole-pass instruments (`benchsplitS`, `benchpass`,
`benchspec`) were always stable to ~5%.

With the fixed harness the kernel baseline is trustworthy and brutal: `QGEMV.multi` is **0.17–0.26×**
MLX at M=2–4 (89 vs 480 GB/s for `gate_proj` at M=3, the same 4–6× gap as before). Any replacement
kernel must clear **>480 GB/s at M=3** to be worth wiring in, and ~600 GB/s to close the verify gap.

The pass moves ~12.6 GB in 37.7 ms = **334 GB/s**, and it is very nearly the sum of these calls: there
is no large hidden overhead left to reclaim. The narrow GDN projections are the weak spot (~225 vs
~500–600 GB/s), but that inefficiency largely *disappears in situ*: fusing all four into one qmv is
1.73× faster in isolation (425 vs 246 GB/s, bit-identical output) yet worth only ~0.5 ms in the pass
(37.2 vs 37.7 ms, interleaved), because the four independent calls already overlap with each other and
with the conv. Not worth +2 GB of resident weights.

### Budget of a depth-2 speculative pass (measured, steady state)

`STRIM_TIMING=1 strim benchspec … 48 2 <natural prompt ids>` splits the loop's own budget:

| phase | ms/pass |
|---|---:|
| verify (S=3 target pass) | 47–49 |
| draft (1 head step + 1 `lm_head`) | 2.1 |
| reseed (2 head steps + 1 `lm_head`) | 4.3 |
| **total** | **~54 ms** for 1.92 tok/pass = **35.6 tok/s steady** |

The 28.9 tok/s that `benchspec` prints for a 48-token generation is lower because the 277-token prefill
(~0.3 s) is amortized into `ms/pass`. The "~18 ms of MTP head work" in the previous revision was that
amortization, not the head: the head costs **~6.4 ms/pass**, of which 2.4 ms is two 389 MB `lm_head`
calls. Compare like with like — rapid-mlx's 48.2 tok/s is a steady figure.

### S cost curve (`strim benchsplitS`, primed state)

| S | ms/pass | Δ |
|--:|--:|--:|
| 1 | 35.4 | — |
| 2 | 40.6 | +5.3 |
| 3 | 47.1 | +6.4 |
| 4 | 49.9 | +2.8 |

S=3 streams the same 12.6 GB as S=1 but costs +11.7 ms. Component split at S=3: **GDN +8.1 ms** (the
recurrence walks the 3 MB fp32 state per head ~8× per token), **MLP +2.8 ms** (M>1 `quantized_matmul`
runs at 114–253 GB/s vs 240–451 at M=1), attention ~flat.

Landed this session: the recurrence was rewritten with fused matmuls (the rank-1 state update and both
reductions are now single kernels) — **−1.7 ms at S=3, −1…−3 ms at S=1**, parity `EXACT` at depths 0
and 2. `STRIM_REC_ELEM=1` restores the elementwise formulation for A/B.

Two follow-ups that did **not** pay:

- **Fusing the two reductions over `r0`** (one `matmul` against `[k|q]`, and `y = <r0,q> + delta·<k,q>`
  so `r1` is never read back): mathematically identical, ~33% less state traffic, measured **neutral**
  (47.6 vs 47.1 ms at S=3). Reverted. So the remaining GDN cost is not state traffic.
- **Hoisting the per-call constants** (`rep` gather index, unit RMS-norm weight) out of the per-token
  path: removes ~96 host→device uploads per pass, but again neutral in time. Kept — it is strictly less
  work, just not measurable.

That leaves the residual S=3 GDN cost (~7.3 ms) in the batched projections and the per-token small-op
chain, not in the recurrence's memory traffic.

- **Suffix-lookup ("prompt-lookup") drafting** — the cheap way to raise tokens/pass without touching
  the pass. Measured with `bench/lookup_stats.py` on 256-token generations: on prose, coverage 44%
  (k=1) with 11% depth-1 acceptance, 3% coverage (k=3) with 25% — at most **1.25 tok/pass**. On
  code (a TS/React prompt), 63%/k=1 with 35% acceptance and 30%/k=2 with 43% — at most **1.80
  tok/pass**. Both are below the MTP head's 1.92 on the natural prompt, and these are upper bounds
  (the match table is fed by the generation itself). Not implemented; at best it is a strength-gated
  substitute for the first draft, never a replacement.

## Revised plan (ordered by measured upside)

Target: a ~46 ms depth-2 pass for 45 tok/s. That is 8 ms out of the current ~54 ms.

1. **GDN per-token cost (~8 ms at S=3, ~2–3 ms at S=1).** The recurrence's traffic is the state, not
   the weights. Next: cut the remaining per-token passes over the 3 MB state (algebraic fusion of
   `decay` into the `kv` reduction; a single kernel for `y = r0·q + delta·(k·q)`), and trim the
   per-token small-op chain (4 conv taps, 2 `rmsNorm`s on `[1,1,16,128]`, gather/replication) that
   costs ~4 ms/pass at S=1. `benchsplitS` attributes every change.
2. ~~**M>1 `quantized_matmul`**~~ — **not measurable, and the hand kernel lost** (both below). The
   per-op instruments vary by up to 2× run to run, so the size of any M>1 penalty is unresolved; do
   not attribute the verify gap to it. The only trustworthy attribution is the pass-level split:
   GDN +8.1 ms, MLP +2.8 ms at S=3.
3. **MTP head (~6.4 ms).** Mostly inherent: two `lm_head` calls (2.4 ms) and three head steps. Batching
   the reseed replay with the seed step saves one head step (~0.3 ms). Low ceiling — do last.
4. **Do not** build the compiled step, and **do not** fuse the GDN projections (both measured, above).

## Risks

- Any change to the verify path must keep `strim benchspec … 0 <prompt>` at `EXACT` and match
  `bench/ref_greedy.py 16`; depth 0 is the cheap exactness gate (one token per pass, no rollback).
- The machine throttles hard and this dominates careless measurement: the same depth-0 pass measured
  **44.2 ms and 67.1 ms in the same hour** depending on how many 16 GB loads preceded it. Take numbers
  only after a long idle, prefer min-of-N within one process, and treat cross-process A/Bs run in
  blocks as unreliable — one such round read a neutral change as −3 ms.
- `history` memory at S=3 is ~450 MB per pass of pure float32 state; that is both a time and a
  footprint risk at longer contexts.

## Instruments (all in `strim`, release build)

```sh
swift build -c release --disable-sandbox
strim benchpass  models/qwen38-4bit 15        # pass ms; per-layer-type split (unreliable)
strim benchpassS  models/qwen38-4bit 10       # S=1..4, growing KV (end-to-end curve)
strim benchsplitS models/qwen38-4bit 8 3      # S=3 pass decomposed: full / no-gdn / no-attn / no-mlp
strim benchqmmS   models/qwen38-4bit 12       # quantizedMatmul at M=1..4, and 3xM1 for comparison
strim benchbuild models/qwen38-4bit 12        # graph build vs GPU: the compile ceiling
strim benchcompile models/qwen38-4bit 8 model # eager vs compiled whole pass, A/B
strim benchfuse  models/qwen38-4bit 40        # 4 split qmv vs 1 fused, isolated
strim benchqmm   models/qwen38-4bit           # per-op GB/s by shape
scripts/bench_swift.sh                        # the SWIFT-PERF table (needs an idle machine)
STRIM_TIMING=1 strim benchspec … 48 2 <ids>   # per-pass draft / verify / reseed split
STRIM_REC_ELEM=1 …                            # old elementwise recurrence, for A/B
strim benchmtp      models/qwen38-4bit models/qwen38-mtp-4bit 48 2 <ids> [reps]
                                              # draft-chain A/B (host sync vs GPU ids)
strim benchpathspec models/qwen38-4bit models/qwen38-mtp-4bit 48 2 <ids> [reps]
                                              # tensor vs kernel loop A/B, one process
strim benchpathS    models/qwen38-4bit 8 4    # tensor vs kernel pass at S=1..4
STRIM_MTP_HOST=1 …                            # per-draft `.item()` chain, for A/B
STRIM_GDN_TENSOR=1 …                          # reference-TF32 recurrence (exact path)
strim checkconv models/qwen38-4bit 4          # conv+silu kernel vs depthwise+silence, per stage
strim benchprefill models/qwen38-4bit 4096    # cold-cache Swift prefill, tok/s
strim benchqmmM models/qwen38-4bit 1024       # large-M qmm, 2D vs 3D, GF/s
bench/test_priority.py                         # admission-policy checks
bench/test_priority_ordering.py                # slot-before-upstream-send regression
```

## What not to retry

- **Batched dequant-GEMV (`QGEMV.multi`, M=2..4).** Extending the M=1 row-per-threadgroup kernel to
  carry four accumulators (one threadgroup per weight row, weight streamed once, `simd_shuffle_xor`
  reduction) is **4–6× slower than MLX**: 64–128 GB/s vs 159–596 at M=2..4, on all four hot shapes,
  with the *same* arithmetic (max diff ≤0.008, i.e. bf16 noise). The scalar per-nibble dequant and the
  single 32-lane threadgroup per row cannot compete with MLX's vectorised path. Beating MLX here needs
  a different kernel design (4-wide dequant, multiple simdgroups per row, shared-memory staging), not
  a modest extension — treat that as its own project. `strim benchgvS` reproduces the comparison.
- **Whole-model compiled step** — 3.1 ms of 38, measured three ways; also breaks exact rollback.
- **Fusing the four GDN projections** — 1.73× isolated, ~1% in-pass (37.2 vs 37.7 ms), +2 GB resident.
- Standalone 4-bit GEMV (`QGEMV.swift`): 150–390 GB/s vs MLX 221–784.
- Fused GDN recurrence (`GDNMetal.swift`): correct, but 50 ms/pass vs 38 — per-row work too small.
- Per-op `mx.compile` of the GDN step: neutral.

## Closed shortcut: no faster MLX path for M=3 (2026-10-25)

Before writing Metal, the MLX Swift API was checked for a cheaper route to the M=2–4 throughput:

- `quantizedMatmul` exposes only `transpose`, `groupSize`, `bits` and `mode: .affine | .mxfp4`. Our
  weights are affine 4-bit, so `.mxfp4` does not apply and there is no tiling/split-K knob to turn.
- `gatherQuantizedMatmul` (`Ops.swift:1496`) gathers *rows* of the weight matrix by index (the
  MoE/expert path); it does not batch several token rows through one dense matmul.

So the 480 GB/s at M=3 is what MLX gives us, and closing the gap requires a Metal kernel. Baseline to
beat (repeatable to 2–5% with the interleaved `benchgvS`): `gate_proj` 484 GB/s, `down_proj` 471,
`qkv` 433, `z` 383 at M=3.

## Kernel design brief (next session starts here)

**Diagnosis.** `QGEMV.multi` runs at 86–91 GB/s on every hot shape — `z` (K=5120, N=6144) 86,
`down` (K=17408, N=5120) 89, `qkv` (K=5120, N=10240) 90, `gate` (K=5120, N=17408) 91. Throughput is
flat in both K and N, so it is **not** bandwidth-starved and not grid-starved: it is ALU-bound on the
scalar dequant loop (`float((word >> (4*i)) & 0xF) * sc + bs` per nibble, 8 per uint32, with float
conversion each). MLX reaches 480 GB/s at M=3 with the same bytes, i.e. ~5× less ALU per byte.

**Requirements for a replacement** (judged by `benchgvS`, interleaved min-of-8, 2–5% repeatable):

1. **Vectorised dequant.** Unpack nibbles with packed integer ops and accumulate in `half`/`float2`
   vectors rather than per-nibble `float` conversion; the arithmetic is the bottleneck, not the loads.
   A 16-entry float LUT indexed by the nibble, applied to `float4` lanes, is the cheap first attempt;
   bit-sliced unpacking of a `uint4` into 32 values is the target.
2. **More than one simdgroup per row** (the current kernel is one 32-lane threadgroup per row) so a
   row's work can span the SM without a serial dependency on a small lane count.
3. **Keep four accumulators** (M=2..4) — that part is sound; a weight row is read once and 2–4 dot
   products fall out of it. The batched structure is not what lost; the dequant is.
4. **Shape-specialise K** where it helps: K is 5120 or 17408, both multiples of 64, so group
   boundaries align with `uint4` spans (32 values) and need no per-value group lookup.
5. Must be bit-comparable to `quantizedMatmul` (currently `d ≤ 0.008`, bf16 noise) and clear
   **>480 GB/s at M=3 on all four shapes** before being wired into `GDN.forward`/`MLP.forward`.

**Do not** re-attempt: one-threadgroup-per-row with scalar dequant (89 GB/s), or an M=1-only kernel
(MLX is 221–784 GB/s there; only the M≥2 path is weak).
**Occupancy tested and excluded (round 12).** Four simdgroups per threadgroup, one row each, to check
whether the 89 GB/s ceiling was one-32-lane-threadgroup occupancy rather than ALU: the ratio to MLX was
unchanged (0.17-0.23x vs 0.17-0.26x), so the structural change is neutral. Reverted. The ceiling is the
scalar dequant, not threadgroup count — a replacement kernel must make the nibble unpack cheaper, not
merely wider.

## Ceiling of the batched-GEMV project: ~39 tok/s, not 48 (2026-10-25)

Worth knowing before more kernel work is funded. Pass-level attribution at S=3 (the trustworthy
instrument) is GDN **+8.1 ms** and MLP **+2.8 ms** over S=1. A perfect M=2..4 quantized GEMV removes
the *projection* part of that, i.e. essentially all of MLP's 2.8 and perhaps ~2 ms of GDN's 8.1 — call
it **~5 ms**, generously.

- depth-2 pass now: ~54 ms (verify 46–48 + head 6.4) → 35.6 tok/s
- with a perfect batched GEMV (~5 ms off the non-recurrent part): ~49 ms → **~39 tok/s**
- with both that *and* the recurrence halved (~4.7 ms): ~44 ms → **~43 tok/s**
- target (parity with rapid-mlx at 48.2): needs ~43 ms, i.e. both kernels landing *and* little slack

So the kernel under construction cannot reach the objective on its own. The residual is GDN's
**per-token chain** (the recurrence plus the conv/norm/gather small ops), which is a *fused GDN layer*
kernel — precisely the thing `GDNMetal.swift` already lost at (50 vs 38 ms/pass), twice counting the
session that wrote it.

Consequences for the plan:

1. The batched-GEMV bar (>480 GB/s at M=3) is still worth clearing — it is ~5 ms, the largest single
   item still in reach, and it is measurable.
2. But the objective needs a second, harder kernel, or higher draft acceptance (the only lever that
   does not touch pass time; measured ceiling for lookup drafting was 1.80 tok/pass vs the head's 1.92,
   so it needs a better drafter, not a lookup table).
3. Beware the earlier arithmetic that made the M>1 penalty look like 13-15 ms: that came from a hot-run
   S=1→S=2 comparison, while MLX's own M=1 vs M=3 rate differs by only ~12% (536 vs 480 GB/s). The
   verify penalty is dominated by GDN, not by qmm.

## Drafter wiring checked against the reference (2026-10-25)

Hypothesis: the 46% depth-2 acceptance might be a wiring bug — `MTP.step` applies
`pre_fc_norm_hidden` to a value that `MTP.normalized` already normalised, i.e. a doubled norm.

Checked against the installed reference,
`.venv-sprint/.../mlx_vlm/speculative/drafters/qwen3_5_mtp/qwen3_5_mtp.py`:
`_forward_hidden` applies `pre_fc_norm_embedding`/`pre_fc_norm_hidden` to its inputs and **returns
`self.norm(h)`**, and the caller chains that returned (normed) value back in as `hidden`. So the
double norm is the reference behaviour, and our wiring matches it. **Not a bug — do not "fix" it.**

Consequence: acceptance has to come from the head's own quality or from the seed/replay stream, not
from a cheap norm correction. Combined with the measured lookup ceiling (1.80 vs 1.92 tok/pass), the
drafter project needs a better head, which is outside this repo (no training path here).

## GDN recurrence share, measured directly (2026-10-25)

`STRIM_SKIP_REC=1` skips only `recurrenceRecFn` inside `GDN.forward`, passing `qr` through in place of
`yAll` so norm/gate/`out_proj` still run at the same shapes. The pass difference is the recurrent work.

| S | full | recurrence skipped | recurrence share |
|--:|--:|--:|--:|
| 1 | 36.84 (min) | 31.01 (min) | **~5.8 ms** |

That is much larger than the 2–3 ms inferred from throughput, and it is 16% of the whole S=1 pass — so
the recurrence, not the projections, is the dominant GDN cost. This is the strongest argument yet for
the fused-GDN-layer kernel: halving it saves ~3 ms at S=1 and more at S=3.

S=3, measured properly (180 s idle, then normal/skip alternated so drift hits both):

| S | full | recurrence skipped | recurrence share |
|--:|--:|--:|--:|
| 3 | 46.02 / 44.81 (min) | 36.24 / 36.46 (min) | **~8.5–9.8 ms** |

So the recurrence is **~9.5 ms of a 46 ms verify pass (20%)** and ~5.8 ms of the S=1 pass. The
non-recurrent part grows 31.0 → 37.4 ms from S=1 to S=3, i.e. the projections/qmm/conv add ~6.4 ms.

## Why the fused recurrence lost: threadgroup count, not arithmetic (2026-10-25, inspection)

Read `GDNMetal.swift` against the measured 9.5 ms recurrence share. Its arithmetic is sound — the state
row lives in registers, the token loop is inside the kernel, traffic per layer drops from ~24 MB/token
to ~6 MB plus the stack. The launch shape is the problem: `grid: (Hv * Dv * 32)` with a 32-lane
threadgroup = **6144 threadgroups per layer, ~295k per pass**, each doing only ~90 cycles of work
(2 × 16 FMA + 2 `simd_sum` per token). At ~50 ns of launch overhead per threadgroup that alone is
~15 ms/pass, which is the right order for its measured 50 vs 38 ms.

**Retry design:** eight simdgroups per threadgroup, one state row each — 768 threadgroups per layer
instead of 6144 — keeping the register-resident row and the in-kernel token loop unchanged. This is the
same fattening that was neutral for `QGEMV.multi`, but there the kernel was ALU-bound (89 GB/s flat
across K and N); here it is launch-bound, so the two cases do not generalise to each other.

Not implemented this session: the timing harness needs the real projection path (rmsNorm on q/k,
head replication to 48, g/beta) rather than a shortcut, and the first attempt at a shortcut helper was
wrong in shape. A retry should either wire `GDNMetal` into `GDN.forward` behind a flag (the honest
end-to-end test, which also exercises the rollback stack) or rebuild `checkmetal` into a timing
command with correct projections.

## Two external reviews (gpt-6-astra via `codex exec`, Opus 5.5 via `claude`), 2026-10-25

Both were asked for kernel design advice. They converged, and they **overturn two of this session's
conclusions**. Recorded verbatim in substance:

**Wrong conclusion 1 — "launch overhead" (6144 threadgroups/layer).** One dispatch contains all 6144;
it is not 6144 launches. Astra: "you have a plausible threadgroup scheduling/occupancy problem, not
demonstrated CPU launch overhead." Opus: per-layer cost (120 µs at S=1) matches ~10 state-sized memory
passes, not launches; v1 at 0.37 ms/layer is ~10× slower than even the unfused graph's traffic, so it
is a layout/coalescing or threadgroup-shape fault.

**Wrong conclusion 2 — "flat GB/s proves ALU saturation."** Equally consistent with narrow loads /
insufficient memory-level parallelism: Little's law at 536 GB/s × ~500 ns needs ~270 KB in flight.
Opus: "flat 86–91 GB/s fits a constant cost per byte (instruction issue or load count), not saturated
ALU." Neither reviewer accepts the dequant-ALU diagnosis as established.

**The dequant fix, if it is pursued at all.** MLX's affine `qmv_wide` (per Astra) uses 8 K-lanes per
row, 2 SIMD groups, 8 output rows per threadgroup, and factors scale/bias out of the inner loop:
`dot = Σ (w & mask_k) · x_k/16^k`, then `acc += scale·dot + bias·Σx`, nibbles **unshifted** and
activations prescaled by 1/16^k. Opus independently: use `uint4` loads with ≥4 in flight, 2 simdgroups
× 4 rows, lanes striding along K, one float conversion of the nibbles shared by all M accumulators.
Both rank this **last**: MLX already does 480 vs 536 GB/s at M=3, so the whole prize is ~2.7 ms.

**Priority order (Opus, unchallenged by Astra):**
1. Check GPU idle/sync between phases — verify is 46 ms inside a 54 ms pass, and if graph build/sampling
   readback is not overlapped that is 2–4 ms of pure idle. Cheap.
2. Fused recurrence **v2**: 128–256 thread threadgroups, one simdgroup per value row (768–1536
   threadgroups/layer instead of 6144), load q/k/v/g/β for all T tokens into threadgroup memory once,
   coalesce on Dk (or map lanes across Dv so no `simd_sum` is needed), write S₁,S₂ to scratch and S₃ in
   place. Opus's floor argument: 150 MB of state does not fit cache, one read + one write is ~0.6 ms;
   with the stack ~1.5 ms at S=3. Expect **9.5 → 2–3 ms**, i.e. −6…−7 ms.
   Also warn: `fast.metalKernel` forces contiguous inputs and blocks `compile` fusion around it, which
   may add copy/elementwise kernels — check before blaming the kernel body.
3. T-step triangular-solve reformulation only if v2 stalls; inside a fused kernel the unrolled 3-token
   loop costs nothing, so the WY form buys nothing there.
4. **Drop the batched GEMV** as an independent project (both reviewers).

**Arithmetic correction to the ceiling.** A free recurrence gives ~44.5 ms, not 43 — it cannot reach the
goal alone. And the 9.2 ms S=1→S=3 increment is NOT 40% recurrence: ~2.7 ms is MLX qmv at M=3 and
~2.8 ms is unattributed (attention, `lm_head`, norms scaling with S). Break that down before calling
the recurrence "the" cost. Removal ablations also remove barriers, so `STRIM_SKIP_REC` measures marginal
cost, not isolated cost — fine as a ceiling, not for per-kernel tuning.

## Fused recurrence v2: fast, but numerically wrong (2026-10-25)

Wired `GDNMetal` into `GDN.forward` behind `STRIM_GDN_METAL=1` (the honest end-to-end test, including
the rollback stack) with 8 simdgroups per threadgroup — 768 threadgroups/layer instead of 6144.

**Speed: real and large.**

| S | tensor recurrence | fused v2 | delta |
|--:|--:|--:|--:|
| 1 | 36.72 / 36.7 ms | 34.52 ms | −2.2 |
| 3 | 46.97 / 46.27 ms | 39.71 / 39.54 ms | **−6.7 … −7.4** |

Depth-2 loop timing with v2: verify 41.4 ms, pass 49.0 ms (was verify ~48, pass ~54). This matches
Opus's prediction (9.5 → 2–3 ms) almost exactly, so the threadgroup fattening was the right fix for v1.

**Correctness: fails the gate.** `strim gen 16` with the kernel produces
`[9707, 1234, 5678, 198, 26076, …]` against the reference's `[…, 198, 2, 220, …]` — divergence at the
first generated token after the prompt, and `benchspec … 0` reports MISMATCH. Changing the `y` output
from bf16 to float32 (to match the tensor path, which keeps f32) did not fix it, so this is not a
precision difference but a computation difference. Suspects, in order: the lane mapping of `Dk`
(each lane owns 4 contiguous values, `simd_sum` across 32) versus MLX's reduction order is only ~1e-6
and should not flip a token at step 1; more likely `delta`/`beta` or the `v`/`g` indexing is off by a
head or a token, or `simd_sum` is being applied to a lane set that is not the full 32.

**State:** default path (no env var) is unchanged and remains exact; the kernel is flag-gated and does
not affect `strimd` or the benchmark numbers above unless `STRIM_GDN_METAL=1`. Left in the tree because
the speed is real and the bug is now a bounded debugging task, not a design question.

### Bisect result: the kernel body is wrong, not the wiring

`strim checkmetal` compares `GDNMetal.run` against `GDN.recurrenceNoState` on identical random inputs,
so it separates kernel from plumbing. It fails badly, and the error grows with S:

| S | y max | ssm max |
|--:|--:|--:|
| 1 | 188.0 | 27.9 |
| 2 | 1004.0 | 263.0 |
| 3 | 5984.0 | 4442.1 |

**Conclusion:** my wiring in `GDN.forward` is not the problem — the kernel itself is wrong under the
8-simdgroup launch. That also means the `y` bf16→f32 change was beside the point (reverted suspicion,
not the cause).

The ~S² growth points at state handling inside the kernel rather than the token math: a per-row state
read/write that collides between simdgroups, or a value carried across the token loop that should be
reset. First thing to instrument: run `checkmetal` at S=1 only and compare `ssmOut` element-wise against
`ref.1` to see *which* rows are wrong (all rows → indexing; a subset → simdgroup/row mapping). Note v1
(one row per threadgroup) was documented as numerically matching, so the regression is in the fattening,
most likely `row = tg*8 + sg` versus how `thread_position_in_threadgroup` maps to simdgroups on this
GPU, or the `row >= nRows` early return interacting with `simd_sum` in partially-filled threadgroups.

## Correction: the 2025 "fused recurrence is slower" verdict was wrong

Re-measured end-to-end with the kernel wired into `GDN.forward` (`STRIM_GDN_METAL=1`), the *original*
`GDNMetal` (one row per threadgroup, 6144 threadgroups/layer — the design the earlier session rejected
at "50 ms/pass vs 38") is actually **faster**, not slower:

| S=3 pass | ms |
|---|---:|
| tensor recurrence | 45.69 (min 44.60) |
| fused v1 kernel | **40.90** (min 39.07) |

So the prior rejection was a measurement artefact, and the kernel's launch shape was fine all along.
That also means my "threadgroup fattening" work in this session was unnecessary — and it actively
broke correctness (max diff 188/1004/5984 at S=1/2/3, growing ~S²). Restoring the original file brings
numerics back to max 0.008 at S=1, i.e. bf16 noise. **v2 fattening is a dead end; delete it.**

**Remaining blocker:** exactness over a long generation. With v1 wired in, `strim gen 16` matches the
reference for 15 tokens and then flips one near-tie (`…95971, 198, 2` vs `…95971, 9616, 96012`), and
the flip is the same with `y` in bf16 or f32. So it is the reduction order: the kernel sums `Dk` with
`simd_sum` over 32 lanes × 4 values, MLX sums with `.sum(-1)`. Both are fp32, but the difference
(~1e-6) accumulates until a near-tie flips. The tensor path survives 107 tokens on the natural prompt;
the kernel survives 15 here.

Options, in order of preference:

(a) Match MLX's `Dk` reduction order. Unknown without reading MLX's Metal source for the exact op used
by the tensor path (`matmul` in the MM recurrence, not `.sum(-1)` — that matters, and should be checked
before assuming).
(b) Serial-sum `Dk` in one lane with the state in threadgroup memory. Deterministic and easy to reason
about, but gives up the register-resident state that makes the kernel fast — measure before committing.
(c) ~~Compute the reduction in double.~~ **Withdrawn:** Apple-silicon Metal generally has no fp64, so
this is probably not available. Not verified here — a standalone `xcrun metal` probe was blocked by the
sandbox (the compiler's module cache lives outside the workspace), so treat the fp64 claim as expected
rather than proven. Verify with a one-line shader under a non-sandboxed compiler before designing
around it.
(d) Accept a documented near-tie risk and use the kernel only where the gate tolerates it — not
acceptable for the product path.

**Speed accounting if (a) lands:** ~5 ms off the S=3 verify pass, on top of the harness's existing
numbers — the largest single win found in this session, and it needs no new kernel design, only a
reduction-order fix in a kernel that already exists.

## Exactness solved: the kernel is now bit-identical (2026-10-25)

Two external reviews named the two causes, and both were real:

1. **Reduction order.** Astra: MLX's gemv reduces with explicit `simd_shuffle_down` at offsets
   16, 8, 4, 2, 1 (`BM=4, BN=1, SM=1, SN=32, TM=4, TN=4`). `simd_sum` is a different association order.
   Replaced with that tree, plus `simd_broadcast(kv, 0)` because a shuffle-down tree leaves the total
   only in lane 0 while the state update needs it in every lane.
2. **FMA contraction.** Opus: the MLX path rounds between separate ops, while a fused kernel contracts
   them. Added `#pragma clang fp contract(off)` to the kernel, and restored the `y` bf16 cast so the
   dtype matches what `GDN` does (`y.asType(v.dtype)`).

Result: **exact**.

- `strim gen 16` (degenerate prompt, the strictest external check) matches the Python reference token
  for token: `[9707, 1234, 5678, 198, 2, 220, 17, 15, 17, 18, 95859, 16, 17, 96212, 17, 17, 95971,
  9616, 96012]`.
- `benchspec … 32 0` → EXACT (35 tokens); `benchspec … 48 2` → EXACT (107 tokens).

Speed, with exactness on:

| | ms/pass | tok/s |
|---|---:|---:|
| depth 2 before | 67.7 | 28.4 |
| depth 2 after | **57.0** | **33.7** |
| depth 0 after | 38.0 | 26.3 |

Now the **default** (`STRIM_GDN_TENSOR=1` reverts to the MLX-op recurrence). Both reviewers agreed on the
gating policy: ship behind a flag with a committed test rather than prose — the test is `gen 16` against
`bench/ref_greedy.py` plus `benchspec … 0`, both of which now pass.

**Outstanding, per the reviews:** decompose the competitor (48.2 tok/s is 39.8 ms/pass only if they also
get 1.92 tok/pass — their tokens/pass is unmeasured), sweep depth 0–3 on the new economics, and drop the
redundant state writes (last stack slice as final state; no stack for greedy) for ~0.5 ms.

## Depth sweep with the fused kernel: depth 2 still wins (2026-10-25)

Both reviewers said to re-sweep depth on the new economics (Opus estimated depth 3 ≈ 2.2 tok/pass at
~+3 ms ≈ 36 tok/s). Measured on the natural prompt, 48 tokens, idle-separated:

| depth | ms/pass | tok/pass | accept | tok/s |
|--:|--:|--:|--:|--:|
| 0 | 39.7 | 1.00 | — | 25.2 |
| 1 | 47.9 | 1.55 | 55% | 32.3 |
| **2** | **55.8** | **1.92** | 46% | **34.4** |
| 3 | 63.8 | 2.09 | 36% | 32.7 |

Depth 2 remains the optimum. The estimate assumed acceptance would hold at depth 3; it drops to 36%,
so the extra pass time (+8 ms) is not repaid (+0.17 tok/pass). No default change.

## The competitor's own stats, and a like-for-like comparison (2026-10-25)

Both reviewers said to measure the competitor's tokens/pass before optimising pass time. mlx-vlm's
`--verbose` reports it:

```
Speculative decoding: 2.86 accepted tokens/round (1.86 accepted drafts/round, 93.2% of drafted,
avg draft 2.00) over 22 rounds
Generation: 64 tokens, 43.008 tokens-per-sec
```

That is 64/22 = 2.86 tok/pass at 64/43.0 = 1.488 s / 22 = **67.6 ms per round** — i.e. rapid-mlx's pass
is *slower* than ours (55.8 ms). Its advantage is acceptance: 93.2% of drafts.

Same prompt, same model, same machine, ours at depth 2:

| | tok/pass | accept | ms/pass | tok/s |
|---|---:|---:|---:|---:|
| mlx-vlm + MTP | 2.86 | 93.2% | 67.6 | 43.0 |
| **this engine** | 2.71 | **85%** | **52.0** | **52.1** |

Ours is **1.21× faster end-to-end with `EXACT` parity** on that prompt. Note the shape of it: our pass is
23% quicker and our acceptance is close; the earlier "we are 0.72×" came entirely from the *prose*
prompt, where our acceptance collapses to 46% (34.4 tok/s) while the drafter's code-shaped acceptance
holds at 85%.

**Consequence for the objective:** comparing "our tok/s" to "their tok/s" on different prompts was never
valid. Per-pass we are now ahead; the remaining deficit is *draft acceptance on prose*, which is drafter
quality — the one lever both reviewers said is outside this repo (no training path). Also worth noting
this single 64-token run is one prompt, not a corpus; the honest claim is "faster on code-shaped
prompts, behind on prose", not "faster".

## The fused kernel is NOT exact in general: reverted to opt-in (2026-10-25)

Cross-prompt evidence, all at depth 2, 64 tokens, same model and machine:

| prompt | mlx-vlm tok/s | ours (kernel) tok/s | ours (tensor) tok/s | kernel parity |
|---|---:|---:|---:|---|
| code-csv | 44.2 (2.86/pass) | **52.5** (2.71) | — | EXACT |
| code-ts | 32.0 (2.37/pass) | **44.5** (2.37) | 37.0 | **MISMATCH** |
| prose | 38.9 (2.37/pass) | **42.0** (2.20) | — | EXACT |

On `code-ts` the attribution is unambiguous: fused kernel → MISMATCH, `STRIM_GDN_TENSOR=1` → EXACT
(121 tokens). So `simd_shuffle_down` + `contract(off)` + the bf16 cast fixed the *first* observed
divergence (the degenerate 16-token check now matches the Python reference) but not all of them; a
further ~1e-6 difference remains and flips a near-tie on this prompt.

**Action:** `useMetal` is back to opt-in (`STRIM_GDN_METAL=1`); the tensor recurrence is the default
again. That costs the 20% pass-time win (44.5 → 37.0 tok/s on `code-ts`) but restores `EXACT` on every
prompt tested, which is the stated gate. The kernel is kept because the speed is real and the remaining
drift is a bounded, now-documented bug — Opus's "localize by sub-step" advice is the next step: compare
`kv_mem`, `delta`, the state and `out` separately rather than whole tokens.

**Also established:** on the same prompts the Swift engine beats mlx-vlm on tok/s when the kernel is on
(52.5 vs 44.2, 44.5 vs 32.0, 42.0 vs 38.9). The earlier "0.72×" comparison was across different prompts
and was never valid.

## Sub-step localisation, first attempt: inconclusive (2026-10-25)

`checkmetal` now compares the kernel against **both** references — the elementwise recurrence and the
compiled matmul one the model actually uses — because the kernel was only ever validated against the
former.

Results on its *random, unnormalised* inputs:

- kernel vs elementwise: close (y max 0.002 at S=1, 8 at S=3).
- elementwise vs matmul: wildly apart (y max 0.5 / 4 / 64 at S=1/2/3).

That second number is alarming but **not yet evidence of a bug**: `checkmetal` feeds raw
`MLXRandom.normal` q/k, whereas the model always rmsNorms q/k and scales them by ~1/8. On
unnormalised inputs both recurrences are summing large-magnitude products, so absolute differences of
tens coexist with tiny relative error, and bf16 rounding of `y` differs. The model-level gate says the
matmul path matches the Python reference for 107 tokens, so the matmul path is very likely fine and the
harness is the thing that's too weak.

**Next attempt must use realistic tensors**: take the actual `qr`, `kr`, `v`, `g`, `beta`, `ssm` for one
GDN layer at one token from the failing `code-ts` prompt (after rmsNorm and head replication), dump them
from both paths, and compare `kv_mem`, `delta`, the state and `out` separately — Opus's sub-step method,
with inputs that match what the model sees.

## Retraction: the round-24 attribution was a single-sample error (2026-10-25)

Round 24 reverted the kernel to opt-in on this evidence: `code-ts` gave kernel MISMATCH but
`STRIM_GDN_TENSOR=1` EXACT, which looked like a kernel-specific residue.

Re-running the **default tensor path** on `code-csv` — a prompt where the *kernel* had been EXACT —
gives **MISMATCH** (depth 2, 45.7 tok/s). So the flip is not kernel-specific: depth-2 batched verify
is not bit-identical to per-token math in either path, exactly as this document said at the very start
("a near-tie can still flip. Observed once on a degenerate repetitive prompt"). Depth 0 — one token per
pass, no rollback — remains **EXACT** (35 tokens, 39.3 ms/pass) in the shipped configuration.

**Consequences:**

1. One sample per prompt cannot attribute a flip to a code path. Any comparison of flip *rates* needs a
   corpus (≥10 prompts × ≥64 tokens) run identically for both paths, and the metric must be "tokens
   identical to depth-0 greedy", not a single EXACT/MISMATCH.
2. Round 24's revert to tensor-default was therefore not justified by that evidence. It is still the
   conservative choice (the kernel has the larger measured drift on realistic tensors), but it should be
   re-decided on the corpus result, not on one prompt.
3. The kernel's real status is: **20% faster per pass (44.5 vs 37.0 tok/s at depth 2), with an unknown
   excess flip rate**. That is the open question, and it is measurable.

## Corpus result: the kernel is not the exactness problem (2026-10-25)

8 prompts (code, prose, SQL, math, lists, rust, JSON), depth 2, 64 tokens, both paths, one run each:

| prompt | tensor | kernel |
|---|---|---|
| csv-py | MISMATCH 46.1 tok/s | EXACT 53.6 |
| ts-hook | EXACT 37.4 | MISMATCH 46.1 |
| prose | MISMATCH 36.4 | EXACT 42.8 |
| sql | EXACT 39.3 | MISMATCH 43.8 |
| math | EXACT 47.3 | EXACT 55.5 |
| list | MISMATCH 37.4 | EXACT 45.2 |
| rust | EXACT 46.9 | EXACT 57.2 |
| json | MISMATCH 40.2 | MISMATCH 53.0 |
| **EXACT** | **4/8** | **5/8** |
| **mean tok/s** | **41.4** | **49.6** |

Conclusions:

1. **Flip rate is indistinguishable** (4/8 vs 5/8 at n=8) and the kernel is **20% faster**. The kernel
   is therefore the default again; round 24's revert was an artefact of one sample per prompt.
2. **Depth-2 speculative decode diverges from this engine's own greedy decode on about half of prompts**
   in bf16 — in *both* paths, including the shipped MLX-op one. The earlier claim in `SWIFT-PERF.md` of
   "107-token natural generations token-identical" does not generalise; it was one prompt. The cause is
   the documented one: a batched verify is not bit-identical to per-token math, so near-ties flip.
3. **Only depth 0 is EXACT** as a configuration (verified: 35 tokens, 39.3 ms/pass). The goal's parity
   gate (`benchspec … 0` EXACT) is satisfiable; the same gate at depth 2 is not, and never was.

This is a product-relevant finding independent of the kernel: the Swift engine's depth-2 output cannot be
claimed token-identical to greedy. `strimd` is unaffected (it serves rapid-mlx), but the Swift engine's
documented guarantee must be softened to "depth 0 exact; depth 2 diverges on near-ties at a rate to be
characterised".

Open: recovery would need one of (a) fp32 verify, (b) verifying in per-token order (slow), or (c)
accepting the drift with a measured rate — which is what the corpus now provides.

## Second optimization round: reviewer guidance and the per-row slope (2026-10-25)

**Measured, fused kernel default, natural prompt, idle:** S=1 40.27 ms, S=2 42.67 (+2.40), S=3 44.75
(+2.08), S=4 48.73 (+3.98) — a **~2.5 ms/row slope**, between the 1.5 and 4–5 branches both reviewers
posed. Rows are real cost but not dominant.

**The dominant number is the base pass: 40.27 ms for ~12.6 GB = 313 GB/s against a ~530 GB/s ceiling.**
Astra's arithmetic: at depth 2 with perfect acceptance the cap is 3 tok/pass, so 60 tok/s needs a 50 ms
pass and 50.8 tok/s needs 59 ms — i.e. the corpus mean is bounded by the base pass, not by drafting.
Opus puts the base pass at ~82% of a cycle (40.3 + 2.4 + 6.4).

**Opus's ranked changes:**

1. **Fused GDN surrounding-op kernel** (~5 ms, 40.3 → ~35 ms): recurrence plus conv, silu, l2norm, gate
   exp, beta sigmoid and the output `rmsnorm·silu(z)` in one or two kernels, with **column-wise summation
   order unchanged so the result is bit-identical** — which matters given the exactness history here.
   Breakdown: recurrence 4.6 → 1.1 ms (~3.5) plus ~1.5–2 ms of dispatches (~5 fewer × 48 layers × 8 µs).
2. **Cut dispatch count in the MLP and residual chain** (~1.5–2 ms): fuse gate+up into one N=2·intermediate
   qmv, fold `silu·mul` into the down_proj prologue, fuse residual-add with rmsnorm.
3. Tree verification: **skip** — break-even at ~0.10 extra tokens per row against a 0.10 threshold.
   Prompt-lookup as a *hybrid* (skip the 6.4 ms MTP head when a 3-gram match exists) is the better bet on
   copy-heavy work, and would not show on the current prose-heavy corpus.
4. The MTP head is itself off-roofline: 6.4 ms for ~0.6–1.1 GB is 3–5× off, with a likely argmax→CPU sync.

**Memory check on change 2 (why it is not done yet):** fusing gate+up builds a second copy of those
weights — 2 × 44.6 MB per layer × 64 layers = **~5.7 GB extra resident**, not the 2 GB quoted for the GDN
projection fusion. Opus's point is that this is net zero *if the originals are dropped* — but this store
keeps whole shards resident (`WeightStore.shards`), so dropping individual tensors is not currently
possible without a store change. Any fusion needs that change first, or it trades a few ms for GBs.

**Next instrument (Opus):** a per-op roofline table for one S=1 pass — `MLX_MAX_OPS_PER_BUFFER=1` (name
unverified), GPUStartTime/GPUEndTime per kernel, grouped by op name and shape with count, Σ µs, bytes and
GB/s, plus total-gaps = wall − kernel sum. Predicted: recurrence ~95 µs/layer vs ~12 µs ideal, 30–40
sub-10 µs elementwise kernels per GDN layer, large GEMVs at ≥480 GB/s, kernel sum ~33–36 ms against a
40.27 ms wall.

## Landed: gate+up fused into one qmv — S=1 40.27 → 34.67 ms (2026-10-25)

Opus's change 2 was expected to be worth 1.5–2 ms; it delivered **5.6 ms** because doubling N from
17408 to 34816 rows moves the MLP from ~421 GB/s into MLX's wide-GEMV regime, on top of one fewer
dispatch per layer.

Implementation: `WeightStore.mlpFused(layer)` builds `[gate; up]` weights once, `eval`s them (a lazy
concat would re-copy 89 MB per token — the earlier trap), then **drops the six original tensors** via a
new `WeightStore.drop(_:)`, which makes the fusion memory-neutral. `MLP.forward(layer:)` runs one
`quantizedMatmul` and slices the two halves. Rows are independent, so the result is bit-identical.

Gates: `benchspec … 0` **EXACT** (35 tokens), `gen 16` **matches the Python reference token for token**.

| | before | after |
|---|---:|---:|
| S=1 pass | 40.27 ms | **34.67 ms** |
| corpus mean, depth 2 | 41.4 tok/s (tensor path) | **50.2 tok/s** |
| corpus EXACT | 4/8 | 5/8 |

The corpus is now **50.2 tok/s mean** against mlx-vlm's 43–44 on the same prompts.

**Lesson worth keeping:** the same change had been rejected earlier ("fusing gate+up needs +5.7 GB"), and
the objection dissolved once the store could drop originals. The memory argument was right about the cost
and wrong about it being unavoidable — check whether the copy can *replace* rather than *shadow*.

## GDN projection fusion re-tested with `drop`: still negligible (2026-10-25)

With `WeightStore.drop` available, the four GDN projections were fused into one `[16480, K]` qmv and the
originals dropped, so the memory objection is gone. Result:

| | S=1 pass |
|---|---:|
| before | 34.67 ms |
| fused, first run | 33.93 ms |
| fused, repeat | 34.23 ms |

**~1.3–2.1%, inside the 2–5% measurement noise** — and exact (`benchspec … 0` EXACT, `gen 16` matches
the reference). Reverted, because my own bar is ≥3% and this is not a win; it is the third time this
particular fusion has measured negligible in-pass (1.73× isolated, ~0.5 ms real). The lesson from the
MLP fusion does *not* transfer: gate+up doubled N into the wide regime, whereas qkv|z|b|a is dominated by
the already-wide qkv term and merely absorbs three narrow blocks whose cost was mostly latency, not bytes.

Keep in mind for the next candidate: the MLP win came from changing the *GEMV shape class*, not from
reducing dispatch count.

## Implementation spec: the remaining wins, sized from measurements (2026-10-25)

Current: S=1 pass 34.67 ms, depth-2 corpus mean 50.2 tok/s, exact at both gates. Base pass is ~82% of a
depth-2 cycle, so this is where the remaining milliseconds are.

### 1. Conv + silu kernel (smallest, ~2.5 ms estimated) — start here

`GDN.depthwise` is four sliced multiplies plus three adds, then `silence` (x·sigmoid(x)): **7 kernels per
layer on 10240-element tensors**, × 48 layers. At ~8 µs of latency each that is ~2.7 ms/pass of pure
dispatch on tensors far too small to be bandwidth-bound.

One kernel: input `convIn [B,4,10240]` bf16, weight `[10240,4]` bf16, output `[B,1,10240]`:
`out[c] = silu(Σ_{k=0..3} convIn[k][c] * w[c][k])`, with the four multiply-adds **in k order 0,1,2,3** to
match `depthwise`'s accumulation, then `x * sigmoid(x)` in f32 and a final cast — the same shape as the
existing `GDNMetal`/`QGEMV` kernels, so the harness and the exactness checks already exist.

Gate: `benchsplitS` S=1 ≥3% better, `benchspec … 0` EXACT, `gen 16` matches the reference.

### 2. Fused GDN surrounding-op kernel (~5 ms, Opus's Change A)

Recurrence + conv + silu + l2norm + gate exp + beta sigmoid + output `rmsnorm(y)·silu(z)` in one or two
kernels. **Constraint that makes it safe:** keep the summation **column-wise in the same order** as the
current kernels, so the result is bit-identical and cannot reopen the exactness problem that cost several
rounds. Sizing from Opus: recurrence 4.6 → ~1.1 ms (~3.5) plus ~1.5–2 ms of dispatches.

### 3. MTP head (6.4 ms/pass, 3–5× off roofline)

~0.6–1.1 GB of weight traffic for 6.4 ms. Suspects in order: an `argmax(...).item(Int32)` sync per draft
(two per pass), and two 389 MB `lm_head` calls (2.4 ms). Check the byte count first; if the head's weights
are bf16 rather than 4-bit, that alone explains the gap.

### 4. Only after the base pass

Adaptive depth via accepted-prefix survival (`Q_d = 1 + Σ P(first i drafts accepted)`, add a draft when
`ΔQ > Q_d·ΔT/T_d`), and prompt-lookup as a hybrid that skips the 6.4 ms head on n-gram hits. Astra's cap
arithmetic stands: at depth 2 the maximum is 3 tok/pass, so 60 tok/s needs a 50 ms pass.

**Do not** re-attempt: GDN projection fusion (three measurements, all ~1–2%), whole-model compile, or
anything that reduces dispatch count without changing a GEMV's shape class — that distinction is what
separated the 5.6 ms MLP win from every 1–2% change.

## MTP head diagnosed: sync-bound, not bandwidth-bound (2026-10-25)

Checked the head's weights before attempting anything: `models/qwen38-mtp-4bit` is one shard, 31 tensors,
**8 quantized** — i.e. it really is 4-bit, and its total weight traffic is ~170 MB (fc + one layer + norms;
`lm_head` lives in the target).

6.4 ms per pass for ~170 MB is **~27 GB/s**, roughly 20× off the streaming ceiling. That rules out weight
bandwidth and points at the three synchronisation points per round plus tiny dependent kernel launches:

1. `MTP.nextToken` → `argMax(...).item(Int32)` per draft (one sync each).
2. The verify pass's `argMax(...).asArray(Int32)` (one sync).
3. The reseed replay and the seed step issued as **two** `MTP.step` calls where one would do.

**Cheapest correct fix, in order:**

- **Batch reseed replay + seed into one `MTP.step`.** They are the same operation on consecutive positions:
  tokens `drafts[0..<accepted] + [b]` with hiddens `vNorm[0..<accepted+1]`. One forward and one sync
  instead of two. Estimated 0.5–1 ms; below the 3% bar on its own, so fold it in with the next change.
- **Defer the draft argmax out of the loop.** `MTP.step` only needs the *token id* for an embedding lookup,
  and MLX `take` accepts an `MLXArray` index, so drafts can stay on the GPU through the chain; the values
  are only needed once, for the acceptance comparison. This removes 1–2 `.item()` syncs per round and is
  the real 2–4 ms; it requires reworking `generateSpec`'s control flow to compare prefix acceptance as an
  array and materialise the accepted prefix in one read.

Both keep output identical by construction (same arithmetic, fewer round trips), so the depth-0 and
reference gates should be unaffected — but verify them anyway, as with every change here.

## MTP reseed+seed batched (2026-10-25)

The replay of the accepted drafts and the seed step are the same operation on consecutive positions, so
they are now one `MTP.step` over `drafts[0..<accepted] + [b]` with hiddens `vNorm[0..<accepted+1]`,
returning the last position as the seed. One forward and one sync instead of two.

Parity: `benchspec … 2` **EXACT** (107 tokens), `benchspec … 0` **EXACT** (35 tokens).

**Timing: no measurable win claimed.** The run after the change gave 51.2 ms / 37.5 tok/s at depth 2 on
the natural prompt, but the same configuration was not measured immediately before it, and this session
has repeatedly shown that cross-run comparisons at this scale are noise. The change strictly removes work
(one head forward, one sync) and cannot be slower in principle, so it is kept — but it is recorded as
**unmeasured**, not as a gain, until an A/B with a flag exists.

The larger MTP item is still open and is the one that matters: keeping draft tokens on the GPU so the
per-draft `argMax(...).item()` disapears. Estimated 2–4 ms, and it needs `generateSpec`'s acceptance logic
to compare prefixes as an array.

## Current state after MLP fusion + MTP batching (2026-10-25)

Corpus, 8 prompts, depth 2, 64 tokens, one run each, both paths:

| | EXACT | mean tok/s |
|---|---:|---:|
| tensor path | 5/8 | 49.9 |
| fused kernel | 5/8 | **50.0** |

Per-prompt (kernel): csv 54.2, ts-hook 46.9, prose 44.9, sql 45.1, math 54.1, list 44.8, rust 56.6,
json 52.2. Both paths tie on every prompt within ~0.4 tok/s, so the fused recurrence is now
indistinguishable from the MLX-op path in speed at depth 2 — its win shows in the **S=1 pass**
(34.67 ms vs ~40) rather than in the speculative loop, where rows and the head dominate.

The MTP reseed+seed batching moved nothing (50.2 → 50.0, i.e. noise), which is what "unmeasured, kept
because it removes work" predicted. Its real value is that it is a prerequisite step for the no-sync
refactor, which is still the largest open item.

Baseline for the next session: **S=1 34.67 ms, depth-2 corpus mean 50.0 tok/s, 5/8 EXACT (both paths),
depth 0 exact**. Against mlx-vlm's 43–44 tok/s on the same prompts.

## Ordering confirmed, plus one new hypothesis (Opus, 2026-10-25)

**Read of the kernel/tensor tie at depth 2:** it is mostly "the kernel's saving does not survive S>1",
not hidden pipeline stalls. The numbers close without a stall term — verify at S=3 ≈ 34.67 + 2×2.5 =
39.7 ms, two head passes ≈ 12.8 ms, total ≈ 52 ms against ~50 ms/round observed. So **~25% of every round
is the MTP head plus its syncs**, and the head is latency-bound at 27 GB/s.

**New hypothesis worth 2–4 ms:** the fused kernel's *per-row* cost at S>1 may be eating its S=1 gain. That
is one concrete explanation for why the fused and tensor paths tie at depth 2 while the fused path is 5+
ms faster at S=1. Measure before assuming.

**Order of work (opaque to argument, so follow it):**

0. **Diagnostic, ~30 min, no refactor.** Compare wall time per round against the sum of GPU time for the
   passes (Metal capture, or timestamps around each `.item()`). If the idle gap is ≥3 ms, item 1 is
   justified. *Metric: idle gap in ms per round.*
1. **No-sync MTP.** Drafts stay on the GPU; acceptance compared as an array. Largest and most certain
   item, and the head is latency-bound. *Metric: corpus tok/s, interleaved A/B, EXACT stays ≥5/8; the
   acceptance counts must be bit-identical.*
2. **conv+silu kernel.** Judge at **S=3, not S=1** — 336 dispatches at 3–7 µs is 1–2.3 ms, and anything the
   GPU already overlaps will not show. *Expect 1–2 ms, not 2.5.*
3. **Investigate the kernel's S>1 per-row cost**, then the fused GDN surrounding-op kernel. Only start it
   once that is explained. *Metric: kernel path beating tensor path at depth 2 by >1 ms.*

Why conv+silu may underdeliver despite being a different change from the projection fusion: that one was
already bandwidth-efficient (fusing saved nothing), whereas this one saves dispatch gaps — but only the
gaps that are actually serialised, which is why it must be judged at S=3.

## Step 0 diagnostic: ~4–5 ms/pass outside the measured phases (2026-10-25)

`STRIM_TIMING=1` on the natural prompt, depth 2: draft 2.1 + verify 41.3 + reseed 2.1 = **45.5 ms of a
50.9 ms pass**, i.e. **~5.4 ms/pass unaccounted** (a 59-token prompt, so prefill amortisation is only
~1 ms of it — call it 4–5 ms of genuine per-round overhead outside the timed windows: acceptance logic,
cache rollback/trim, bookkeeping, and any sync not inside a timed block).

That clears Opus's gate (**≥3 ms → the no-sync MTP work is justified**) on its own, independently of the
head's 27 GB/s.

Also confirms the phase split at S=3: verify **41.3 ms**, against 34.67 ms at S=1 + 2 rows × ~2.5 =
39.7 predicted — so rows cost what the slope said, and the head + overhead (2.1 + 2.1 + 4–5) is
**~8–9 ms per round, 17% of the pass**.

**Implication for order:** the no-sync refactor should target *both* ends — the two `argMax().item()` calls
inside the head phases *and* the untimed per-round work, since together they are ~8–9 ms and the latter
has never been instrumented at finer granularity.

## Landed: conv+silu kernel, −1.1 ms at S=3 (2.7%, below the bar — see why)

`GDN.depthwise` (four sliced multiplies + three adds) followed by `silence` was seven dispatches per
layer on 10240-element bf16 tensors. Replaced with one kernel (`gdn_conv_silu`), one thread per output
element, bf16 accumulation in k order 0,1,2,3 with `#pragma clang fp contract(off)` so the rounding
sequence matches the tensor path.

| S=3 | run 1 | run 2 |
|---|---:|---:|
| tensor conv | 39.74 | 39.62 |
| **conv kernel** | **38.69** | **38.50** |

**−1.05 / −1.12 ms = 2.7%**, and `benchspec … 0` **EXACT** (35 tokens).

This is **below the 3% bar**, and it is kept anyway — stated explicitly rather than glossed: the sign is
consistent across two interleaved rounds, the mechanism is understood (336 fewer dispatches, each with a
serialised gap), the change is exact, and it costs no memory. Opus predicted 1–2 ms here and warned it
would underdeliver versus the 2.5 ms estimate, which is exactly what happened. `STRIM_CONV_TENSOR=1`
restores the tensor path for A/B.

> **Correction 2026-10-26:** "the change is exact" holds at the depth-0 gate, not at bit level.
> `strim logithash` with the conv kernel differs from `STRIM_CONV_TENSOR=1` at position 0 already
> (top2 7.4375 vs 7.40625) and at every position over 16; in combination with the recurrence
> kernel it makes `gen 16` fail. The conv kernel is in the default path and passes the gates on
> its own, but it is a second ~1 ulp source. **Fixed later on 2026-10-26:** the cause was MLX's
> bf16 `Sigmoid` rounding at every step; the kernel is now bit-exact (0/40960 differing). See
> "Kernel exactness closed" at the end.

## Row cost collapsed after the kernel work (2026-10-25)

`benchpassS` with the fused recurrence, MLP fusion and conv kernel:

| S | ms/pass | Δ |
|--:|--:|--:|
| 1 | 35.87 | — |
| 2 | 36.88 | **+1.01** |
| 3 | 39.08 | +3.21 |
| 4 | 42.93 | +7.06 |

The per-row slope at the low end is now **~1.0 ms**, down from 2.5 ms when the recurrence was still MLX
ops. That crosses Opus's threshold — rows below 1.5 ms mean the remaining depth-2 cost is head +
bookkeeping, not the verify body, and it makes tree/branching verification and prompt-lookup drafting
viable again (their break-even was judged against a 2.4–2.5 ms row).

**Depth re-check, natural prompt, 48 tokens:** depth 2 = **38.8 tok/s** (49.5 ms/pass, 1.92 tok/pass),
depth 3 = 38.2 (54.7 ms). Depth 2 still wins by a hair: +5.2 ms buys only +0.17 tok/pass because
acceptance falls to 36%. Keep depth 2 as the default.

**Where the remaining time is, updated:** S=3 verify is 39.1 ms of a ~49.5 ms round, so head + bookkeeping
is ~10 ms (20%) and the verify body is bound by the 12.6 GB weight stream — the same floor as before.

## Spec: no-sync MTP refactor (top item, 2–4 ms)

**Why:** head + bookkeeping is ~10 ms of a 49.5 ms round (20%), and the head moves ~170 MB at 27 GB/s —
20× off roofline, i.e. latency-bound. Three `.item()`/`.asArray()` syncs per round, plus ~4–5 ms of
untimed per-round work that has never been broken down.

**The blocker to removing them** is that `MTP.step(tokens: [Int32], …)` and
`WeightStore.embedding(_:tokens:)` take Swift integers, so every draft token must come back to the host
before the next step can embed it.

**Changes, in dependency order:**

1. `WeightStore.embedding(_ prefix: String, indices: MLXArray, …) -> MLXArray` — same function with the
   `MLXArray(tokens)` construction replaced by the caller's index array, so `take(idx, axis: 0)` runs
   straight off the GPU tensor. (Existing `[Int32]` overload stays.)
2. `MTP.stepIndex(tokens: MLXArray, hidden: MLXArray, …) -> MLXArray` — identical to `step` but uses
   change 1. `hidden` for a single token is `[1,1,5120]`; for the replay batch `[1,n,5120]`.
3. `MTP.nextTokenIndex(_ hidden:…) -> MLXArray` — `argMax(logits[0, -1])` **without** `.item()`, shape
   `[1]`-ish, to be used as the index in change 2.
4. `generateSpec`: keep `drafts` as `[MLXArray]` (seed draft included), and build `feed` for the verify
   pass by concatenating token ids — this is the one place that still needs ints, because
   `QwenModel.forwardAll(tokens:)` takes `[Int32]`. Options: (a) add an index-based `forwardAll`, or
   (b) accept **one** sync per round here (materialise `feed` once) and remove only the *draft-chain*
   syncs. (b) is the 80/20: it kills 1–2 of the 3 syncs with a fraction of the risk.
5. Acceptance: `preds` is already an `Int32` array; `drafts` values are needed for comparison — materialise
   them in the same read as `feed` (one sync, not per-draft).

**Recommended scope for one round:** do (b) — items 1–3 plus one materialisation point in the draft chain
— measure corpus tok/s by interleaved A/B, and require `EXACT` ≥5/8 with identical acceptance counts. If
that lands, extend to an index-based `forwardAll` for the last sync.

**Do not** attempt the full array-based rewrite in one step: `generateSpec` is the only correctness-critical
control flow in the project and a broken draft chain silently corrupts acceptance counts rather than
failing loudly.

## Corpus after the conv kernel: 51.7 tok/s (2026-10-25)

| | EXACT | mean tok/s |
|---|---:|---:|
| tensor path | 4/8 | 51.1 |
| fused kernel | 4/8 | **51.7** |

Per-prompt (kernel): csv 55.4, ts-hook 49.2, prose 43.8, sql 50.1, math 54.9, list 47.7, rust 58.4,
json 54.4. Against mlx-vlm's 43–44 on the same prompts.

**Note on the EXACT column:** the set of prompts that flip *changed between runs of the same binary*
(csv-py was EXACT in the previous corpus, MISMATCH here; prose and sql went the other way). That confirms
these are marginal near-tie flips whose outcome sits on a knife edge, not a stable property of a prompt —
so 4–5 of 8 is the right way to read the column, and no single run should be used to compare code paths.
This is the same trap that caused two opposite kernel-default reverts earlier in the project.

## How to fuse the gating chain without touching rmsNorm's reduction (Opus, 2026-10-25)

The blocker I raised — that any custom `rmsNorm` changes the summation order and could add knife-edge
flips that the 4–5/8 corpus statistic cannot resolve — is avoidable:

**Keep `MLXFast.rmsNorm` exactly as it is**, then fuse only the elementwise tail into one kernel over
`normed` (bf16) and `z` (bf16): `bf16(silu(z_f32) * float(normed))` with float32 intermediates and
`fp contract(off)`. That replaces ~5 dispatches (two `asType`s, the `silence` sigmoid+mul, the multiply,
the final cast) and has **no reduction-order risk at all**, because it is elementwise.

Two caveats: the only place it can still differ is the `sigmoid`/`exp` flavour (MLX uses `precise` vs
`fast` math — check which, and match it), and you cannot fold this into `quantizedMatmul`'s prologue
because that is MLX's kernel.

**Do not write a custom norm.** If it ever becomes necessary, MLX's `rms_single_row` for axis 128 is one
simdgroup per row, each lane reading 4 contiguous elements, squares summed sequentially in f32, then
`simd_sum` across lanes, `precise::rsqrt(acc/N + eps)`, output `w * T(x * normalizer)` with the `w`
multiply in bf16 — but `simd_sum`'s internal order is undocumented, so it must be **proved by test**, not
inference: capture real `yAll` from several layers, compare bit patterns (`==` on the uint16 view) over
≥10⁶ rows plus adversarial ones (large dynamic range, near-zero). One mismatch means do not ship.

**Acceptance criterion, now the standard for any kernel here:**

1. Bit-exact sub-step outputs on captured real tensors, then
2. depth-0 `benchspec` EXACT, then
3. identical logits (max |Δlogit| = 0) over **8 prompts × 128 tokens**.

With zero numeric difference no flip statistic is needed. If a change is *not* bit-exact, do not use flip
counts — 4–5 of 8 has too much variance. Instead compare teacher-forced logits against the unfused path
over ≥2k tokens and report max |Δlogit|, p99, and the fraction of positions whose top1−top2 margin is
smaller than |Δ|; accept only if those sit at or below the existing bf16 run-to-run noise floor.

**Rank: finish the no-sync MTP refactor first** (2–4 ms, 5–10% of a round), then this gating fusion
(~2%, five dispatches versus the 2.7% we got from seven).

## Instrument: `logithash`, and the real character of the kernel/tensor difference (2026-10-25)

Token-level EXACT cannot distinguish "bit-identical" from "same argmax by luck", and the project kept
needing that distinction. New command:

    strim logithash <model> <n> [ids]

prints, per generated position, the argmax token, an FNV-1a hash of the float32 logit vector, top-1/top-2
and their margin. Run twice under different flags and diff.

**Result, tensor path (`STRIM_GDN_TENSOR=1`) vs fused kernel, 24 positions, degenerate prompt:**

| | first position |
|---|---|
| tensor | top1 198 @ 7.750000, margin 0.312500 |
| kernel | top1 198 @ 7.718750, margin 0.312500 |

- **All 24 positions differ** in logits (every hash differs).
- The difference is **~1 bf16 ulp** (7.718750 vs 7.750000; bf16 step 0.03125 at that magnitude).
- **All 24 tokens agree** on this run.

So the correct statement, which the docs have not made until now: the fused recurrence is **not
bit-identical** to the MLX-op path; it is accurate to ~1 ulp, tokens agree except when the top1−top2 margin
is smaller than that error, and the depth-2 corpus flips (4–5 of 8) are those near-ties. This also explains
why the flips changed between runs of the same binary earlier — the two paths' disagreement sits right at
the margin of the prompts involved.

Use this instrument next for Opus's acceptance criterion: a change is bit-exact only when the hashes match
at every position. Otherwise report max |Δlogit|, p99 and the marginal-position fraction, and compare
against the bf16 noise floor — which this measurement now bounds at roughly one ulp for the recurrence.

### Determinism and the ~1 ulp gap, re-checked (2026-10-25)

- **Both paths are deterministic across process launches**: the tensor path gave identical hashes on 3/3
  runs and the fused kernel on 2/2. So the gap is not run-to-run noise.
- **The gap is stable and ~1 bf16 ulp**: tensor top1 7.750000 vs kernel 7.718750 at position 0, every
  position differing, tokens agreeing on this prompt. It reproduced byte-for-byte after a rebuild,
  confirming it is a genuine arithmetic difference rather than scheduling.
- An earlier attempt to attribute it to **FMA contraction was confounded**: the edit replaced the pragma
  inside *both* Metal kernels (recurrence and conv), so both paths moved by the same ulp and the
  comparison proved nothing. Reverted; the contraction hypothesis on the recurrence is still **untested**.

**Next clean test for the ulp:** the state update is the prime suspect, because its *form* differs — the
tensor path uses `r1 = r0 + matmul(delta⊗k)` while the kernel does `st += k*delta` elementwise with
contraction off. Change only the recurrence kernel's contraction (leave `convKernel` alone), then diff
`logithash` against `STRIM_GDN_TENSOR=1`. If hashes match at every position, the kernel is bit-exact and
the depth-2 flips disappear; if they do not, the difference is in the reduction and matching it would need
MLX's exact gemv association, which is not worth further rounds unless a quality complaint demands it.

### Contraction ruled out as the cause of the ~1 ulp gap (2026-10-25)

Clean test — pragma changed in the **recurrence kernel only**, conv kernel untouched:

| recurrence kernel | top1 at position 0 |
|---|---:|
| tensor path (reference) | 7.750000 |
| contraction **off** | 7.718750 |
| contraction **on** | 7.687500 |

Contraction **on** moves the kernel *further* from the reference (2 ulps instead of 1). So FMA contraction
is not the cause; the remaining difference is the **form of the reduction and state update** — the tensor
path uses `matmul` (MLX's gemv/gemm association) for `<r0,k>`, `<r1,q>` and the `delta⊗k` outer product,
while the kernel uses `simd_shuffle_down` sums and elementwise FMA-free updates.

Reverted to the off-pragma build, which is the closest of the three.

**Verdict:** closing this thread. Chasing MLX's exact gemv association is not worth further rounds — the
gap is 1 bf16 ulp, deterministic, and only flips tokens whose top1−top2 margin is below it (the corpus
near-ties already characterised). If a quality complaint ever demands bit-identical output, the answer is
to use `STRIM_GDN_TENSOR=1`, not to keep tuning the kernel.

> **Wrong, 2026-10-26:** the association *was* the cause, and it was cheap once measured properly. MLX's
> gemv accumulates with FMA; the kernel had contraction off. A Python replication of the gemv tree
> matches MLX bit-for-bit only with true FMA. Fixed with `metal::fma` in the two reductions. The other
> half of the gap was bf16 `Sigmoid` rounding in the conv kernel. See "Kernel exactness closed".

## Gating-chain fusion: bit-exact but worthless (0.4%) — reverted (2026-10-25)

Built exactly as specified: MLX's `rmsNorm` untouched, one kernel for the elementwise tail
`bf16(silu(z_f32) * float(normed))` with `precise::exp`/`precise::divide` to match MLX's math flavour.

**Bit-exact:** the `logithash` of the fused path was byte-identical to the pre-fusion kernel path
(`b13bf60972507b83`), so this change provably altered no arithmetic.

**Speed: nothing.** S=3 interleaved A/B:

| S=3 | run 1 | run 2 |
|---|---:|---:|
| tensor chain | 38.47 | 38.36 |
| **fused kernel** | **38.30** | **38.23** |

−0.17 / −0.13 ms = **0.4%**, an order of magnitude under Opus's ~2% estimate and inside noise. Reverted.

**Why the conv kernel paid (2.7%) and this one did not (0.4%), despite both replacing ~5–7 dispatches:**
the conv operates on 10240-element tensors *before* the recurrence and sits on the critical path between
the projections and the recurrence, whereas this tail sits between `rmsNorm` and `out_proj` where the GPU
already has the `out_proj` GEMV queued behind it and can overlap the elementwise work. **Dispatch
reduction only pays where the dispatches are actually serialised** — the third independent confirmation of
that rule in this project, and the reason the pre-fusion `benchsplitS` estimate (7 dispatches ≈ 2 ms at
8 µs each) systematically overstates.

## Decision: exactness wins a 1.2% trade (2026-10-25)

The corpus measures both recurrence paths end to end at depth 2:

| path | mean tok/s | numerical status |
|---|---:|---|
| tensor (MLX ops) | 51.1 | **bit-identical** to the Python mlx-vlm reference (`gen 16` matches) |
| fused kernel | 51.7 | ~1 bf16 ulp off (`logithash` differs at every position) |

The kernel's advantage is concentrated in the **S=1 pass** (35.9 vs 40.3 ms, ~11%), which barely matters
in the speculative loop — hence only 1.2% at depth 2.

The objective says *unchanged output quality*, so the default is now the **bit-identical tensor path** and
the kernel is opt-in (`STRIM_GDN_METAL=1`) for anyone who wants the S=1 speed and accepts near-tie drift.
That is a deliberate reversal of the round-27 decision, and it is the right one under this goal's wording:
a 1.2% throughput difference does not buy the right to change outputs.

Anyone revisiting this should treat the numbers above as the argument: if a future change makes the kernel
bit-identical (see the closed contraction thread — the residual difference is gemv association, not FMA), the
default should flip back and the ~11% S=1 gain becomes free.

> **Superseded 2026-10-26:** the 1.2% is wrong. Interleaved inside one process, exactness costs
> **17.5% at depth 2** on the natural prompt and **22.8%** on a code prompt; the "tie at depth 2"
> came from comparing separate processes across thermal drift. The tensor default still stands,
> but for a stronger reason than 1.2%: the kernel path fails `gen 16`. The price of that
> exactness is now large enough that closing the kernel's remaining ~1 ulp is the top
> performance item. See the last sections of this file.
>
> **Superseded again 2026-10-26 (later the same day):** the gap was two concrete rounding
> details (bf16 sigmoid steps, gemv FMA), both fixed. The kernel now passes `gen 16`, ties the
> tensor path 7/8 on the corpus and is the **default**. See "Kernel exactness closed" below.



## No-sync MTP draft chain: 2 of 3 syncs gone, worth ~0.5–1% not 2–4 ms (2026-10-26)

Implemented the 80/20 from the spec above: `WeightStore.embedding(indices:)`,
`MTP.stepIndex`, `MTP.nextTokenIndex`, and **one** materialisation per round (concatenate
`[b, d1, d2]` and `asArray` once). Drafts and the reseed seed stay on the GPU; the old
per-draft-sync path is kept as `STRIM_MTP_HOST=1` for A/B.

Interleaved A/B in one process (`strim benchmtp`), depth 2, 48 tokens, alternating order:

| prompt | host sync | index no-sync | delta | accept |
|---|---:|---:|---:|---:|
| natural | 63.48 ms/pass | 62.79 | −0.69 (−1.1%) | 23/50 both |
| code-ts | 74.24 | 73.90 | −0.34 (−0.5%) | 31/34 both |

Token outputs and acceptance counts were identical in every generation of both A/Bs (28
generations). Gates unchanged:
`benchspec … 2` **EXACT** (107 tokens), `benchspec … 0` **EXACT** (91), `gen 16` matches the
Python reference.

**Why the win is small.** The three syncs are dependency waits, not round-trip overhead.
Natural prompt, `STRIM_TIMING=1`:

| chain | draft | verify | reseed |
|---|---:|---:|---:|
| host | 2.1–2.2 | 49.1–49.3 | 2.2 |
| index | 4.0–4.1 | 49.1 | **0.1** |

The ~2 ms reseed wait moves into the draft phase rather than disappearing: the draft chain's
last `lm_head` cannot be read until it is produced, and verify cannot start until that read
completes. What is actually removed is the host round trip, ~0.3–0.7 ms/pass. The untimed
4–5 ms/pass is therefore **not** these `.item()` calls — the capture below puts the inter-pass
gap at 3–5 ms with the GPU ~88% busy, consistent with graph construction and bookkeeping.

**Do not** budget 2–4 ms for sync removal on this chain. The remaining MTP cost is two 389 MB
`lm_head` calls plus the head's own layer — dependent GPU work. The last remaining sync (the
verify-feed read) is 3 token ids; an index-based `forwardAll` would remove it and nothing else,
so it is not attempted. The measured ceiling here makes that consistent with the earlier
step-0 result.

## The kernel's S>1 cost is not per-row; the "1.2% at depth 2" was cross-process noise (2026-10-26)

The open hypothesis was that the fused recurrence's **per-row cost at S>1** eats its S=1 gain,
explaining the kernel/tensor tie at depth 2 (51.1 vs 51.7 tok/s) and the 1.2% exactness price
used to justify the tensor default. Two instruments that did not exist before settle it.

`strim benchpathS` times a primed 64-layer pass with both paths **in one process**, alternating
per repetition (min-of-8):

| S | tensor ms | kernel ms | kernel − tensor |
|--:|--:|--:|--:|
| 1 | 36.36 | 34.45 | **−1.92 (−5.3%)** |
| 2 | 40.08 | 35.95 | **−4.14 (−10.3%)** |
| 3 | 44.90 | 39.28 | **−5.62 (−12.5%)** |
| 4 | 50.06 | 42.66 | **−7.40 (−14.8%)** |

The kernel wins *more* at S>1, not less, so the per-row hypothesis is refuted: the fused kernel
amortises the state across the token loop instead of paying per row, which is what it was
written for.

`strim benchpathspec` then runs the real depth-2 loop (growing KV, rollback, MTP head),
alternating the recurrence path per generation:

| prompt | tensor | kernel | delta | accept |
|---|---:|---:|---:|---:|
| natural | 62.26 ms/pass | 51.36 | −10.91 (**−17.5%**) | 46% both |
| code-ts | 74.28 | 57.37 | −16.91 (**−22.8%**) | 91% both |

Both paths were deterministic across reps; token outputs and acceptance counts were identical
on these two prompts. Absolute numbers here are inflated by a resident UTM VM and Chrome (the
8-prompt idle corpus earlier read 51.1/51.7 tok/s); the in-process delta is the measurement of
record. **The exactness trade costs 17–23% at depth 2, not 1.2%.**

**Decision: the tensor path stays the default — but not at 1.2%.** `STRIM_GDN_METAL=1 strim gen 16`
fails the reference at generated token 15 (`…95971, 198, 2` vs `…95971, 9616, 96012`), while
the default tensor path passes and `benchspec … 0` is EXACT. So the flip would break the one
gate that is currently satisfied. Two findings from isolating it:

- The two ~1 ulp sources are **additive**: recurrence kernel + tensor conv passes `gen 16`,
  tensor recurrence + conv kernel passes, both together fail it.
- The conv kernel is **not bit-exact**, contrary to the "matches `depthwise` + `silence`
  exactly" claim next to it: `logithash` with the conv kernel differs from `STRIM_CONV_TENSOR=1`
  at position 0 already (top2 7.4375 vs 7.40625, hash differs), and at all 16 positions.
  Rewriting its sigmoid to MLX's exact form (`1/(1+exp(|x|))`, then `1-y` for x≥0) changed
  **nothing**, so the residual difference is in the accumulation or the bf16 multiply, not the
  sigmoid flavour.

The recurrence kernel remains ~1 bf16 ulp off, as the closed contraction/gemv thread found.
With exactness now priced at 11–17 ms/pass, making the recurrence bit-identical is the
highest-value performance item; the kernel is the fastest code in the tree and is left enabled
by `STRIM_GDN_METAL=1` for anyone who does not need `gen 16`.

## GPU capture: no per-kernel attribution, and the pass is GPU-busy (2026-10-26)

`xcrun xctrace record --template 'Metal System Trace'` over the kernel path
(`STRIM_GDN_METAL=1 strim benchpassS models/qwen38-4bit 6`, 28 passes including warmups)
records and exports fine, but MLX does not label its Metal dispatches: every encoder appears
as `Compute Command N`, so the trace **cannot** attribute time to `gdn_recurrence` versus a
qmv. That is the limit of this instrument; per-kernel questions need MLX dispatch labels or a
standalone kernel A/B.

What the capture does establish, over 2889 strim GPU intervals: union GPU-busy time
**1585 ms of a 1798 ms span (88%)**, with 3–5 ms gaps between passes and 30/24 ms at startup
(weight load / first eval). So the round is not GPU-idle waiting on the host, and the untimed
per-pass overhead is host-side submission/bookkeeping, matching the ~2.6 ms graph build
measured earlier. The whole-pass interleaved instruments above remain the attribution of
record.


## Kernel exactness closed: bf16 sigmoid + gemv FMA; kernel is the default (2026-10-26)

Two concrete rounding causes, found with two new sub-step instruments (`checkconv`, and a
Python replication of MLX's gemv tree):

1. **Conv+silu kernel.** `strim checkconv` splits the kernel into sum-only and silu-only modes
   on real projections. The 4-tap sum was already exact (0/40960 differing); the silu was not.
   MLX's `Sigmoid` instantiated on `bfloat16_t` rounds at every step — `1/(1+exp(|x|))` in bf16,
   then `1-y` for x≥0 — while the kernel computed it in f32 and cast once. Fixed; the full
   kernel now differs on **0/40960** elements.
2. **Recurrence kernel.** MLX's `gemv` accumulates with FMA (`gemv.h` has no
   `contract(off)`), while the kernel had `#pragma clang fp contract(off)`. Replicating the
   `bm4/sn32/tm4/tn4` gemv tree (32 lanes × 4 values, shuffle-down 16..1) in NumPy matches
   MLX bit-for-bit only when each `acc += w*x` is a true FMA; separate mul+add is 4.77e-06
   off. The kernel now uses `metal::fma` in the two reductions and keeps separate mul+add for
   the rank-1 state update (the K=1 matmul is an exact product, then a separate add).

**The residual is TF32, not association.** MLX's tensor path runs the recurrence matmuls with
`MLX_ENABLE_TF32=1` (the default), i.e. TF32-rounded f32 inputs; the kernel uses full f32.
With `MLX_ENABLE_TF32=0` the tensor and kernel paths are **bit-identical over 16 positions**
and `checkmetal` is exactly 0. The kernel is therefore the *more* accurate path, not a
tolerance trade.

**Default flipped.** Corpus, 8 prompts × 64 tokens, depth 2, both paths, kernel prefill too:

| | EXACT | mean tok/s |
|---|---:|---:|
| tensor (TF32 reference) | 7/8 | 41.0 |
| **fused kernel (default)** | **7/8** | **50.3 (+23%)** |

Per prompt (kernel): natural 41.3, code 54.1, sql 55.6, rust 53.7, csvpy 53.3, prose 37.7,
math 55.4, json 51.1. Prose is the one MISMATCH for **both** paths (the known batched-verify
near-tie). Gates: `gen 16` matches the Python reference, depth-0 EXACT (91 tokens), depth-2
natural EXACT (107). `STRIM_GDN_TENSOR=1` restores the reference-TF32 path.

This supersedes the "exactness wins 1.2%", "not worth further rounds" and "the kernel fails
`gen 16`" conclusions above. The gap cost one session once the sub-step instruments existed.

## Prefill: 266 → 799 tok/s at 4k by using the fused kernel (2026-10-26)

New instrument: `strim benchprefill <model> <n>` (cold cache, one chunk). Before this change
the Swift engine ran the tensor recurrence for prefill, which walks the 3 MB per-head state
per token and — worse — always built the per-token state stack (at S=4k that would be ~13 GB).

| S | tensor prefill | fused kernel | gain |
|--:|---:|---:|---:|
| 512 | 251 tok/s | **688** | 2.7× |
| 1024 | 266 | **838** (756 on a repeat run) | 3.2× |
| 4096 | — | **799** (751 on a repeat run) | — |

**+ last-token-only lm_head (2026-10-26):** prefill was computing `lm_head` over every prompt
position; only the last is needed. At 4K that removes ~6.4 TFLOP ([1,4096,152K] logits) and
measures **825–846 tok/s at 4K, 827–863 at 1K** (was 778–798 / 787–822). Gates unchanged.

Changes: a no-stack recurrence (`recurrenceMMNoState`) and a `recordStack` flag on the fused
kernel, so neither allocates the rollback stack when not recording; and the kernel now handles
prefill too (`metalMaxS` default covers all S; `STRIM_GDN_METAL_MAX_S=8` restores the tensor
prefill for A/B). Token outputs are unchanged: a 59-token prompt generates identically through
kernel and tensor prefill, and depth-0/depth-2 stay EXACT.

**Causal-mask prefill (same day).** A fresh prefill has `offset == 0`, so the S×S f32 mask
array built in Swift (and its 8M-element loop per layer at S=1024) is exactly MLX's standard
causal mask. Using `MLXFast...MaskMode.causal` there is bit-identical (`logithash` matches over
8 positions) and measured 1.21 vs 1.27 s at 1024 and 5.05 vs 5.22 s at 4096 (min-of-2,
cross-build): **+3–5% prefill**. Cached/verify passes still build the manual offset mask.

**Why 1,200 is not reachable here.** Split at S=1024 with the kernel: MLP 747 ms (63%), GDN
349 ms (30%), attention 103 ms (9%). `benchqmmM` puts MLX's large-M 4-bit qmm at **38–55
TFLOP/s** (gate+up 48, down 51, qkv 38 at M=1024). At 54 GFLOP/token that is a **~890 tok/s
prefill roofline**; 825–846 is 93–95% of it. A raw bf16 GEMM on the same shapes measures
**62.9 TF/s** (qmm 57.5), so a 4K prefill at 100% GEMM is ~1,170 tok/s: **1,200 is at/above
the hardware edge**, not a scheduling gap. The remaining 4K cost is GDN (~30%) and MLP (~63%). 1,200 would need >65 TFLOP/s effective, i.e. a faster
matmul path than MLX's qmm on this machine, not a scheduling fix. The prefill goal is
therefore re-scoped to the roofline, and the 3.2× is real.

## Concurrency/priority: admission was after the backend call (fixed 2026-10-26)

`strimd` already had a `PriorityGate` (interactive vs background, background capped and
yielding), but every streaming path called `client.send(upstream)` **before** taking the slot.
The backend had therefore already admitted the request into its batch; the gate only throttled
the relay, not the GPU work. Fixed in `/v1/chat/completions`, `/v1/messages` and the streaming
`/v1/responses`: the slot is taken first and released on upstream error.

Also per-backend gates now match what the engine can actually batch — speed 4, quality 2
(`--max-num-seqs`), background capped at 1 each — instead of one global 2-slot gate that
serialised the speed backend to half its capacity. `/v1/strim/status` reports
`priority.<mode>` per backend.

Tests: `bench/test_priority.py` (policy: interactive never waits behind background, background
cap) and `bench/test_priority_ordering.py` (regression: a slot is held when the upstream send
happens). Both pass.

**Boundary:** this is admission priority, not mid-token preemption; a background request already
inside rapid-mlx's batch still competes for GPU. The Swift engine itself has no server,
continuous batching or KV paging — that remains the product-side rapid-mlx path.


## Adaptive MTP depth: +12% corpus, +22% on code (2026-10-26)

Depth 2 was chosen when the head accepted 46% on prose; code-shaped prompts accept 91–94%,
where a third draft pays for its extra pass. `generateSpec` now keeps an EWMA of accepted
drafts and moves 2 → 3 after two rounds above 0.82, then 3 → 4 above 0.84 (the extra
depth costs a longer verify pass, so it needs higher acceptance), and back to 2 below
0.60. It never goes to depth 1: the measured depth sweep had depth 1 below depth 2 on
every prompt, so a low acceptance only keeps 2. The ceiling is depth 4.

Corpus, 8 prompts × 64 tokens, same run, fixed vs adaptive:

| | fixed depth 2 | adaptive | delta |
|---|---:|---:|---:|
| mean tok/s | 49.2 | **55.1** | **+12.0%** |
| code | 53.1 | **64.8** | +22% |
| json | 50.4 | **58.6** | +16% |
| sql | 54.2 | **62.6** | +15% |
| math | 54.0 | **62.1** | +15% |
| natural | 41.0 | **41.6** | +1.5% (stays at 2) |
| prose | 36.8 | **37.5** | +1.9% (stays at 2) |

EXACT is **7/8 for both** (prose is the shared MISMATCH); `gen 16` and depth-0 EXACT still
pass. The mechanism is tokens/pass, not a faster pass: code goes 2.87 → 4.00 tok/pass at
~61 ms. The decode-only mean is **55.1 tok/s**; end-to-end including prefill is 54.9.

Default is now adaptive; `STRIM_MTP_FIXED=1` restores the fixed depth-2 policy. The load
was a loaded machine (UTM + Chrome); the relative gain is the measurement of record, and a
quiet-machine corpus A/B is still worth running.

### MCP tool calls now go through the same admission gate

`strimd.delegate` (the MCP `strim_summarize`/`review_diff`/… tools) posted straight to the
backend, bypassing `PriorityGate`: an agent running several MCP tools could occupy the
backend while a chat request waited, the same class of bug as the earlier chat relay
ordering. `delegate` now holds a per-backend interactive slot for the whole call.
`bench/test_mcp_gate.py` is the regression test; it joins the other two priority tests in
`scripts/ab_bench.sh`.

## Decode headroom checks: depth 4 and an 8-bit MTP head (2026-10-26)

Two decode ideas were measured and rejected; recording them so they are not retried blindly.

- **Depth 4** was first measured on a heavily loaded machine, where it lost on code
  (60.5 → 57.3) and won only on sql. On the quieter run it wins on high-acceptance code
  and sql (code 60.8 → 64.8, sql 59.3 → 62.6), loses on csvpy/json, and is now the
  adaptive ceiling above 0.84 acceptance. Fixed depth 4 still loses on natural/prose.
- **8-bit MTP head** (`models/qwen38-mtp-8bit`, target unchanged): natural acceptance
  52 → 55%, tokens/pass 2.03 → 2.10, but pass time 49.5 → 52.0 ms, so tok/s 41.0 → 40.3;
  code acceptance unchanged (94%) and pass time 58.2 → 65.6 ms (53.7 tok/s); prose no win.
  Rejected; the 4-bit head stays.

The decode ceiling at the corpus level is now set by **acceptance on natural/prose** (52/42%),
not by pass time: code already runs 60.5 tok/s at 94% acceptance. Improving that needs a better
drafter, which is outside this repository.
