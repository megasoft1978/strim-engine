---
name: diff-review
description: Review a working diff for correctness, regressions, and missing tests before reporting done.
---

# diff-review

Use before declaring a non-trivial change complete, or when asked to review.

1. `git diff --stat` and `git diff` (use `git diff -- <path>` for a large diff).
2. Call `strim_review_diff` with the diff and the changed file paths. Treat its findings as
   hypotheses: verify each against the code before repeating it.
3. Check the three usual regressions: a changed public contract, a path that now skips a test,
   and an error path that no longer restores state.
4. Run the smallest relevant test/build command. If it cannot run, say exactly why.
5. Report only verified findings, each as `path:line — problem — fix`. Do not pad with style
   opinions. If the diff is clean, say so and name the test you ran.
