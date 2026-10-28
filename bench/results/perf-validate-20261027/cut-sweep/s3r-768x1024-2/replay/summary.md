# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | /tmp/perfval/s3r-768x1024-2/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4090 | 4.225 |
| 2 | 3 | 9345 | 5.556 |
| 3 | 5 | 14626 | 6.021 |
| 4 | 7 | 19883 | 6.480 |
| 5 | 9 | 25155 | 7.011 |
| 6 | 11 | 30377 | 7.426 |
| 7 | 13 | 35636 | 8.083 |
| 8 | 15 | 40837 | 7.246 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 52.048 | 52.048 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 43.7% |
| 3 | 62.9% |
| 4 | 72.0% |
| 5 | 77.3% |
| 6 | 80.9% |
| 7 | 83.3% |
| 8 | 87.2% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 72.0 |
| 2 | 68.4 |
| 3 | 60.6 |
| 4 | 54.9 |
| 5 | 54.7 |
| 6 | 52.7 |
| 7 | 54.1 |
| 8 | 52.4 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
