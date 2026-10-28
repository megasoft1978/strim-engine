# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | /tmp/perfval/r3m1536x2048-1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4093 | 4.247 |
| 2 | 3 | 9348 | 5.491 |
| 3 | 5 | 14629 | 7.024 |
| 4 | 7 | 19886 | 6.372 |
| 5 | 9 | 25158 | 8.147 |
| 6 | 11 | 30380 | 7.389 |
| 7 | 13 | 35639 | 7.064 |
| 8 | 15 | 40840 | 8.800 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 54.534 | 54.534 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 43.7% |
| 3 | 55.9% |
| 4 | 72.0% |
| 5 | 73.2% |
| 6 | 80.9% |
| 7 | 85.2% |
| 8 | 84.4% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 58.2 |
| 2 | 71.0 |
| 3 | 61.8 |
| 4 | 55.3 |
| 5 | 55.6 |
| 6 | 56.3 |
| 7 | 51.5 |
| 8 | 51.8 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
