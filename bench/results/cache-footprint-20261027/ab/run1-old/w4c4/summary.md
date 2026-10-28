# Scoreboard 20261027-230427

- reps: 2; value = median over reps of per-rep median; cv = stdev/mean over reps
- tokens: tokenizer (strim tokenizer: <repo>/models/qwen38-4bit/tokenizer.json)
- skipped (pending): none
- cache info: usage.prompt_tokens_details.cached_tokens, else server log, else unknown
- thinking: disabled (chat_template_kwargs.enable_thinking=false)
- excluded rows (no_usage, short) have no decode tok/s and void their concurrent batch's aggregate; ttft kept

| workload | variant | metric | strim |
|---|---|---|---|
| W4 | distinct-c4 | aggregate_tps | 12.3 cv 0.4% (n=2) |
| W4 | distinct-c4 | decode_tps | 6.92 cv 0.2% (n=2) |
| W4 | distinct-c4 | ttft_s | 10.99 cv 0.5% (n=2) |

## Flags per arm

- strim: requests 8, errors 0, tokens mismatch 0, short 0, no usage 0, retokenized 0, excluded rows 0 (decode/aggregate dropped), cache_info {'usage': 8}, W4 rows not zero-hit/verified 0
