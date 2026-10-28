# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | /tmp/perfval/s3r-1024x1536-1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4092 | 4.069 |
| 2 | 3 | 9347 | 6.562 |
| 3 | 5 | 14628 | 6.499 |
| 4 | 7 | 19885 | 6.138 |
| 5 | 9 | 25157 | 7.220 |
| 6 | 11 | 30379 | 6.683 |
| 7 | 13 | 35638 | 7.851 |
| 8 | 15 | 40839 | 7.316 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 52.338 | 52.338 | 0 |

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
| 1 | 58.1 |
| 2 | 74.2 |
| 3 | 62.2 |
| 4 | 59.7 |
| 5 | 58.0 |
| 6 | 52.9 |
| 7 | 54.7 |
| 8 | 50.0 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
