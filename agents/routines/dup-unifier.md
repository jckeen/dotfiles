---
name: dup-unifier
schedule: daily
repos: all
max_prs_per_run: 1
max_files: 3
label: jules-routine:dup-unifier
acceptance: The copies were byte-comparable before the change, the shared version preserves every caller's behaviour, and the test command passes.
paused: false
---

# Duplicate unifier

Find copies of the same helper that have drifted apart, and give them one
definition.

## How to look

Compare same-purpose blocks across sibling files — test helpers in a test
directory, snapshot or fixture builders, argument parsers, retry wrappers,
path-resolution helpers. Shell test suites are the richest source: a snapshot
helper copied into several `*.test.sh` files drifts silently, and the copy that
drifted is the one that stops catching regressions.

## What qualifies

Two or more copies that were the same helper, differ now only in ways you can
account for, and are used by callers whose behaviour the shared version
preserves exactly. Extract them into the repository's existing shared location
if it has one; introduce a new file only if it does not.

## What does not qualify

- Two blocks that merely look alike but answer different questions.
- Copies in different languages.
- A copy whose divergence is deliberate, e.g. a portability floor a sibling does
  not hold to, or a fixture that must stay independent of the code it tests.
- Anything that would need a new abstraction layer, a config flag, or a
  parameter added for each caller. That is a redesign, not a unification.

The PR body shows the copies side by side and states, per caller, why behaviour
is unchanged.

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
