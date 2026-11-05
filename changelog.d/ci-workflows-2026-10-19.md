## 2026-10-19 — ci: harvest late Codex bot reviews; enforce changelog-fragment scope

- `harvest-codex-comments.yml` also runs on `pull_request_review: submitted`,
  for reviews by `chatgpt-codex-connector[bot]` on merged same-repo PRs, so a
  bot review that lands after a fast auto-merge is harvested (#617). A review
  payload has `merged_at` but no `merged` field, so the review path tests
  `merged_at`. Token scopes, the merge-commit checkout and the close-time run
  are unchanged. Concurrency moved to the job and is gated on the job's `if`,
  so a human review queued on the same PR cannot replace the bot's pending run.
- Dropped the unverifiable claim that a nightly routine re-runs the harvest as
  a backstop, from the workflow header, `harvest-codex-comments.sh` and the
  scripts README. New `WorkflowTriggerTests` in
  `tests/harvest-codex-comments.test.py` evaluate the job's `if` against
  close and review payloads, and pin the triggers, token scopes, the checkout
  ref and the concurrency gate.
- The `doc-truth` job runs `assemble-changelog.sh --check` and, on pull
  requests, a self-contained shell step for the fragment scope rule, read
  from the diff's file list alone: at most one added fragment, no edit or
  rename of a fragment on the base, no `CHANGELOG.md` edit beside a fragment,
  and fragments removed only all at once by a fold PR whose `CHANGELOG.md`
  carries every removed entry's heading (#626). `tests/changelog-scope.test.sh` extracts the step
  from `ci.yml` and runs it against fixture repos.
- `.github/CONTRIBUTING.md` gains a Changelog Entries section, and the PR
  template asks for a fragment instead of a `CHANGELOG.md` edit.
- The `doc-truth (bash 3.2)` job runs `tests/statusline.test.sh` with
  `STATUSLINE_BASH3` set to its bash 3.2.57 build, so `claude/statusline.sh`
  is rendered under the shell the macOS settings template invokes (#588).
- **The fold check compares every fragment line, not only headings (Codex
  gate, 2026-11-05).** A fold that copied each entry heading into
  `CHANGELOG.md` and dropped every bullet passed the PR-scope step and the
  content validator alike, and matching lines anywhere in the file let a fold
  drop a bullet an older entry shared or hide every entry in an HTML comment.
  The step now requires `CHANGELOG.md` to differ from the base by exactly one
  inserted block whose non-blank lines are the removed fragments' lines, each
  fragment contiguous and in order, placed above the first existing entry;
  eight cases in `changelog-scope.test.sh` cover the bypasses.
