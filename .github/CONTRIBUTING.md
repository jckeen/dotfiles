# Contributing

This repo is a personal Claude Code + Codex jumpstart. The maintainer is
opinionated about scope, style, and direction — please read this page before
opening a PR.

## PRs Welcome For

- Cross-platform fixes (macOS, Linux, WSL)
- Security hardening (quoting, `set -euo pipefail`, safer defaults)
- Documentation corrections and clarifications
- New agents, skills, or hooks **with a clear, documented use case**

## PRs That Will Likely Be Closed

- Personal preference changes ("I like fish better than bash")
- Renames or restructures without a concrete reason
- New dependencies without strong justification
- Anything that breaks a fresh `./setup.sh` on macOS or Ubuntu

## Required Before Submitting

If your PR touches `setup.sh`:

- Run `shellcheck setup.sh` — it must be clean (severity `warning`).
- Run `./setup.sh --check` on at least one platform and include the result
  in the PR description, e.g. *"I ran `./setup.sh --check` on macOS 14
  (Apple Silicon) — passes."*

If your PR touches `claude/hooks/*.hook.ts`:

- Run `bunx tsc --noEmit` in `claude/hooks/` — it must pass.

## Commit Style

We use [Conventional Commits](https://www.conventionalcommits.org/) — this
matches the in-repo `claude/hooks/conventional-commit.sh` hook:

```
feat(setup): add --repair flag
fix(hooks): handle missing JSON input
docs(readme): clarify WSL prerequisites
chore: bump bun-types
```

Allowed types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`,
`build`, `perf`, `style`, `revert`.

## Questions

Open a GitHub issue and label it `question` (Discussions is not enabled on
this repo). Keep questions separate from bug reports and feature requests —
one issue per topic.
