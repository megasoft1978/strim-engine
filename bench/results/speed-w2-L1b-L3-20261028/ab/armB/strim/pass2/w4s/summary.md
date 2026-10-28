# Scoreboard 20261028-081702

- reps: 1; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | strim |
|---|---|---|---|
| W4 | distinct-c4 | aggregate_tps | 63.92 cv 0.0% (n=1) |
| W4 | distinct-c4 | decode_tps | 20.04 cv 0.0% (n=1) |
| W4 | distinct-c4 | ttft_s | 1.595 cv 0.0% (n=1) |
| W4 | distinct-c8 | aggregate_tps | 71.2 cv 0.0% (n=1) |
| W4 | distinct-c8 | decode_tps | 11.2 cv 0.0% (n=1) |
| W4 | distinct-c8 | ttft_s | 2.88 cv 0.0% (n=1) |

## Flags per arm

- strim: requests 12, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 12}, W4 rows not zero-hit/verified 0
