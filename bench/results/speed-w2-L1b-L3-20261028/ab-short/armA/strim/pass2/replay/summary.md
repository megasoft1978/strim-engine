# Agent replay summary

- fixture: `bench/results/speed-w2-L1b-L3-20261028/short-8turn.json` sha256:329be5d9e38bf346, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | bench/results/speed-w2-L1b-L3-20261028/ab-short/armA/strim/pass2/server.txt |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 491 | 0.617 |
| 2 | 3 | 783 | 0.423 |
| 3 | 5 | 1084 | 0.427 |
| 4 | 7 | 1381 | 0.427 |
| 5 | 9 | 1674 | 0.428 |
| 6 | 11 | 1962 | 0.428 |
| 7 | 13 | 2267 | 0.436 |
| 8 | 15 | 2563 | 0.435 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 3.621 | 3.621 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 61.8% |
| 3 | 71.6% |
| 4 | 78.0% |
| 5 | 82.1% |
| 6 | 85.0% |
| 7 | 86.2% |
| 8 | 88.2% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 65.5 |
| 2 | 62.0 |
| 3 | 79.4 |
| 4 | 80.0 |
| 5 | 81.9 |
| 6 | 81.7 |
| 7 | 78.5 |
| 8 | 78.8 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
