# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | /tmp/perfval/new-r2/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4093 | 4.238 |
| 2 | 3 | 9348 | 6.796 |
| 3 | 5 | 14629 | 6.207 |
| 4 | 7 | 19886 | 6.737 |
| 5 | 9 | 25158 | 7.200 |
| 6 | 11 | 30380 | 7.594 |
| 7 | 13 | 35639 | 8.109 |
| 8 | 15 | 40840 | 9.049 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 55.931 | 55.931 | 0 |

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
| 8 | 85.2% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 52.1 |
| 2 | 59.3 |
| 3 | 59.7 |
| 4 | 49.3 |
| 5 | 52.1 |
| 6 | 52.9 |
| 7 | 36.3 |
| 8 | 45.8 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
