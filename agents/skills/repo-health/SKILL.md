---
name: repo-health
description: Produce a read-only repository health briefing covering stack, git state, setup, tests, dependencies, blockers, and next steps.
---

# Repo Health

Use for quick orientation or a read-only health check of a repository.

## Workflow

1. Identify the project:
   - read `README.md`, project guidance files, and manifests such as
     `package.json`, `pyproject.toml`, `go.mod`, or `Cargo.toml`
2. Inspect current state:
   - `git status --short`
   - `git log --oneline -10`
   - current branch and uncommitted work
3. Find commands:
   - setup/install
   - test
   - lint/typecheck/build
4. Check dependency health when practical:
   - use ecosystem-native commands if dependencies are installed
   - do not install or update dependencies without user approval
5. Search for obvious blockers in handoffs, changelogs, TODOs, and issue notes.

## Output

Keep it short:

```markdown
## Repo Health
**Stack:** ...
**State:** ...
**Commands:** ...
**Verification:** ...
**Dependency Notes:** ...
**Blockers:** ...
**Next Steps:** ...
```

This is read-only by default. Do not edit files unless the user separately asks
for fixes.
