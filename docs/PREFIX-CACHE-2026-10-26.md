# Shared-prefix cache: 4K concurrency 7.1 -> 41.9 tok/s (2026-10-26)

Agent requests resend the same repo/system context. `benchserve` now has a prefix mode
(`... <ctx> 1`): it warms one shared prefix once, then four requests share that prefix and
carry a unique 16-token question suffix.

## Results

| workload | prefix warm | scheduler wall | aggregate | per-request |
|---|---:|---:|---:|---:|
| 4 requests, 1K prefix, 16 tokens | 1.19 s | 1.41 s | **51.2** | 16.8 |
| 4 requests, 4K prefix, 64 tokens | 4.51 s | 6.30 s | **41.9** | 11.2 |
| 4 requests, 4K, no prefix (serial prefill) | — | 37.3 s | 7.1 | 2.8 |

For 4K, **41.9 aggregate excluding prefix warm, 23.7 including it** — above rapid-mlx's
cold 12.4 and cache-assisted 15.9 on the same four-request/64-token workload. Prefix warm is
paid once per shared context and amortised over every later turn of a session.

## Caveat

Greedy tokens do not match the sequential full-prefill baseline (first token 12 vs 1234 in
the 4K run). The shared prefix is prefilled once and each suffix is a separate forward
(plus batch qmm tiling), so the arithmetic is not the same as one 4K prefill. This is the
known long-context/prefill-split issue, not a repeat of the earlier lengths bug. The mode is
a scheduler benchmark prototype, not a production path, until token parity and a radix/LCP
cache are implemented.

## Implementation

`strim benchserve <model> <requests> <maxTokens> [slots] [mix] [ctx] [prefixMode]`
warms a `ModelCache` over the shared prefix (`ctx-16` tokens), snapshots it, and each
admission starts from `snapshot()` and prefills only its unique suffix. No eviction, no
longest-common-prefix matching, no paged KV yet.

Raw log: `bench/results/prefix-cache-20261026/log`.
