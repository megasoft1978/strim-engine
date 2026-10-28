# Scoreboard 20261026-205051

- reps: 2; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | rapid |
|---|---|---|---|
| - | - | peak_rss_kb | 1.598e+07 cv 0.0% (n=2) |
| W3 | ctx-16384 | decode_tps | 43.97 cv 1.0% (n=2) |
| W3 | ctx-16384 | ttft_s | 16.87 cv 0.1% (n=2) |
| W3 | ctx-32768 | decode_tps | 41.26 cv 0.4% (n=2) |
| W3 | ctx-32768 | ttft_s | 36.14 cv 0.1% (n=2) |
| W3 | ctx-4096 | decode_tps | 47.57 cv 0.3% (n=2) |
| W3 | ctx-4096 | ttft_s | 4.102 cv 0.5% (n=2) |
| W4 | distinct-c2 | aggregate_tps | 11.95 cv 0.2% (n=2) |
| W4 | distinct-c2 | decode_tps | 29.38 cv 0.4% (n=2) |
| W4 | distinct-c2 | ttft_s | 8.568 cv 0.3% (n=2) |
| W4 | distinct-c4 | aggregate_tps | 13.15 cv 0.1% (n=2) |
| W4 | distinct-c4 | decode_tps | 24.37 cv 0.0% (n=2) |
| W4 | distinct-c4 | ttft_s | 16.89 cv 0.1% (n=2) |

## Flags per arm

- rapid: requests 18, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'unknown': 18}, W4 rows not zero-hit/verified 12
