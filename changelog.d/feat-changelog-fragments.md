## 2026-10-19 — feat: per-PR changelog fragments (#626)

- **`changelog.d/<branch-slug>.md`** replaces editing `CHANGELOG.md` in a PR.
  The slug is the branch name with `/` turned to `-`. The file holds the entry
  exactly as it will read in `CHANGELOG.md`: a
  `## YYYY-MM-DD — <type>: <summary>` heading followed by bullets. Two open PRs
  no longer touch the same lines, so a merge to `main` stops forcing a conflict
  and a full re-gate (about 17 minutes of tests plus a Codex review) on every
  other open PR.
- **`claude/scripts/assemble-changelog.sh`** folds the fragments into
  `CHANGELOG.md` above the first entry, newest date first, with ties broken by
  filename and then by position in the file. It then deletes the fragments.
  With no fragments it does nothing, so a second run changes nothing. A
  malformed fragment is refused and nothing is written. `--check` validates
  without writing. `--base REF --branch NAME` also holds a PR to one fragment,
  named after its branch.
- **Assembly is manual**, done at release or handoff time as an ordinary PR.
  A bot commit to `main` cannot pass: `main` requires status checks on every
  commit, including from admins, and a `GITHUB_TOKEN` push never starts
  them. CI runs `--check` in the required `doc-truth` job, with the PR scope on
  pull requests.
- `.doc-contract` declares `changelog.d/*.md` as SOURCE, and `check-doc-refs.sh`
  exempts fragments the same way it exempts `CHANGELOG.md`. CONTRIBUTING, the
  PR template, `CLAUDE-GUIDE.md`, `ROADMAP.md` and the scripts README describe
  the new flow. Tests: `claude/scripts/tests/assemble-changelog.test.sh`.
