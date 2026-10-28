# Scoreboard 20261027-073641

- reps: 2; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | rapid-mlx |
|---|---|---|---|
| - | - | peak_rss_kb | 1.601e+07 cv 0.1% (n=2) |
| W1 | greedy-256 | decode_tps | 50.03 cv 1.8% (n=2) |
| W1 | greedy-256 | ttft_s | 0.2657 cv 1.3% (n=2) |
| W1 | greedy-64 | decode_tps | 47.9 cv 7.1% (n=2) |
| W1 | greedy-64 | ttft_s | 0.2698 cv 4.2% (n=2) |
| W2 | temp0.6-256 | decode_tps | 51.73 cv 2.1% (n=2) |
| W2 | temp0.6-256 | ttft_s | 0.2646 cv 1.0% (n=2) |
| W3 | ctx-16384 | decode_tps | 44.25 cv 1.8% (n=2) |
| W3 | ctx-16384 | ttft_s | 17.06 cv 0.0% (n=2) |
| W3 | ctx-32768 | decode_tps | 40.36 cv 0.9% (n=2) |
| W3 | ctx-32768 | ttft_s | 36.51 cv 0.1% (n=2) |
| W3 | ctx-4096 | decode_tps | 46.53 cv 2.5% (n=2) |
| W3 | ctx-4096 | ttft_s | 4.165 cv 0.2% (n=2) |
| W4 | distinct-c2 | aggregate_tps | 11.82 cv 0.1% (n=2) |
| W4 | distinct-c2 | decode_tps | 29.39 cv 0.1% (n=2) |
| W4 | distinct-c2 | ttft_s | 8.683 cv 0.1% (n=2) |
| W4 | distinct-c4 | aggregate_tps | 12.99 cv 0.0% (n=2) |
| W4 | distinct-c4 | decode_tps | 24.42 cv 0.4% (n=2) |
| W4 | distinct-c4 | ttft_s | 17.13 cv 0.1% (n=2) |
| W5 | shared16384-c4 | aggregate_tps | 3.308 cv 0.2% (n=2) |
| W5 | shared16384-c4 | decode_tps | 20.3 cv 0.4% (n=2) |
| W5 | shared16384-c4 | ttft_s | 74.28 cv 0.2% (n=2) |

## Flags per arm

- rapid-mlx: requests 74, errors 0, tokens mismatch 0, short 10, no usage 0, retokenized 0, excluded rows 10 (decode/aggregate dropped), cache_info {'unknown': 64, 'usage': 10}, W4 rows not zero-hit/verified 12
