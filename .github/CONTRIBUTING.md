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

- Run `shellcheck --severity=warning setup.sh` — it must be clean, matching CI.
- Run `./setup.sh --check` on at least one platform and include the result
  in the PR description, e.g. *"I ran `./setup.sh --check` on macOS 14
  (Apple Silicon) — passes."*

To check the full shell surface, including shell dotfiles and the extension-less
pre-push hook:

```bash
git ls-files -z '*.sh' '.bash_aliases' '.bash_profile' 'githooks/pre-push' | xargs -0 shellcheck --severity=warning
```

The ShellCheck action and its configuration are maintained in
[`ci.yml`](workflows/ci.yml); use that source when matching the CI environment.

If your PR touches `claude/hooks/*.hook.ts`:

- Run `bunx tsc --noEmit` in `claude/hooks/` — it must pass.

If your PR touches `*.py`:

- Run both, from the repo root, with the ruff version pinned in `ruff.toml`
  (`required-version`) — they must be clean, matching the `python-lint` CI job:

```bash
uvx ruff@0.16.8 check .
uvx ruff@0.16.8 format --check .
```

`ruff format .` and `ruff check --fix .` apply the mechanical fixes; anything
left (e.g. B023 loop-variable closures) is fixed by hand, never with a
blanket `noqa`.

If your PR touches `.github/workflows/*.yml` or any tracked `.json`:

- Run [`actionlint`](https://github.com/rhysd/actionlint) from the repo root
  (the version CI pins is in [`ci.yml`](workflows/ci.yml)) — it must report
  nothing. It shellchecks every inline `run:` block, which the ShellCheck
  action cannot see.
- Run `git ls-files -z '*.json' | xargs -0 -n1 jq empty` — every tracked JSON
  file must parse.

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
