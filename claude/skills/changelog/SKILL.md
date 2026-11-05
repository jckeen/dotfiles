---
name: changelog
description: Records what changed this session into a CHANGELOG.md at the project root, or, where the repo keeps a `changelog.d/` directory, into the branch's `changelog.d/<branch-slug>.md` fragment — reads git log since the last entry and writes a dated entry (What changed / Decisions made / Known issues), then commits it. Use when the user explicitly wants to log/record changes — "update the changelog", "log this session", "add a changelog entry", "record what we did". For preserving context across /clear or a new session use handoff instead; for improving your skills use session-retro.
---

When the user runs /changelog, do the following:

1. If the project root has a `changelog.d/` directory, the entry goes in this
   branch's fragment, `changelog.d/<branch-slug>.md` (the branch name with
   every `/` turned to `-`), not in `CHANGELOG.md`: create it, or update it
   if the branch already has one. The slug is not unique (`feat/a-b` and
   `feat-a/b` both give `feat-a-b`) and the validator accepts only letters,
   digits, `.`, `_` and `-` in the name, so before updating an existing
   fragment confirm it is this branch's (`git log -- changelog.d/NAME.md`
   shows this branch's commits, or its headings describe this work); if it
   belongs to another branch, or the slug holds other characters, create a
   fragment under a distinct valid name instead (append the PR number, say).
   A fragment's entry heading is `## YYYY-MM-DD — type: summary` (a
   conventional-commit type) with at least one `- ` bullet; `###`
   subsections are allowed; no code fences, HTML comments or other `#`
   lines, and no `<` placeholders (`<` before a letter, `/`, `!` or `?` is
   refused even in inline code): write NAME-style placeholders. Validate with `claude/scripts/assemble-changelog.sh --check`
   where the repo has it.
   Otherwise check if `CHANGELOG.md` exists in the project root; if not,
   create it.
2. Run `git log --oneline` to see commits since the last changelog entry.
3. Add a new entry at the TOP of the file (most recent first) with this format
   (in a `changelog.d/` fragment the heading also carries `— type: summary`):

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
