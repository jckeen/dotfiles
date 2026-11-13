## 2026-11-12 — test(gates): concurrent gate runs keep their own request, state and receipt (#680)

- **`claude/scripts/tests/codex-review-gate.test.sh`** gains a regression case
  for #680. Five live gate runs start at once and a barrier holds every
  reviewer in flight together. Two are multipart runs in separate repos, each
  with a request of over 1 MB. Three run in the primary checkout and two
  linked worktrees of one repo. Each run must end with its own verdict (four
  approvals and one block) and its own receipt. Each multipart
  reviewer must be sent its own repo's diff. A receipt copied from another
  repo, or from a sibling worktree, must not ship, including a copy of the
  same commit, where only the receipt's repository and Git directory tell
  the two apart. A deadline over the whole round fails the case instead of
  hanging the suite. It reports the stuck runs' pids and keeps their
  directories rather than killing them, since a killed gate cannot clean up
  its own temporary files. Each run's wrapper also sends its own output to
  /dev/null, so a stuck run cannot keep a piped caller waiting after the
  suite exits; a probe asserts that. A failed run's private diagnostic is
  removed (#765).
- No gate code changes. The gate already isolates concurrent runs: each run
  has a private run directory under its worktree's own receipt store, the
  attempt transitions take the store's flock, and every temporary file comes
  from `mktemp`. The collision #680 recorded was in the test fixture, which
  found the gate's request file in the shared `/tmp` by its digest; #743 fixed
  that with a per-run nonce.
- The new case fails against three mutants: a request file shared between
  runs, one receipt store shared across worktrees, and a receipt check that
  ignores the repository and Git directory. It passes against the real gate.
