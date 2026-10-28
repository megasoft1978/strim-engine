# GDN prefill: why it is slow and the blocked-scan plan (2026-10-26)

## The gap, with evidence

`rapidmlx.server.log` (local run log, not committed) shows two concrete advantages in the product engine:

```
[gdn_prefill] blocked-seq GDN prefill kernel installed (prompt>=64 tokens, Dk=128)
[cache_fetch] HIT prompt_tokens=4108 cached=4093 remaining=15
```

rapid-mlx has a **blocked-sequence GDN prefill kernel**. Our prefill uses `GDNMetal.run`, one
state row per threadgroup with a **serial loop over all S tokens**. At 4K that GDN share is
~30% of the pass (~1.5 s of 4.9 s). The same log shows that repeated prompts hit a radix
prefix cache and only prefill 15 tokens; any prefill/tok-s number that includes a warm hit is
not comparable to `strim benchprefill`, which is cold-cache.

Measured qmm throughput at M=4096 (this machine): bf16 GEMM 62.9 TF/s, affine 4-bit qmm
57.5, 6-bit 53.4, 8-bit 54.6, MXFP4 56.8. So the gap is not the quantisation; it is the
serial GDN prefill and graph/engine differences. A 4K prefill at 100% bf16 GEMM is ~1,170
tok/s, which is why 1,200 is at/above the hardware edge.

## The blocked recurrence, derived and validated

Per head, per token (matching `GDN.recurrenceMM`):

```
S_t = g_t S_{t-1} + delta_t k_t^T
delta_t = beta_t (v_t - g_t S_{t-1} k_t)
y_t = S_t q_t
```

For a chunk of C tokens from state S0, with `P_t = prod_{i<=t} g_i` and
`d_{j,t} = P_t / P_j = prod_{i=j+1..t} g_i`:

```
A[t,j] = beta_t d_{j,t} (k_j . k_t),  j < t        (strictly lower)
rhs[t] = beta_t (v_t - P_t (S0 k_t))
(I + A) delta = rhs
y_t = P_t (S0 q_t) + sum_{j<=t} d_{j,t} (k_j . q_t) delta_j
S_C = P_{C-1} S0 + sum_j d_{j,C-1} delta_j k_j^T
```

A NumPy prototype against the token loop matches to `y 4.5e-08`, `S 3.0e-08` (Hv=3,
D=8, C=5). The expensive part is the triangular solve `(I+A)^{-1}`.

## The MLX blocker

`mlx.linalg.tri_inv` / `inv` are **not supported on the GPU** in MLX 0.32.x:

```
[linalg::inv] This op is not yet supported on the GPU. Explicitly pass a CPU stream.
```

A CPU stream per chunk/layer would serialise and dominate. Options:

1. **Custom Metal blocked kernel** — one threadgroup per (head, chunk), state in registers,
   forward substitution over C steps in threadgroup memory, `K K^T`/`Q K^T` and the state
   update with simdgroup matrix ops. This is the real fix and the only one likely to reach
   ~1,000+ tok/s. It is a focused kernel project, not a tuning pass.
2. **Small-C unrolled tensor path** — C=8/16, explicit forward substitution with MLX ops.
   The graph becomes thousands of small ops per layer; unlikely to beat the serial kernel,
   useful only as a correctness stepping stone.
3. **CPU triangular solve** — rejected; transfers and serialisation.

Expected if (1) works: GDN 1.5 s → ~0.3–0.5 s at 4K, prefill ~825 → ~1,000–1,100 tok/s.
That is the ceiling; 1,200 remains above the measured bf16 GEMM roofline (~1,170).

## Next

1. Implement (1) as `gdn_prefill_blocked` for S > 8, keep the existing kernel for decode.
2. Validate against `GDN.recurrenceMM` on random tensors, then against `gen 16`/depth-0
   tokens; prefill hidden differences must not change the corpus EXACT set.
3. Measure cold 4K prefill, not warm-cache.
4. Prefix cache is separate and only matters if the Swift engine becomes the server; the
   product already has it.
