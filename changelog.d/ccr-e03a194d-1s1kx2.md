## 2026-11-10 — fix(gates): one finding class across many files is one issue (#761)

- **`claude/scripts/codex-review-schema.json`** gains a required `category` on
  every finding, and the review prompt asks for the same category on findings
  of the same kind. The local validator in `codex-review-gate.sh` requires it
  too, so a finding without one is not a valid review.
- **`claude/scripts/codex-review-gate.sh`**: new low findings that share a
  category across two or more files are filed as one issue. It lists every
  location as a checklist item and carries one location marker per file, so
  the per-file dedup and the close-as-not-planned acceptance keep working for
  each file. A category in a single new file is filed as before. One review
  had produced eleven near-identical issues, one per file (#744 to #753, #757).
- The category is reduced to a lowercase slug before it reaches an issue
  title, and it never affects the verdict.
- Tests: `claude/scripts/tests/codex-review-gate.test.sh` covers the grouped
  issue, a later run on a grouped file, an accepted group, a single new file,
  the dry-run preview, and the rejection of a finding with no category.
