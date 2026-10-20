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
  Cheap exits run first: a command whose text, with quotes and backslashes
  removed, has neither `switch` nor `checkout` (every blocked pattern has
  one) costs one grep. The real checks run on both the raw and the
  normalized text, so `git sw''itch` or `git sw\itch` is still caught. The
  linked-worktree
  and contention checks run before any parsing, so a 4000-line commit
  command is allowed in milliseconds instead of about 20 seconds.
- **`claude/hooks/conventional-commit.sh`**: extracts `-m` messages with
  POSIX `awk`/`sed` instead of `grep -P`, which macOS grep lacks. Before,
  the error was masked and `-m` messages went unchecked. It now:
  - reads a quoted message that spans lines;
  - takes the first non-blank line of a heredoc, and treats a message as a
    heredoc only when the `-m` argument is a `$(cat` substitution, with any
    whitespace or newline between `$(` and `cat`, ignoring CRLF line
    endings when it looks for the first non-blank line;
  - denies a commit whose message it cannot read;
  - has no early-exiting reader (`head`, a piped `grep -q`) under pipefail,
    so a long heredoc can no longer SIGPIPE its own extraction into a
    denial.
- **`claude/hooks/PreMergeCodexHarvest.hook.sh`**: runs the harvester only
  when the whole command starts with the merge command, after `VAR=value`
  assignments whose values are plain words, on a single line. There is no
  splitting, so a search, an echo, quoted text, an assignment value holding
  quotes or operators, or a heredoc body never fires it. The old unanchored match filed #691 from a `sed` command.
  A merge in a compound command or inside `$(…)` is a documented miss: the
  close-time workflow harvests every PR anyway.
