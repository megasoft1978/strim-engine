---
name: test-fix
description: Reproduce a failing test or build, diagnose it with local evidence, and make the smallest fix.
---

# test-fix

Use when a build or test fails.

1. Reproduce the failure with the project's own command and keep the first error, not the whole
   log. `2>&1 | tail -80` is usually enough; use `head`/`rg -n "error|FAIL"` for a long log.
2. Call `strim_explain_error` with the error text and the most relevant file. Treat CAUSE /
   EVIDENCE / NEXT as hypotheses; confirm in the source.
3. Fix the cause, not the assertion. Never delete a test, loosen an assertion, or add a sleep to
   hide a race unless the task explicitly asks for a behavior change.
4. Rerun the exact failing command, then the nearest broader suite. Report the command and result.
5. If the failure is environmental (missing model, disk, network), say so and stop; do not edit
   code to work around the environment.
