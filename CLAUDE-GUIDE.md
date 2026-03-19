# Working with Claude Code — Quick Reference

See the [README](README.md) for the full best practices guide. This is the cheat sheet.

---

## First-time setup

```bash
cd ~/dev
git clone https://github.com/jckeen/dotfiles.git
cd dotfiles && chmod +x setup.sh && ./setup.sh
```

The script auto-detects your platform (macOS, WSL, or Linux) and installs everything accordingly.

Then: `gh auth login` and `claude` to authenticate.

---

## Starting a Session

```bash
cc                       # Recommended: sync repos + memory, health check, launch
claude                   # Start new session directly
claude --continue        # Resume most recent
claude --resume          # Pick from recent sessions
claude-server            # Isolated worktree + remote access
```

Remote access is always on. Connect from anywhere at `claude.ai/code`.

---

## The Workflow

```
Plan → Build → Verify → Simplify → Review → Log → Handoff
```

1. **Shift+Tab (x2)** — Enter Plan Mode
2. Go back and forth until the plan is solid
3. Switch to Normal Mode — Claude executes
4. `/simplify` — Remove unnecessary complexity
5. `/review` — Check quality and security
6. `/changelog` — Log what happened
7. `/handoff` — If ending the session

---

## Slash Commands

| Command | Use |
|---------|-----|
| `/kickoff` | New project setup |
| `/changelog` | Log session changes |
| `/log-error` | Document error patterns |
| `/review` | Quality/security review |
| `/handoff` | Session transition |
| `/fix-issue 123` | Fix a GitHub issue end-to-end |
| `/simplify` | Remove over-engineering |
| `/commit-push-pr` | Commit + push + PR in one shot |
| `/claude-server` | Spawn worktree + remote |

---

## Key Shortcuts

| Key | Action |
|-----|--------|
| `Shift+Tab` (x2) | Plan Mode |
| `Ctrl+G` | Edit plan in editor |
| `Ctrl+B` | Background task |
| `Esc` | Stop (context preserved) |
| `Esc+Esc` | Rewind menu |
| `/clear` | Reset context |
| `/compact` | Compress context |
| `/btw` | Side question (no context cost) |

---

## Golden Rules

1. **Context is finite** — `/clear` between unrelated tasks
2. **Plan before building** — Plan Mode for anything non-trivial
3. **Always verify** — tests, screenshots, or expected outputs
4. **Use subagents** — for investigation and review (protects context)
5. **Be specific** — vague prompts waste tokens on wrong approaches
6. **Parallelize** — run multiple sessions with git worktrees
7. **CLAUDE.md compounds** — keep it pruned and accurate

---

## When Things Go Wrong

| Problem | Fix |
|---------|-----|
| Claude repeating itself | `/clear` and start fresh |
| Same error 3+ times | "Stop. Explain why this is failing" |
| Ignoring CLAUDE.md rules | CLAUDE.md too long — prune it |
| Context getting high | `/handoff` then `/clear` |
| Need to explore without cost | "Use subagents to investigate X" |
