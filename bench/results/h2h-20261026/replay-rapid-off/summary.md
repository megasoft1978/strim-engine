# Agent replay summary

- fixture: `bench/results/h2h-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 2; session tag on
- order per rep: rep0: rapid-off; rep1: rapid-off
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| rapid-off | http://127.0.0.1:8202 | models/qwen38-4bit | off | bench/results/h2h-20261026/logs/rapid-off.server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | rapid-off |
| --- | --- | --- | --- |
| 1 | 1 | 4093 | 4.083 |
| 2 | 3 | 9348 | 9.380 |
| 3 | 5 | 14629 | 14.945 |
| 4 | 7 | 19886 | 20.694 |
| 5 | 9 | 25158 | 26.901 |
| 6 | 11 | 30380 | 33.077 |
| 7 | 13 | 35639 | 39.827 |
| 8 | 15 | 40840 | 46.448 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| rapid-off | 195.354 | 195.691 / 195.016 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | rapid-off |
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

| turn | rapid-off |
| --- | --- |
| 1 | 49.8 |
| 2 | 44.7 |
| 3 | n/a |
| 4 | n/a |
| 5 | n/a |
| 6 | n/a |
| 7 | n/a |
| 8 | n/a |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 12.
