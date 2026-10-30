# Scoreboard 20261029-223622

- reps: 4; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | A1 |
|---|---|---|---|
| W6 | agent-c4 | aggregate_tps | 27.19 cv 1.1% (n=4) |
| W6 | agent-c4 | decode_tps | 9.235 cv 23.0% (n=4) |
| W6 | agent-c4 | ttft_s | 4.767 cv 40.4% (n=4) |
| W6 | agent-c8 | aggregate_tps | 22.71 cv 2.0% (n=4) |
| W6 | agent-c8 | decode_tps | 3.528 cv 3.7% (n=4) |
| W6 | agent-c8 | ttft_s | 9.083 cv 7.7% (n=4) |

## Flags per arm

- A1: requests 48, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 48}, W4 rows not zero-hit/verified 0
