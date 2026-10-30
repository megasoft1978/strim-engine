# Scoreboard 20261029-225209

- reps: 3; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | B2 |
|---|---|---|---|
| W6 | agent-c1 | aggregate_tps | 46.22 cv 0.9% (n=3) |
| W6 | agent-c1 | decode_tps | 73.71 cv 1.7% (n=3) |
| W6 | agent-c1 | ttft_s | 1.042 cv 0.8% (n=3) |

## Flags per arm

- B2: requests 3, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 3}, W4 rows not zero-hit/verified 0
