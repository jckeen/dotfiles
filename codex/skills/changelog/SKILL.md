---
name: changelog
description: Update a project CHANGELOG.md or equivalent session log with concise notes about completed changes, decisions, and known issues.
---

# Changelog

Use when the user asks to update the changelog, log the session, or record what
changed.

## Workflow

1. Check whether `CHANGELOG.md` exists at the project root.
2. Read the top of the file to match its existing style.
3. Inspect recent relevant commits or diffs if needed.
4. Add a new entry near the top unless the existing changelog uses another
   clear ordering.
5. Keep notes public-safe and concise.
6. Commit the changelog only if the user asked for a commit or the local
   workflow clearly expects it.

## Default Entry Shape

```markdown
## YYYY-MM-DD

### What Changed
- ...

### Decisions
- ...

### Known Issues
- ...
```

Do not include private context, generated runtime paths, or unrelated work.
