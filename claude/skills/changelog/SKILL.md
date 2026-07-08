---
name: changelog
description: Records what changed this session into a CHANGELOG.md at the project root — reads git log since the last entry and prepends a dated entry (What changed / Decisions made / Known issues), then commits it. Use when the user explicitly wants to log/record changes — "update the changelog", "log this session", "add a changelog entry", "record what we did". For preserving context across /clear or a new session use handoff instead; for improving your skills use session-retro.
---

When the user runs /changelog, do the following:

1. Check if `CHANGELOG.md` exists in the project root. If not, create it.
2. Run `git log --oneline` to see commits since the last changelog entry.
3. Add a new entry at the TOP of the file (most recent first) with this format:

```markdown
## YYYY-MM-DD

### What changed
- bullet point summary of each meaningful change

### Decisions made
- any architectural or design decisions worth remembering

### Known issues
- anything broken, deferred, or flagged for later
```

4. Keep entries concise — this is a reference log, not prose.
5. Commit the changelog update.
