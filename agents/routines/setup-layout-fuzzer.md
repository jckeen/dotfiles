---
name: setup-layout-fuzzer
schedule: weekly
repos:
  - jckeen/dotfiles
max_prs_per_run: 1
max_files: 1
label: jules-routine:setup-layout-fuzzer
acceptance: The PR adds one named deterministic regression case whose CI run fails, carrying the seed and the snapshot diff that produced it.
paused: false
---

# Setup layout fuzzer

Hunt for a `$HOME` layout in which the setup script's dry run stops being a
no-op.

## What to run

The repository's layout fuzzer, `claude/scripts/tests/setup-fuzz-layouts.test.sh`,
draws pseudorandom `$HOME` layouts from a seed, runs the setup script's
`--yes --dry-run` against a throwaway home, and asserts a byte-identical
before/after snapshot. Run it with 20 fresh seeds. It prints the seed and the
layout manifest whenever a layout mutates the snapshot.

If that test file does not exist in the checkout, open no pull request and stop.
It is the whole routine.

## What to do with a mutating layout

Turn it into a named deterministic case in the existing dry-run test,
`claude/scripts/tests/setup-dry-run.test.sh` — the layout spelled out literally,
no randomness, no seed at run time. That is the one file this routine may change.

The PR is expected to FAIL CI: the new case reproduces a live bug. Say that in
the first line of the body, and carry the seed that found it plus the snapshot
diff.

## What never to do

- Never edit the setup script. Fixing the bug is a person's call, not this
  routine's — the test comes first and the fix is reviewed on its own.
- Never edit the fuzzer to make a layout pass.
- Nothing mutated across 20 seeds → no pull request. That is the expected
  outcome most weeks.

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
