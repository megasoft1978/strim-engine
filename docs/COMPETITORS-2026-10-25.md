# Competitor benchmark — same model, same machine, single and concurrent requests

**Date:** 2026-10-25 · **Machine:** M5 Max 64 GB · **Checkpoint:** `models/qwen38-8bit`
(Qwen3.8-27B, affine 8-bit, 29.5 GB) · **Prompt:** 4,096 tokens of code-ish text, 128 generated,
greedy · **Harness:** `bench/compare.py` (retired Python script, in git history) — OpenAI streaming, TTFT from request
start to first content token.

The point of this run is to establish the bar we must beat, not to crown a winner: engines differ in
maturity, and the oMLX build available offline is 0.4.5, not 0.7.1.

---

## 1. Results

| Engine | Load | TTFT (1 req) | Decode (1 req) | 4 concurrent TTFT | 4× decode each | 4× aggregate |
|---|---:|---:|---:|---:|---:|---:|
| **Strim / mlx-vlm + MTP** | ~10 s | ~7.7 s* | **33.3 tok/s** | — | — | — |
| Strim / mlx-vlm, no MTP | ~10 s | ~7.7 s* | 17.2 tok/s | — | — | — |
| **rapid-mlx 0.15.7** | 13.7 s | **2.6–5.0 s** | 17.4–17.8 tok/s | 18.3 s | **16.0 tok/s** | **19.5 tok/s** |
| oMLX 0.4.5.dev1 | 1.6 s (lazy) | 12.7 s | 16.2 tok/s | 15.1 s | 3.7 tok/s | 8.9 tok/s |
| TensorFold 1.0.12 | 10.6 s | 14.3 s | 16.1 tok/s | 54.4 s | 14.5 tok/s | 8.1 tok/s |

\* our TTFT is derived from prefill throughput (4,108 tokens / 532 tok/s), not measured at the HTTP
layer; the concurrency columns are **not available** for our stack — it is a CLI/one-request process.

Notes:

- The 4-concurrent runs use **distinct prompts** (a unique marker per request) so prefix caching
  cannot help. With four *identical* prompts, rapid-mlx reached **61 tok/s aggregate** and 0.5 s
  TTFT — a real batching + prefix-cache win, but not a realistic multi-agent workload.
- The oMLX number is the offline 0.4.5 build. oMLX 0.7.1 reports 45 tok/s for this model at 1 k
  context with MTP on a 128 GB machine, so treat 0.4.5 as a floor for oMLX, not its ceiling.
- TensorFold's high TTFT is prefill, not queueing: 4 k / 14.3 s ≈ 287 tok/s, versus 1,560 tok/s for
  rapid-mlx.

---

## 2. What the numbers mean

**Decode is a bandwidth wall, and MTP is the only way through it.** Every engine lands at 16–18 tok/s
for 8-bit, because 29.5 GB / 515 GB/s = 17.4 tok/s. MTP verifies several drafted tokens per weight
read, which is why we get 33.3. This is the one place we already beat every competitor by ~2×, and it
is independent of engine maturity.

**Prefill is where we are losing.** rapid-mlx does 4 k prefill in 2.6 s (≈1,560 tok/s) against our
7.7 s (532 tok/s) and oMLX's 12.7 s (324 tok/s). That is a 3× gap on the metric that dominates agent
wall time: a 30 k-token repo context is 19 s vs 58 s. Prefill is compute-bound, and rapid-mlx is
using the M5's tensor units; our mlx-vlm path is not. This must be fixed before any claim of
"fastest for agents".

**Concurrency does not multiply throughput for a single dense model — it preserves per-user speed.**
With 4 distinct 4 k requests, rapid-mlx keeps ~16 tok/s per request (near its 17.4 serial number) and
reaches only 19.5 tok/s aggregate, because the wall is prefill (4 × 5 s) and the 128-token decode
windows barely overlap. With identical prompts (prefix cached) it reached 61 tok/s aggregate: batch
decode reuses one weight read across sequences. So:

- **Batch decode is a real win**: N sequences share the weight read, so N users can each keep most of
  serial decode speed until compute saturates.
- **Prefill is the bottleneck** for multi-agent use: it must be batched/chunked, or agents will queue
  behind each other.
- **Aggregate throughput cannot exceed ~17.4 tok/s of decode for 8-bit**, no matter how many requests;
  6-bit lifts that to ~23, 4-bit to ~33.

**Nobody has real priority scheduling.** rapid-mlx exposes `--scheduling-policy
{fcfs,shortest_validated_tail}`, but that is queue ordering, not preemption. A foreground request
arriving behind three background agents waits for their prefill. That is the gap we can own: two
classes (interactive, background) with token-level preemption and a reserved decode slot.

---

## 3. Implications for the plan

The v1 scope in [PLAN-v1.md](PLAN-v1.md) is single-session. That is no longer enough — the product
must answer "one user" and "several agents" without lying about speed. Add:

1. **Continuous batching, 2–4 sequences** (Phase 2, not Phase 4). Target: 4 distinct 4 k requests
   each at ≥80% of serial decode, aggregate ≥3× serial while prefill is shared.
2. **Prefill at ≥1,200 tok/s** (Phase 1–2). Port the NAX path (or use MLX's `mx.compile` + larger
   prefill chunks) until 4 k TTFT ≤3 s. This is the single largest user-visible gap.
3. **Priority classes**: interactive requests get a reserved slot and preempt background decode at
   token boundaries; background work uses the remaining slots. Measure foreground TTFT under 3
   background streams — target ≤1.5× its idle TTFT.
4. **Prefix cache is mandatory**, not an optimization: agents resend the same repo context every turn.
5. **Quality stays the constraint**: all of the above on 6-bit graded + MTP, with the 24-task bake-off
   unchanged.

This makes the engine a small continuous-batching server, not a one-shot CLI wrapper. It also means
the Swift runtime needs a real scheduler and paged KV from the start rather than a single cache.

---

## 4. Next measurements

| # | Test | Why |
|---|---|---|
| C1 | oMLX 0.7.1 (wheel already cached) + MTP, 4 k/16 k, 1 and 4 requests | the real oMLX competitor, not 0.4.5 |
| C2 | rapid-mlx with 6-bit and 4-bit checkpoints | see how the bar moves with quant |
| C3 | llama.cpp + GGUF Q4_K_M/Q6_K (needs a ~17–23 GB download) | the most popular Mac option |
| C4 | Ollama with the same GGUF | the default user choice |
| C5 | Foreground-vs-background priority on rapid-mlx and our engine | prove or disprove the priority gap |
| C6 | Prefill-only sweep: chunk size, `mx.compile`, NAX on/off | close the 3× gap |

Until C1–C4 exist, the honest claim is: **fastest single-stream decode on this machine (2×), but
behind on prefill and without multi-session serving.**

---

## Correction (2026-10-25, after user challenge): the first table compared default configs

The first comparison used stock `mlx-community` 8-bit and each engine's defaults. That is fair for
"what a new user gets", but it is **not** what the published high-speed numbers use. Re-measured at
1 k context:

| Engine / config | Decode | TTFT | Note |
|---|---:|---:|---|
| rapid-mlx 0.15.7, stock 8-bit | 18.8 tok/s | 0.89 s | no speculation; ~1,150 tok/s prefill |
| oMLX 0.7.1, stock 8-bit, defaults | 18.9 tok/s | 4.08 s | no MTP, no ANE |
| oMLX 0.7.1, `mtp_enabled=true`, ANE prefill on | 18.8 tok/s | **36.2 s** | MTP weights absent from this checkpoint, so no draft; ANE cold-compiles on first requests |
| **Strim, 8-bit + MTP-8** | **35.4 tok/s** | ~2.7 s | matching drafter |
| **Strim, 4-bit + MTP-4** (4 k) | **51.1 tok/s** | ~5.7 s | matching drafter |

What this means:

1. **The 17–19 tok/s numbers are physics, not a broken harness.** 29.5 GB / 515 GB/s = 17.4 tok/s.
   Every engine lands there when it reads the full 8-bit weights once per token without speculation.
   Our own 8-bit baseline (17.2) sits exactly on that line.
2. **The published 45.2 tok/s for oMLX on 27B 8-bit is a different configuration**: 128 GB M5 Max,
   oMLX's own MTP-enabled checkpoint and recipe, ANE prefill enabled, short context. It is not
   reproducible by pointing stock oMLX at a stock checkpoint on 64 GB. Enabling the toggles on a
   checkpoint without MTP weights does nothing for decode and makes the first TTFT worse (ANE compile).
3. **Like-for-like, our MTP stack is ahead**: 35.4 vs 18.8–18.9 at 8-bit, and 51.1 at 4-bit.
   But **prefill we still lose**: rapid-mlx ~1,150 tok/s at 1 k, oMLX ~250 default / ~800 with ANE warm;
   ours 387 at 1 k and 532–741 at 4 k.
4. To make the oMLX comparison truly apples-to-apples we need its own MTP checkpoint
   (`jundot/Qwen3.8-27B-oQ8e-mtp` or similar). The repo API returned 307 earlier; confirm access,
   then run the same 1 k/4 k protocol. That is the open test, not a conclusion.

**Honest status:** fastest single-stream decode measured on this machine with the same stock
checkpoint; prefill behind rapid-mlx; concurrency still unbuilt; oMLX's own-checkpoint number unverified.

---

## Where the "100+ tok/s" numbers come from (verified on this machine, 2026-10-25)

The user's memory is correct — but it belongs to the MoE, not the dense 27B.

Measured here, stock checkpoints, prefill-step 2048:

| Model | Quant | Engine | Context | Decode | Prefill | Peak |
|---|---|---|---:|---:|---:|---:|
| **Qwen3.6-35B-A3B (3B active)** | 4-bit | mlx-vlm | 1 k | **129.3 tok/s** | 4,127 | 21.6 GB |
| **Qwen3.6-35B-A3B** | 4-bit | mlx-vlm | 4 k | **127.4 tok/s** | 5,327 | 22.4 GB |
| Qwen3.8-27B (dense) + MTP-4 | 4-bit | mlx-vlm | 4 k | 57.7 tok/s | 1,000 | 19.5 GB |
| Qwen3.8-27B + DFlash2 (z-lab, 3.85 GB) | 4-bit | mlx-vlm | 1 k | 54.6 tok/s | 919 | 21.9 GB |

So on this exact machine: **129 tok/s is real for a 35B-A3B at 4-bit** — 3B active parameters, 21.6 GB,
no speculation needed. That is the "much faster" memory. The dense 27B cannot get there without a
purpose-built stack.

Published dense-27B 100+ numbers are conditional:

- **101.7 tok/s** on M5 Max 64 GB — LM Studio "Splash" package: stock `mlx-community` 4-bit target +
  `incoai` DFlash2 drafter, short code task (llm-bench, 2026-10-14). One measured run; median across
  13 M5 Max runs in that dataset is 73.1.
- **102 short / 90.9 @16k** — MTPLX with MTP depth 3 on M5 Max.
- **162–226 @2k** — TensorFold + DFlash2 on M5 Ultra (not 64 GB).
- **45–72** — oMLX's own oQ4e/oQ6e/oQ8e **MTP checkpoints**, not stock mlx-community weights.
- At 32k+ every dense stack falls to ~54–120.

Our DFlash2 test (54.6) used the generic z-lab drafter, not Splash's tuned package, so it matches MTP
rather than beating it. Reproducing 100 on the dense model needs the Splash/MTPLX recipe, which we
have not validated.

**Product implication:** the honest speed story on this machine is two modes — **A3B 4-bit at ~127
tok/s** for throughput/agents, **27B 4-bit + MTP at ~58 tok/s** for quality. Both fit in 64 GB
(19 GB + 16 GB weights), so they could both stay resident with an instant switch, at the cost of a
smaller KV budget.

## Update 2026-10-26: Swift prefill and admission priority

This file's competitor table is the product stack (rapid-mlx / mlx-vlm). Two claims have moved:

- **Prefill.** The Swift engine's prefill was 251–266 tok/s at 512–1024; after the fused GDN
  recurrence took over prefill it is **750–840 tok/s at 1k/4k**. That is still behind
  rapid-mlx's ~1,150–1,560, but the Swift path is now above the mlx-vlm product number in this
  table (532) rather than far below it. The remaining gap is MLX qmm compute: the measured
  38–55 TFLOP/s puts a ~890 tok/s roofline on this machine at 4-bit, so 1,200+ needs a faster
  matmul, not scheduling.
- **Priority.** `strimd` now takes its admission slot **before** the upstream request (it used
  to send first and gate only the relay, which made priority cosmetic), and gates are
  per-backend with capacity matching `--max-num-seqs` (speed 4, quality 2, background capped at
  1). This is still *admission* priority, not mid-token preemption: a background request already
  in rapid-mlx's batch competes for GPU. The "nobody has real priority scheduling" claim above
  should be read as "nobody has preemption"; the router does have two-class admission now.
  Measured with 3 background + 1 interactive on the speed backend: interactive slot wait
  **0.0 s**, background total wait **2.57 s** (`/v1/strim/status` → `priority.strim-speed`).

The Swift engine itself still has no server, continuous batching or KV paging — that boundary is
unchanged.

## 2026-10-26 measured matrix, 4-bit Qwen3.8-27B, 4K prompt, 64 generated

Same machine, same `models/qwen38-4bit`, OpenAI streaming via the same (retired) harness; decode is
completion tokens / (total - TTFT), concurrent uses four distinct prompts.

| engine | prefill | 4K TTFT | 4K decode | short-corpus decode | 4 distinct 4K aggregate |
|---|---:|---:|---:|---:|---:|
| **Strim Swift + MTP** | **915 tok/s** (4.48 s) | 4.48 s | **46.1** | **55.1** | **7.1** serial-prefill; **41.9** with shared 4K prefix |
| rapid-mlx 0.15.7 4-bit + MTP | **963** (4.26 s) | 4.26 s | 45.5 | 49.5 | 15.9 (cache-assisted); **12.4 cold** |
| TensorFold 1.0.12 4-bit | 958 (4.29 s) | 4.29 s | 28.9 | — | 13.1 |
| mlx-lm 4-bit | 853 (4.82 s) | 4.82 s | 32.2 | — | 12.0 |
| oMLX 0.6.1, 128 GB, oQ4e + MTP + ANE (published) | 718 | 5.7 s | 60.2 | — | 4× batch **92** |
| TensorFold 1.0.12 8-bit (old run) | 287 | 14.3 s | 16.1 | — | 8.1 |
| oMLX 0.4.5 8-bit (old run) | 324 | 12.7 s | 16.2 | — | 8.9 |

Notes:
- The rapid-mlx MTP serial run reported TTFT 0.191 s because its prefix cache had the 4K prompt
  from the immediately preceding cold run; the cold TTFT is 4.26 s from the target-only run.
- oMLX's 60.2/92 numbers are a 128 GB 40-core M5 Max benchmark (oQ4e, MTP, ANE prefill), not
  reproduced on this 64 GB machine yet.
- Strim's 4K code decode (46.1) is lower than its short-corpus 55.1 because the 4K prefill seed
  and attention/RoPE change acceptance; rapid-mlx is 45.5 at 4K.
- Prefill is close: rapid/TensorFold ~4.26-4.29 s, Swift 4.48 s. Decode short is Swift's win;
  concurrent aggregate is oMLX's win (MTP inside a batch).

What must be beaten:
1. **Prefill**: 4.26 s / 963 tok/s (rapid, TensorFold). Swift is 5% behind.
2. **Single 4K decode**: rapid 45.5, oMLX 60.2 (published). Swift 46.1.
3. **Concurrency**: oMLX 4× 92 tok/s aggregate (published). Swift scheduler is 51.9 at 32
   tokens and not yet measured at 4K; rapid is 15.9 at four distinct 4K prompts.
