# Scoreboard 20261027-090405

- reps: 3; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | llama.cpp |
|---|---|---|---|
| - | - | peak_rss_kb | 3.11e+07 cv 6.5% (n=3) |
| W1 | greedy-256 | decode_tps | 27.4 cv 0.3% (n=3) |
| W1 | greedy-256 | ttft_s | 0.2457 cv 42.6% (n=3) |
| W1 | greedy-64 | decode_tps | 28.31 cv 1.9% (n=3) |
| W1 | greedy-64 | ttft_s | 0.2469 cv 7.7% (n=3) |
| W2 | temp0.6-256 | decode_tps | 27.35 cv 0.3% (n=3) |
| W2 | temp0.6-256 | ttft_s | 0.2533 cv 6.0% (n=3) |
| W3 | ctx-16384 | decode_tps | 25.57 cv 1.7% (n=3) |
| W3 | ctx-16384 | ttft_s | 23.36 cv 0.1% (n=3) |
| W3 | ctx-4096 | decode_tps | 27.84 cv 2.0% (n=3) |
| W3 | ctx-4096 | ttft_s | 5.446 cv 0.1% (n=3) |
| W4 | distinct-c2 | aggregate_tps | 9.262 cv 0.5% (n=3) |
| W4 | distinct-c2 | decode_tps | 20.73 cv 0.8% (n=3) |
| W4 | distinct-c2 | ttft_s | 10.68 cv 0.7% (n=3) |
| W4 | distinct-c4 | aggregate_tps | 9.274 cv 0.4% (n=3) |
| W4 | distinct-c4 | decode_tps | 18.08 cv 0.9% (n=3) |
| W4 | distinct-c4 | ttft_s | 17.55 cv 0.3% (n=3) |
| W5 | shared16384-c4 | aggregate_tps | 4.517 cv 0.1% (n=3) |
| W5 | shared16384-c4 | decode_tps | 16.31 cv 0.4% (n=3) |
| W5 | shared16384-c4 | ttft_s | 50.71 cv 0.1% (n=3) |

## Flags per arm

- llama.cpp: requests 111, errors 3, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 108, 'unknown': 3}, W4 rows not zero-hit/verified 0
