---
name: log-error
description: Document a persistent error pattern with failure classification and what was tried
user_invocable: true
---

When the user runs /log-error, do the following:

1. Ask (if not obvious from context): What were you trying to do? What error kept appearing?
2. Classify the failure into one of these categories:
   - **Hallucination** — Claude generated false information (wrong API, nonexistent method, fabricated docs)
   - **Instruction ignored** — Claude neglected an explicit directive in CLAUDE.md or the conversation
   - **Context lost** — Claude forgot prior conversation context or repeated earlier mistakes
   - **Wrong tool** — Claude applied the wrong methodology or tool for the task
   - **Incomplete execution** — Claude started a task but abandoned it partway through
   - **External** — The error came from tooling, environment, or dependencies (not Claude's fault)

3. Create or append to `ERRORS.md` in the project root with this format:

```markdown
## [date] — Short description of the error

**Category:** hallucination | instruction-ignored | context-lost | wrong-tool | incomplete | external
**Goal:** What we were trying to accomplish
**Error:** The exact error message or behavior
**What we tried:**
- Attempt 1 — result
- Attempt 2 — result

**Root cause:** (if found)
**Fix:** (if resolved)
**Status:** resolved | unresolved | workaround in place
**Lesson:** One sentence on what to do differently next time
```

4. If the error is unresolved, suggest: rephrase the goal, try a different approach, or flag it for a fresh session.
5. If the error reveals a pattern that should prevent future mistakes, suggest adding it to the project's CLAUDE.md or saving it as a feedback memory.
6. Commit the error log.

### Success logging

If the user says something like "that worked great" or "log that as a win", append to `ERRORS.md` under a `## Wins` section:

```markdown
### [date] — Short description
**What worked:** The approach or prompt that produced a reliable result
**Why it worked:** Best guess at what made this successful
```
