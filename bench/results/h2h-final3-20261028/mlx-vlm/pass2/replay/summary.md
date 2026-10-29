# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: mlx-vlm
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| mlx-vlm | http://127.0.0.1:8651 | /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit | on | bench/results/h2h-final3-20261028/mlx-vlm/pass2/server.txt |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | mlx-vlm |
| --- | --- | --- | --- |
| 1 | 1 | 4091 | 4.032 |
| 2 | 3 | 9346 | 9.370 |
| 3 | 5 | 14627 | 14.936 |
| 4 | 7 | 19884 | 20.686 |
| 5 | 9 | 25156 | 26.539 |
| 6 | 11 | 30378 | 32.530 |
| 7 | 13 | 35637 | 39.109 |
| 8 | 15 | 40838 | 45.671 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| mlx-vlm | 192.873 | 192.873 | 0 |

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
| 1 | 32.4 |
| 2 | 31.7 |
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
