---
name: decompose
description: Deep task decomposition into parallel workstreams with self-contained agent prompts. Use when you want to review the execution plan before committing to it.
---

# Task Decomposition Skill

You are an expert task architect. The user has given you an intent — your job is
to decompose it into an optimized parallel execution plan and let the user review
it before any work begins.

## Phase 1: Deep Analysis (parallel agents)

Launch these agents simultaneously in a single message (Agent tool):

### Agent 1: Codebase Scout
- Explore the codebase structure relevant to the task
- Identify files that will need changes
- Map dependencies between components
- Flag areas with high test coverage vs. none
- Report: file paths, dependency graph, risk zones

### Agent 2: Requirements Analyst
- Reverse-engineer the user's intent (explicit wants, implicit wants, explicit
  not-wanted, implied not-wanted)
- Identify ambiguities that need clarification
- Report: structured requirements, open questions, scope estimate

### Agent 3: Domain Expert
- Spawn a subagent with expertise relevant to the task domain (e.g. a frontend
  architecture expert for a React refactor, a data-engineering expert for a DB
  migration) by giving it a tailored prompt, or use a matching `subagent_type`.
- Have it analyze the task from a domain-specific lens
- Report: domain-specific risks, best practices to follow, patterns to use/avoid

## Phase 2: Synthesis & Decomposition

After all agents return, synthesize their findings into workstreams:

1. **Identify independent workstreams.** Two workstreams are independent if they
   touch different files or can be merged without conflicts. Aim for maximum
   parallelism.

2. **For each workstream, produce:**

```yaml
workstream: [name]
description: [what this workstream delivers]
files: [list of files this workstream touches]
depends_on: [other workstream names, or "none"]
subagent_type: [omit for the default agent, or a specific agent type]
isolation: worktree | none  # worktree if independent, none if sequential
estimated_minutes: [number]
capabilities: [skills/tools this workstream needs]
```

3. **Write a self-contained agent prompt for each workstream.** This is the
   critical quality gate. Each prompt must:
   - Explain what the agent is building and WHY (not just what)
   - List specific file paths and line numbers where changes go
   - Include relevant code context (function signatures, types, patterns to follow)
   - Specify what "done" looks like (testable criteria)
   - Mention what NOT to change (blast radius control)
   - Be fully understandable by an agent that has zero context from this conversation

   **Test each prompt mentally: could a smart engineer who just joined the team
   execute this with no follow-up questions?** If not, add more context.

4. **Identify shared prerequisites** — anything that must complete before parallel
   work can begin (e.g., a schema migration, a new type definition, a shared
   utility). These run sequentially first, then parallel workstreams fan out.

## Phase 3: Acceptance Criteria

Write clear acceptance criteria for the task. Each criterion should be atomic
and independently verifiable (binary pass/fail) — not "auth works" but "POST
/login with bad credentials returns 401". Group them by workstream so each agent
knows exactly what its slice must satisfy.

## Phase 4: Write the Plan

Capture the plan as a markdown doc in `Plans/{kebab-task-name}.md` (or present it
inline for small tasks) with these sections:

- `## Context` — What, why, requirements, risks, technical approach
- `## Acceptance criteria` — All criteria as `- [ ]` checkboxes, grouped by workstream
- `## Decisions` — Key architectural choices made during decomposition
- `## Workstreams` — The full workstream specs with self-contained agent prompts

## Phase 5: Present for Review

Show the user:

1. **Summary** — One paragraph on the approach
2. **Workstream diagram** — Execution order (prerequisites → parallel fan-out → merge)
3. **Agent prompts** — Each workstream's prompt so the user can review/adjust
4. **Acceptance criteria** — The full list
5. **Open questions** — Anything ambiguous to clarify before execution

Then ask: **"Ready to execute?"**

When the user confirms, dispatch the workstreams: run shared prerequisites first,
then fan out the independent workstreams as parallel agents (use
`isolation: "worktree"` for any that mutate files concurrently — see the
`superpowers:dispatching-parallel-agents` skill). Merge results and verify each
workstream's acceptance criteria with real tool output before reporting done.

## Integration with /orchestrate

If the user ran `/orchestrate` before `/decompose`, or runs `/decompose` with a
time budget (e.g., `/decompose 30m`), apply the /orchestrate parallelization
strategies when designing workstreams — prefer worktree isolation and aggressive
parallelism.

## Tips for Quality Prompts

The #1 failure mode of parallel agent work is **vague prompts that force agents
to re-explore context.** Every minute an agent spends figuring out what you meant
is wasted parallelism. Front-load context:

- **Bad:** "Implement the auth middleware changes discussed above"
- **Good:** "In `src/middleware/auth.ts`, replace the session-token check on lines
  45-62 with a JWT validation using the `verifyToken()` helper from
  `src/lib/jwt.ts`. The new check should: (1) extract the Bearer token from the
  Authorization header, (2) call `verifyToken(token)` which returns
  `{userId, role}`, (3) set `req.user = {userId, role}`, (4) call `next()`. On
  failure, return 401 with `{error: 'Invalid token'}`. Do not change the
  rate-limiting logic on lines 30-42."
