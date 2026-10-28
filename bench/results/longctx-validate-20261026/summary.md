# Long-context validation of blocked GDN prefill (2026-10-26)

Binary `.build/release/strim` (not rebuilt). Model `models/qwen38-4bit`, MTP head `models/qwen38-mtp-4bit`.
Prompts: natural repo prose, Qwen tokenizer, disjoint windows (tokenization script removed 2026-10-27 (see `strim tokenize`); `prompts.json` has previews).
Greedy 16 tokens via `logithash` (default blocked/compiled; `STRIM_GDN_BLOCKED=0` serial fused kernel;
`STRIM_GDN_METAL_MAX_S=8` tensor recurrence for prefill only, decode S<=8 unchanged). Driver: `run.sh`.

| prompt | tokens | determinism (2 default runs) | first token default / serial / tensor | 16-tok agree default vs serial | default vs tensor |
|---|---:|---|---|---:|---:|
| p4k_a | 4096 | yes | 310 / 310 / 310 (agree) | 16/16 (100%) | 14/16 (88%) |
| p4k_b | 4096 | yes | 220 / 220 / 220 (agree) | 16/16 (100%) | 16/16 (100%) |
| p4k_c | 4096 | yes | 4487 / 4487 / 4487 (agree) | 16/16 (100%) | 16/16 (100%) |
| p4k_d | 4096 | yes | 364 / 364 / 364 (agree) | 6/16 (38%) | 16/16 (100%) |
| p4k_e | 4096 | yes | 23 / 23 / 23 (agree) | 4/16 (25%) | 4/16 (25%) |
| p1k_a | 1024 | yes | 25 / 25 / 25 (agree) | 16/16 (100%) | 16/16 (100%) |
| p1k_b | 1024 | yes | 469 / 469 / 469 (agree) | 16/16 (100%) | 16/16 (100%) |
| p1k_c | 1024 | yes | 16 / 16 / 16 (agree) | 16/16 (100%) | 16/16 (100%) |

First-token disagreement where default differs from both others: none (8/8 agree).

Divergence points (all at bf16 near-ties; logits are printed bf16-rounded):
- p4k_a: default vs tensor diverges at generated token 14; default top1 margin 0.000 (exact tie). Serial and default agree.
- p4k_d: default vs serial diverges at token 6; default margin 0.125. Default and tensor agree.
- p4k_e: default diverges from serial AND tensor at token 4; margin 0.000. Serial and tensor agree 16/16 with each other. Not a first-token defect, but it is the one pattern to chase (see below).

Spec-vs-greedy parity (`benchspec ... 32 2 <ids> 1`):
- p4k_a: MISMATCH, first diff at generated token 14 (spec 874, greedy 279; the tensor path also picks 874 there).
- p4k_c: MISMATCH, first diff at generated token 18.
- Not EXACT at 4K (2/2). Same as HANDOFF 5.1 note; this run does not confirm EXACT.

Limits and caveats:
- Top-5 overlap and logit gaps not available: `logithash` prints top-2 only, `logits` uses fixed tokens. No mode exposes top-5 for arbitrary ids; not added (Sources untouched).
- `logithash` printed `tok` column is stale from step 1 on (one token behind). All comparisons above use the `top1` column, which matches `benchspec` greedy (checked on p4k_a).
- Greedy-16 agreement is positional over 16 tokens; a single bf16 tie flips everything after it.
