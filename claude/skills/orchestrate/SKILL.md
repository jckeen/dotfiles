---
name: orchestrate
description: Full-lifecycle orchestration for comprehensive execution — selects relevant skills, delegates bounded work, then simplifies, completes documentation, verifies, reviews the final artifact, and delivers with a durable handoff. Use when you want maximum effort, to go all-in, or to orchestrate a big task end-to-end.
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
  step (removed in Claude Code 2.1.x). Requires agent teams to be enabled
  (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` set in the environment/settings —
  off by default); when it is not, or SendMessage is unavailable, fall back
  to regular unnamed subagents launched in one parallel batch.
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
- **Check every result in a parallel batch** — when independent tool calls go
  out together, one error among successes is easy to skim past. A failed Edit
  ("File has not been read yet") or a rejected call that goes unnoticed only
  surfaces later as a mysterious CI/verify failure that needs re-diagnosis.
  Scan the batch for errors before moving on.
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

1. `/simplify`, then complete intended documentation, `/changelog`, and
   generated-file updates.
2. Re-run affected tests and `/verify` — drive the real change end-to-end.
3. Review the final artifact with `/code-review` and a read-only **coach pass**
   (see the `review` skill). For auth, secrets, payments, destructive operations,
   schema changes, or public trust boundaries, require `/security-review` from
   a different model family than the implementer. A fresh context alone is not
   a different family; record actual reviewer evidence, not only a model label.
4. Any subsequent artifact edit invalidates approval. Repeat affected
   verification and final review, including required cross-family review.
   Use `/commit-push-pr` for authorized delivery: require the shipping gate
   after the last commit and check its private receipt immediately before push.
   Gate exit 0 alone does not prove review completed; report exemptions as such.
5. `/handoff` if the session is ending, then `/session-retro` on success.

## What NOT to Do

- Don't ask "should I use worktrees?" — just use them if the task has independent
  workstreams.
- Don't serialize work that can be parallelized.
- Don't select capabilities you won't invoke — every selection is a binding commitment.
- Don't skip /simplify because "the code looks fine" — the whole point of max
  effort is thoroughness.

For verification or rescue work, require a falsifiable claim to disprove and
an exact repro command or deterministic flow before assigning review.
