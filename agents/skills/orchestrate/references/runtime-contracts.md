# Runtime Contracts

Use the current runtime's native controls. Do not imitate another agent's tool
syntax.

## Codex

- Explicit user requests such as "use subagents" and applicable `AGENTS.md` or
  skill instructions authorize delegation. Do not fan out merely because a
  task is large.
- Use the native agent controls to spawn, message, redirect, wait for, and stop
  agents. Inspect the available concurrency rather than hardcoding a count.
- Agents in one thread may share a filesystem. Unless the harness explicitly
  provides isolation, create a Git worktree before giving an agent an editing
  task, assign files disjoint from every concurrent agent, and include the
  absolute worktree path and base commit in its prompt.
- Keep the main thread as conductor. Child agents may delegate narrower work,
  but the main thread owns dependency order, integration, verification, and the
  final response.
- A child agent's final report is delivered back to its parent. Still inspect
  the resulting files and rerun the claimed verification from the integration
  checkout.
- Prefer the built-in read-only review surface or spawn a review agent without
  inherited turns for the final diff. Use another model lineage when the
  project requires independent refutation.

## Claude Code

- Use Claude's native agent and teammate controls rather than Codex tool names.
- Use the runtime's worktree isolation for editing agents when available.
- Named teammates must report through the channel the current Claude runtime
  exposes; verify the result rather than relying on idle notifications.
- Preserve the repository's existing Claude-specific review gates and hooks.

## Antigravity Or Generic Runtimes

- Delegate only if the runtime exposes a real agent boundary. Multiple prompts
  executed serially in one context are not subagents.
- Use separate worktrees for concurrent edits and preserve one owner per file.
- If a model or provider pin matters to lineage independence, verify the
  runtime actually honored it before counting the review.
- When native orchestration is absent, execute the same phases sequentially
  and keep the claim/repro and evidence contract intact.

## Agent Prompt Template

```text
Role: <bounded role>
Goal: <observable outcome>
Why: <user or system impact>
Checkout: <absolute isolated path, or read-only>
Base: <commit and relevant dirty-state dependency>
Context: <facts, interfaces, and patterns the agent must not rediscover>
Scope: <files and behavior owned>
Do not change: <explicit exclusions>
Claim to disprove: <required for verification work>
Exact repro: <command or deterministic flow>
Done when: <binary acceptance criteria>
Verify: <post-change command or observable>
Report: <findings or changes, ref/commit/diff, evidence, residual risk>
```

Use the minimum context that makes the prompt self-contained. For skill or
process evaluation, provide the artifact under test without leaking the
expected finding.
