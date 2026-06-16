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
- Doc contract: a repo's Markdown surfaces are declared in a root
  `.doc-contract` (LIVING / GENERATED / SOURCE / HISTORICAL + BANNED guards)
  and asserted in CI by `check-doc-truth.sh`; bootstrap or audit one with
  `/drift-sweep` (ADR 0005 in dotfiles). Keep LIVING small — a wrong doc is
  worse than no doc; delete or mark HISTORICAL rather than let it freeze.
- Never hardcode a count, version, SHA, or hostname in prose that CI can't
  assert — point at the canonical source instead. GitHub issues are the only
  open-work tracker: docs may link issues, never duplicate their state
  (no TODO.md / checklist files).
- Retiring a process or doc: same day, add the historical banner
  (`> **Historical** — point-in-time record (date). Do not act on this.`),
  then search for docs that bill the dead thing as authoritative and repoint
  them.

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
