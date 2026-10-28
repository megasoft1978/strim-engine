# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 3; session tag on
- order per rep: rep0: llama.cpp; rep1: llama.cpp; rep2: llama.cpp
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| llama.cpp | http://127.0.0.1:8080 | /Users/user/Desktop/Freelance/strim-engine/models/gguf/Qwen3.8-27B-Q4_K_M.gguf | on | /Users/user/Desktop/Freelance/strim-engine/bench/results/final-20261026/llama.cpp/pass1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | llama.cpp |
| --- | --- | --- | --- |
| 1 | 1 | 4094 | 5.789 |
| 2 | 3 | 9349 | 7.506 |
| 3 | 5 | 14630 | 8.060 |
| 4 | 7 | 19887 | 8.632 |
| 5 | 9 | 25159 | 9.153 |
| 6 | 11 | 30381 | 9.592 |
| 7 | 13 | n/a | n/a |
| 8 | 15 | n/a | n/a |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| llama.cpp | n/a | n/a | 3 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | llama.cpp |
| --- | --- |
| 1 | 0.0% |
| 2 | 43.7% |
| 3 | 63.9% |
| 4 | 73.5% |
| 5 | 79.0% |
| 6 | 82.8% |
| 7 | unknown |
| 8 | unknown |

## Decode tok/s per turn (median over reps)

| turn | llama.cpp |
| --- | --- |
| 1 | 27.8 |
| 2 | 27.2 |
| 3 | 25.5 |
| 4 | 25.9 |
| 5 | 25.3 |
| 6 | 24.7 |
| 7 | n/a |
| 8 | n/a |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 6; rows excluded from decode (short / no_usage): 0.
