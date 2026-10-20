## 2026-10-20 — fix: worktree guard, commit-message and pre-merge hooks parse commands safely

- **Scope**: split out of #681, which enables these hooks for every fresh
  clone through the public settings template. The new
  `claude/scripts/tests/hook-guards.test.sh`, run from
  `setup-dry-run.test.sh`, feeds each real hook the reproductions from that
  PR's review rounds; the previous hooks fail 12 of them.

- **`claude/hooks/worktree-guard.sh`**: checks every segment of a compound
  command, split on `&&`, `||`, `;`, `|`, `&`, `$(…)`, backticks and
  newlines. Before, `git worktree list && git switch -c x` bypassed the
  guard, because any command containing `git … worktree` was exempt. It now
  fails closed:
  - each segment's raw text, quotes kept, is matched against a broad
    branch-op pattern;
  - the whole command, quotes removed, is also checked word by word and
    order-free: `git` plus `switch`, or `git` plus `checkout` plus a
    `-b`-style flag or `--orphan[=…]` before any `--`. A separator inside a
    quoted argument (`git -c 'user.name=A (B)' checkout main -b x`) can no
    longer cut `git` from its subcommand.
  Only a plain `git worktree …` is exempt, and a fancier worktree call that
  contains branch-op text is a safe false positive. After `--`, checkout
  arguments are pathspecs, so `git checkout -- -backup` is allowed (#695).
- **`claude/hooks/conventional-commit.sh`**: extracts `-m` messages with
  POSIX `awk`/`sed` instead of `grep -P`, which macOS grep lacks. Before,
  the error was masked and `-m` messages went unchecked. It now:
  - reads a quoted message that spans lines;
  - takes the first non-blank line of a heredoc, and treats a message as a
    heredoc only when the `-m` argument is a `$(cat` substitution;
  - denies a commit whose message it cannot read.
- **`claude/hooks/PreMergeCodexHarvest.hook.sh`**: runs the harvester only
  when the whole command starts with the merge command, after `VAR=value`
  assignments whose values hold no quotes or `$`. There is no splitting, so
  a search, an echo, quoted text or a quoted assignment value never fires
  it. The old unanchored match filed #691 from a `sed` command.
  A merge in a compound command or inside `$(…)` is a documented miss: the
  close-time workflow harvests every PR anyway.
