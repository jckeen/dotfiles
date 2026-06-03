---
name: max
description: Maximum effort mode — worktrees, parallel agents, batches, full capability selection. Use when you want comprehensive, no-compromise execution.
user_invocable: true
---

# Maximum Effort Mode

The user is requesting comprehensive, parallelized, no-compromise execution.
Apply ALL of the following strategies that fit the task. This is not a suggestion
list — use every applicable technique.

## Plan First

- Decompose the task before executing. For anything with 2+ independent areas,
  use `/decompose` to produce a reviewable parallel execution plan.
- Write atomic, independently-verifiable acceptance criteria up front, then hold
  the work to them.
- If a time budget is given (e.g., `/max 10m`), use it to scope depth and how
  wide to parallelize.

## Parallelization (Mandatory)

Use ALL applicable parallelization patterns:

- **Worktree isolation** — For any task touching 2+ independent areas of code,
  spawn agents with `isolation: "worktree"` so they work on isolated copies. Each
  agent gets its own branch. Merge results after. See
  `superpowers:dispatching-parallel-agents`.
- **Background agents** — For research, exploration, or investigation that doesn't
  block other work, use `run_in_background: true`. Don't wait when you don't need to.
- **Agent teams** — For 3+ independent workstreams, use `TeamCreate` to coordinate
  agents with shared task visibility.
- **Batch operations** — For similar changes across 3+ files (refactors, renames,
  migrations), give one agent clear, repeatable instructions over the file list.
- **Launch in one message** — All independent research/exploration agents MUST
  launch in a single message. No staggering.

## Capability Selection (Go Wide)

Select capabilities aggressively from the available skills and platform features:

- **Research** — If the task involves unknowns, use `/deep-research` or launch
  parallel search agents (multiple queries at once).
- **Specialized agents** — Spawn subagents with tailored prompts (or a matching
  `agentType`) so each brings domain-specific expertise.
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

- **Vertical slice first** — For greenfield work, build one end-to-end slice
  before parallelizing.
- **Verify with tools** — Never claim done without evidence. Screenshots, test
  output, diffs.
- **TDD for bugs** — Reproduce with a failing test first, then fix
  (`superpowers:test-driven-development`).
- **Context compaction** — At phase boundaries, self-summarize to prevent context
  rot in long runs.

## What NOT to Do

- Don't ask "should I use worktrees?" — just use them if the task has independent
  workstreams.
- Don't serialize work that can be parallelized.
- Don't select capabilities you won't invoke — every selection is a binding commitment.
- Don't skip /simplify because "the code looks fine" — the whole point of max
  effort is thoroughness.
