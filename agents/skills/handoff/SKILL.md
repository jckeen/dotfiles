---
name: handoff
description: Generate a concise session handoff for resuming work later, including current state, decisions, open issues, and next steps.
---

# Handoff

Use when the user asks for a handoff, context note, session summary, or resume
brief.

## Workflow

1. Inspect the current repo state with `git status --short`.
2. Review relevant recent commits or diffs if needed.
3. Summarize only durable context that would help the next session.
4. Queue USER ACTION items to `~/.claude/operator-queue.md` — see
   "Operator-action queue" below for the block format and rules.
5. Session-end hygiene (before saving the note):
   - `git worktree list` — remove worktrees this session created and no
     longer needs (`git worktree remove <path>`).
   - Delete local branches fully merged into the default branch
     (`git branch --merged "$(git rev-parse --abbrev-ref origin/HEAD)"` —
     don't assume it's named `main`), excluding the default and current
     branches.
   - Push or PR every branch that has work on it — never leave work
     stranded local-only.
   - `gh pr list` — note each open PR's review + CI state in the
     handoff's "Open issues" section.
6. Save the note to `~/.claude/handoffs/YYYY-MM-DD-<project>-handoff.md` —
   the same directory the Claude `/handoff` skill uses, so either tool can
   resume the other's session. Create the directory if needed. Never save it
   inside the public repo.

## Output

Use the same section names as the Claude `/handoff` skill so notes are
interchangeable across tools:

```markdown
## Handoff — YYYY-MM-DD

### What we did
- ...

### Where we left off
- ...

### Key decisions made
- ...

### Open issues
- ...

### Next steps
- ...

### Context for next session
- ...

### Session continuity
- (optional) Resumable agent sessions: my Codex session id (`codex resume <id>`),
  or an agy conversation id (`agy --conversation <id>`). Omit if none.
```

Keep it concise. Do not include secrets, private project details, tokens, or
machine-specific paths unless the user explicitly asks and the destination is
private.

### Operator-action queue

Anything only the operator can do (rotate a token, click an approval, decide
on a purchase) goes to the durable queue at `~/.claude/operator-queue.md` —
handoff prose gets buried by the next handoff; the queue does not. One item
per block:

```markdown
## <stable-slug>
- added: YYYY-MM-DD
- project: <source project>
- deadline: YYYY-MM-DD
- action: <one line: what the operator must do>
```

The slug is stable (same action = same slug across sessions); `deadline` is
optional — omit the line if none. **Append only if absent** — match on the
slug, never re-add or duplicate an existing item. **Remove an item's block
only when the action is actually done**, not when it's merely mentioned
again.
