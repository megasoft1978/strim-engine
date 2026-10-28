# Scoreboard 20261027-092351

- reps: 3; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | ollama |
|---|---|---|---|
| - | - | peak_rss_kb | 3.052e+07 cv 2.7% (n=3) |
| W1 | greedy-256 | decode_tps | 24 cv 0.1% (n=3) |
| W1 | greedy-256 | ttft_s | 0.2657 cv 14.6% (n=3) |
| W1 | greedy-64 | decode_tps | 24.14 cv 1.0% (n=3) |
| W1 | greedy-64 | ttft_s | 0.1875 cv 31.9% (n=3) |
| W2 | temp0.6-256 | decode_tps | 24.06 cv 0.1% (n=3) |
| W2 | temp0.6-256 | ttft_s | 0.1107 cv 11.0% (n=3) |
| W3 | ctx-16384 | decode_tps | 22.47 cv 0.5% (n=3) |
| W3 | ctx-16384 | ttft_s | 26.4 cv 0.1% (n=3) |
| W3 | ctx-32768 | decode_tps | 21.53 cv 0.5% (n=3) |
| W3 | ctx-32768 | ttft_s | 63.28 cv 0.1% (n=3) |
| W3 | ctx-4096 | decode_tps | 23.57 cv 1.0% (n=3) |
| W3 | ctx-4096 | ttft_s | 5.893 cv 2.0% (n=3) |
| W4 | distinct-c2 | aggregate_tps | 7.507 cv 0.3% (n=3) |
| W4 | distinct-c2 | decode_tps | 23.96 cv 1.4% (n=3) |
| W4 | distinct-c2 | ttft_s | 10.14 cv 0.0% (n=3) |
| W4 | distinct-c4 | aggregate_tps | 7.509 cv 0.3% (n=3) |
| W4 | distinct-c4 | decode_tps | 23.86 cv 0.8% (n=3) |
| W4 | distinct-c4 | ttft_s | 18.66 cv 0.2% (n=3) |
| W5 | shared16384-c4 | aggregate_tps | 5.737 cv 0.3% (n=3) |
| W5 | shared16384-c4 | decode_tps | 22.78 cv 0.9% (n=3) |
| W5 | shared16384-c4 | ttft_s | 34.64 cv 0.4% (n=3) |

## Flags per arm

- ollama: requests 111, errors 0, tokens mismatch 0, short 6, no usage 0, retokenized 0, excluded rows 6 (decode/aggregate dropped), cache_info {'usage': 111}, W4 rows not zero-hit/verified 18
