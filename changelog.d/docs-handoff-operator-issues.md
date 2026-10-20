## 2026-10-19 — docs(handoff): file operator items as issues in the repo they concern

- **Handoff skills** (`claude/` and `agents/`): USER ACTION items are filed as
  `operator-action` issues in the private repo they concern. Items for a public
  repo or for several repos go to the private home repo. Close an issue only
  when it is done; bump `verified` with a comment. `~/.claude/operator-queue.md`
  is retired. The workflow invariant now reads "close it only when done".
- **OperatorQueueReminder hook**: new `--scope` (prints the host, home repo
  and owners it searches) and `--find <slug>` (prints each open item it would
  list under that slug; exit 2 when it cannot tell). The handoff skills call
  these instead of copying the hook's search, so the two can no longer drift.
  The refresh and `--find` share one GraphQL query and one "what counts" filter.
