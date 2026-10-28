# Agent replay summary

- fixture: `bench/results/speed-w2-L1b-L3-20261028/short-8turn.json` sha256:329be5d9e38bf346, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | bench/results/speed-w2-L1b-L3-20261028/ab-short/armA/strim/pass1/server.txt |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 490 | 0.621 |
| 2 | 3 | 782 | 0.430 |
| 3 | 5 | 1083 | 0.432 |
| 4 | 7 | 1380 | 0.431 |
| 5 | 9 | 1673 | 0.431 |
| 6 | 11 | 1961 | 0.434 |
| 7 | 13 | 2266 | 0.442 |
| 8 | 15 | 2562 | 0.438 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 3.658 | 3.658 | 0 |

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
| 1 | 73.9 |
| 2 | 84.6 |
| 3 | 78.3 |
| 4 | 77.0 |
| 5 | 72.7 |
| 6 | 60.2 |
| 7 | 75.9 |
| 8 | 76.4 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
