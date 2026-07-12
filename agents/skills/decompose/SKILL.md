---
name: decompose
description: Decompose substantial engineering work into explicit prerequisites, bounded workstreams, atomic acceptance criteria, and self-contained agent prompts. Use when the user asks to decompose, wants to review an execution plan before implementation, or needs a safe parallelization design for a multi-area task.
---

# Decompose

Produce a reviewable execution contract. Do not implement until the user accepts
the plan unless their request already authorizes immediate execution.

## Ground The Plan

1. Read applicable instructions, recent handoffs, repository state, and the
   surrounding implementation.
2. State the requested outcome and the most important quality bar.
3. Resolve only ambiguities that materially change scope or architecture.
4. Use bounded read-only agents for independent codebase, requirement, or
   domain research when the runtime and instructions authorize delegation.
   Keep a narrow task single-agent.

## Define Acceptance Criteria

Write atomic, observable criteria. Include the negative behavior most likely to
regress. Name the command or deterministic flow that proves each criterion.

For verification or rescue work, require both a falsifiable claim to disprove
and an exact repro. Return to the originator when either is missing.

## Map Workstreams

Identify shared prerequisites first. A parallel workstream must be independently
useful, bounded to one owner, explicit about files and exclusions, and
verifiable without another agent's unstated context.

For every workstream provide:

- outcome and why it matters;
- files or contracts owned;
- dependencies;
- isolation (`read-only`, `worktree`, or sequential shared checkout);
- acceptance criteria and verification command;
- the destructive failure or boundary condition to check.

Parallel edits require separate worktrees and globally disjoint file or contract
ownership. Sequence overlaps. Record the base commit and dirty state so an
isolated checkout does not silently omit user-owned prerequisites.

## Write Self-Contained Prompts

Use this shape for each delegated workstream:

```text
Role: <bounded role>
Goal: <observable outcome>
Why: <user or system impact>
Checkout: <absolute isolated path, or read-only>
Base: <commit and relevant dirty-state dependency>
Context: <facts, interfaces, and patterns already discovered>
Scope: <files and behavior owned>
Do not change: <explicit exclusions>
Claim to disprove: <verification work only>
Exact repro: <command or deterministic flow>
Done when: <binary acceptance criteria>
Verify: <post-change command or observable>
Report: <findings or changes, ref/diff, evidence, residual risk>
```

Do not make an agent rediscover known facts. Do not leak an expected finding to
a fresh-context reviewer.

## Present The Plan

Present the approach, prerequisite order, parallel fan-out, prompts, acceptance
criteria, open questions, and integration verification. Keep it inline unless
the repository explicitly uses plan artifacts. Respect any rule that GitHub
issues are the only open-work tracker.

If the user approves execution, hand the contract to `$orchestrate` or execute
it directly with the same ownership and verification boundaries.
