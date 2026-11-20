<!-- GENERATED FILE (ADR-0007) — do not edit directly.
     Sources: agents/canon/CANON.md + agents/canon/fragments/cloud.md
     Regenerate: claude/scripts/gen-instruction-files.sh -->

# Repository guidance for cloud coding agents

This is the root `AGENTS.md` for `jckeen/dotfiles`. It is written for an agent
that arrives with no session history — a Claude Code or Codex cloud session, or
any other runtime that reads `AGENTS.md` and opens a pull request. Local
runtimes load their own fuller instruction file; this file is the part that
must reach an agent whose only context is the checkout in front of it.

A cloud session has this checkout and nothing else: the global instruction
file, the skills, the hooks and the local review gates are not installed
there. CI and the pull-request review are the checks that apply, so never
report a local gate or hook as having run.

## Working style

- Treat the worktree as shared with the user; do not revert changes you did not
  make unless explicitly asked.
- Read the surrounding code before changing behavior.
- Prefer the repository's existing patterns over new abstractions.
- Keep edits scoped to the requested behavior.
- Verify meaningful changes with the smallest useful test or static check.
- Report any test you could not run.
- A test asserts behavior: call the code and check its result. Never assert on
  source text, or only that a mock was called. Use the lowest test level that
  proves the change, and a fake over a mock.
- Prefer the real engine or parser over a hand-rolled regex or grammar scanner
  in tests: let the target runtime evaluate or parse the artifact (for
  example, PostgreSQL `PREPARE` and `pg_locks` instead of regex-scanning SQL)
  so grammar edge cases cannot slip past the test.

## Build standards

- **Build standards hold in every language (ADR-0010).** Each is enforced by
  lint where the repo has a rule for it and by review where it has none; the
  repo's config holds the numbers.
  - *Size budget:* where the repo's config sets a line budget, a file over it
    may not grow. A change that would grow it extracts just enough of the
    code it is editing to keep the file at its current length; that
    extraction is part of the change, and any wider split is its own change.
    No configured budget, no size rule.
  - *Contracts at the boundary:* data entering the application from outside
    (a request, a webhook, model output, a file, the environment) is validated
    once, where it enters, by the language's contract mechanism: a runtime
    schema with the static type derived from it, where the language has one.
    Internal calls and data already validated are not boundaries.
  - *Explicit state:* a feature with a lifecycle models it as a tagged union
    or a transition table, never as loose booleans or one type with many
    optional fields. A feature with no lifecycle gets no state machine.
  - *Pure core, injected edges:* domain logic takes its dependencies and the
    current time as arguments instead of importing network, disk, database or
    clock. Adapters and orchestration, whose job is the I/O, live in their
    own modules.
  - *No type escape hatches:* no `any`-equivalent and no unchecked cast.
    Narrow with a check or a parse.
  - *Fakes over mocks:* test domain behaviour against an in-memory
    implementation of the port, not by spying on which method was called.
    Rules about who may import what belong in the linter, not the test runner.
  - *Ratchet:* in a repo that has recorded its baseline, existing violations
    may only decrease and a new file meets every rule. In one that has not,
    new files and new functions meet these; an edit inside existing code
    follows that code's current shape, and nothing existing is rewritten to
    conform.

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
A pull request's changelog entry is one `changelog.d/<branch-slug>.md`
fragment (the branch name with every `/` turned to `-`); `CHANGELOG.md` is
never edited in a pull request, except the one that folds the fragments in.
A fragment allows no `<` placeholders (write NAME-style ones), code fences or
HTML comments.

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
