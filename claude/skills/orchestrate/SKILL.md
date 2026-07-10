---
name: orchestrate
description: Full-lifecycle orchestration for comprehensive, no-compromise execution — roll-calls the right skills, fans out parallel/worktree agents, then closes the loop (verify, review, simplify, changelog, handoff, retro). Use when you want maximum effort, to go all-in, or to orchestrate a big task end-to-end.
---

# Orchestrate (Maximum-Effort Mode)

The user is requesting comprehensive, parallelized, no-compromise execution.
Apply ALL of the following strategies that fit the task. This is not a suggestion
list — use every applicable technique.

## Plan First

- **Roll-call the skills first.** Before executing, scan the available-skills
  list and invoke the matching *process* skills without being asked:
  `brainstorming` for new features, `systematic-debugging` for bugs,
  `test-driven-development` before implementation. Match the task to the
  toolset — don't rely on the user (or yourself) to remember to name them.
- Decompose the task before executing. For anything with 2+ independent areas,
  use `/decompose` to produce a reviewable parallel execution plan.
- Write atomic, independently-verifiable acceptance criteria up front, then hold
  the work to them.
- If a time budget is given (e.g., `/orchestrate 10m`), use it to scope depth
  and how wide to parallelize.

## Parallelization (Mandatory)

Use ALL applicable parallelization patterns:

- **Worktree isolation** — For any task touching 2+ independent areas of code,
  spawn agents with `isolation: "worktree"` so they work on isolated copies. Each
  agent gets its own branch. Merge results after. See
  `superpowers:dispatching-parallel-agents`.
- **Background agents** — For research, exploration, or investigation that doesn't
  block other work, use `run_in_background: true`. Don't wait when you don't need to.
- **Named teammates** — For 3+ independent workstreams, spawn named teammates
  via the Agent tool (`name:` parameter) and coordinate them with SendMessage.
  Every session already has one implicit team — there is no TeamCreate/TeamDelete
  step (removed in Claude Code 2.1.x).
- **Batch operations** — For similar changes across 3+ files (refactors, renames,
  migrations), give one agent clear, repeatable instructions over the file list.
- **Launch in one message** — All independent research/exploration agents MUST
  launch in a single message. No staggering.
- **Named agents must report via SendMessage** — a named agent (`Agent` with
  `name:`) ends with a bare idle notification; its final text does NOT reach
  you. Instruct every named agent to `SendMessage(to: "main")` its completion
  report as its last act, and expect to nudge idle agents that skipped it.

## Capability Selection (Go Wide)

Select capabilities aggressively from the available skills and platform features:

- **Research** — If the task involves unknowns, use `/deep-research` or launch
  parallel search agents (multiple queries at once).
- **Specialized agents** — Spawn subagents with tailored prompts (or a matching
  `subagent_type`) so each brings domain-specific expertise.
- **Multiple perspectives** — For design or architecture decisions, spin up
  several subagents with different viewpoints and synthesize.
- **Competing hypotheses** — For debugging, spawn N agents each testing a
  different theory simultaneously (see `superpowers:systematic-debugging`).
- **Writer/reviewer split** — For code quality, have one agent write and a
  separate fresh-context agent review independently.
- **First-principles decomposition** — For complex design work, break the problem
  down to fundamentals before committing to an approach.
- **/simplify** — After any code changes, run the simplify review. Near-mandatory
  for max effort.
- **/code-review** — Review the diff for correctness and quality before finishing.
- **/security-review** — For auth, RLS, payments, or data handling, run a security
  review before shipping.

## Execution Quality

- **Name the bar, then clear it** — before starting, state the single most useful
  thing that would make this better than a rote pass (a fact to verify instead of
  assert, an earlier artifact to build on, an approach worth trying). Do that
  thing. Before finishing, re-read what you produced and confirm you did. If the
  task is genuinely trivial, say so and skip — don't manufacture busywork.
- **Vertical slice first** — For greenfield work, build one end-to-end slice
  before parallelizing.
- **Verify with tools** — Never claim done without evidence. Screenshots, test
  output, diffs.
- **Name the failure mode when delegating** — a subagent's verification
  instruction must name the *specific destructive failure* to check (e.g. "run
  `--dry-run` against a throwaway HOME and diff the target"), not just "verify it
  works." A subagent verifies what you name; unnamed side-effects slip through to
  integration.
- **TDD for bugs** — Reproduce with a failing test first, then fix
  (`superpowers:test-driven-development`).
- **Context compaction** — At phase boundaries, self-summarize to prevent context
  rot in long runs.

## Close the Loop (fire these; don't wait to be told)

When the work is done, run these in order — skip only what genuinely doesn't
apply. The point of max effort is that the wrap-up happens automatically, not
that the user has to remember each skill:

1. `/verify` — drive the real change end-to-end (the app/flow, not just tests).
2. `/code-review` (and `/security-review` for auth, RLS, payments, or data
   handling), then `/simplify`; then a **coach pass** (see the `review` skill) —
   the single highest-leverage quality lift, not more bug-hunting.
3. If anything changed: `/changelog`; then `/handoff` if the session is ending.
4. On success: `/session-retro` — leave the toolset better than you found it.

## What NOT to Do

- Don't ask "should I use worktrees?" — just use them if the task has independent
  workstreams.
- Don't serialize work that can be parallelized.
- Don't select capabilities you won't invoke — every selection is a binding commitment.
- Don't skip /simplify because "the code looks fine" — the whole point of max
  effort is thoroughness.
