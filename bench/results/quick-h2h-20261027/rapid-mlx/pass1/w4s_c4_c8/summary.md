# Scoreboard 20261027-204907

- reps: 1; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | rapid-mlx |
|---|---|---|---|
| W4 | distinct-c4 | aggregate_tps | 69.99 cv 0.0% (n=1) |
| W4 | distinct-c4 | decode_tps | 25.69 cv 0.0% (n=1) |
| W4 | distinct-c4 | ttft_s | 2.37 cv 0.0% (n=1) |
| W4 | distinct-c8 | aggregate_tps | 69.98 cv 0.0% (n=1) |
| W4 | distinct-c8 | decode_tps | 25.62 cv 0.0% (n=1) |
| W4 | distinct-c8 | ttft_s | 6.02 cv 0.0% (n=1) |

## Flags per arm

- rapid-mlx: requests 12, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'unknown': 12}, W4 rows not zero-hit/verified 12
