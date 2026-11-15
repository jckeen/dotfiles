## 2026-11-14 — feat(ci): an advisory audit for wasted CI runs

- **`claude/scripts/check-ci-efficiency.py`** reports where a checkout's CI
  config wastes hosted minutes, for the two cases that can be read from
  files (it parses the YAML, so it needs PyYAML): a `pull_request` workflow
  it cannot confirm cancels a superseded run, and a Dependabot `updates`
  entry with no routine grouping. Cancellation depends on expressions GitHub
  evaluates at run time, so the check recognises a short list of
  `concurrency` forms and reports the rest instead of guessing. It is
  read-only and offline;
  `--all DIR` audits every checkout in a directory. A workflow that must not
  cancel carries a `# ci-efficiency: no-cancel` line with its reason.
  `pull_request_target` workflows are not judged. It is advisory: a finding
  is a lead, a clean result proves nothing, and the script header lists the
  configs known to pass without cancelling or grouping. CI runs its self-test
  only; its verdict gates nothing. It follows a month in which the hosted allowance ran
  out two weeks early.
- `smoke-install.yml` now cancels a superseded pull-request run; a manual run
  keeps a group of its own. `delete-branch-on-close.yml` and
  `harvest-codex-comments.yml` are marked as workflows that must not cancel.
