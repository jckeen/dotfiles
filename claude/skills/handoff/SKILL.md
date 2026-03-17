---
name: handoff
description: Generate a handoff note for clean session transitions — preserves context across /clear or new sessions
user_invocable: true
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

2. Save the note to `.claude/handoffs/[date]-handoff.md` in the project root (create the directory if needed).
3. If the project has a `CHANGELOG.md`, update it with what happened this session.
4. Commit all pending work and the handoff note.
5. Display the handoff note so the user can copy it or reference it when starting a new session.

**Tip:** The user can paste the handoff note at the start of a new session to restore context cleanly.
