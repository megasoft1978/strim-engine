# Scoreboard 20261027-072549

- reps: 2; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | strim |
|---|---|---|---|
| - | - | peak_rss_kb | 8.92e+06 cv 0.0% (n=2) |
| W1 | greedy-256 | decode_tps | 68.28 cv 1.4% (n=2) |
| W1 | greedy-256 | ttft_s | 0.1113 cv 0.1% (n=2) |
| W1 | greedy-64 | decode_tps | 63.01 cv 0.9% (n=2) |
| W1 | greedy-64 | ttft_s | 0.1106 cv 0.2% (n=2) |
| W2 | temp0.6-256 | decode_tps | 68.22 cv 1.1% (n=2) |
| W2 | temp0.6-256 | ttft_s | 0.1117 cv 0.2% (n=2) |
| W3 | ctx-16384 | decode_tps | 47.56 cv 4.4% (n=2) |
| W3 | ctx-16384 | ttft_s | 17.37 cv 0.3% (n=2) |
| W3 | ctx-32768 | decode_tps | 47.53 cv 11.9% (n=2) |
| W3 | ctx-32768 | ttft_s | 37.47 cv 0.2% (n=2) |
| W3 | ctx-4096 | decode_tps | 62.82 cv 2.7% (n=2) |
| W3 | ctx-4096 | ttft_s | 4.177 cv 0.3% (n=2) |
| W4 | distinct-c2 | aggregate_tps | 11.84 cv 0.2% (n=2) |
| W4 | distinct-c2 | decode_tps | 18.69 cv 0.5% (n=2) |
| W4 | distinct-c2 | ttft_s | 6.33 cv 0.5% (n=2) |
| W4 | distinct-c4 | aggregate_tps | 12.42 cv 0.1% (n=2) |
| W4 | distinct-c4 | decode_tps | 6.754 cv 0.2% (n=2) |
| W4 | distinct-c4 | ttft_s | 10.66 cv 0.3% (n=2) |
| W5 | shared16384-c4 | aggregate_tps | 3.338 cv 0.1% (n=2) |
| W5 | shared16384-c4 | decode_tps | 2.414 cv 1.6% (n=2) |
| W5 | shared16384-c4 | ttft_s | 46.53 cv 0.1% (n=2) |

## Flags per arm

- strim: requests 74, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 74}, W4 rows not zero-hit/verified 0
