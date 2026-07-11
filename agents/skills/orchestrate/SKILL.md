---
name: orchestrate
description: Coordinate complex engineering work end to end with proportional planning, explicit acceptance criteria, isolated delegation, implementation, verification, adversarial review, and durable handoff. Use when the user asks to orchestrate, go all-in, use subagents or parallel agents, execute a multi-workstream task, run a maximum-effort pass, or carry a substantial issue or PR through completion.
---

# Orchestrate

Keep the main agent responsible for the outcome. Delegate bounded work, not the
through-line.

Read `references/runtime-contracts.md` before dispatching agents. Follow the
section for the current runtime and its actual tool surface.

## Calibrate

1. Read the applicable instructions, recent project handoff, repository state,
   and surrounding implementation before proposing changes.
2. State the outcome and the single quality bar that matters most.
3. Inventory relevant installed skills. Invoke process or domain skills only
   when they add a real constraint or capability.
4. Scale ceremony to risk. Keep a narrow task single-agent unless the user
   explicitly requires delegation; in that case, prefer one bounded read-only
   verifier over manufactured parallel edits. Orchestrate when parallelism,
   independent verification, or a long integration path improves quality or
   elapsed time.

Do not create a plan or checklist file unless the repository explicitly uses
one. GitHub issues remain the open-work tracker when project instructions say
so.

## Define The Contract

Write atomic, observable acceptance criteria before implementation. Include the
negative behavior most likely to regress, not only the happy path.

For a verification or rescue handoff, require both:

- **Claim to disprove:** one falsifiable statement.
- **Exact repro:** one command or deterministic flow that exercises it.

If either field is missing, return to the originator for it before dispatch.
Do not invent a claim that biases the reviewer or guess at a repro.

Resolve genuine ambiguity before editing. Do not pause for approval merely
because work is reversible and already in scope.

## Decompose

Map prerequisites and workstreams. Delegate only a task that is:

- independently useful and bounded;
- owned by one agent;
- explicit about files or checkout;
- explicit about what must not change;
- verifiable with named commands or observables.

Each agent prompt must contain the goal, why it matters, relevant context,
scope, constraints, completion criteria, verification command, and requested
report shape. Do not make the agent rediscover information already known.

Parallelize read-only research freely. Before parallel edits, require both a
separate worktree per editing agent and globally disjoint file or contract
ownership. Sequence any overlap.

Record the base commit and dirty working-tree state before creating worktrees.
Do not assume an isolated checkout contains user-owned uncommitted
prerequisites. Keep dependent work in the owning checkout, or transfer an
explicit reviewed patch without altering the user's state.

## Execute

1. Complete shared prerequisites first.
2. Prefer a thin end-to-end slice before broad fan-out on greenfield work.
3. For behavior changes and bugs, establish a failing test or equivalent
   reproduction before the fix when practical.
4. Dispatch independent workstreams together, then continue useful conductor
   work while they run.
5. Inspect every returned artifact and command result. Treat agent reports as
   claims until the main agent verifies the integration state.
6. Integrate in dependency order and run a focused check after each boundary.

If an agent hangs or stops, inspect its worktree, branch, diff, and process
state before retrying. Salvage usable artifacts first, then relaunch only the
missing scope. Remove a worktree only after its work is integrated or
deliberately rejected.

Keep progress updates short and evidence-based. Redirect or stop an agent whose
work has become redundant, conflicting, or out of scope.

## Refute And Verify

Run the smallest focused verification first, then the repository's broader
required checks. Exercise the real user-facing flow when tests alone do not
prove the claim.

Use a fresh-context reviewer with no inherited conversation for material
changes. Pass only the raw artifact or diff, scope, claim, repro, and necessary
repository facts. Ask it to find a counterexample, not to confirm the
implementation. Separate these concepts:

- **Context independence:** a fresh agent has not inherited the author's
  reasoning.
- **Lineage independence:** a different model family provides genuinely
  different failure modes.

Multiple agents from one model lineage add breadth but do not satisfy a
cross-lineage review requirement. Route disputed claims back through the exact
repro and prefer observed behavior over votes.

For authentication, authorization, secrets, payments, destructive operations,
schema changes, or public trust boundaries, add a focused security review.

## Close The Loop

1. Simplify the changed code without changing behavior.
2. Re-run every check affected by integration or simplification.
3. Inspect the final diff and working tree for unrelated or generated state.
4. Update living documentation only when behavior or repository policy
   requires it. Do not create shadow trackers.
5. Publish, comment, merge, or perform another outward-facing action only when
   the user requested it or already approved that exact action.
6. Persist a durable handoff or issue/PR verdict when project instructions
   require one.

Finish with the outcome, verification evidence, review verdict, and any
remaining risk. Do not end on a plan that could still be executed.

## Non-Negotiables

- The conductor owns integration and the final claim.
- One working-tree owner at a time.
- No success claim without fresh evidence.
- No review without a defined scope; no adversarial handoff without a claim
  and repro.
- No external skill, dependency, or service installation without verifying it
  against both the current project and an authoritative source.
- Maximum effort means removing uncertainty, not multiplying ceremony.
