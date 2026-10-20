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
  requests, a self-contained shell step for the fragment scope rule: at most
  one added fragment, no edit, rename or copy of a fragment on the base, and
  no `## ` entry added to `CHANGELOG.md` beside a fragment (#626).
- `.github/CONTRIBUTING.md` gains a Changelog Entries section, and the PR
  template asks for a fragment instead of a `CHANGELOG.md` edit.
