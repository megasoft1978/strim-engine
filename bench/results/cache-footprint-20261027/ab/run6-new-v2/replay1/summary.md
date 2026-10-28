# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8221 | qwen38-4bit | on | bench/results/cache-footprint-20261027/ab/run6-new-v2/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4090 | 4.172 |
| 2 | 3 | 9345 | 5.583 |
| 3 | 5 | 14626 | 5.898 |
| 4 | 7 | 19883 | 6.197 |
| 5 | 9 | 25155 | 6.536 |
| 6 | 11 | 30377 | 6.760 |
| 7 | 13 | 35636 | 7.166 |
| 8 | 15 | 40837 | 7.382 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 49.694 | 49.694 | 0 |

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
| 1 | 72.1 |
| 2 | 73.4 |
| 3 | 62.5 |
| 4 | 63.8 |
| 5 | 57.9 |
| 6 | 56.6 |
| 7 | 53.9 |
| 8 | 53.5 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
