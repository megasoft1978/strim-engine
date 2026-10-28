# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 3; session tag on
- order per rep: rep0: omlx; rep1: omlx; rep2: omlx
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| omlx | http://127.0.0.1:8651 | qwen38-4bit | on | /Users/user/Desktop/Freelance/strim-engine/bench/results/final-20261026/omlx/pass1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | omlx |
| --- | --- | --- | --- |
| 1 | 1 | n/a | n/a |
| 2 | 3 | n/a | n/a |
| 3 | 5 | n/a | n/a |
| 4 | 7 | n/a | n/a |
| 5 | 9 | n/a | n/a |
| 6 | 11 | n/a | n/a |
| 7 | 13 | n/a | n/a |
| 8 | 15 | n/a | n/a |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| omlx | n/a | n/a | 3 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | omlx |
| --- | --- |
| 1 | unknown |
| 2 | unknown |
| 3 | unknown |
| 4 | unknown |
| 5 | unknown |
| 6 | unknown |
| 7 | unknown |
| 8 | unknown |

## Decode tok/s per turn (median over reps)

| turn | omlx |
| --- | --- |
| 1 | n/a |
| 2 | n/a |
| 3 | n/a |
| 4 | n/a |
| 5 | n/a |
| 6 | n/a |
| 7 | n/a |
| 8 | n/a |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 24; rows excluded from decode (short / no_usage): 0.
