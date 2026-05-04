# Codex Global Guidance

This file is safe to keep in the public dotfiles repo. Keep personal identity,
private project context, tokens, client names, and machine-specific paths out of
this file.

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
