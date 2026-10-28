# Batched decode core: 2–4 sequences (2026-10-26)

`BatchModel` / `BatchedAttention` / `DecoderLayer.forwardBatched` add a lockstep batched
decode path to the Swift engine. It is the concurrency core, not a full server: prompt
lengths may differ (padded KV + per-sequence mask), decode is lockstep, and there is no MTP
or scheduler/preemption yet.

## Measured (loaded machine, 32-token prompts, differing lengths, 8 decode steps, greedy, no MTP)

| sequences | sequential aggregate | batched aggregate | batched per-request | token match |
|---:|---:|---:|---:|---|
| 2 | 28.1 tok/s | **48.8** | 24.4 | yes |
| 3 | 27.1 | 63.5 | 21.2 | yes |
| 4 | 27.8 | **74.9** | 18.7 | yes |

“Sequential” is the same number of single-sequence forwards, timed in the same process;
“batched” is one `BatchModel.forward` per step with shared weights. Aggregate is
**1.75× / 2.34× / 2.86×** the sequential aggregate. Single-sequence non-spec decode in
this run was ~13.5 tok/s (loaded machine); batched per-request is higher because the
weight read is amortised across the batch.

## Correctness

Batched logits differ from single-sequence logits by **max 0.156–0.453** (qmm M>1 tiling
plus KV padding/mask), but greedy token sequences matched over all tested steps and prompts. This is the expected arithmetic change for batching; the quality gate for a
serving path must compare tokens on a broader corpus, not just the 8-step smoke.

## What is implemented

- `BatchedAttentionCache` / `BatchedModelCache`: per-sequence KV (different lengths) with front padding + mask, and stacked GDN state.
- `Attention.forwardBatched` (per-sequence RoPE, SDPA over stacked KV).
- `GDN.forward` uses the tensor recurrence for B>1; the fused decode kernel is B=1-only.
- `GDN` conv falls back to `depthwise`+`silence` for B>1 (the conv kernel is B=1-only).
- `BatchModel.forward` one token per sequence, returns `[B,1,vocab]`.
- `strim benchbatch <model> <prompt-len> <steps> [2..4]`.

## Continuous-batching scheduler prototype (2026-10-26)

`strim benchserve <model> <requests> <maxTokens> [slots]` adds a token-boundary
scheduler: requests are prefilled serially, then decode in a batched loop; finished
requests are removed and new ones are admitted into freed slots. Prompt lengths differ.

Loaded machine, 8 requests, 16 tokens, greedy, no MTP:

| slots | sequential aggregate | batched aggregate | per-request decode | mean TTFT | tokens match |
|---:|---:|---:|---:|---:|---|
| 2 | 23.5 tok/s | **35.8** | 22.1 | 2392 ms | yes |
| 4 | 23.4 | **51.9** | 16.6 | 2023 ms | yes |

With admission priority (`mix=1`, half the requests background):

| slots | aggregate | interactive TTFT | background TTFT | tokens match |
|---:|---:|---:|---:|---|
| 2 | 38.3 tok/s | **1291 ms** (4) | 3251 ms (4) | yes |
| 4 | 54.6 | **1218 ms** (4) | 2636 ms (4) | yes |

The scheduler admits waiting interactive requests before background ones, stops a
sequence at EOS (248044/248046) or its token budget, and removes it. It is admission
priority, not mid-token preemption: a background request already in the batch keeps its
slot until it finishes. TTFT is from request arrival and includes queueing; prefill is
serial and decode is batched. This is a scheduler prototype, not an HTTP server; no MTP.

## 4K concurrency is prefill-bound (2026-10-26)

`benchserve <model> 4 16 4 0 4096` (four distinct 4K prompts, 16 tokens):
sequential 21.8 s / 3.3 tok/s aggregate; batched scheduler 22.5 s / 3.2 tok/s, mean TTFT 22.4 s.
The scheduler prefills serially, so four 4K prefills cost ~4 x 5.45 s; batched decode cannot
recover that. rapid-mlx's 15.9 aggregate on four distinct 4K prompts was **cache-assisted**: its radix cache
matched 4096 tokens on two of the four requests despite the distinct markers. With the cache
disabled, rapid-mlx is 18.1 s TTFT / **12.4 aggregate** at 64 tokens, 38.0 decode serial. The
Swift scheduler at the same 64-token budget is 37.3 s wall / **7.1 aggregate** (4 slots); the
gap is prefill serialization plus the copy-based 4K KV path, not a 5x decode gap. Batched or
chunked prefill and a preallocated KV cache are the next scheduler requirements; the 32-token
numbers (35.8/51.9) do not transfer to agent-length contexts. Token parity also differs at 4K (first token near-tie), as with the
blocked GDN prefill.

## Shared-prefix benchmark (2026-10-26)

`benchserve ... 4096 1` warms one 4K prefix and gives four requests unique 16-token suffixes:
4K scheduler wall 6.30 s / **41.9 aggregate** (11.2 per request) after 4.51 s prefix warm;
including warm, 23.7 aggregate. Serial-prefill no-prefix is 7.1. Not yet token-exact; see
[PREFIX-CACHE-2026-10-26.md](PREFIX-CACHE-2026-10-26.md).

## Not implemented yet

- **HTTP server**: the scheduler is a CLI benchmark. EOS, priority admission and
  join/leave are in place; there is no HTTP surface or mid-token preemption.
- **MTP/speculation inside a batch**: each sequence needs its own MTP state and draft
  verification; the current batch path is non-speculative, so per-request speed is below
  the single-sequence MTP path.
- **Scheduler / preemption / priority** and an HTTP server around it.
- **Long-context batch** (>4K) and KV memory accounting.

## Next

1. Add per-sequence offsets/padding to the KV cache and a mask so prompts of different
   lengths can join; then a step scheduler (admit/evict at token boundaries).
2. Add speculative decode per sequence: draft on the MTP head (or a shared draft batch),
   verify the batch, roll back per sequence.
3. Match the product rapid-mlx concurrency measurement (2/4 requests, aggregate and
   per-request, same prompts) and keep the admission gate for priority.
