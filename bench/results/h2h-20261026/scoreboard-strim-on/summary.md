# Scoreboard 20261026-201556

- reps: 3; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | strim |
|---|---|---|---|
| - | - | peak_rss_kb | 8.915e+06 cv 0.0% (n=3) |
| W1 | greedy-256 | decode_tps | 70.66 cv 0.1% (n=3) |
| W1 | greedy-256 | ttft_s | 0.1086 cv 0.2% (n=3) |
| W1 | greedy-64 | decode_tps | 65.36 cv 0.2% (n=3) |
| W1 | greedy-64 | ttft_s | 0.1084 cv 0.2% (n=3) |
| W2 | temp0.6-256 | decode_tps | 70.32 cv 0.2% (n=3) |
| W2 | temp0.6-256 | ttft_s | 0.1091 cv 0.4% (n=3) |
| W3 | ctx-16384 | decode_tps | 49.18 cv 0.5% (n=3) |
| W3 | ctx-16384 | ttft_s | 17.4 cv 1.1% (n=3) |
| W3 | ctx-32768 | decode_tps | 45.6 cv 1.3% (n=3) |
| W3 | ctx-32768 | ttft_s | 37.39 cv 0.1% (n=3) |
| W3 | ctx-4096 | decode_tps | 64.02 cv 1.6% (n=3) |
| W3 | ctx-4096 | ttft_s | 4.186 cv 1.5% (n=3) |
| W4 | distinct-c2 | aggregate_tps | 11.58 cv 0.2% (n=3) |
| W4 | distinct-c2 | decode_tps | 17.25 cv 0.2% (n=3) |
| W4 | distinct-c2 | ttft_s | 6.341 cv 0.3% (n=3) |
| W4 | distinct-c4 | aggregate_tps | 12.56 cv 0.2% (n=3) |
| W4 | distinct-c4 | decode_tps | 7.056 cv 0.2% (n=3) |
| W4 | distinct-c4 | ttft_s | 10.7 cv 0.2% (n=3) |
| W5 | shared16384-c4 | aggregate_tps | 3.354 cv 0.1% (n=3) |
| W5 | shared16384-c4 | decode_tps | 2.864 cv 8.0% (n=3) |
| W5 | shared16384-c4 | ttft_s | 46.36 cv 0.1% (n=3) |

## Flags per arm

- strim: requests 111, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 111}, W4 rows not zero-hit/verified 0
