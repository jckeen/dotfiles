---
name: session-retro
description: Runs a short retrospective that PROPOSES edits to the user's Claude Code skills — capturing a newly-found gotcha, fixing a description that didn't auto-trigger, retiring a dead skill, or extracting a reusable pattern into a new skill. Improves the TOOLSET, not the session log. Use when the user signals satisfaction at the end of real work ("thanks", "thanks that worked", "that worked great", "nice", "perfect", "exactly what I needed"), or when they explicitly run /session-retro. Always proposes and waits for confirmation — never edits skills silently. In unattended runs (/orchestrate, overnight, or /session-retro --auto), writes proposals to ~/.claude/retro-proposals/ instead of blocking.
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

## Memory refresh pass (ADR-0006)

Retro and auto-memory only *add* knowledge; nothing prunes it when reality
moves on. So alongside step 1, re-verify the project's recalled memories —
the auto-memory index (`MEMORY.md` and its topic files) and `ERRORS.md` if
present — against the current codebase:

- **Verify before flagging.** A memory that cites a file, function, flag,
  script, or path gets checked with tools (`rg`, `ls`, `git log`) — it is
  stale only when the evidence says the referent no longer exists or no
  longer behaves as described, not merely because the entry is old.
- **Every aging entry gets one of five explicit outcomes** (the
  `ce-compound-refresh` lifecycle ADR-0006 adopted): **Keep** (still true,
  untouched), **Update** (referent moved/renamed but the lesson holds),
  **Consolidate** (merge near-duplicates), **Replace** (lesson superseded by
  a better one), or **Delete** (referent gone and the lesson with it).
- Memories citing files/functions/flags that no longer exist are flagged for
  **Update** or **Delete** — never silently rewritten.

Refresh findings are proposals like any other: they join the step-2 cut
(still at most 1–3 total, quality over quantity) and go through the same
propose → confirm → apply flow. In auto mode they are written to
`~/.claude/retro-proposals/` like everything else — memory files are never
edited without an explicit yes in some session.

## Auto mode (unattended runs)

When invoked as `/session-retro --auto`, or when running unattended (inside
`/orchestrate`, `overnight.sh`, or any session where no user is present to confirm):

- Do steps 1–3 (reflect, pick, write proposals) but **never apply anything**.
- Write the proposals to `~/.claude/retro-proposals/YYYY-MM-DD-<project>.md`
  (create the directory; append if the file exists) instead of waiting for
  confirmation.
- End with one line: "N retro proposal(s) written to <path> — review and apply
  with /session-retro."
- A later interactive `/session-retro` should check that directory first and
  offer any pending proposals before reflecting on the current session;
  delete the file once its proposals are applied or rejected.

Auto mode changes *where proposals go*, never *whether edits need a yes* —
skills are still never edited without explicit confirmation in some session.

## Guardrails

- Propose → confirm → apply. The default action is **propose**, never auto-edit.
- One pass per session. Small footprint. Don't derail the flow with a wall of text.
- Trust the user's "none" — dropping all proposals is a valid, common outcome.
