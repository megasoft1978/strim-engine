# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8217 | qwen38-4bit | on | bench/results/cache-footprint-20261027/ab/run2-new/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4092 | 4.158 |
| 2 | 3 | 9347 | 5.604 |
| 3 | 5 | 14628 | 5.923 |
| 4 | 7 | 19885 | 6.222 |
| 5 | 9 | 25157 | 6.522 |
| 6 | 11 | 30379 | 6.767 |
| 7 | 13 | 35638 | 7.165 |
| 8 | 15 | 40839 | 7.371 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 49.731 | 49.731 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 43.7% |
| 3 | 63.9% |
| 4 | 73.5% |
| 5 | 79.0% |
| 6 | 82.8% |
| 7 | 85.2% |
| 8 | 87.2% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 60.5 |
| 2 | 72.9 |
| 3 | 62.3 |
| 4 | 61.6 |
| 5 | 58.4 |
| 6 | 56.6 |
| 7 | 56.3 |
| 8 | 53.2 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
