## 2026-10-22 — fix(operator-queue): search per scope and retry incomplete results (#716)

- **OperatorQueueReminder hook**: GitHub search often times out partway and
  answers short, which the completeness check rightly refused — so with the
  queue file retired, no cache was ever built. The refresh now searches one
  scope at a time (home repo, then each owner), retries a search that comes
  back incomplete (`OPERATOR_QUEUE_RETRY_SLEEPS`, default `2 5`), and merges
  the results by node id. `--find` retries the same way.
