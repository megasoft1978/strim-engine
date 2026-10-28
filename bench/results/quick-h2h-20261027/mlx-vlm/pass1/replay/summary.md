# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: mlx-vlm
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| mlx-vlm | http://127.0.0.1:8651 | /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit | on | bench/results/quick-h2h-20261027/mlx-vlm/pass1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | mlx-vlm |
| --- | --- | --- | --- |
| 1 | 1 | 4095 | 4.039 |
| 2 | 3 | 9350 | 9.373 |
| 3 | 5 | 14631 | 14.942 |
| 4 | 7 | 19888 | 20.694 |
| 5 | 9 | 25160 | 26.895 |
| 6 | 11 | 30382 | 33.113 |
| 7 | 13 | 35641 | 39.843 |
| 8 | 15 | 40842 | 46.570 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| mlx-vlm | 195.470 | 195.470 | 0 |

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
| 1 | 31.6 |
| 2 | 31.1 |
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
