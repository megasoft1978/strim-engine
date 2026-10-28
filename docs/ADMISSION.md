# Priority admission

`StrimAdmission` (no dependencies) holds the policy; `StrimJobs` and `StrimServer` share one `PriorityGate`.

- Classes: `interactive` (chat: HTTP requests with default or `interactive` priority, chat user turns with `RunProfile.interactive`) and `background` (`x-strim-priority: background`, delegated/MCP jobs, `RunProfile.delegated`). Raw values equal `StrimEngine.Priority`.
- Slots: `maxInflight` total; background capped at `maxBackground` (clamped to `maxInflight - 1`, min 1) so an arriving interactive request finds a free slot. Interactive always goes first; a background waiter is passed over at most `starvationLimit` interactive admissions.
- Order: the slot is taken BEFORE the engine call (HTTP: before session lease/append; jobs: before the executor starts). Disconnect or cancel while queued drops the waiter; every exit path releases.
- Turn boundaries: `AgentLoop` calls `AdmissionCheckpoint.wait()` before each model turn except the first (task-local, bound by `JobManager` for background jobs; a no-op when unbound, e.g. chat). A checkpoint that is cancelled while waiting ends the run as `cancelled` (worktree cleaned). While interactive work is active or queued the job gives up its slot and re-queues; it resumes when interactive work is gone (or the starvation guard fires). Never mid-token.
- Enable: `strim serve` builds one `PriorityGate` and passes it as `ServerConfig(admission:)`; `StrimHost` hands it to `JobManager`. On by default.
  - `--max-inflight N`: total slots. Default `STRIM_MAX_SESSIONS` (8). The engine has no fixed sequence count (it admits by memory, `insufficient_memory`), so this is an admission cap, not the engine batch size.
  - `--max-background N`: background cap. Default inflight - 1 (min 1); clamped to inflight - 1.
  - `--no-admission`: no gate, no checkpoints (previous behaviour).
  - Startup log: `admission: on  max_inflight=N  max_background=M` or `admission: off (--no-admission)`. Parsing and defaults: `AdmissionOptions` (unit-tested).

Engine hook: implement `AdmissionControlling` in the scheduler (or map `AdmissionClass.rawValue` to `Priority`) and inject it instead of `PriorityGate`.
