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
4. If asked to save the handoff, prefer a private location outside the public
   repo unless the project already has a tracked handoff convention.

## Output

Use this shape:

```markdown
## Handoff - YYYY-MM-DD

### What We Did
- ...

### Current State
- ...

### Decisions
- ...

### Open Issues
- ...

### Next Steps
- ...

### Resume Context
- ...
```

Keep it concise. Do not include secrets, private project details, tokens, or
machine-specific paths unless the user explicitly asks and the destination is
private.
