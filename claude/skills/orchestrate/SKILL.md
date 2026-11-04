---
name: orchestrate
description: Maximum-effort, full-lifecycle execution that plans, delegates bounded work, verifies independently, and closes the loop with docs, review and handoff. Use when the user says 'orchestrate', 'go all-in', 'max effort', 'throw everything at it', or wants a big task carried end to end with independent verification.
argument-hint: >-
  [time budget e.g. 10m] [task]
---

# Orchestrate (Maximum-Effort Mode)

The user wants the task carried end to end with independent verification. Use
the techniques below where they fit the task. Maximum effort means removing
uncertainty, not multiplying ceremony: skip what the task does not need.

Wrap-up checklist: see Close the Loop at the end; re-read it before declaring done.

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
- **Fork mode** — On by default since 2.1.302 (`CLAUDE_CODE_FORK_SUBAGENT=0`
  turns it off): in interactive sessions Claude cannot wait on a subagent, so
  plan for results to arrive as messages. `subagent_type: "fork"`
  inherits the whole conversation: use it for a side task needing full
  context, never for unbiased review, which needs a fresh one.
- **Named teammates** — Agent teams cost several times the tokens of a
  single session, so prefer plain subagents unless workstreams must talk to each
  other. When they must, spawn named teammates (Agent `name:`) and coordinate
  with SendMessage; there is no TeamCreate step. Teams need
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` set; without it, or without
  SendMessage, launch unnamed subagents in one parallel batch.
- **Batch operations** — Under ~10 similar files, one agent with clear,
  repeatable instructions over the list. Above that, one agent per item in a
  workflow, so no single context declares done at item 35 of 50.
- **Launch independent agents in one message** — staggered launches serialize
  work that could overlap.
- **Reports land in a file** — a teammate's idle notification carries its
  final answer, but long reports are truncated in delivery. Have every agent
  also write its full report to a scratchpad file and name the path; a closing
  SendMessage is good practice, not the only channel.

## Model And Effort Routing

A subagent that names no model inherits the session's, and its price. Set
`model` on the Agent call (or `model`/`effort` in an agent definition):

- Lookup, search, and log- or test-output-reading agents: `haiku` or `sonnet`.
- Agents that write code: `haiku` for a tightly scoped fix, `sonnet` for
  multi-file or repeatedly failing work. Orchestration, review and judgment
  calls stay on the session's model.
- The Agent call takes `effort` (2.1.292), overriding the agent definition's
  `effort` field. Honor the model the user names for the session; absent one,
  the routing above applies.
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
- **Workflows** — For one step over many items (10+ files, every route, a
  ticket backlog), adversarial verification, or run-until-dry discovery, use a
  dynamic workflow: say "use a workflow", or `/effort ultracode` for the whole
  session (the `ultracode` keyword is ignored in `-p` and scheduled prompts).
  Prefer `pipeline()` over barrier `parallel()`. Run a slice first; workflows
  cost meaningfully more tokens and take no mid-run input. Keep orchestration
  itself in the session: it needs approval breaks, commits, and pushes.
- **Waiting and loops** — `Monitor` for streams (logs, file changes);
  `run_in_background` Bash for one long command (default timeout 30 min, max
  2 h), never a polling loop. `/loop PROMPT` with a written stop condition to
  watch something external until done (CI, review, deploy). `/goal CONDITION …
  or stop after N turns` for "keep going until" (a session-scoped Stop hook
  judged by a small model). A command Stop hook only for a mechanically
  checkable gate, honoring `stop_hook_active` and the block cap
  (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, default 8). `/schedule` when it must run
  without this machine.
- **Caps before launch** — set hard caps (turns, time, items) before a loop or
  workflow starts; hitting a cap is a report, not a retry. The decision layer
  lives in the `autonomous-run` skill.
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
- **Delegation template** — every delegated prompt carries Role; Goal (an
  observable outcome); Scope (files it may touch, what not to change); Context
  it must not rediscover; for verification, the Claim to disprove and exact
  repro; Done-when (binary criteria); Report (where to write it, what evidence).
- **TDD for bugs** — Reproduce with a failing test first, then fix.
- **Context compaction** — At phase boundaries, self-summarize to prevent
  context rot in long runs.

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
