# Agent replay summary

- fixture: `bench/results/speed-w2-L1b-L3-20261028/short-8turn.json` sha256:329be5d9e38bf346, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | bench/results/speed-w2-L1b-L3-20261028/ab-short/armB/strim/pass1/server.txt |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 492 | 0.558 |
| 2 | 3 | 784 | 0.976 |
| 3 | 5 | 1085 | 0.439 |
| 4 | 7 | 1382 | 0.432 |
| 5 | 9 | 1675 | 0.430 |
| 6 | 11 | 1963 | 0.432 |
| 7 | 13 | 2268 | 0.441 |
| 8 | 15 | 2564 | 0.435 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 4.143 | 4.143 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 0.0% |
| 3 | 71.6% |
| 4 | 78.0% |
| 5 | 82.1% |
| 6 | 85.0% |
| 7 | 86.2% |
| 8 | 88.2% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 62.9 |
| 2 | 59.2 |
| 3 | 78.4 |
| 4 | 79.9 |
| 5 | 72.0 |
| 6 | 66.2 |
| 7 | 76.3 |
| 8 | 75.4 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
