# Shared agent sources

## Instruction canon (`agents/canon/`)

`agents/canon/` is the canonical source for every global instruction file
(ADR-0007): shared cross-agent rules live once in `CANON.md`, per-tool voice and
tool-specific guidance in a `fragments/<tool>.md` skeleton.
`claude/scripts/gen-instruction-files.sh` compiles them; the `TARGET` map in
that script is the authoritative list of what it builds, and every target is a
committed build artifact. Edit the sources here and regenerate — CI's
`check-agent-parity.sh` fails on hand-edits or stale artifacts.

The root `AGENTS.md` is one of those targets, built from `fragments/cloud.md`.
It is the brief an agent reads from the checkout itself when it has
no session history — a Claude Code or Codex cloud session — so it carries only the rules
that survive without one: how to verify a change in this repository, the pull
request conventions, the doc contract, and what is out of bounds. It stays short
because Codex concatenates a repository's root `AGENTS.md` with the global
`~/.codex/AGENTS.md` under a size cap. Unlike the three local files it is not
held to the concept-parity phrase list in `check-agent-parity.sh`; byte currency
against its fragment is what CI asserts.

## Shared agent skills (`agents/skills/`)

`agents/skills/` is the agent-neutral workflow skill set — the single source
consumed by every non-Claude agent in this setup:

- **Codex**: `setup.sh` directory-links each skill into the documented user
  scope at `~/.agents/skills/<name>/`; per-file links under
  `~/.codex/skills/<name>/` remain as compatibility support for older clients.
- **Antigravity (agy)**: `setup.sh` dir-symlinks each skill into
  `~/.gemini/config/skills/<name>/`.

Claude Code keeps its own richer set under `claude/skills/`.
`agents/skill-coverage.tsv` classifies every workflow as shared or
runtime-specific, and `claude/scripts/check-skill-parity.sh` fails CI when a
skill is added, removed, or promoted without updating that contract. The
`changelog` and `handoff` pairs must also keep identical artifact shapes.

Keep these skills generic and public-safe — personal preferences and private
project context belong in the private memory repos (`codex-memory`,
`agy-memory`), not here.

> **Transition note:** this directory was `codex/skills/` until 2026-07
> (issue #166). It was renamed because it had become the shared source for
> both Codex and Antigravity, not a Codex-only set. Re-run `./setup.sh`
> after pulling so the `~/.agents/skills/`, compatibility
> `~/.codex/skills/`, and `~/.gemini/config/skills/`
> symlinks repoint at the new path.

## Capability and workflow contracts

`capabilities.json` declares each runtime's provider, scope, owner, prerequisite
interface, and passive probe. `claude/scripts/check-capability-parity.py` checks
public provider references in CI. Add `--live-home "$HOME"` for an advisory
installed-provider report; additional local skills are allowed. The report
checks presence and configuration, not execution, authentication, hook trust,
or equivalence between runtime internals. Unsupported and advisory capabilities
are explicit; no unverified hook adapter is installed by this contract.

`workflow-invariants.json`, adjacent to `skill-coverage.tsv`, declares the small
instruction requirements shared workflows must carry. The skill-parity checker
checks each Claude body and the shared Codex/Antigravity body or local override.
It ignores Markdown formatting, wrapping, frontmatter and comments; fixtures
verify that removing an invariant fails with its workflow and runtime named.
These checks detect declared instruction drift without requiring identical
wording or proving that an agent followed the instructions during execution.
