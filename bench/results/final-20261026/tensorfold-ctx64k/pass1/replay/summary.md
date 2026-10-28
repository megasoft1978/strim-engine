# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 3; session tag on
- order per rep: rep0: tensorfold-ctx64k; rep1: tensorfold-ctx64k; rep2: tensorfold-ctx64k
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| tensorfold-ctx64k | http://127.0.0.1:8651 | qwen38-4bit | on | /Users/user/Desktop/Freelance/strim-engine/bench/results/final-20261026/tensorfold-ctx64k/pass1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | tensorfold-ctx64k |
| --- | --- | --- | --- |
| 1 | 1 | 4098 | 4.111 |
| 2 | 3 | 9353 | 5.617 |
| 3 | 5 | 14634 | 5.891 |
| 4 | 7 | 19891 | 6.193 |
| 5 | 9 | 25163 | 6.561 |
| 6 | 11 | 30385 | 6.885 |
| 7 | 13 | 35644 | 7.251 |
| 8 | 15 | 40845 | 7.571 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| tensorfold-ctx64k | 50.119 | 50.119 / 50.171 / 50.092 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | tensorfold-ctx64k |
| --- | --- |
| 1 | 0.0% |
| 2 | 43.7% |
| 3 | 63.9% |
| 4 | 73.5% |
| 5 | 79.0% |
| 6 | 82.8% |
| 7 | 85.2% |
| 8 | 87.2% |

## Decode tok/s per turn (median over reps)

| turn | tensorfold-ctx64k |
| --- | --- |
| 1 | 29.2 |
| 2 | 28.9 |
| 3 | 28.3 |
| 4 | 27.5 |
| 5 | 27.0 |
| 6 | 26.3 |
| 7 | 25.6 |
| 8 | 24.9 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
