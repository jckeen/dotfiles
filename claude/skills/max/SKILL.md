---
name: max
description: Maximum effort mode — worktrees, parallel agents, batches, full capability selection. Use when you want comprehensive, no-compromise execution.
user_invocable: true
---

# Maximum Effort Mode

The user is requesting comprehensive, parallelized, no-compromise execution. Apply ALL of the following strategies that fit the task. This is not a suggestion list — use every applicable technique.

## Effort & Algorithm

- Force **Advanced+ effort tier** in the Algorithm (24+ ISC minimum). If the task is large enough, use Deep (40+) or Comprehensive (64+).
- If an SLA/time budget is given (e.g., `/max 10m`), use it to pick the right tier. Otherwise default to Advanced.
- Decompose ISC criteria aggressively — apply the Splitting Test to every criterion. Atomic only.

## Parallelization (Mandatory)

Use ALL applicable parallelization patterns:

- **Worktree isolation** — For any task touching 2+ independent areas of code, spawn agents with `isolation: "worktree"` so they work on isolated copies. Each agent gets its own branch. Merge results after.
- **Background agents** — For research, exploration, or investigation that doesn't block other work, use `run_in_background: true`. Don't wait when you don't need to.
- **Agent teams** — For Extended+ effort with 3+ independent workstreams, use `TeamCreate` to coordinate agents with shared task visibility.
- **Batch operations** — For similar changes across 3+ files (refactors, renames, migrations), invoke `/batch` with clear instructions.
- **OBSERVE parallelization** — All research/exploration agents selected in OBSERVE MUST launch in a single message. No staggering.

## Capability Selection (Go Wide)

Select capabilities aggressively from both PAI skills and platform capabilities:

- **Research** — If the task involves unknowns, launch research agents (multiple queries in parallel).
- **Custom agents** — Use the Agents skill to compose specialized agents with relevant expertise for the domain.
- **Council/debate** — For design decisions or architecture, spin up a council of custom agents with different perspectives.
- **Competing hypotheses** — For debugging, spawn N agents each testing a different theory simultaneously.
- **Writer/reviewer** — For code quality, have one agent write and a separate agent review independently.
- **First principles** — For complex design work, invoke first principles decomposition.
- **/simplify** — After any code changes, run the 3-agent simplify review. Near-mandatory for max effort.
- **/security-review** — For auth, RLS, payments, or data handling, run security review before execution.

## Execution Quality

- **Vertical slice first** — For greenfield work, build one end-to-end slice before parallelizing.
- **Verify with tools** — Never claim done without evidence. Screenshots, test output, diffs.
- **Context compaction** — At phase boundaries, self-summarize to prevent context rot in long runs.

## What NOT to Do

- Don't ask "should I use worktrees?" — just use them if the task has independent workstreams.
- Don't serialize work that can be parallelized.
- Don't select capabilities you won't invoke — every selection is a binding commitment.
- Don't skip /simplify because "the code looks fine" — the whole point of max effort is thoroughness.
