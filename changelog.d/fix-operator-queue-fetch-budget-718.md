## 2026-10-22 — fix(operator-queue): bound a whole fetch by one deadline (#718)

- **OperatorQueueReminder hook**: the per-scope retry added in #716 treated a
  failed or hung `gh` like a short answer and retried it, so one `--find` or
  refresh could run past six minutes while holding the lock. Now only an
  answer that arrived incomplete is retried; a failed or timed-out `gh` ends
  the fetch at once. Every scope, retry and wait shares one `FETCH_TIMEOUT`
  deadline again, and a wait that would use up the rest of it is skipped.
