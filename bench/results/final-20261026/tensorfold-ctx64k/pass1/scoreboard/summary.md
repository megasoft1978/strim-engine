# Scoreboard 20261027-100701

- reps: 3; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (tokenizers: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | tensorfold-ctx64k |
|---|---|---|---|
| - | - | peak_rss_kb | 2.142e+07 cv 0.4% (n=3) |
| W3 | ctx-16384 | decode_tps | 28.36 cv 0.2% (n=3) |
| W3 | ctx-16384 | ttft_s | 16.8 cv 0.1% (n=3) |
| W3 | ctx-32768 | decode_tps | 26.52 cv 0.0% (n=3) |
| W3 | ctx-32768 | ttft_s | 36.46 cv 0.1% (n=3) |
| W3 | ctx-4096 | decode_tps | 29.48 cv 0.1% (n=3) |
| W3 | ctx-4096 | ttft_s | 4.113 cv 0.4% (n=3) |

## Flags per arm

- tensorfold-ctx64k: requests 9, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 9}, W4 rows not zero-hit/verified 0
