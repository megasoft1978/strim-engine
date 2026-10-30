# Scoreboard 20261029-225330

- reps: 4; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | A2 |
|---|---|---|---|
| W6 | agent-c4 | aggregate_tps | 27.02 cv 1.1% (n=4) |
| W6 | agent-c4 | decode_tps | 9.116 cv 0.3% (n=4) |
| W6 | agent-c4 | ttft_s | 4.772 cv 3.6% (n=4) |
| W6 | agent-c8 | aggregate_tps | 22.08 cv 4.1% (n=4) |
| W6 | agent-c8 | decode_tps | 3.347 cv 6.1% (n=4) |
| W6 | agent-c8 | ttft_s | 8.114 cv 7.2% (n=4) |

## Flags per arm

- A2: requests 48, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 48}, W4 rows not zero-hit/verified 0
