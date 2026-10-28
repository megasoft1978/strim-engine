# Scoreboard 20261027-071451

- reps: 2; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | rapid-mlx |
|---|---|---|---|
| - | - | peak_rss_kb | 1.599e+07 cv 0.0% (n=2) |
| W1 | greedy-256 | decode_tps | 50.58 cv 0.1% (n=2) |
| W1 | greedy-256 | ttft_s | 0.2625 cv 0.6% (n=2) |
| W1 | greedy-64 | decode_tps | 50.3 cv 0.6% (n=2) |
| W1 | greedy-64 | ttft_s | 0.2665 cv 1.8% (n=2) |
| W2 | temp0.6-256 | decode_tps | 52.49 cv 0.3% (n=2) |
| W2 | temp0.6-256 | ttft_s | 0.2632 cv 0.3% (n=2) |
| W3 | ctx-16384 | decode_tps | 44.79 cv 1.0% (n=2) |
| W3 | ctx-16384 | ttft_s | 16.92 cv 0.0% (n=2) |
| W3 | ctx-32768 | decode_tps | 40.91 cv 0.8% (n=2) |
| W3 | ctx-32768 | ttft_s | 36.15 cv 0.0% (n=2) |
| W3 | ctx-4096 | decode_tps | 48.09 cv 0.1% (n=2) |
| W3 | ctx-4096 | ttft_s | 4.132 cv 0.1% (n=2) |
| W4 | distinct-c2 | aggregate_tps | 11.92 cv 0.2% (n=2) |
| W4 | distinct-c2 | decode_tps | 29.68 cv 0.6% (n=2) |
| W4 | distinct-c2 | ttft_s | 8.619 cv 0.2% (n=2) |
| W4 | distinct-c4 | aggregate_tps | 13.11 cv 0.1% (n=2) |
| W4 | distinct-c4 | decode_tps | 24.58 cv 0.3% (n=2) |
| W4 | distinct-c4 | ttft_s | 16.97 cv 0.0% (n=2) |
| W5 | shared16384-c4 | aggregate_tps | 3.329 cv 0.0% (n=2) |
| W5 | shared16384-c4 | decode_tps | 20.2 cv 1.8% (n=2) |
| W5 | shared16384-c4 | ttft_s | 73.79 cv 0.1% (n=2) |

## Flags per arm

- rapid-mlx: requests 74, errors 0, tokens mismatch 0, short 10, no usage 0, retokenized 0, excluded rows 10 (decode/aggregate dropped), cache_info {'unknown': 64, 'usage': 10}, W4 rows not zero-hit/verified 12
