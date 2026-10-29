# Scoreboard 20261028-234414

- reps: 1; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | mlx-vlm |
|---|---|---|---|
| W5 | shared16384-c4 | aggregate_tps | 3.445 cv 0.0% (n=1) |
| W5 | shared16384-c4 | decode_tps | 19.44 cv 0.0% (n=1) |
| W5 | shared16384-c4 | ttft_s | 71.08 cv 0.0% (n=1) |

## Flags per arm

- mlx-vlm: requests 4, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 4}, W4 rows not zero-hit/verified 0
