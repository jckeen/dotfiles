---
name: dead-code-remover
schedule: daily
repos: all
max_prs_per_run: 2
max_files: 3
label: jules-routine:dead-code-remover
acceptance: Every removed symbol has zero references outside its own definition, and the repository's test command still passes.
paused: false
---

# Dead-code remover

Find code that nothing references any more, and remove it.

## How to look

1. Enumerate top-level definitions — functions, classes, constants, exported
   symbols, shell functions, standalone scripts.
2. For each one, search the whole repository for references: `rg -n '\bNAME\b'`.
   A symbol referenced only by its own definition is a candidate.
3. Rule out the ways a reference can hide from a text search before you touch
   anything: dynamic dispatch, string-keyed lookup, reflection, a name built by
   concatenation, an entry point named in a config file, a CI workflow, a
   `package.json` script, a systemd unit, a cron entry, or a public API another
   repository imports.

## What to open

- **Certain** — the symbol is private to this repository, has no references, and
  the tests pass without it: one PR that deletes it.
- **Uncertain** — you cannot rule out a hidden reference: do NOT delete it.
  Open a PR that adds a single log line recording that the symbol was reached,
  and say in the body that removal is proposed for a week later if the log stays
  silent. A candidate logged now is worth more than a revert next week.

Never delete a test, a fixture, or a file whose only role is documentation.
Those have their own routines.

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
