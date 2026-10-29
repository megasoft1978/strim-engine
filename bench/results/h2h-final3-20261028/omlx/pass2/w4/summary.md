# Scoreboard 20261028-231437

- reps: 1; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | omlx |
|---|---|---|---|
| W4 | distinct-c4 | aggregate_tps | 11.95 cv 0.0% (n=1) |
| W4 | distinct-c4 | decode_tps | 17.7 cv 0.0% (n=1) |
| W4 | distinct-c4 | ttft_s | 17.71 cv 0.0% (n=1) |
| W4 | distinct-c8 | aggregate_tps | 14.04 cv 0.0% (n=1) |
| W4 | distinct-c8 | decode_tps | 8.813 cv 0.0% (n=1) |
| W4 | distinct-c8 | ttft_s | 35.3 cv 0.0% (n=1) |

## Flags per arm

- omlx: requests 12, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 3, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 9, 'unknown': 3}, W4 rows not zero-hit/verified 3
