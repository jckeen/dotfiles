---
name: decompose
description: Deep task decomposition into parallel workstreams with self-contained agent prompts. Run before the Algorithm to skip OBSERVE/PLAN. Use when you want to review the execution plan before committing to it.
user_invocable: true
---

# Task Decomposition Skill

You are an expert task architect. The user has given you an intent — your job is to decompose it into an optimized parallel execution plan that the Algorithm can pick up at BUILD phase.

**This replaces the Algorithm's OBSERVE and PLAN phases.** Do them better, with more rigor, and let the user review before execution begins.

## Phase 1: Deep Analysis (parallel agents)

Launch these agents simultaneously in a single message:

### Agent 1: Codebase Scout
- Explore the codebase structure relevant to the task
- Identify files that will need changes
- Map dependencies between components
- Flag areas with high test coverage vs. none
- Report: file paths, dependency graph, risk zones

### Agent 2: Requirements Analyst
- Reverse-engineer the user's intent (explicit wants, implicit wants, explicit not-wanted, implied not-wanted)
- Identify ambiguities that need clarification
- Determine effort level based on scope
- Report: structured requirements, open questions, effort estimate

### Agent 3: Domain Expert (custom agent)
- Use the Agents skill to compose a custom agent with expertise relevant to the task domain (e.g., if it's a React refactor, compose a frontend architecture expert; if it's a database migration, compose a data engineering expert)
- Have this agent analyze the task from a domain-specific lens
- Report: domain-specific risks, best practices to follow, patterns to use/avoid

## Phase 2: Synthesis & Decomposition

After all agents return, synthesize their findings into workstreams:

1. **Identify independent workstreams.** Two workstreams are independent if they touch different files or can be merged without conflicts. Aim for maximum parallelism.

2. **For each workstream, produce:**

```yaml
workstream: [name]
description: [what this workstream delivers]
files: [list of files this workstream touches]
depends_on: [other workstream names, or "none"]
agent_type: [Engineer, custom agent spec, or specific subagent_type]
isolation: worktree | none  # worktree if independent, none if sequential
estimated_minutes: [number]
capabilities: [skills/tools this workstream needs]
```

3. **Write a self-contained agent prompt for each workstream.** This is the critical quality gate. Each prompt must:
   - Explain what the agent is building and WHY (not just what)
   - List specific file paths and line numbers where changes go
   - Include relevant code context (function signatures, types, patterns to follow)
   - Specify what "done" looks like (testable criteria)
   - Mention what NOT to change (blast radius control)
   - Be fully understandable by an agent that has zero context from this conversation

   **Test each prompt mentally: could a smart engineer who just joined the team execute this with no follow-up questions?** If not, add more context.

4. **Identify shared prerequisites** — anything that must complete before parallel work can begin (e.g., a schema migration, a new type definition, a shared utility). These run sequentially first, then parallel workstreams fan out.

## Phase 3: ISC Criteria

Generate atomic ISC criteria for the entire task. Follow the Algorithm's Splitting Test — every criterion must be independently verifiable, 8-12 words, binary pass/fail. Apply domain decomposition (UI/API/data/logic boundaries).

Minimum criteria counts by effort tier:
- Standard (< 2min): 8
- Extended (< 8min): 16
- Advanced (< 16min): 24
- Deep (< 32min): 40
- Comprehensive (< 120min): 64

## Phase 4: Write the PRD

Create the PRD at `MEMORY/WORK/{slug}/PRD.md` with:

```yaml
---
task: [8 word description]
slug: [YYYYMMDD-HHMMSS_kebab-description]
effort: [tier]
phase: plan
progress: 0/[N]
mode: interactive
started: [ISO timestamp]
updated: [ISO timestamp]
---
```

Populate all sections:
- `## Context` — What, why, requirements, risks, technical approach
- `## Criteria` — All ISC criteria as `- [ ] ISC-N: text` checkboxes
- `## Decisions` — Key architectural choices made during decomposition
- `## Workstreams` — The full workstream specs with agent prompts (this section is unique to /decompose PRDs)

## Phase 5: Present for Review

Show the user:

1. **Summary** — One paragraph on the approach
2. **Workstream diagram** — Show the execution order (prerequisites → parallel fan-out → merge)
3. **Agent prompts** — Show each workstream's prompt so the user can review/adjust
4. **ISC criteria** — The full list
5. **Open questions** — Anything ambiguous that the user should clarify before execution

Then ask: **"Ready to execute? I'll enter the Algorithm at BUILD phase."**

When the user confirms, enter the Algorithm by reading `PAI/Algorithm/v3.7.0.md` but skip directly to BUILD phase (the PRD is already populated with context, criteria, and plan). Set the PRD's phase to `build` and proceed.

## Integration with /max

If the user ran `/max` before `/decompose`, or runs `/decompose` with a time budget (e.g., `/decompose 30m`), apply the /max parallelization strategies when designing workstreams — prefer worktree isolation, agent teams, and aggressive parallelism.

## Tips for Quality Prompts

The #1 failure mode of parallel agent work is **vague prompts that force agents to re-explore context.** Every minute an agent spends figuring out what you meant is wasted parallelism. Front-load context:

- **Bad:** "Implement the auth middleware changes discussed above"
- **Good:** "In `src/middleware/auth.ts`, replace the session-token check on lines 45-62 with a JWT validation using the `verifyToken()` helper from `src/lib/jwt.ts`. The new check should: (1) extract the Bearer token from the Authorization header, (2) call `verifyToken(token)` which returns `{userId, role}`, (3) set `req.user = {userId, role}`, (4) call `next()`. On failure, return 401 with `{error: 'Invalid token'}`. Do not change the rate-limiting logic on lines 30-42."
