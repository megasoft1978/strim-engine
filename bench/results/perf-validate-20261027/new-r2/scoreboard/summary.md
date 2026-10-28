# Scoreboard 20261027-161838

- reps: 4; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: <repo>/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | strim |
|---|---|---|---|
| - | - | peak_rss_kb | 8.705e+06 cv 4.9% (n=4) |
| W5 | shared16384-c4 | aggregate_tps | 10.29 cv 4.4% (n=4) |
| W5 | shared16384-c4 | decode_tps | 12.29 cv 12.1% (n=4) |
| W5 | shared16384-c4 | ttft_s | 19.54 cv 1.7% (n=4) |

## Flags per arm

- strim: requests 16, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 16}, W4 rows not zero-hit/verified 0
