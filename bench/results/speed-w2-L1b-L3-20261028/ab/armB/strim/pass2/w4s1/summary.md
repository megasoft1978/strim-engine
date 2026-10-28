# Scoreboard 20261028-081725

- reps: 5; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | strim |
|---|---|---|---|
| W4 | distinct-c1 | aggregate_tps | 42.99 cv 5.0% (n=5) |
| W4 | distinct-c1 | decode_tps | 53.57 cv 6.4% (n=5) |
| W4 | distinct-c1 | ttft_s | 0.6033 cv 1.3% (n=5) |

## Flags per arm

- strim: requests 5, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 5}, W4 rows not zero-hit/verified 0
