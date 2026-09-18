---
name: lint-debt-fixer
schedule: daily
repos: all
max_prs_per_run: 2
max_files: 6
label: jules-routine:lint-debt-fixer
acceptance: One lint rule per PR, every finding fixed at the source, no suppression comment added, and both the linter and the test command pass.
paused: false
---

# Lint-debt fixer

Clear the repository's own linters, one rule per pull request.

## How to look

Run the linters the repository already configures — do not introduce a linter,
change its configuration, or raise its severity. Read the repository's CI
workflow to find the exact commands and pinned versions, and run those.

Group the findings by rule. Pick the rule with the most findings that you can
fix at the source, and fix every instance of that one rule.

## Hard constraints

- One rule per PR. A PR that fixes three rules is three PRs.
- Never add a suppression: no `# noqa`, no `# shellcheck disable`, no
  `eslint-disable`, no `# type: ignore`, no per-file ignore entry. If a finding
  can only be silenced, leave it and say so in the PR body.
- Never change the linter's configuration, pinned version, or rule selection.
- Never reformat code the rule does not flag. A formatting sweep is its own
  change and it buries the review.

The PR body names the rule, the count of findings it fixed, and the tail of both
the linter run and the test run.

## Rules for every routine run

- Read the repository's `AGENTS.md` first. If the repository has none, read
  `CLAUDE.md` and `README.md` instead — they carry the same working rules.
- One pull request per finding. Never batch unrelated findings into one PR.
- Change no more files per pull request than the "Hard limits" line above allows.
- Run the repository's own test command, and paste the tail of its output into
  the PR body. If you cannot find or cannot run it, say so in the PR body
  instead of claiming a pass.
- Apply the required PR label from the "Hard limits" line above.
- The PR body states the evidence for the change and the exact command that
  reverts it (`git revert <sha>`).
- Never edit CI workflows, git hooks, or agent instruction files — anything
  under a `.github/` directory, anything under a `githooks/` directory, and any
  `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `agents/canon/`, `claude/skills/` or
  `agents/skills/` path.
- If nothing qualifies, open no pull request. An empty run is a good run.
