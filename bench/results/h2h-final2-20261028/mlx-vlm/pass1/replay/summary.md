# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: mlx-vlm
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| mlx-vlm | http://127.0.0.1:8651 | /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit | on | bench/results/h2h-final2-20261028/raw/mlx-vlm/pass1/server.txt |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | mlx-vlm |
| --- | --- | --- | --- |
| 1 | 1 | 4094 | 4.039 |
| 2 | 3 | 9349 | 9.374 |
| 3 | 5 | 14630 | 14.835 |
| 4 | 7 | 19887 | 20.538 |
| 5 | 9 | 25159 | 26.662 |
| 6 | 11 | 30381 | 32.998 |
| 7 | 13 | 35640 | 39.918 |
| 8 | 15 | 40841 | 46.407 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| mlx-vlm | 194.771 | 194.771 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | mlx-vlm |
| --- | --- |
| 1 | 0.0% |
| 2 | 0.0% |
| 3 | 0.0% |
| 4 | 0.0% |
| 5 | 0.0% |
| 6 | 0.0% |
| 7 | 0.0% |
| 8 | 0.0% |

## Decode tok/s per turn (median over reps)

| turn | mlx-vlm |
| --- | --- |
| 1 | 31.7 |
| 2 | 30.4 |
| 3 | n/a |
| 4 | n/a |
| 5 | n/a |
| 6 | n/a |
| 7 | n/a |
| 8 | n/a |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 6.
