---
name: repo-context
description: Gather the minimum repository context for a task without dumping the repo into a 27B dense context window.
---

# repo-context

Use when the task names a feature, error, or file area you have not inspected.

1. Locate, do not list everything:
   - `rg --files -g '!vendor' -g '!node_modules' | head -80`
   - `rg -n "<symbol or error text>" --glob '!vendor' --glob '!node_modules'`
   - `git status --short` and `git diff --stat` when the task is about current work.
2. Pick at most 12 files. For each, read the smallest relevant range with `sed -n` or the read
   tool. For files over 400 lines, call `strim_summarize` first and read only the cited ranges.
3. Run `python3 scripts/context_pack.py --root . --paths <files>` to produce a compact map of
   symbols, sizes, and likely entry points. Do not paste its raw output into the final answer.
4. Write a five-bullet context note for yourself: entry point, data flow, test command, risk,
   open question. If a bullet is unknown, inspect one more thing; do not guess.
5. Stop gathering when the note answers the task. Extra context is a cost, not a virtue.
