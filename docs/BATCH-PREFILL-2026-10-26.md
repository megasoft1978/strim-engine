# Batched prefill experiment — negative at 4K (2026-10-26)

Goal: raise 4K concurrent prefill above the serial scheduler by prefilling B sequences together.

Implemented `BatchModel.prefill` (chunked at 1024 tokens), a causal SDPA shortcut for equal-length
empty-cache prefill, and B>1 support in the blocked GDN kernel. `strim benchbatchprefill` measures
serial vs batched prefill on equal-length prompts.

| B | S | serial | batched | speedup | next-token match |
|---:|---:|---:|---:|---:|---|
| 2 | 1024 | 772 tok/s | 880 | 1.14x | no |
| 4 | 1024 | 839 | 874 | 1.04x | no |
| 2 | 4096 | 857 | 823 | 0.96x | no |
| 4 | 4096 | 867 | 822 | 0.95x | no |

At 4K the batched path is slower: the attention mask/SDPA and the growing KV dominate, and qmm at
M=4096-16384 does not recover it. Next-token match is also not exact because the batch changes qmm
tiling (same caveat as batched decode). Not adopted for serving. Raw log:
`bench/results/batchprefill-20261026/log`.

The scheduler still prefills serially. Rapid-mlx's 4-concurrent 4K TTFT (13.5 s) remains
unexplained by this experiment; its advantage is more likely chunked prefill overlapped with
decode and/or a more efficient batched attention path, not plain B-way qmm. Next attempt:
per-sequence chunked prefill with a shared qmm across active sequences (not a full B x S
attention), or MTP batching for decode first.
