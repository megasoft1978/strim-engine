# Scoreboard 20261027-070403

- reps: 2; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | strim |
|---|---|---|---|
| - | - | peak_rss_kb | 8.919e+06 cv 0.0% (n=2) |
| W1 | greedy-256 | decode_tps | 68.26 cv 0.4% (n=2) |
| W1 | greedy-256 | ttft_s | 0.1126 cv 0.5% (n=2) |
| W1 | greedy-64 | decode_tps | 63.45 cv 0.7% (n=2) |
| W1 | greedy-64 | ttft_s | 0.1108 cv 1.3% (n=2) |
| W2 | temp0.6-256 | decode_tps | 68.49 cv 0.7% (n=2) |
| W2 | temp0.6-256 | ttft_s | 0.1114 cv 0.1% (n=2) |
| W3 | ctx-16384 | decode_tps | 48.75 cv 0.2% (n=2) |
| W3 | ctx-16384 | ttft_s | 17.45 cv 0.3% (n=2) |
| W3 | ctx-32768 | decode_tps | 48.5 cv 6.6% (n=2) |
| W3 | ctx-32768 | ttft_s | 37.54 cv 0.1% (n=2) |
| W3 | ctx-4096 | decode_tps | 61.59 cv 1.4% (n=2) |
| W3 | ctx-4096 | ttft_s | 4.194 cv 0.6% (n=2) |
| W4 | distinct-c2 | aggregate_tps | 11.79 cv 0.1% (n=2) |
| W4 | distinct-c2 | decode_tps | 18.68 cv 0.3% (n=2) |
| W4 | distinct-c2 | ttft_s | 6.366 cv 0.5% (n=2) |
| W4 | distinct-c4 | aggregate_tps | 12.38 cv 0.2% (n=2) |
| W4 | distinct-c4 | decode_tps | 6.766 cv 0.1% (n=2) |
| W4 | distinct-c4 | ttft_s | 10.74 cv 0.2% (n=2) |
| W5 | shared16384-c4 | aggregate_tps | 3.328 cv 0.2% (n=2) |
| W5 | shared16384-c4 | decode_tps | 2.704 cv 7.5% (n=2) |
| W5 | shared16384-c4 | ttft_s | 46.69 cv 0.1% (n=2) |

## Flags per arm

- strim: requests 74, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 74}, W4 rows not zero-hit/verified 0
