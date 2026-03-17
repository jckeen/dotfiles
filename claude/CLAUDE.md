# Global Instructions

## Session Workflow
At the start of every session:
1. Read the project's `CLAUDE.md` and `CHANGELOG.md` if they exist
2. Run `git status` and `git log --oneline -5` to understand current state
3. If the user's goal is unclear, ask before coding — don't guess

During a session:
- **Plan before building** — for anything non-trivial, outline the approach first and get sign-off
- **Test before committing** — run the project's build/check/test command before every commit
- **Stay focused** — do what was asked, nothing more. No drive-by refactors, no surprise features
- **When stuck, say so** — if the same error appears 3+ times, stop and explain the root cause instead of retrying

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

## Context Hygiene
- Context degrades after ~50k tokens. For long sessions, suggest the user start fresh or use `/handoff` to preserve context cleanly.
- Keep responses concise. Don't repeat what the user said. Don't summarize what you just did unless asked.
- Treat context as a finite resource — irrelevant tokens actively impair performance.

## Subagent Control
- Use **Opus subagents** for complex reasoning, architecture, and knowledge-intensive tasks. Don't let important work fall to lighter models.
- One clear objective per subagent with well-defined inputs/outputs.
- Prefer more focused subagents over fewer overloaded ones — parallel isolation beats shared context pollution.
- Verify subagent outputs deterministically when chaining — don't pass hallucinations downstream.

## Lean Tooling
- Every MCP tool and integration costs context tokens. Only add tools that earn their keep.
- Prefer Claude's native capabilities (Read, Grep, Bash) before reaching for MCPs.
- If a tool hasn't been used in a session, it's wasting context.

## Agent Pack
See `~/.claude/AgentPackJCK.md` for the multi-agent review framework. When analyzing, reviewing, or improving a project, use the agent perspectives defined there and label which agent is speaking.

## Available Skills
- `/kickoff` — Bootstrap a new project with proper structure and config
- `/changelog` — Update the project changelog with what happened this session
- `/log-error` — Document errors with failure classification (hallucination, instruction-ignored, context-lost, wrong-tool, incomplete, external)
- `/review` — Review recent changes for quality, security, and correctness
- `/handoff` — Generate a handoff note for clean session transitions
- `/claude-server` — Start a remote control server in an isolated worktree
