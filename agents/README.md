# Shared agent sources

## Instruction canon (`agents/canon/`)

`agents/canon/` is the canonical source for the three global instruction
files (ADR-0007): shared cross-agent rules live once in `CANON.md`, per-tool
voice and tool-specific guidance in `fragments/{claude,codex,antigravity}.md`.
`claude/scripts/gen-instruction-files.sh` compiles them into
`claude/CLAUDE.md`, `codex/AGENTS.md`, and `antigravity/GEMINI.md` — those
three are committed build artifacts; edit the sources here and regenerate
(CI's `check-agent-parity.sh` fails on hand-edits or stale artifacts).

## Shared agent skills (`agents/skills/`)

`agents/skills/` is the agent-neutral workflow skill set — the single source
consumed by every non-Claude agent in this setup:

- **Codex**: `setup.sh` links each skill file into `~/.codex/skills/<name>/`.
- **Antigravity (agy)**: `setup.sh` dir-symlinks each skill into
  `~/.gemini/config/skills/<name>/`.

Claude Code keeps its own richer set under `claude/skills/`; the
`changelog` and `handoff` pairs here must stay shape-identical to their
Claude counterparts (asserted in CI by
`claude/scripts/check-skill-parity.sh`).

Keep these skills generic and public-safe — personal preferences and private
project context belong in the private memory repos (`codex-memory`,
`agy-memory`), not here.

> **Transition note:** this directory was `codex/skills/` until 2026-07
> (issue #166). It was renamed because it had become the shared source for
> both Codex and Antigravity, not a Codex-only set. Re-run `./setup.sh`
> after pulling so the `~/.codex/skills/` and `~/.gemini/config/skills/`
> symlinks repoint at the new path.
