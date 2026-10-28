# Scoreboard 20261027-074751

- reps: 3; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | mlx-lm |
|---|---|---|---|
| - | - | peak_rss_kb | 1.574e+07 cv 0.0% (n=3) |
| W1 | greedy-256 | decode_tps | 30.08 cv 0.1% (n=3) |
| W1 | greedy-256 | ttft_s | 0.2287 cv 0.5% (n=3) |
| W1 | greedy-64 | decode_tps | 30.45 cv 0.9% (n=3) |
| W1 | greedy-64 | ttft_s | 0.2158 cv 0.9% (n=3) |
| W2 | temp0.6-256 | decode_tps | 30.65 cv 0.6% (n=3) |
| W2 | temp0.6-256 | ttft_s | 0.1062 cv 4.4% (n=3) |
| W3 | ctx-16384 | decode_tps | 27.86 cv 1.2% (n=3) |
| W3 | ctx-16384 | ttft_s | 18.14 cv 0.1% (n=3) |
| W3 | ctx-32768 | decode_tps | 26.72 cv 0.2% (n=3) |
| W3 | ctx-32768 | ttft_s | 39.33 cv 0.1% (n=3) |
| W3 | ctx-4096 | decode_tps | 29.01 cv 1.3% (n=3) |
| W3 | ctx-4096 | ttft_s | 5.484 cv 12.4% (n=3) |
| W4 | distinct-c2 | aggregate_tps | 11.54 cv 10.9% (n=3) |
| W4 | distinct-c2 | decode_tps | 27.52 cv 1.7% (n=3) |
| W4 | distinct-c2 | ttft_s | 8.798 cv 14.1% (n=3) |
| W4 | distinct-c4 | aggregate_tps | 12.86 cv 0.5% (n=3) |
| W4 | distinct-c4 | decode_tps | 22.82 cv 1.0% (n=3) |
| W4 | distinct-c4 | ttft_s | 17.17 cv 0.4% (n=3) |
| W5 | shared16384-c4 | aggregate_tps | 3.248 cv 1.3% (n=3) |
| W5 | shared16384-c4 | decode_tps | 19.67 cv 0.1% (n=3) |
| W5 | shared16384-c4 | ttft_s | 75.62 cv 1.4% (n=3) |

## Flags per arm

- mlx-lm: requests 111, errors 0, tokens mismatch 0, short 12, no usage 0, retokenized 0, excluded rows 12 (decode/aggregate dropped), cache_info {'usage': 111}, W4 rows not zero-hit/verified 0
