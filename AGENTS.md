<!-- GENERATED FILE (ADR-0007) — do not edit directly.
     Sources: agents/canon/CANON.md + agents/canon/fragments/jules.md
     Regenerate: claude/scripts/gen-instruction-files.sh -->

# Repository guidance for cloud coding agents

This is the root `AGENTS.md` for `jckeen/dotfiles`. It is written for an agent
that arrives with no session history — Jules, a Codex cloud task, or any other
runtime that reads `AGENTS.md` and opens a pull request. Local runtimes load
their own fuller instruction file; this file is the part that must reach an
agent whose only context is the checkout in front of it.

## Working style

- Treat the worktree as shared with the user; do not revert changes you did not
  make unless explicitly asked.
- Read the surrounding code before changing behavior.
- Prefer the repository's existing patterns over new abstractions.
- Keep edits scoped to the requested behavior.
- Verify meaningful changes with the smallest useful test or static check.
- Report any test you could not run.

## Verifying a change

- Run the checks this repository's CI workflow runs, not a generic guess at
  them. The workflow is the source of truth for the commands and their pinned
  versions.
- A shell script change: `shellcheck --severity=warning` on the file, plus the
  self-test named in the script's header comment.
- A Python change: the repository's pinned `ruff check` and `ruff format
  --check`, plus the matching `*.test.py` under a `tests/` directory.
- A Markdown change: the doc-contract and doc-reference checkers under
  `claude/scripts/`.
- Paste the tail of every command you ran into the pull request body. Report a
  check you could not run rather than leaving it unmentioned.

## Pull request conventions

These bind a cloud agent opening a pull request from this brief. A pull
request shipped from an operator-attended local session under the operator's
standing authorization follows that runtime's instruction file and its review
gates instead; do not read it against this list.

- One pull request per finding. Unrelated findings are separate pull requests,
  never one batched change.
- Conventional commit subjects: `type: short description`, with the type set the
  repository's commit-format checker enforces.
- The body states the evidence for the change and the exact command that reverts
  it (`git revert <sha>`).
- Never push to the default branch and never bypass a hook or a required check.

## Documentation contract

Every tracked Markdown file is declared in the root `.doc-contract` with a tier
(LIVING, GENERATED, SOURCE, or HISTORICAL), and CI asserts it. Adding a Markdown
file means adding its contract entry in the same change. Never hand-edit a
GENERATED file — edit its source and regenerate. Never hardcode a count,
version, SHA, or hostname in guidance prose that CI cannot assert; point at the
file that holds it instead. A dated record — a `CHANGELOG.md` entry, a handoff
note — is a point-in-time statement and may state the figure it measured.

## Out of bounds

Do not change CI workflows, git hooks, or agent instruction surfaces: anything
under `.github/` or `githooks/`, any `AGENTS.md`, `CLAUDE.md` or `GEMINI.md`,
and anything under `agents/canon/`, `claude/skills/`, `agents/skills/` or
`antigravity/skills/`. Those changes need a human reviewer from the start, so
raise an issue instead of opening a pull request.

That is the cloud-agent rule. A local session under the operator's standing
authorization may prepare such a change, but it lands only after the operator
has reviewed the diff. The gates' instruction-surface override, which only the
operator can run, lifts the self-review guard; it is not the review itself. A
pull request carrying an operator-reviewed change, with that review stated in
its body, is not out of bounds.
