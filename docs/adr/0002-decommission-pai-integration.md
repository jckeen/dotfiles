# 0002. Decommission the PAI integration

- **Status:** Accepted
- **Date:** 2026-06-03

## Context

The dotfiles carried a deep integration with PAI — a private "Personal AI
Infrastructure" system: a large engine under `~/.claude/PAI`, dozens of PAI
skills and subagents, many hooks, a pulse daemon and voice-server systemd unit,
and a `pai-mode.sh` toggle that swapped between the full PAI config and a lean
"plain" baseline. The earlier plain-mode toggle was already an experiment in
stripping this back: the AI-tooling landscape had converged on lean `CLAUDE.md`
files plus verification infrastructure over heavy prompt scaffolding. The
experiment ran its course; maintaining the PAI layer no longer paid for itself.

## Decision

We remove PAI entirely from the live system and both repos, returning the setup
to a lean, model-led baseline. The former plain `CLAUDE.md` is promoted to the
standalone global instruction file. Genuinely reusable tooling is kept
(git-hygiene, Codex parity, chrome bridge, review agents, the personal skills,
the `claude-memory` cross-machine repo); the portable identity/steering content
is folded out into the private `claude-memory` layer. The full operational
record is retained privately in the operator's `claude-memory` repo.

## Consequences

**Positive**
- The PAI engine, pulse daemon, and voice-server unit are gone; faster, leaner
  sessions.
- Plain is now simply the baseline — no toggle, no dual-config to keep in sync.

**Negative**
- The PR-watcher hook loop was lost: `PromptProcessing.hook.ts`,
  `PRWatcherAutoLaunch.hook.ts`, and `PRWatcherSurface.hook.ts` — the
  watch→fix→re-review automation around PRs (addressed in ADR-0003).
- Significant **doc drift** had to be scrubbed: README, CLAUDE-GUIDE, and
  several skills referenced PAI and the removed hooks, requiring cleanup across
  multiple follow-up commits. This motivated the doc-reference drift-guard
  (ADR-0001's CI-gate idea; see `claude/scripts/check-doc-refs.sh`).
