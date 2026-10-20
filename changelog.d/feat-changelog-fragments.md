## 2026-10-19 — feat: per-PR changelog fragments, checked before push (#626)

- **`changelog.d/`** replaces editing `CHANGELOG.md` in a PR. Each PR adds
  one fragment file, named by convention after its branch with `/` turned to
  `-`. The file holds the entry exactly as it will read in `CHANGELOG.md`: a
  `## YYYY-MM-DD — <type>: <summary>` heading followed by bullets. Two open
  PRs no longer touch the same lines. A merge to `main` therefore stops
  forcing a conflict and a full re-gate (about 17 minutes of tests plus a
  Codex review) on every other open PR.
- **`claude/scripts/assemble-changelog.sh --check`** validates fragments
  before push and never writes. The name is historical: the script's fold mode
  was removed before merge, after review kept finding Markdown edge cases in
  it.
- **Folding is a reviewed manual step**, done at release or handoff time in a
  `docs: fold changelog fragments` PR. Copy each fragment's entries above the
  first `## ` entry in `CHANGELOG.md`, newest date first, then `git rm` the
  fragments. It is not a bot push to `main`: `main` requires status checks on
  every commit, including from admins, and a `GITHUB_TOKEN` push never starts
  them.
- **Every fragment line must match an allowed shape**, so the parsed surface
  is finite. A line must be one of:
  - blank;
  - an entry heading;
  - a `### ` subsection;
  - a bullet, indented 0–3 spaces;
  - a continuation line, indented 2+ spaces.

  Bullet and continuation text may not start with `<`, `>`, `|`, `#` or `=`.
  That holds as written and again after every leading list or quote marker
  is stripped. The text also may not consist only of `-`, `*`, `_`, `=`, `:`
  and `|`, which would make it a rule, a setext underline or a table
  delimiter row. No line may contain an HTML comment marker, a run of three
  backticks or a run of three tildes, anywhere. Inline code is fine.
- **`--check` also refuses:**
  - a bad heading or calendar date;
  - an entry with no bullet;
  - a tab in a heading line;
  - CRLF line endings;
  - the same heading repeated among pending fragments;
  - an entry whose heading is already a line in `CHANGELOG.md`;
  - an unreadable or symlinked input;
  - a `CHANGELOG.md` that is missing, lacks its title on line 1, or holds
    anything above its first `## ` line besides blank lines, the title and
    the script's own pointer lines.
- **The script is a pure content validator.** It reads the working tree,
  runs no git and writes nothing. The PR-scope rule needs the PR's diff, so
  it is not part of the script. That rule is: a PR adds at most one
  fragment, modifies or renames none already on `main`, and adds no `## `
  entry to `CHANGELOG.md` alongside a fragment. The filename is never
  derived from the branch, because two branches can share a slug.
- **In CI**, `doc-refs.test.sh` runs the script's self-test and `--check` on
  the checkout's own fragments.
- **Docs:** `CLAUDE-GUIDE.md`, `ROADMAP.md`, the scripts README and the
  pointer lines under the `CHANGELOG.md` title describe the flow. The
  doc-contract entry for `changelog.d/*.md` landed separately, in #663. Tests:
  `claude/scripts/tests/assemble-changelog.test.sh`.
