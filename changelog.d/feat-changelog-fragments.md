## 2026-10-19 — feat: per-PR changelog fragments (#626)

- **`changelog.d/`** replaces editing `CHANGELOG.md` in a PR. Each PR adds
  one fragment file, named by convention after its branch with `/` turned to
  `-`. The file holds the entry exactly as it will read in `CHANGELOG.md`: a
  `## YYYY-MM-DD — <type>: <summary>` heading followed by bullets. Two open
  PRs no longer touch the same lines. A merge to `main` therefore stops
  forcing a conflict and a full re-gate (about 17 minutes of tests plus a
  Codex review) on every other open PR.
- **`claude/scripts/assemble-changelog.sh`** inserts every pending entry
  immediately above the first line in `CHANGELOG.md` that starts with `## `.
  It then deletes the fragments. Entries appear in assembly order. Within one
  assembly they run newest date first; entries that share a date are ordered
  by filename, then by position in the file. Existing history is never parsed
  or reordered. With no fragments the script does nothing, so a second run
  changes nothing.
- **Every fragment line must match an allowed shape**, so the parsed surface
  is finite. A line must be one of:
  - blank;
  - an entry heading;
  - a `### ` subsection;
  - a bullet, indented 0–3 spaces;
  - a continuation line, indented 2+ spaces.

  Bullet and continuation text may not start with `<`, `>`, `|`, `#`, `=` or
  a fence. It also may not consist only of rule characters (`-`, `*`, `_`,
  `=`). Code fences, HTML blocks, comments, blockquotes, tables and setext
  underlines therefore have no line shape that passes. Inline code is fine.
- **A malformed fragment is refused and nothing is written.** Besides a line
  of the wrong shape, that covers:
  - a bad heading or calendar date;
  - an entry with no bullet;
  - a tab in a heading line;
  - the same heading repeated among pending fragments;
  - CRLF line endings;
  - an unreadable or symlinked input;
  - an entry whose heading is already a line in `CHANGELOG.md`.
- **`CHANGELOG.md` is checked only above its first `## ` line.** That region
  may hold only `# ` titles, blank lines and plain text. A line there that
  starts with `<`, `>`, `|`, a backtick, `~` or `#` is refused, in `--check`
  and in assembly.
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
