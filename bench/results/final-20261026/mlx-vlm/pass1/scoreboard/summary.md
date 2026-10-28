# Scoreboard 20261027-083811

- reps: 3; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | mlx-vlm |
|---|---|---|---|
| - | - | peak_rss_kb | 1.668e+07 cv 0.0% (n=3) |
| W1 | greedy-256 | decode_tps | 32.22 cv 1.4% (n=3) |
| W1 | greedy-256 | ttft_s | 0.1688 cv 1.1% (n=3) |
| W1 | greedy-64 | decode_tps | 32.02 cv 1.2% (n=3) |
| W1 | greedy-64 | ttft_s | 0.1692 cv 2.9% (n=3) |
| W2 | temp0.6-256 | decode_tps | 31.85 cv 1.2% (n=3) |
| W2 | temp0.6-256 | ttft_s | 0.1683 cv 4.8% (n=3) |
| W3 | ctx-16384 | decode_tps | 30.47 cv 0.1% (n=3) |
| W3 | ctx-16384 | ttft_s | 16.69 cv 0.1% (n=3) |
| W3 | ctx-32768 | decode_tps | 29.11 cv 0.3% (n=3) |
| W3 | ctx-32768 | ttft_s | 35.69 cv 0.0% (n=3) |
| W3 | ctx-4096 | decode_tps | 32.14 cv 0.9% (n=3) |
| W3 | ctx-4096 | ttft_s | 4.039 cv 0.1% (n=3) |
| W4 | distinct-c2 | aggregate_tps | 12.3 cv 5.0% (n=3) |
| W4 | distinct-c2 | decode_tps | 21.68 cv 6.3% (n=3) |
| W4 | distinct-c2 | ttft_s | 7.082 cv 3.1% (n=3) |
| W4 | distinct-c4 | aggregate_tps | 13.47 cv 0.2% (n=3) |
| W4 | distinct-c4 | decode_tps | 22.73 cv 0.6% (n=3) |
| W4 | distinct-c4 | ttft_s | 16.24 cv 0.1% (n=3) |
| W5 | shared16384-c4 | aggregate_tps | 3.489 cv 0.0% (n=3) |
| W5 | shared16384-c4 | decode_tps | 19.51 cv 0.2% (n=3) |
| W5 | shared16384-c4 | ttft_s | 70.15 cv 0.0% (n=3) |

## Flags per arm

- mlx-vlm: requests 111, errors 0, tokens mismatch 0, short 12, no usage 0, retokenized 0, excluded rows 12 (decode/aggregate dropped), cache_info {'usage': 111}, W4 rows not zero-hit/verified 0
