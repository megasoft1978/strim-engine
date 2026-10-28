# Scoreboard 20261026-203951

- reps: 3; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | rapid |
|---|---|---|---|
| - | - | peak_rss_kb | 1.597e+07 cv 0.1% (n=3) |
| W1 | greedy-256 | decode_tps | 50.53 cv 0.2% (n=3) |
| W1 | greedy-256 | ttft_s | 0.2653 cv 0.2% (n=3) |
| W1 | greedy-64 | decode_tps | 50.3 cv 0.3% (n=3) |
| W1 | greedy-64 | ttft_s | 0.2644 cv 0.2% (n=3) |
| W2 | temp0.6-256 | decode_tps | 51.95 cv 0.4% (n=3) |
| W2 | temp0.6-256 | ttft_s | 0.2658 cv 0.3% (n=3) |
| W5 | shared16384-c4 | aggregate_tps | 3.333 cv 0.0% (n=3) |
| W5 | shared16384-c4 | decode_tps | 20.7 cv 1.1% (n=3) |
| W5 | shared16384-c4 | ttft_s | 73.74 cv 0.0% (n=3) |

## Flags per arm

- rapid: requests 84, errors 0, tokens mismatch 0, short 15, no usage 0, retokenized 0, excluded rows 15 (decode/aggregate dropped), cache_info {'usage': 18, 'unknown': 66}, W4 rows not zero-hit/verified 0
