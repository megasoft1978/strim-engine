# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | /tmp/perfval/old2-r1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4091 | 4.120 |
| 2 | 3 | 9346 | 6.635 |
| 3 | 5 | 14627 | 6.040 |
| 4 | 7 | 19884 | 6.513 |
| 5 | 9 | 25156 | 7.031 |
| 6 | 11 | 30378 | 7.619 |
| 7 | 13 | 35637 | 8.174 |
| 8 | 15 | 40838 | 8.703 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 54.836 | 54.836 | 0 |

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
| 1 | 70.5 |
| 2 | 74.4 |
| 3 | 61.0 |
| 4 | 58.7 |
| 5 | 48.7 |
| 6 | 41.7 |
| 7 | 41.2 |
| 8 | 45.7 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
