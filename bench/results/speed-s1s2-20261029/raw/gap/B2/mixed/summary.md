# Scoreboard 20261029-224743

- reps: 4; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | B2 |
|---|---|---|---|
| W6 | agent-c4 | aggregate_tps | 26.08 cv 4.2% (n=4) |
| W6 | agent-c4 | decode_tps | 9.017 cv 5.0% (n=4) |
| W6 | agent-c4 | ttft_s | 4.957 cv 7.9% (n=4) |
| W6 | agent-c8 | aggregate_tps | 21.96 cv 1.1% (n=4) |
| W6 | agent-c8 | decode_tps | 4.02 cv 3.8% (n=4) |
| W6 | agent-c8 | ttft_s | 8.978 cv 11.0% (n=4) |

## Flags per arm

- B2: requests 48, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 48}, W4 rows not zero-hit/verified 0
