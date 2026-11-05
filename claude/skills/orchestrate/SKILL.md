---
name: orchestrate
description: Full-lifecycle orchestration for comprehensive execution — selects relevant skills, delegates bounded work, then simplifies, completes documentation, verifies, reviews the final artifact, and delivers with a durable handoff. Use when you want maximum effort, to go all-in, or to orchestrate a big task end-to-end.
---

# Orchestrate (Maximum-Effort Mode)

The user wants the task carried end to end with independent verification. Use
the techniques below where they fit the task. Maximum effort means removing
uncertainty, not multiplying ceremony: skip what the task does not need.

## Plan First

- **Check the skills list first.** Invoke a listed process or domain skill when
  it adds a real constraint or capability; skills come and go between sessions,
  so match against what is listed now rather than a remembered name.
- Decompose before executing. For 2+ independent areas, write a short plan of
  workstreams, owners, and the files each may touch (use `/decompose` if it is
  available) so the user can review it.
- Write atomic, independently-verifiable acceptance criteria up front, then hold
  the work to them.
- If a time budget is given (e.g., `/orchestrate 10m`), use it to scope depth
  and how wide to parallelize.
- For a plan or review longer than about a hundred lines that a person will
  read, offer an HTML page instead of terminal Markdown.

## Parallelization

Parallelize where workstreams are independent; it saves wall-clock time, and
concurrent edits to shared files cause conflicts.

- **Worktree isolation** — For any task touching 2+ independent areas of code,
  spawn agents with `isolation: "worktree"` so they work on isolated copies. Each
  agent gets its own branch. Merge results after.
- **Background agents** — Run research that doesn't block other work with
  `run_in_background: true`, and keep working meanwhile.
- **Named teammates** — Agent teams cost several times the tokens of a
  single session, so prefer plain subagents unless workstreams must talk to each
  other. When they must, spawn named teammates (Agent `name:`) and coordinate
  with SendMessage; there is no TeamCreate step. Teams need
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` set; without it, or without
  SendMessage, launch unnamed subagents in one parallel batch.
- **Batch operations** — For similar changes across 3+ files (refactors, renames,
  migrations), give one agent clear, repeatable instructions over the file list.
- **Launch independent agents in one message** — staggered launches serialize
  work that could overlap.
- **Named agents must report via SendMessage** — a named agent (`Agent` with
  `name:`) ends with a bare idle notification; its final text does NOT reach
  you. Instruct every named agent to `SendMessage(to: "main")` its completion
  report as its last act, and expect to nudge idle agents that skipped it.

## Model And Effort Routing

A subagent that names no model inherits the session's, and its price. Set
`model` on the Agent call (or `model`/`effort` in an agent definition):

- Lookup, search, and log- or test-output-reading agents: `haiku` or `sonnet`.
- Agents that write code: `haiku` for a tightly scoped fix, `sonnet` for
  multi-file or repeatedly failing work. Orchestration, review and judgment
  calls stay on the session's model.
- Raise effort before changing model; use high effort for review, security,
  and edge-case work.
- When the session runs above `opus`, escalate a subagent to the session's
  model only after `opus` has failed twice on the same problem. On an `opus`
  session, `opus` already is the top tier.

## Capability Selection

- **Research** — For unknowns, use deep research or parallel search agents.
- **Specialized agents** — Use a matching `subagent_type` or a tailored prompt.
- **Multiple perspectives / competing hypotheses** — For design decisions, spin
  up differing viewpoints; for debugging, one agent per theory.
- **Writer/reviewer split** — A separate fresh-context agent reviews the work.
- **Workflows** — When a phase has a variable-size work list or needs
  adversarial verification, and the user has opted into a workflow, run that
  phase as one. Keep orchestration itself in the session: it needs approval
  breaks, commits, and pushes that a workflow cannot do.
- **/code-review** for correctness; **/security-review** for auth, RLS,
  payments, or data handling.

## Execution Quality

- **Name the bar, then clear it** — before starting, state the single most useful
  thing that would make this better than a rote pass (a fact to verify instead of
  assert, an earlier artifact to build on, an approach worth trying). Do that
  thing. Before finishing, re-read what you produced and confirm you did. If the
  task is genuinely trivial, say so and skip.
- **Vertical slice first** — For greenfield work, build one end-to-end slice
  before parallelizing.
- **Verify with tools** — Never claim done without evidence. Screenshots, test
  output, diffs.
- **Check every result in a parallel batch** — one error among successes is easy
  to skim past, and a missed failed Edit surfaces later as a mysterious CI
  failure. Scan the batch for errors before moving on.
- **Name the failure mode when delegating** — a subagent verifies what you name,
  so name the *specific destructive failure* to check (e.g. "run `--dry-run`
  against a throwaway HOME and diff the target"), not just "verify it works."
- **TDD for bugs** — Reproduce with a failing test first, then fix.
- **Context compaction** — At phase boundaries, self-summarize to prevent context
  rot in long runs.

## Close the Loop

Run these in order when the work is done, skipping what does not apply, so the
wrap-up does not depend on the user remembering each step:

1. Simplify the changed code without changing behavior (`/simplify` if
   available), then complete intended documentation and the changelog entry
   (the branch's `changelog.d/` fragment where the repo keeps one),
   and regenerate generated files.
2. Re-run affected tests and drive the real change end-to-end.
3. Review the final artifact with `/code-review` and a read-only coach pass
   (the `review` skill if available). For auth, secrets, payments, destructive
   operations, schema changes, or public trust boundaries, require
   `/security-review` from a different model family than the implementer. A
   fresh context alone is not a different family; record actual reviewer
   evidence, not only a model label. `review-gates` covers gate mechanics.
4. Any subsequent artifact edit invalidates approval. Repeat affected
   verification and final review, including required cross-family review.
   For authorized delivery (`/commit-push-pr` if available), require the
   shipping gate after the last commit and check its private receipt
   immediately before push. Gate exit 0 alone does not prove review completed;
   report exemptions as such.
5. `/handoff` if the session is ending, then `/session-retro` on success.

For verification or rescue work, require a claim to disprove and an exact repro
command or deterministic flow before assigning review.
