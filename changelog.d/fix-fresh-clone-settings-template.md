## 2026-10-19 — fix: a fresh clone without claude-memory gets a settings.json that wires the hooks

- **`claude/settings.example.json`** (new): a public `hooks` block that
  registers the hooks in `claude/hooks/` with their events and matchers,
  plus the `statusLine` for `statusline.sh`. Every command quotes its
  `$HOME` path, so a home directory with spaces still works. It holds no
  permissions, MCP servers or env. Listed in `claude/nolink.txt`, so the
  symlink pass never deploys it (#588).
  Two hooks are left out on purpose, listed with their reasons in the new
  `claude/settings-optout.txt`. `StripProjectPermissions.hook.ts` deletes a
  project's whole `permissions` block, deny rules included, which is only
  safe beside a global allowlist the template does not ship.
  `OperatorQueueReminder.hook.sh` defaults to the owner's private queue
  repo. `check-hooks-wired.sh` reads the same list and does not ask for
  those hooks, unless the live settings file opts in with
  `"env": {"CHECK_HOOKS_REQUIRE_ALL": "1"}`, as a full private setup does.
  Then every hook is required. The key is read from the file, never the
  process environment. Any other missing hook still reports as drift.
- **`claude/statusline.sh`**: runs on bash 3.2. The template runs it as
  `bash …`, which is system bash on macOS. A read loop replaces `readarray`,
  and `date` replaces printf's `%(…)T`. The per-directory git cache key falls
  back from `md5sum` to `md5 -q` to `cksum`; on macOS every directory had
  shared one key. The new
  `claude/scripts/tests/statusline.test.sh` (run from
  `setup-dry-run.test.sh`) renders it under the default bash,
  `bash --posix`, and `$STATUSLINE_BASH3` when that names a bash 3.x. The
  bash 3.2.57 case was verified locally; wiring it into CI's
  `doc-truth (bash 3.2)` job waits on an operator-reviewed workflow patch.
- **`claude/statusline.sh` cache format**: the git-info cache uses the
  0x1F unit separator instead of tabs, in a `.v2` file. A tab-separated read
  collapsed an empty field, such as no `origin` remote, and shifted every
  later column, so cached renders showed a repo named `0` and wrong
  counters.
- **Bash hooks the template enables** (new
  `claude/scripts/tests/hook-guards.test.sh`, run from
  `setup-dry-run.test.sh`):
  - `worktree-guard.sh` checks every segment of a compound command. `&&`,
    `||`, `;`, `|`, `&`, `$(…)`, backticks and newlines all split segments.
    It fails closed: each segment's raw text, quotes kept, is matched
    against a broad branch-op pattern, so quoted options such as
    `git -c 'user.name=A B' switch` cannot hide the subcommand. Only a
    segment that is plainly `git worktree …` is exempt. After `--`, checkout
    arguments are pathspecs (#695). Before, `git worktree list && git switch
    -c x` bypassed the guard.
  - `conventional-commit.sh` extracts `-m` messages with POSIX `awk`/`sed`
    instead of `grep -P`, which macOS grep lacks. It reads a quoted message
    that spans lines and validates its first line. It denies a commit whose
    message it cannot read. Before, the masked error let unvalidated
    messages through.
  - `PreMergeCodexHarvest.hook.sh` runs the harvester only for a command
    segment that starts with the merge command, after `VAR=value`
    assignments. The template also gives it `"if": "Bash(gh pr merge*)"`.
    Before, a search such as `rg` for the text filed issues. A merge inside
    `$(…)` or `if …; then` is deliberately not recognised: the close-time
    workflow harvests every PR anyway, while a false trigger files a junk
    issue.
- **`claude/hooks/HygieneStatus.hook.sh`**: finds `hygiene-status.sh` at
  setup's `~/.local/bin` link, then through its own symlink back to the
  checkout, instead of a fixed `~/dev/dotfiles` path. It exits 0 silently
  when neither resolves. Before, any checkout outside `~/dev` made the
  template's SessionStart hook exit 127. A sweep of the other template
  hooks and the helpers they call found no other fixed checkout path.
- **`setup.sh`**: when Claude Code is selected and neither
  `~/.claude/settings.json` (a dangling symlink counts) nor
  `claude-memory/bootstrap.sh` exists, `seed_claude_settings` copies the
  example in as a real file. A noclobber write means it never overwrites a
  file. It runs before the Claude CLI, auth and plugin steps, because a
  user-scope plugin install creates a `settings.json` that holds only
  `enabledPlugins`. `--dry-run` previews the copy, and the summary says
  which of the two happened. A real run that leaves hooks linked with
  `settings.json` missing ends with a warning and the fix. So does one whose
  settings lack any expected dotfiles hook registration, judged by
  `check-hooks-wired.sh` itself, so a file holding only custom hooks still
  warns. Before, such a clone reported a successful setup
  while every hook and the status line were inert.
- **`claude/scripts/tests/settings-example.test.sh`** (new; run from
  `setup-dry-run.test.sh`): the public counterpart of
  `check-hooks-wired.sh`. Every hook file must be registered unless
  `settings-optout.txt` lists it with a reason. The checker must pass
  `--strict` on the template and still flag an unlisted missing hook. Every registration must name a real file
  and run under `sh -c` when `HOME` contains a space. The status line must
  run `statusline.sh`, the template must carry no private keys, and the
  symlink pass must never link it. The seed must run before the plugin
  install, create the file once, never overwrite it, leave a dangling link
  alone, defer to the bootstrap, and only preview under `--dry-run`.
- **Docs**: README no longer claims hooks and the status line work without
  `claude-memory`. Its `touch settings.json` recipe (not valid JSON) is now a
  copy of the example plus a working `bootstrap.sh`. Its `--check` mode, which
  `setup.sh`'s health audit calls, only reports and writes nothing; the test
  suite runs the recipe straight from the README. CLAUDE-GUIDE's Hooks
  section, `claude/scripts/README.md` and `check-hooks-wired.sh`'s hints
  point at the template.
