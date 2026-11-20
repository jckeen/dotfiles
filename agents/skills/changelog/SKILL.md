---
name: changelog
description: Update a project CHANGELOG.md, the branch's changelog.d/ fragment where the repo keeps one, or an equivalent session log with concise notes about completed changes, decisions, and known issues.
---

# Changelog

Use when the user asks to update the changelog, log the session, or record what
changed.

## Workflow

1. If the project root has a `changelog.d/` directory, write the entry to
   this branch's fragment, `changelog.d/<branch-slug>.md` (the branch name
   with every `/` turned to `-`), and leave `CHANGELOG.md` alone. The slug is
   not unique (`feat/a-b` and `feat-a/b` both give `feat-a-b`) and the
   validator accepts only letters, digits, `.`, `_` and `-` in the name, so
   before updating an existing fragment confirm it is this branch's (`git log
   -- changelog.d/NAME.md` shows this branch's commits, or its headings describe
   this work); if it belongs to another branch, or the slug holds other
   characters, create a fragment under a distinct valid name instead (append
   the PR number, say). A fragment's entry heading is `## YYYY-MM-DD — type: summary` (a
   conventional-commit type) with at least one `- ` bullet; `###`
   subsections are allowed; no code fences, HTML comments or other `#`
   lines, and no `<` placeholders (`<` before a letter, `/`, `!` or `?` is
   refused even in inline code): write NAME-style placeholders. Validate with `claude/scripts/assemble-changelog.sh --check`
   where the repo has it.
   Otherwise check whether `CHANGELOG.md` exists at the project root.
2. Read the top of the file to match its existing style.
3. Inspect recent relevant commits or diffs if needed.
4. Add a new entry near the top unless the existing changelog uses another
   clear ordering.
5. Keep notes public-safe and concise.
6. Commit the changelog only if the user asked for a commit or the local
   workflow clearly expects it.

## Default Entry Shape

Use the same headings as the Claude `/changelog` skill so entries look identical
regardless of which tool wrote them (in a `changelog.d/` fragment the heading
also carries `— type: summary`):

```markdown
## YYYY-MM-DD

### What changed
- ...

### Decisions made
- ...

### Known issues
- ...
```

Do not include private context, generated runtime paths, or unrelated work.
