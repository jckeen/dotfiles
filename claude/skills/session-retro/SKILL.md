---
name: session-retro
description: Runs a short retrospective that PROPOSES edits to the user's Claude Code skills — capturing a newly-found gotcha, fixing a description that didn't auto-trigger, retiring a dead skill, or extracting a reusable pattern into a new skill. Improves the TOOLSET, not the session log. Use when the user signals satisfaction at the end of real work ("thanks", "thanks that worked", "that worked great", "nice", "perfect", "exactly what I needed"), or when they explicitly run /session-retro. Always proposes and waits for confirmation — never edits skills silently.
---

This skill practices **compound engineering**: every successful session should leave the
toolset slightly better. It is the tooling cousin of "end every session by updating CLAUDE.md
so the same mistake never recurs."

Skills live in this dotfiles repo at `claude/skills/<name>/SKILL.md` and are **symlinked**
into `~/.claude/skills/`, so they sync across machines — any change must be **committed** here
to propagate. CLAUDE.md / memory live alongside; architectural learnings may instead warrant
an ADR in `docs/adr/`.

## Scope — what this skill is and is NOT

- **IS:** improving the *toolset* — skills, their trigger descriptions, CLAUDE.md, ADRs.
- **IS NOT:** logging what happened. For that, defer to the existing skills:
  - `changelog` — what changed this session
  - `log-error` — a persistent error pattern + classification
  - `handoff` — context for the next session
  If the user wants a record, point them there and stop.

## When NOT to run

- Mid-task thank-yous, or a "thanks" before the work is actually done — wait for a real stopping point.
- Trivial / social pleasantries with no session learning behind them.
- A session where nothing notable was learned — say so in one line and stop (see step 5).
- A session you already retro'd — never retro the same session twice.
- When the user explicitly just wants a log entry — route to `changelog` / `log-error` / `handoff`.

## Workflow

1. **Reflect silently.** Scan THIS session for toolset-level signals, e.g.:
   - A skill that *should* have auto-triggered but didn't → its `description` needs better triggers.
   - A gotcha / footgun discovered the hard way → add it to the relevant skill's body.
   - A reusable, repeated pattern with no home → candidate for a *new* skill.
   - A skill that's now stale, redundant, or superseded → candidate to retire.
   - A learning that's architectural, not tooling → candidate for CLAUDE.md or an ADR.

2. **Pick at most 1–3** of the highest-value findings. Quality over quantity. Discard the rest.

3. **PROPOSE — do not apply.** For each finding, show a concise, scannable summary:
   - target file (e.g. `claude/skills/<name>/SKILL.md`, `CLAUDE.md`, or a new ADR)
   - the change as a short before/after or a few-line diff sketch — not a full rewrite
   - one sentence on *why* (what in this session justifies it)
   Keep the whole proposal short enough to read in one glance.

4. **CONFIRM.** Ask the user which proposals to apply ("all / 1 and 3 / none / edit"). Default
   to applying nothing until they choose. Never edit a skill, CLAUDE.md, or ADR without an
   explicit yes.

5. **If nothing is worth changing,** say exactly that in one line
   (e.g. "Nothing toolset-worthy from this session — no changes proposed.") and stop. Do not
   manufacture suggestions to look busy.

6. **Apply only what was confirmed.** Then:
   - For a *new* skill: create `claude/skills/<name>/SKILL.md` with frontmatter
     (`name`, third-person `description` with WHAT + "Use when…" triggers).
   - For a description fix: tighten the `description` so the trigger phrasing matches how the
     user actually asked.
   - For a retired skill: confirm twice before deleting; prefer noting it for removal over
     silent deletion.
   - For a CLAUDE.md / ADR change: edit memory, or scaffold a new ADR if the learning is
     architectural.

7. **Commit** the applied changes in this repo with a conventional message
   (e.g. `chore(skills): add <name> gotcha from session-retro`) so they sync across machines.
   Commit only the files that were changed; never `git add -A`.

## Guardrails

- Propose → confirm → apply. The default action is **propose**, never auto-edit.
- One pass per session. Small footprint. Don't derail the flow with a wall of text.
- Trust the user's "none" — dropping all proposals is a valid, common outcome.
