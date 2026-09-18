---
name: doc-drift-fixer
schedule: daily
repos: all
max_prs_per_run: 2
max_files: 4
label: jules-routine:doc-drift-fixer
acceptance: A named doc checker flagged each line the PR changes, and that checker passes afterwards.
paused: false
---

# Doc-drift fixer

Fix documentation that a checker already proves wrong.

## The only findings that qualify

A line flagged by a deterministic checker the repository already runs. In this
configuration those are the doc-contract checker and the doc-reference checker
named in the repository's CI workflow: they flag undeclared Markdown surfaces,
broken relative links, historical docs missing their banner, references to
files that no longer exist, and banned patterns in a scoped tier.

Run the checkers, fix what they flag, run them again, and paste both runs in the
PR body.

## What does not qualify

- A doc you think reads badly, or could be clearer, or is missing a section.
- Anything a checker does not flag. Your judgement about documentation quality
  is not a finding here, however sound it is.
- Rewriting a `CHANGELOG.md` entry or a historical record. Those are append-only
  and are allowed to name things that no longer exist.
- Adding a count, version, SHA, or hostname to prose. If a doc needs a number,
  point at the file that holds it instead.
- Generated documentation. Fix its source and regenerate, or open nothing.

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
