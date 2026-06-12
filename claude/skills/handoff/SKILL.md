---
name: handoff
description: Generate a handoff note for clean session transitions — preserves context across /clear or new sessions. Use when ending a session, when context is getting high, or when the user says "hand off", "wrap up the session", or "save state for next time".
---

When the user runs /handoff, do the following:

1. Summarize the current session into a handoff note with this structure:

```markdown
## Handoff — [date]

### What we did
- Bullet points of completed work this session

### Where we left off
- Current state of the work (what's done, what's in progress)
- Any uncommitted changes or pending tasks

### Key decisions made
- Architectural or design choices worth remembering

### Open issues
- Anything broken, blocked, or deferred

### Next steps
- What to pick up in the next session (prioritized)

### Context for next session
- Anything the next session needs to know that isn't in the code or git history
```

2. Save the note to `~/.claude/handoffs/[date]-[project-name]-handoff.md` (the global Claude config directory, NOT inside the project repo). Create the directory if needed. **If the file already exists, Read it first before Writing** — this prevents the overwrite confirmation prompt.
3. Update `CHANGELOG.md` with what happened this session. Create it if it doesn't exist. Keep entries concise — what changed and why, not how.
4. Session-end hygiene (before committing):
   - `git worktree list` — remove worktrees this session created and no
     longer needs (`git worktree remove <path>`).
   - Delete local branches fully merged into the default branch
     (`git branch --merged main`), excluding main and the current branch.
   - Push or PR every branch that has work on it — never leave work
     stranded local-only.
   - `gh pr list` — note each open PR's review + CI state in the
     handoff's "Open issues" section.
5. Commit all pending work (do NOT commit the handoff note — it lives outside the repo).
6. Display the handoff note so the user can copy it or reference it when starting a new session.

**Tip:** The user can paste the handoff note at the start of a new session to restore context cleanly.
