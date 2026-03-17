---
name: changelog
description: Update the project changelog with what happened this session
user_invocable: true
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
