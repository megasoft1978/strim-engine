# screen summary

Generated 2026-10-26T17:01:56 from raw.jsonl. Medians of valid rows, min-max in parens; n = valid rows. Cold rows (S2, S3) with any cache hit are excluded (labeled hit). Prefill = prompt_tokens / (TTFT - one decode step), one decode step = 1/decode_tps of the same row; plain prompt_tokens/TTFT is in the S2 table. Verdict uses the adjusted prefill (Strim: its benchprefill time has no decode step, so plain). Rules: CONTENDER if decode >= 0.85x best AND prefill >= 0.85x best (best over all measured rows incl. Strim), or ahead of Strim on decode or prefill; BEHIND otherwise; NOT COMPARABLE if S1/S2 missing or a different checkpoint. Token check: HTTP engines must give the same prompt_tokens and completion_tokens for the same prompt, else MISMATCH.

## S1 decode (64 tok, greedy, 3 prompts x 2 reps; rapid-mlx and strim use MTP; thinking disabled for HTTP)

| engine | decode tok/s median (min-max) | n | TTFT s median (non-warm) | cache | token flags | token check | verdict | reason |
|---|---|---|---|---|---|---|---|---|
| strim | 61.7 (42.9-65.1) | 3 | n/a | none (in-process) | ok | n/a (raw ids) | REFERENCE | in-process reference row; method differs from HTTP rows |
| rapid-mlx | 47.3 (46.1-51.8) | 6 | n/a | hit | ok | match | CONTENDER | prefill 1000.2 > Strim 932.5 (margin 7.3%) |
| mlx-lm | 33.0 (32.9-33.0) | 6 | 0.4 (0.3-0.4) | hit,zero | ok | match | BEHIND | decode 33.0 vs best 65.1; prefill 913.9 vs best 1003.1 |
| tensorfold | 30.1 (29.9-30.1) | 6 | 0.1 (0.1-0.2) | zero | ok | match | CONTENDER | prefill 994.8 > Strim 932.5 (margin 6.7%) |
| mlx-vlm | n/a | 0 | n/a | unknown | retokenized | unverified (no usage prompt_tokens) | NOT COMPARABLE | S1 decode not measurable: stream timing bursty (>400 tok/s rejected) |
| omlx | 33.5 (33.4-33.6) | 6 | 0.4 (0.4-0.5) | zero | ok | match | NOT COMPARABLE | different checkpoint (qwen38-oq4e-mtp); numbers shown for context only |
| llama.cpp/ollama | n/a | 0 | n/a | ? | ? | unverified (no usage prompt_tokens) | NOT COMPARABLE | not run: no local GGUF |

## S2 cold prefill (4K distinct per rep, 16 tok, 2 reps; strim: synthetic 4K, fresh cache, no decode)

| engine | prefill tok/s adj median (min-max) | n | plain prompt/TTFT tok/s median | TTFT s median | cache | warm excluded | cold assert | verdict |
|---|---|---|---|---|---|---|---|---|
| strim | 932.5 (928.0-937.0) | 2 | 932.5 (928.0-937.0) | 4.4 (4.4-4.4) | none (in-process, fresh ModelCache) | 0 | n/a | REFERENCE |
| rapid-mlx | 1000.2 (997.3-1003.1) | 2 | 994.8 (991.9-997.7) | 4.1 (4.1-4.1) | unknown | 0 | PASS no cached_tokens field; no cache-hit log lines (unverified from usage) | CONTENDER |
| mlx-lm | 913.9 (913.8-914.1) | 2 | 907.6 (907.4-907.8) | 4.5 (4.5-4.5) | zero | 0 | PASS cached_tokens=0 | BEHIND |
| tensorfold | 994.8 (994.8-994.8) | 1 | 986.4 (986.4-986.4) | 4.2 (4.2-4.2) | hit,zero | 1 | FAIL cached_tokens=3; PASS cached_tokens=0 | CONTENDER |
| mlx-vlm | n/a | 0 | n/a | n/a | unknown | 0 | PASS no cached_tokens field; no cache-hit log lines (unverified from usage) | NOT COMPARABLE |
| omlx | 875.2 (873.1-877.4) | 2 | 870.6 (868.4-872.7) | 4.7 (4.7-4.7) | zero | 0 | PASS cached_tokens=0 | NOT COMPARABLE |
| llama.cpp/ollama | n/a | 0 | n/a | n/a | n/a | 0 | n/a | NOT COMPARABLE |

## S3 concurrency (4 x ~1K distinct cold, 32 tok, 1 run)

| engine | aggregate tok/s | wall s | per-req TTFT s median | per-req decode tok/s median | cache | cold assert | flags |
|---|---|---|---|---|---|---|---|
| strim | 17.8 | 6.24 | n/a (strim records end-to-end latency: mean 5.84 s) | 10.0 (mean) | none (prefix mode off) | n/a | in-process means only |
| rapid-mlx | 23.1 | 5.55 | 4.35 | 25.8 | unknown | PASS no cached_tokens field; no cache-hit log lines (unverified from usage) | ok |
| mlx-lm | 19.8 | 6.46 | 4.90 | 20.0 | unknown | PASS cached_tokens=0 | ok |
| tensorfold | 21.2 | 6.03 | 2.69 | 9.5 | hit | FAIL cached_tokens=3 | ok |
| mlx-vlm | 14.3 | 8.98 | 5.61 | n/a | unknown | PASS no cached_tokens field; no cache-hit log lines (unverified from usage) | ok |
| omlx | 18.5 | 6.91 | 5.06 | 17.6 | unknown | PASS cached_tokens=0 | ok |
| llama.cpp/ollama | n/a | n/a | n/a | n/a | n/a | n/a | not run: no local GGUF |

## S4 quality proxy (greedy text; rep 1 of S1, plus S2 rep 1 as extra)

CHEAP PROXY ONLY. Strim has no text reference (its CLI prints greedy ids only on MISMATCH). HTTP engines use the same chat template and the same token counts (see token check). A pair is compared only when both outputs are valid: no error, not empty. Invalid outputs are reported as errors, never as identical.

| engine | vs | prompt | status | common prefix chars | longer len | identical |
|---|---|---|---|---|---|---|
| rapid-mlx | mlx-lm | code | ok | 265 | 265 | yes |
| rapid-mlx | mlx-lm | natural | ok | 315 | 315 | yes |
| rapid-mlx | mlx-lm | json | ok | 190 | 190 | yes |
| rapid-mlx | mlx-lm | 4K-distinct | ok | 84 | 84 | yes |
| rapid-mlx | tensorfold | code | ok | 265 | 265 | yes |
| rapid-mlx | tensorfold | natural | ok | 315 | 315 | yes |
| rapid-mlx | tensorfold | json | ok | 190 | 190 | yes |
| rapid-mlx | tensorfold | 4K-distinct | ok | 84 | 84 | yes |
| rapid-mlx | mlx-vlm | code | ok | 265 | 265 | yes |
| rapid-mlx | mlx-vlm | natural | ok | 315 | 315 | yes |
| rapid-mlx | mlx-vlm | json | ok | 190 | 190 | yes |
| rapid-mlx | mlx-vlm | 4K-distinct | ok | 84 | 84 | yes |
| rapid-mlx | omlx | code | ok | 85 | 265 | no |
| rapid-mlx | omlx | natural | ok | 34 | 315 | no |
| rapid-mlx | omlx | json | ok | 190 | 190 | yes |
| rapid-mlx | omlx | 4K-distinct | ok | 0 | 84 | no |
| mlx-lm | tensorfold | code | ok | 265 | 265 | yes |
| mlx-lm | tensorfold | natural | ok | 315 | 315 | yes |
| mlx-lm | tensorfold | json | ok | 190 | 190 | yes |
| mlx-lm | tensorfold | 4K-distinct | ok | 84 | 84 | yes |
| mlx-lm | mlx-vlm | code | ok | 265 | 265 | yes |
| mlx-lm | mlx-vlm | natural | ok | 315 | 315 | yes |
| mlx-lm | mlx-vlm | json | ok | 190 | 190 | yes |
| mlx-lm | mlx-vlm | 4K-distinct | ok | 84 | 84 | yes |
| mlx-lm | omlx | code | ok | 85 | 265 | no |
| mlx-lm | omlx | natural | ok | 34 | 315 | no |
| mlx-lm | omlx | json | ok | 190 | 190 | yes |
| mlx-lm | omlx | 4K-distinct | ok | 0 | 84 | no |
| tensorfold | mlx-vlm | code | ok | 265 | 265 | yes |
| tensorfold | mlx-vlm | natural | ok | 315 | 315 | yes |
| tensorfold | mlx-vlm | json | ok | 190 | 190 | yes |
| tensorfold | mlx-vlm | 4K-distinct | ok | 84 | 84 | yes |
| tensorfold | omlx | code | ok | 85 | 265 | no |
| tensorfold | omlx | natural | ok | 34 | 315 | no |
| tensorfold | omlx | json | ok | 190 | 190 | yes |
| tensorfold | omlx | 4K-distinct | ok | 0 | 84 | no |
| mlx-vlm | omlx | code | ok | 85 | 265 | no |
| mlx-vlm | omlx | natural | ok | 34 | 315 | no |
| mlx-vlm | omlx | json | ok | 190 | 190 | yes |
| mlx-vlm | omlx | 4K-distinct | ok | 0 | 84 | no |

Self-determinism (rep 1 vs rep 2, same engine, greedy):

- rapid-mlx code: identical
- rapid-mlx natural: identical
- rapid-mlx json: identical
- mlx-lm code: identical
- mlx-lm natural: identical
- mlx-lm json: identical
- tensorfold code: identical
- tensorfold natural: identical
- tensorfold json: identical
- mlx-vlm code: identical
- mlx-vlm natural: identical
- mlx-vlm json: identical
- omlx code: identical
- omlx natural: identical
- omlx json: identical

## Consistency (token counts; same prompt must give same prompt_tokens and completion_tokens)

- no HTTP mismatches
- strim S1 code: raw ids 93 prompt tokens (HTTP chat prompt 104), completion 64
- strim S1 natural: raw ids 59 prompt tokens (HTTP chat prompt 71), completion 64
- strim S1 json: raw ids 30 prompt tokens (HTTP chat prompt 42), completion 64
- strim S2 rep 1: synthetic 4096 prompt tokens (HTTP chat prompt 4107); not the same prompt
- strim S2 rep 2: synthetic 4096 prompt tokens (HTTP chat prompt 4107); not the same prompt

## Failures, skips and flags

- tensorfold S2: FAIL cached_tokens=3
- llama.cpp/ollama S1: not run: no local GGUF
- llama.cpp/ollama: not run: no local GGUF
