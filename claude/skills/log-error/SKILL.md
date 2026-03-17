---
name: log-error
description: Document a persistent error pattern and what was tried
user_invocable: true
---

When the user runs /log-error, do the following:

1. Ask (if not obvious from context): What were you trying to do? What error kept appearing?
2. Create or append to `ERRORS.md` in the project root with this format:

```markdown
## [date] — Short description of the error

**Goal:** What we were trying to accomplish
**Error:** The exact error message or behavior
**What we tried:**
- Attempt 1 — result
- Attempt 2 — result

**Root cause:** (if found)
**Fix:** (if resolved)
**Status:** resolved | unresolved | workaround in place
```

3. If the error is unresolved, suggest: rephrase the goal, try a different approach, or flag it for a fresh session.
4. Commit the error log.
