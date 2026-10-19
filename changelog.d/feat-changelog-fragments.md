## 2026-10-19 — feat: per-PR changelog fragments (#626)

- **`changelog.d/`** replaces editing `CHANGELOG.md` in a PR. Each PR adds
  one fragment file, named by convention after its branch with `/` turned to
  `-`. The file holds the entry exactly as it will read in `CHANGELOG.md`: a
  `## YYYY-MM-DD — <type>: <summary>` heading followed by bullets. Two open
  PRs no longer touch the same lines. A merge to `main` therefore stops
  forcing a conflict and a full re-gate (about 17 minutes of tests plus a
  Codex review) on every other open PR.
- **`claude/scripts/assemble-changelog.sh`** merges the fragments into
  `CHANGELOG.md` by date. Each entry goes above the first existing entry dated
  on or before it, so newest-first order holds. Entries that share a date are
  ordered by filename, then by position in the file. The script then deletes
  the fragments. With no fragments it does nothing, so a second run changes
  nothing.
- **A malformed fragment is refused and nothing is written.** That covers:
  - a bad heading or calendar date;
  - an entry with no list item (one indented at most three spaces);
  - an indented heading;
  - the same heading repeated among pending fragments;
  - an unclosed or mismatched fence;
  - CRLF line endings;
  - an unreadable or symlinked input;
  - an entry that is already in `CHANGELOG.md`.
- **Flags:** `--check` validates without writing. `--base REF` also holds a PR
  to one fragment file. The filename is never derived from the branch, because
  two branches can share a slug.
- **Assembly is manual**, at release or handoff time, as an ordinary PR. A bot
  commit to `main` cannot pass: `main` requires status checks on every commit,
  including from admins, and a `GITHUB_TOKEN` push never starts them. The
  self-test runs in CI through `doc-refs.test.sh`.
- **Docs:** `.doc-contract` declares `changelog.d/*.md` as SOURCE, and
  `check-doc-refs.sh` exempts fragments the same way it exempts
  `CHANGELOG.md`. `CLAUDE-GUIDE.md`, `ROADMAP.md` and the scripts README
  describe the new flow. Tests: `claude/scripts/tests/assemble-changelog.test.sh`.
