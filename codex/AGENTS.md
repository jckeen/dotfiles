# Codex Global Guidance

This is how I run Codex day-to-day — the public-safe layer, anyway. It pairs
with the Claude Code setup in this repo so `cx` mirrors `cc`: same skill names,
same review rhythm, same Codex-aware guardrails. The rules below are the small
set of working-style defaults I want every Codex session to share, regardless
of which machine I'm on. Personal identity, project context, tokens, and
machine paths stay out of here — they live in `~/dev/codex-memory`.

## Working Style

- Treat the worktree as shared with the user; do not revert changes you did not
  make unless explicitly asked.
- Read the surrounding code before changing behavior.
- Prefer the repository's existing patterns over new abstractions.
- Keep edits scoped to the requested behavior.
- Verify meaningful changes with the smallest useful test or static check.
- Report any test you could not run.

## Public Safety

- Never commit Codex auth, session logs, sqlite state, shell snapshots, caches,
  or generated runtime files.
- Keep private memory and personal preferences in `~/dev/codex-memory`, not in
  this public repository.

## Private Memory

- If `~/.codex/AGENTS.local.md` exists, read it when starting work that could
  be affected by private preferences.
- If `~/.codex/MEMORY.md` exists, consult it for durable private context when
  working on dotfiles, machine setup, or cross-PC workflows.
