---
name: session-retro
description: Propose one to three durable improvements to the shared agent toolset after meaningful work, including skill triggers, workflow gotchas, canonical instructions, parity gaps, and stale memory. Use when the user requests a retro, when a skill failed to trigger, after a notable workflow discovery, or at a genuine successful stopping point. Propose first and never edit without confirmation; unattended runs write proposals for later review.
---

# Session Retro

Improve the toolset, not the session log. Route ordinary history to changelog or
handoff workflows.

## Select The Right Source

- Shared behavior across agents: `agents/canon/` and regenerate the produced
  global instruction files.
- Portable workflows: `agents/skills/`.
- Claude-only workflows: `claude/skills/`.
- Private preferences or machine context: the relevant private memory repo.
- Architectural policy: an ADR when the repository uses ADRs.

Do not edit generated `claude/CLAUDE.md`, `codex/AGENTS.md`, or
`antigravity/GEMINI.md` directly.

## Reflect And Propose

1. Scan the completed work for a missed skill trigger, recurring footgun,
   reusable pattern, stale workflow, cross-agent parity gap, or obsolete memory.
2. Verify each candidate against current files, commands, and behavior. Age
   alone is not evidence of staleness.
3. Pick at most three high-value findings.
4. For each, show the target source, a short before/after or diff sketch, and
   the evidence from this session that justifies it.
5. Apply nothing until the user confirms which proposals to take. Retiring or
   deleting a skill requires explicit confirmation.

If nothing is worth changing, say exactly that in one line and stop.

## Apply Confirmed Changes

Use `$skill-creator` for new or substantially revised skills. Tighten trigger
descriptions around the phrasing that actually failed. Update shared canonical
sources before tool-specific adapters, regenerate derived instructions, run
parity and skill validation checks, and commit only the confirmed files.

Classify refreshed memory as Keep, Update, Consolidate, Replace, or Delete.
Never silently rewrite memory whose referent moved or disappeared.

## Unattended Mode

When invoked from unattended orchestration, write proposals to
`~/.claude/retro-proposals/YYYY-MM-DD-<project>.md` and do not apply them. A
later interactive retro should surface pending proposals first and remove the
proposal file only after the user accepts or rejects it.
