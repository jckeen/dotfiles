## 2026-11-14 — feat(ci): a checker for wasted CI runs

- **`claude/scripts/check-ci-efficiency.sh`** reports where a checkout's CI
  config wastes hosted minutes, for the two cases that can be read from
  files: a `pull_request` workflow that never cancels a superseded run, and a
  Dependabot `updates` entry with no `groups`. It is read-only and offline;
  `--all DIR` audits every checkout in a directory. A workflow that must not
  cancel carries a `# ci-efficiency: no-cancel` line with its reason.
  `pull_request_target` workflows are not judged. CI runs its self-test and
  runs it on this repo. It follows a month in which the hosted allowance ran
  out two weeks early.
- `smoke-install.yml` now cancels a superseded pull-request run; a manual run
  keeps a group of its own. `delete-branch-on-close.yml` and
  `harvest-codex-comments.yml` are marked as workflows that must not cancel.
