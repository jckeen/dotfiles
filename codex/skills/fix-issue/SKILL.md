---
name: fix-issue
description: Pick up a GitHub issue or issue-like bug report end to end: investigate, reproduce when useful, implement, verify, commit, push, and prepare a PR when requested.
---

# Fix Issue

Use this workflow for GitHub issue numbers, issue URLs, or clear bug reports.

## Workflow

1. Understand the issue:
   - For GitHub issues, use `gh issue view` when available.
   - Read linked files, logs, screenshots, and acceptance criteria.
2. Investigate locally:
   - Search with `rg`.
   - Read the implementation and nearby tests before editing.
   - Identify the smallest behavioral surface that should change.
3. Reproduce first when practical:
   - Add or run a failing test for bugs.
   - For UI issues, reproduce with the project’s existing tooling when possible.
4. Implement the minimum fix.
5. Verify:
   - Run the focused new test first.
   - Then run the smallest useful existing test, lint, or typecheck command.
6. If asked to ship:
   - Stage only relevant files.
   - Commit with a conventional message such as
     `fix: handle expired session refresh (#123)`.
   - Push and create a PR with summary, fix details, verification, and
     `Fixes #N` when applicable.

## Constraints

- Do not use broad staging like `git add -A` when unrelated files exist.
- Do not commit secrets, generated runtime state, or unrelated cleanup.
- Do not close ambiguity by guessing if the issue lacks enough information to
  define expected behavior.
