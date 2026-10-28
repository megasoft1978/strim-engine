# Scoreboard 20261028-100534

- reps: 1; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | x |
|---|---|---|---|
| W3 | ctx-16384 | decode_tps | 47.6 cv 0.0% (n=1) |
| W3 | ctx-16384 | ttft_s | 16.92 cv 0.0% (n=1) |
| W3 | ctx-32768 | decode_tps | 45.44 cv 0.0% (n=1) |
| W3 | ctx-32768 | ttft_s | 36.56 cv 0.0% (n=1) |
| W3 | ctx-4096 | decode_tps | 63.78 cv 0.0% (n=1) |
| W3 | ctx-4096 | ttft_s | 4.104 cv 0.0% (n=1) |

## Flags per arm

- x: requests 3, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 3}, W4 rows not zero-hit/verified 0
