## 2026-10-22 — docs(changelog): archive 2026 Q3 out of CHANGELOG.md (#707)

- **CHANGELOG.md holds the current quarter again.** The 101 entries dated
  2026-07-03 to 2026-09-25 moved verbatim to `docs/changelog/CHANGELOG-2026-Q3.md`,
  which the footer links beside the Q1 and Q2 archives. The move went out as
  two pull requests (add the archive, then trim CHANGELOG.md) because the
  review gate caps a fenced review at `CODEX_GATE_MAX_LINES` and the whole
  move exceeds it.
