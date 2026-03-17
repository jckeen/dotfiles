# Global Instructions

## Session Workflow
At the start of every session:
1. Read the project's `CLAUDE.md` and `CHANGELOG.md` if they exist
2. Run `git status` and `git log --oneline -5` to understand current state
3. If the user's goal is unclear, ask before coding — don't guess

During a session:
- **Plan before building** — for anything non-trivial, use Plan Mode (Shift+Tab twice). Go back and forth until the plan is solid, then switch to auto-accept and execute. A good plan is the difference between 1-shotting a PR and burning context on corrections.
- **Test before committing** — run the project's build/check/test command before every commit
- **Stay focused** — do what was asked, nothing more. No drive-by refactors, no surprise features
- **When stuck, say so** — if the same error appears 3+ times, stop and explain the root cause. Don't retry the same approach. Say: "This approach isn't working because X. Here are alternatives."
- **Course-correct early** — if you realize mid-implementation that the approach is wrong, stop immediately and say so rather than continuing down a bad path

At the end of a session or major task:
- Update `CHANGELOG.md` if the project has one
- Commit and push

## Git Workflow (Auto-Commit Routine)
- Use conventional-style commit messages: `type: short description`
  - Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `style`
- **Commit automatically** after completing each meaningful unit of work — do not wait for the user to ask
  - A "meaningful unit" = a feature, fix, refactor, config change, or any coherent set of changes
  - Run the project's build/check command before committing to ensure nothing is broken; do not commit broken code
  - If the build fails, fix it first, then commit
- **Push periodically** — after every 2-3 commits, or when finishing a task
- Stage specific files rather than `git add -A` to avoid accidentally committing secrets or junk
- Do not commit `.env`, `*.db`, `node_modules/`, or other sensitive/generated files

## Context Hygiene — YOUR MOST IMPORTANT RESOURCE
Context is finite and precious. Performance degrades as context fills. Treat every token as a cost.

- **Run `/clear` between unrelated tasks** — don't let irrelevant context accumulate
- Context degrades after ~50k tokens. For long sessions, suggest the user start fresh or use `/handoff` to preserve context cleanly
- Keep responses concise. Don't repeat what the user said. Don't summarize what you just did unless asked
- **Use subagents for investigation** — when exploring a codebase, delegate to subagents so file reads don't bloat the main context. Report back summaries, not raw content
- When compacting, always preserve: modified file list, test commands, key decisions, and current task state
- If auto-compaction triggers, that's a signal the session is getting long. Consider `/handoff` soon

## Subagent Control
- Use **Opus subagents** for complex reasoning, architecture, and knowledge-intensive tasks. Don't let important work fall to lighter models.
- One clear objective per subagent with well-defined inputs/outputs
- Prefer more focused subagents over fewer overloaded ones — parallel isolation beats shared context pollution
- Verify subagent outputs deterministically when chaining — don't pass hallucinations downstream
- **Use subagents for code review** — a fresh context reviews better than one biased toward code it just wrote

## Verification — ALWAYS VERIFY YOUR WORK
- IMPORTANT: Always provide verification. Run tests, compare screenshots, validate outputs
- If you can't verify it, don't ship it
- Address root causes, not symptoms — don't suppress errors, fix them
- When fixing bugs: write a failing test that reproduces the issue FIRST, then fix it

## Prompting the User
When the user gives a vague prompt for a non-trivial task, use the interview pattern:
- Ask clarifying questions about technical implementation, edge cases, and tradeoffs
- Don't ask obvious questions — dig into the hard parts they might not have considered
- Once aligned, write a spec or plan before implementing

## Self-Improvement Loop
- Every time you make a mistake that the user corrects, suggest adding a rule to the project's CLAUDE.md to prevent it from happening again
- Claude is "eerily good at writing rules for itself" — lean into this
- After every correction, consider: "What rule would have prevented this?"

## Lean Tooling
- Every MCP tool and integration costs context tokens. Only add tools that earn their keep
- Prefer Claude's native capabilities (Read, Grep, Bash) before reaching for MCPs
- If a tool hasn't been used in a session, it's wasting context
- Use CLI tools (gh, aws, gcloud) over MCP when possible — they're more context-efficient

## CLAUDE.md Maintenance
- Keep CLAUDE.md files under 200 lines. If it's too long, Claude ignores half of it
- For each line, ask: "Would removing this cause Claude to make mistakes?" If not, cut it
- If Claude keeps doing something wrong despite a rule, the file is too long and the rule is getting lost
- Convert frequently-violated rules into hooks instead — hooks are enforced, CLAUDE.md is advisory

## Agent Pack
See `~/.claude/AgentPack.md` for the multi-agent orchestration framework. Agents are real subagents — each runs in its own isolated context. Spawn them in parallel for reviews, collect findings in the main thread, apply fixes sequentially.

## Available Skills
- `/kickoff` — Bootstrap a new project with proper structure and config
- `/changelog` — Update the project changelog with what happened this session
- `/log-error` — Document errors with failure classification (hallucination, instruction-ignored, context-lost, wrong-tool, incomplete, external)
- `/review` — Review recent changes for quality, security, and correctness
- `/handoff` — Generate a handoff note for clean session transitions
- `/claude-server` — Start a remote control server in an isolated worktree
- `/fix-issue` — Pick up a GitHub issue, implement the fix, test, and PR
- `/simplify` — Review code for unnecessary complexity and simplify it
- `/commit-push-pr` — Commit, push, and create a PR in one shot (Boris's most-used daily command)

## Available Subagents (12 agents — see AgentPack.md for orchestration)
- `product-strategist` — User flow, feature scope, stickiness
- `ux-reviewer` — Layout, hierarchy, mobile, interaction design
- `frontend-architect` — Components, state management, rendering performance
- `backend-architect` — Schema, APIs, queries, data integrity
- `growth-strategist` — Sharing, SEO, viral loops, engagement
- `content-reviewer` — Microcopy, tone, empty states, error messages
- `trust-safety` — Abuse prevention, moderation, legal compliance
- `qa-lead` — Edge cases, bad input, error states, mobile testing
- `perf-accessibility` — Performance, WCAG compliance, keyboard navigation
- `launch-operator` — Deploy readiness, monitoring, environment config
- `security-reviewer` — Injection, auth flaws, secrets, insecure data
- `code-simplifier` — Over-engineering, dead code, premature abstractions
