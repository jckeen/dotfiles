## 2026-10-19 — fix: jules-dispatch max_files limit cannot wrap, and oversized PRs are recorded however they ended

- **`claude/scripts/jules-dispatch.sh`** (#639): `max_files` and
  `max_prs_per_run` are capped at six digits in the frontmatter, and a
  ledger `max_files` is capped the same way. A PR's `changedFiles` is capped
  at nine digits. Before, a value past 2^63-1 wrapped in `[[ -gt ]]`, so every
  non-empty pull request read as oversized.
- Reconcile now checks the size before the closed/merged no-op. A PR merged
  or closed before reconcile ran but over its session's limit is recorded
  `blocked-oversized` and counted in `reconcile.oversized`, not `noop`.
- An oversized PR that an earlier partial pass labeled
  `jules-routine:<routine>` has that label removed, so it no longer passes
  as a compliant routine result.
- Tests: three new cases in `claude/scripts/tests/jules-dispatch.test.sh`,
  covering a 20-digit limit in the ledger and the frontmatter, label removal,
  and a merged oversized PR.
