# Scoreboard 20261027-231714

- reps: 2; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: <repo>/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | strim |
|---|---|---|---|
| W5 | shared16384-c4 | aggregate_tps | 8.029 cv 22.4% (n=2) |
| W5 | shared16384-c4 | decode_tps | 7.742 cv 36.0% (n=2) |
| W5 | shared16384-c4 | ttft_s | 23.44 cv 16.0% (n=2) |

## Flags per arm

- strim: requests 8, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 8}, W4 rows not zero-hit/verified 0
