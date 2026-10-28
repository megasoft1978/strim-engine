# Scoreboard 20261027-080748

- reps: 3; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | tensorfold |
|---|---|---|---|
| - | - | peak_rss_kb | 2.158e+07 cv 0.0% (n=3) |
| W1 | greedy-256 | decode_tps | 30.07 cv 1.2% (n=3) |
| W1 | greedy-256 | ttft_s | 0.1252 cv 2.0% (n=3) |
| W1 | greedy-64 | decode_tps | 30.25 cv 0.2% (n=3) |
| W1 | greedy-64 | ttft_s | 0.08792 cv 2.2% (n=3) |
| W2 | temp0.6-256 | decode_tps | 30.1 cv 0.1% (n=3) |
| W2 | temp0.6-256 | ttft_s | 0.126 cv 2.4% (n=3) |
| W3 | ctx-16384 | decode_tps | 28.33 cv 0.1% (n=3) |
| W3 | ctx-16384 | ttft_s | 16.81 cv 0.1% (n=3) |
| W3 | ctx-4096 | decode_tps | 29.37 cv 0.3% (n=3) |
| W3 | ctx-4096 | ttft_s | 4.106 cv 18.0% (n=3) |
| W4 | distinct-c2 | aggregate_tps | 9.334 cv 13.1% (n=3) |
| W4 | distinct-c2 | decode_tps | 16.75 cv 5.2% (n=3) |
| W4 | distinct-c2 | ttft_s | 8.826 cv 19.9% (n=3) |
| W4 | distinct-c4 | aggregate_tps | 9.62 cv 21.7% (n=3) |
| W4 | distinct-c4 | decode_tps | 5.836 cv 19.9% (n=3) |
| W4 | distinct-c4 | ttft_s | 14.46 cv 20.6% (n=3) |
| W5 | shared16384-c4 | aggregate_tps | 6.344 cv 20.9% (n=3) |
| W5 | shared16384-c4 | decode_tps | 14.35 cv 7.8% (n=3) |
| W5 | shared16384-c4 | ttft_s | 35.92 cv 25.4% (n=3) |

## Flags per arm

- tensorfold: requests 111, errors 3, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 108, 'unknown': 3}, W4 rows not zero-hit/verified 18
