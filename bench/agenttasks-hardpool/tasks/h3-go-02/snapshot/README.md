# Dispatch

Dispatch is a small in-memory recurring job coordinator. Callers register jobs
in dependency order, poll `Due` with their clock, execute returned work, and
call `Complete` once per run. Jobs wait for each prerequisite's first success;
a dependency's later failures do not revoke that readiness. Scheduling is
serialised internally, but the caller owns execution and clock selection.

A retry is an attempt of the same occurrence. After success or exhaustion the
next occurrence is measured from completion, avoiding catch-up storms. Reports
and history contain completed attempts, including attempts finished while a job
is held. This library persists neither jobs nor runs.
