# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8218 | qwen38-4bit | on | bench/results/cache-footprint-20261027/ab/run3-old/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4091 | 4.090 |
| 2 | 3 | 9346 | 6.568 |
| 3 | 5 | 14627 | 6.468 |
| 4 | 7 | 19884 | 6.125 |
| 5 | 9 | 25156 | 7.187 |
| 6 | 11 | 30378 | 6.662 |
| 7 | 13 | 35637 | 7.823 |
| 8 | 15 | 40838 | 7.277 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 52.199 | 52.199 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 32.9% |
| 3 | 59.8% |
| 4 | 73.5% |
| 5 | 76.4% |
| 6 | 82.8% |
| 7 | 83.5% |
| 8 | 87.2% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 66.8 |
| 2 | 72.2 |
| 3 | 63.0 |
| 4 | 60.4 |
| 5 | 58.4 |
| 6 | 53.7 |
| 7 | 57.2 |
| 8 | 50.6 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
