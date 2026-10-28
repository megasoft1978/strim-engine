# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | /tmp/perfval/r3fixed-1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4092 | 4.145 |
| 2 | 3 | 9347 | 6.648 |
| 3 | 5 | 14628 | 6.076 |
| 4 | 7 | 19885 | 6.538 |
| 5 | 9 | 25157 | 7.064 |
| 6 | 11 | 30379 | 7.495 |
| 7 | 13 | 35638 | 7.977 |
| 8 | 15 | 40839 | 8.460 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 54.403 | 54.403 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 32.9% |
| 3 | 63.0% |
| 4 | 72.1% |
| 5 | 77.3% |
| 6 | 80.9% |
| 7 | 83.3% |
| 8 | 85.3% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 55.2 |
| 2 | 64.6 |
| 3 | 60.9 |
| 4 | 53.9 |
| 5 | 53.4 |
| 6 | 53.2 |
| 7 | 50.1 |
| 8 | 47.0 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
