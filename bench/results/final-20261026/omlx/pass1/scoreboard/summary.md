# Scoreboard 20261027-082421

- reps: 3; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | omlx |
|---|---|---|---|
| - | - | peak_rss_kb | 1.949e+07 cv 11.5% (n=3) |
| W1 | greedy-256 | decode_tps | 33.78 cv 0.8% (n=3) |
| W1 | greedy-256 | ttft_s | 0.3921 cv 0.7% (n=3) |
| W1 | greedy-64 | decode_tps | 35.56 cv 0.2% (n=3) |
| W1 | greedy-64 | ttft_s | 0.3893 cv 0.6% (n=3) |
| W2 | temp0.6-256 | decode_tps | 33.38 cv 2.5% (n=3) |
| W2 | temp0.6-256 | ttft_s | 0.4006 cv 4.9% (n=3) |
| W3 | ctx-16384 | decode_tps | 31.3 cv 0.4% (n=3) |
| W3 | ctx-16384 | ttft_s | 18.63 cv 0.3% (n=3) |
| W3 | ctx-32768 | decode_tps | 29.42 cv 7.5% (n=3) |
| W3 | ctx-32768 | ttft_s | 40.43 cv 0.3% (n=3) |
| W3 | ctx-4096 | decode_tps | 33.12 cv 0.9% (n=3) |
| W3 | ctx-4096 | ttft_s | 5.097 cv 5.5% (n=3) |
| W4 | distinct-c2 | aggregate_tps | 10.91 cv 2.9% (n=3) |
| W4 | distinct-c2 | decode_tps | 18.13 cv 25.7% (n=3) |
| W4 | distinct-c2 | ttft_s | 7.39 cv 13.4% (n=3) |
| W4 | distinct-c4 | aggregate_tps | 11.63 cv 0.7% (n=3) |
| W4 | distinct-c4 | decode_tps | 11.77 cv 23.3% (n=3) |
| W4 | distinct-c4 | ttft_s | 15.73 cv 13.9% (n=3) |
| W5 | shared16384-c4 | aggregate_tps | 3.505 cv 0.0% (n=1) |
| W5 | shared16384-c4 | decode_tps | 9.967 cv 0.0% (n=1) |
| W5 | shared16384-c4 | ttft_s | 76.41 cv 0.0% (n=1) |

## Flags per arm

- omlx: requests 111, errors 8, tokens mismatch 0, short 12, no usage 0, retokenized 1, excluded rows 12 (decode/aggregate dropped), cache_info {'usage': 102, 'unknown': 9}, W4 rows not zero-hit/verified 0
