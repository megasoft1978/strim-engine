# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8220 | qwen38-4bit | on | bench/results/cache-footprint-20261027/ab/run5-new-v2/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4089 | 4.195 |
| 2 | 3 | 9344 | 5.600 |
| 3 | 5 | 14625 | 5.916 |
| 4 | 7 | 19882 | 6.216 |
| 5 | 9 | 25154 | 6.534 |
| 6 | 11 | 30376 | 6.772 |
| 7 | 13 | 35635 | 7.188 |
| 8 | 15 | 40836 | 7.389 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 49.810 | 49.810 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 43.7% |
| 3 | 63.8% |
| 4 | 73.5% |
| 5 | 79.0% |
| 6 | 82.8% |
| 7 | 85.2% |
| 8 | 87.2% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 67.9 |
| 2 | 78.5 |
| 3 | 62.7 |
| 4 | 60.6 |
| 5 | 57.9 |
| 6 | 56.8 |
| 7 | 56.8 |
| 8 | 53.2 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
