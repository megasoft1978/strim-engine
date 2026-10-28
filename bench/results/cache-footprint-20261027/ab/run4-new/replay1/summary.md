# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8219 | qwen38-4bit | on | bench/results/cache-footprint-20261027/ab/run4-new/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4090 | 4.136 |
| 2 | 3 | 9345 | 5.562 |
| 3 | 5 | 14626 | 5.861 |
| 4 | 7 | 19883 | 6.177 |
| 5 | 9 | 25155 | 6.498 |
| 6 | 11 | 30377 | 6.726 |
| 7 | 13 | 35636 | 7.153 |
| 8 | 15 | 40837 | 7.369 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 49.481 | 49.481 | 0 |

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
| 1 | 69.5 |
| 2 | 75.4 |
| 3 | 64.5 |
| 4 | 61.5 |
| 5 | 58.6 |
| 6 | 57.0 |
| 7 | 56.5 |
| 8 | 54.9 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
