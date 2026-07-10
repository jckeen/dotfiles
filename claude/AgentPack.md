# Agent Pack — Multi-Agent Orchestra

A team of 18 specialized subagents, each running in its own isolated context. Spawn the relevant agents in parallel — they investigate independently and report back without polluting each other's context.

Agents deliberately carry no `model:` pin — they inherit the session model, and the orchestrator picks a lighter model per-run when the task warrants it (e.g. a quick `repo-scout` briefing on haiku).

## The Team

### Review agents (read-only)

| Agent | Focus | When to use |
|-------|-------|-------------|
| `product-strategist` | User flow, feature scope, stickiness | Starting a project, pivoting, or reviewing a feature |
| `ux-reviewer` | Layout, hierarchy, mobile, interactions | After UI work, before shipping frontend changes |
| `frontend-architect` | Components, state, rendering, maintainability | After frontend implementation |
| `backend-architect` | Schema, APIs, queries, data integrity | After backend implementation |
| `growth-strategist` | Sharing, SEO, viral loops, analytics | Pre-launch, or when engagement is low |
| `content-reviewer` | Microcopy, tone, empty states, error messages | After building user-facing features |
| `trust-safety` | Abuse prevention, moderation, legal compliance | Before launch, or when adding user-generated content |
| `qa-lead` | Edge cases, bad input, error states, mobile | Before any release |
| `perf-accessibility` | Load times, WCAG, keyboard nav, screen readers | Before launch, after major UI changes |
| `launch-operator` | Deploy pipeline, monitoring, environment config | Pre-launch readiness check |
| `security-reviewer` | In-context app-logic flaws: broken authz/IDOR, trust boundaries, business logic (generic patterns → soundcheck plugin) | After implementation, before merge |
| `code-simplifier` | Over-engineering, dead code, premature abstractions | After implementation, before merge |
| `agent-native-review` | Agent-consumed surfaces: verification affordances, subagent context parity, primitive tool design, instruction drift | After changing skills, hooks, agent definitions, or instruction files |

### Utility agents (read-only except `test-writer`, which edits)

| Agent | Focus | When to use |
|-------|-------|-------------|
| `repo-scout` | Fast codebase orientation and status briefing | Jumping into a repo, starting a session, context refresh |
| `dependency-doctor` | Dep audits, CVEs, outdated packages, upgrade paths | Periodic health checks, before upgrades, pre-launch |
| `test-writer` | Bug reproduction, feature coverage, edge case tests | Before fixing bugs (failing test first), after new features |
| `schema-reviewer` | DB schema, migrations, data integrity, query patterns | After schema changes, before running migrations |
| `package-scout` | Build-vs-buy research — finds existing packages before building from scratch | Before implementing non-trivial features or utilities |

## How to invoke

Ask Claude to spawn agents by name:

- **Single agent:** "Use the qa-lead agent to review this feature"
- **Multiple in parallel:** "Run product-strategist, ux-reviewer, and growth-strategist on this project"
- **Full review:** "Run the full agent pack review on this project" (spawns all relevant agents)
- **Phase-based:** "Run a Phase 1 review" (see workflow below)

Each agent runs in its own context window, reads the codebase fresh, and reports back findings. The main thread synthesizes results.

## Coordination Rules

### When to parallelize

**Safe to run in parallel (read-only review):**
- All review agents can run simultaneously — they don't edit, just report
- Investigation and research tasks
- Reviews of independent subsystems

**Must run sequentially (when agents edit code):**
- Edits to shared files
- Changes where one agent's output affects another's input
- Fixes to interdependent systems

### Orchestration patterns

**Pattern A: Parallel review, apply in main thread**
1. Spawn relevant agents in parallel (read-only investigation)
2. Collect all findings in the main thread
3. Prioritize and apply fixes sequentially
4. Verify (lint, test, build) after each batch

**Pattern B: Staged rounds**
1. Round 1 (parallel): Independent changes with no shared files
2. Verify
3. Round 2 (parallel): Changes that depend on Round 1
4. Verify

**Pattern C: Worktree isolation**
For risky parallel edits, spawn agents with `isolation: "worktree"` — each gets its own branch. Review and merge sequentially.

### Anti-patterns

- Do NOT spawn agents that all edit the same files simultaneously
- Do NOT let agents commit independently when changes are interdependent
- Do NOT skip verification between rounds
- Do NOT have agents guess at schema or API shapes — they must read the actual code

## Recommended Workflow

The three phases below cover the code-review lifecycle. The utility agents
(`repo-scout`, `dependency-doctor`, `test-writer`, `package-scout` — except
where a phase names them) are invoked ad hoc rather than as part of a phase.

### Phase 1 — Product refinement
**Agents:** product-strategist, growth-strategist, trust-safety, package-scout
**Goal:** Define the right product shape before building. Identify existing packages before writing from scratch.
**Mode:** All parallel (read-only review).

### Phase 2 — Architecture and implementation review
**Agents:** frontend-architect, backend-architect, schema-reviewer, ux-reviewer, content-reviewer, security-reviewer
**Goal:** Is it built clean, secure, and simple? (`ux-reviewer` and `schema-reviewer` review built UI and migrations, so they belong here, not before the code exists.)
**Mode:** All parallel (read-only review). Apply fixes sequentially.

### Phase 3 — Launch hardening
**Agents:** qa-lead, perf-accessibility, launch-operator, code-simplifier
**Goal:** Make sure it works, performs, and is ready to ship.
**Mode:** All parallel (review), then apply fixes in dependency order.
