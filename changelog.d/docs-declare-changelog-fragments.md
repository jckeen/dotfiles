## 2026-10-19 — docs: declare changelog.d/ fragments

- **`.doc-contract`** declares `changelog.d/*.md` as LIVING, like `CHANGELOG.md`;
  **`check-doc-truth.sh`** exempts it from the dead-link rule, and
  **`claude/scripts/check-doc-refs.sh`** exempts it from the dead-reference
  rule, as it already exempts `CHANGELOG.md`. A PR may now record its entry
  as one `changelog.d/BRANCH-SLUG.md` fragment instead of prepending to
  `CHANGELOG.md`, so open PRs stop conflicting on the file's head (#626).
- Fragments are folded into `CHANGELOG.md` by hand until the
  `assemble-changelog.sh` tool in #661 lands. Each one holds a
  `## YYYY-MM-DD — type: summary` heading followed by bullets.
