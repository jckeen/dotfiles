## 2026-11-14 — docs(canon): CI cost standard in every agent's instructions

- **New canon block `ci-cost`** (`agents/canon/CANON.md`), compiled into
  `claude/CLAUDE.md`, `codex/AGENTS.md` and `antigravity/GEMINI.md`: hosted CI
  minutes are a budget in every repo. The full suite runs once per merge and
  every other run is cheap: the merge queue's run where there is a queue,
  otherwise the pull request's required run, with the default branch skipping
  a job only when that same job already passed on the identical tree. It
  names the measures (cancel superseded runs, group dependency updates, skip
  unaffected jobs only behind one aggregate required check) and forbids
  saving minutes by weakening what gates a merge. The root `AGENTS.md` for cloud sessions is unchanged.
  When the task is not CI an agent changes no CI and files an issue; required
  checks, branch protection and merge queues stay the operator's decision.
  `check-agent-parity.sh` now holds the rule in all three files.
