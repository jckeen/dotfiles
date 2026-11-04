---
name: autonomous-run
description: Decision layer for unattended or looping work — picks between in-session work, a dynamic workflow, /loop, /goal, Monitor, a Stop hook, or a cloud scheduled task, then sets the stop condition, round cap and verification gate before launch and defines the report. Use when the user says "run this unattended", "keep going until", "loop until done", "babysit this", "come back when it's finished", "overnight", or asks which loop primitive to use. Not for loop syntax itself (/loop, /goal, /schedule, workflow-authoring cover that).
---

# Autonomous Run

Unattended work fails by not stopping, or by stopping and calling it done.
Decide the primitive, the finish line and the check before anything starts.

## Five Questions Before Launch

Answer each in one line before starting. An unanswered one means do not run
unattended.

1. What does done look like?
2. How does it check its own work?
3. What may it touch?
4. What stops it: `--max-turns`, `--max-budget-usd`, a round cap, or K empty rounds?
5. Who signs off?

## Pick the Primitive (first match wins)

1. **Needs the user's input or sign-off partway** — split at the gate and run
   the stages separately.
2. **Finishes in one sitting, little parallelism** — stay in conversation.
   Slow commands go to `run_in_background` Bash (30-min default timeout, 2 h
   max); streams go to `Monitor`.
3. **Many items, independent verification, or unknown-size discovery** — a
   dynamic workflow (say "use a workflow"). Run a slice, then the full run;
   save it under `.claude/workflows/` if it will repeat. It takes no mid-run
   input; in `-p` ask for a workflow in plain words, since the `ultracode`
   keyword is ignored there.
4. **Waiting on something external** (CI, review, deploy) — `/loop PROMPT`
   with no interval and a written stop condition; a fixed `/loop 5m` only for
   a true cadence. A session loop dies with the session. Esc stops a
   self-paced loop while it waits; a fixed-interval loop only stops when you
   ask Claude to cancel it.
5. **"Keep going until CONDITION"** — `/goal CONDITION … or stop after N
   turns`, a prompt-based Stop hook judged by a small model. Deterministic
   criteria work best.
6. **"Keep going until COMMAND passes"** — a command Stop hook ending
   `… 1>&2 || exit 2`, honoring `stop_hook_active` and the block cap
   (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, default 8).
7. **Must run without this machine, or nightly** — `/schedule`, a cloud
   scheduled task. It runs in auto mode at a 1-hour minimum interval and acts
   as your GitHub identity, so protect `main` with a branch rule first.

## Strictness Ladder for Checks

Ask in the prompt → `/goal` → Stop hook → `/code-review` by a fresh reviewer.
Climb only when the rung below keeps failing.

## Guardrails (always)

- Write the stop condition and a hard cap before launch. Hitting the cap is a
  report, not a retry.
- The last step is verification Claude did not author: tests, CI, or a fresh
  refuter agent. Count failed or null agents; never filter them silently.
- Stop and ask on the same error three times; a destructive, shared-branch or
  paid action; ambiguous acceptance criteria; or verifier and implementer
  disagreeing twice.
- No mid-run scope growth. New findings become GitHub issues.
- Keep task state in a file; a checklist survives compaction.
- Size `--max-budget-usd` from a slice run before the full run.
- Read sources from a bookmark, not a time window. Report a failed read as
  unreadable, never as a quiet day.

## Report

One status line first: done, partial, or stopped at cap. Then what changed,
the verification evidence (command plus result tail), what was not verified
or was dropped, and which caps were hit. Then the normal `/handoff`.
