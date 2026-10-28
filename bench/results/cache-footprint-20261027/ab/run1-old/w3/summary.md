# Scoreboard 20261027-230329

- reps: 2; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: <repo>/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | strim |
|---|---|---|---|
| W3 | ctx-16384 | decode_tps | 42.16 cv 14.8% (n=2) |
| W3 | ctx-16384 | ttft_s | 19.92 cv 1.0% (n=2) |
| W3 | ctx-4096 | decode_tps | 62.71 cv 1.2% (n=2) |
| W3 | ctx-4096 | ttft_s | 4.174 cv 0.2% (n=2) |

## Flags per arm

- strim: requests 4, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 4}, W4 rows not zero-hit/verified 0
