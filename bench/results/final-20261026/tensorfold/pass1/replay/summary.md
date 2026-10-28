# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 3; session tag on
- order per rep: rep0: tensorfold; rep1: tensorfold; rep2: tensorfold
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| tensorfold | http://127.0.0.1:8651 | qwen38-4bit | on | /Users/user/Desktop/Freelance/strim-engine/bench/results/final-20261026/tensorfold/pass1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | tensorfold |
| --- | --- | --- | --- |
| 1 | 1 | 4092 | 3.965 |
| 2 | 3 | 9347 | 5.628 |
| 3 | 5 | 14628 | 5.952 |
| 4 | 7 | 19885 | 6.249 |
| 5 | 9 | 25157 | 6.712 |
| 6 | 11 | 30379 | 7.166 |
| 7 | 13 | n/a | n/a |
| 8 | 15 | n/a | n/a |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| tensorfold | n/a | n/a | 3 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | tensorfold |
| --- | --- |
| 1 | 0.0% |
| 2 | 42.5% |
| 3 | 63.9% |
| 4 | 73.5% |
| 5 | 79.0% |
| 6 | 82.8% |
| 7 | unknown |
| 8 | unknown |

## Decode tok/s per turn (median over reps)

| turn | tensorfold |
| --- | --- |
| 1 | 28.9 |
| 2 | 26.7 |
| 3 | 28.2 |
| 4 | 23.3 |
| 5 | 26.3 |
| 6 | 24.6 |
| 7 | n/a |
| 8 | n/a |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 6; rows excluded from decode (short / no_usage): 0.
