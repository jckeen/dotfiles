# Changelog

Entries not yet folded in live one per PR in `changelog.d/`; they are
copied here by hand at release time (see `claude/scripts/README.md`).

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
  There is no `git worktree` exemption: a worktree command without a
  `switch`/`checkout` word is allowed by the cheap exit, and one that
  contains such a word (`git worktree add -b switch …`) is judged like any
  other, a safe false positive. After `--`, checkout
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

## 2026-10-20 — fix(hooks): PluginDriftCheck rescans for mods mid-session

- `PluginDriftCheck.hook.ts` (#618): the hook is now also registered on `UserPromptSubmit`. Its cheap path reads this session's state file at `~/.local/state/plugin-drift/SESSION_ID` and stats every path the last full scan read or listed, about 506 on the operator's machine. The file is plain text and ends in an `end` line, so a truncated file reads as damaged. The cheap path parses no JSON and runs no subprocess.
- The full rescan runs only when one of these changed:
  - a watched path's size, mtime, inode, mode, ctime or existence (a dangling symlink is signed by `lstat`);
  - `DOTFILES_DIR`.
- `plugins.txt` is signed before it is read, so a swap in between counts as a change.
- A rescan names only the mods and unverifiable plugins this session has not been told about yet. A missing or damaged state file counts as a change. Paths and labels are stored as hex-encoded UTF-16 code units, which handles a lone surrogate. The reader accepts up to 64 MiB, because a large cache's state passes 1 MiB. SessionStart prunes state files older than 30 days.
- Measured on the operator's machine:
  - cheap path: about 33 ms, against a bun startup floor of about 40 ms;
  - full scan at SessionStart: about 57 ms;
  - rescan after a change: about 47 ms.
- Issue #647 stays open. Loader-differential cases remain best-effort, because Claude Code exposes no list of the hook modules it loaded. A `claude plugin list --json` union was tried and dropped: it lists no modules and cost about 900 ms per scan. An upstream feature request is drafted for the operator to file. Plugin-location env vars are tracked in #699.
- `check-hooks-wired.sh`: new `EVENT_WIRING` check. It requires `PluginDriftCheck.hook.ts` on both `SessionStart` (install drift and the full scan) and `UserPromptSubmit` (the rescan). The public `claude/settings.example.json` (#681) now registers it. The operator still has to add the `UserPromptSubmit` registration to the private `settings.json`.
- `CLAUDE-GUIDE.md` (Hooks): documents the rescan and says why the mod scan is best-effort.
- `plugin-drift.test.sh`: a stub `claude` on PATH proves the hook never runs the CLI. The rescan cases cover:
  - a mod installed or edited in place, a dangling `hooks.json`, and a directory made readable;
  - no repeated reports, per-session state, and damaged and truncated state;
  - a cwd change and a changed `DOTFILES_DIR`;
  - a project skills link replaced by a directory;
  - an unsafe session id, and pruning.

## 2026-10-20 — fix: skill-dir migration never clobbers a foreign link or follows a symlinked archive

- **`lib-symlinks.sh`** and **`claude/hooks/SymlinkRepair.hook.ts`**
  (issue #697, follow-up to #682): only an absent destination or exactly the bundle
  link (`readlink` equals the source, as `check_link` compares) counts as a
  rival's finished migration. Before, the device check treated any change at
  the destination as success. A foreign link that replaced it there (skills
  on another filesystem) then reached `link_file`, which replaced the user's
  link. Now it is left in place and the migration fails, at the first check,
  the device check and a failed rename alike.
- **The archive root and `kept/` must be real directories.** `mkdir -p`
  accepts a symlink to a directory and the rename followed it, for example
  back into `skills/`, where the archived copy loaded as a duplicate skill.
  A symlinked archive root now refuses the migration and leaves the legacy
  dir in place. A symlinked `kept/` leaves changed content in the archive,
  where `check-claude.sh` still reports it.
- **Tests** (`heal-race`, `symlink-enumerate`): a fake `stat` swaps in a
  foreign link and reports another device; a symlinked archive root and a
  symlinked `kept/` are covered in the shell and, through a Bun `--preload`
  shim, in the hook. Each new case fails on the previous code.

## 2026-10-19 — docs: declare changelog.d/ fragments

- **`.doc-contract`** declares `changelog.d/*.md` as LIVING, like `CHANGELOG.md`;
  **`check-doc-truth.sh`** exempts it from the dead-link rule, and
  **`claude/scripts/check-doc-refs.sh`** exempts it from the dead-reference
  rule, as it already exempts `CHANGELOG.md`. A PR may now record its entry
  as one `changelog.d/BRANCH-SLUG.md` fragment instead of prepending to
  `CHANGELOG.md`, so open PRs stop conflicting on the file's head (#626).
- Fragments are folded into `CHANGELOG.md` by hand until the
  `assemble-changelog.sh` tool in #661 lands. Each one holds a
  `## YYYY-MM-DD — type: summary` heading followed by bullets.

## 2026-10-19 — docs: pause the Jules routine lane; add the two drifted plugins to the manifest

- **`docs/adr/0009-jules-routine-lane.md`**: Status changes from Accepted to
  Paused, with a dated status update. The lane never ran as decided: no timer,
  two manual dispatches, no weekly report, so the 30% merge-rate rule was never
  applied (#589, #446). The update states three restart criteria: the #639
  fixes (already met by #670), an installed timer plus a recorded first weekly report, and web-app
  PRs recorded in the same ledger. The PR-stage fallback in #606 is declined
  along with the lane. `agents/README.md`, `README.md` and
  `claude/scripts/README.md` no longer describe the timer as running.
- **`claude/plugins.txt`**: adds `frontend-design@anthropic-plugin-directory`
  ([global], already enabled) and `supabase@anthropic-plugin-directory`
  ([per-project], listing its Supabase projects). Both were installed but not
  in the manifest, which made PluginDriftCheck report reverse drift at every
  SessionStart. The Anthropic Directory marketplace is built into Claude Code,
  so `setup.sh` gets a no-op registration arm for it, which
  `check-install-integrity.sh` requires for every marketplace in the manifest.
- **`claude/systemd/install.sh`** enforces the pause. The Jules unit is
  installed only with `JULES_LANE_ENABLED=1`. Without it the unit is skipped,
  and a timer an earlier install enabled is disabled, so re-running setup can't
  restart the lane (Codex bot, #678). `setup.sh` no longer tells the user to
  enable the timer. `tests/jules-dispatch.test.sh` covers both paths.
- **`setup.sh`** also disables a `jules-dispatch.timer` that an earlier install
  enabled, unless `JULES_LANE_ENABLED=1`. The normal `dotfiles-update` path
  runs `setup.sh`, not the systemd installer, so the pause has to be enforced
  there too (Codex bot, #678). Under `--dry-run` this is only a preview.

## 2026-10-19 — feat: per-PR changelog fragments, checked before push (#626)

- **`changelog.d/`** replaces editing `CHANGELOG.md` in a PR. Each PR adds
  one fragment file, named by convention after its branch with `/` turned to
  `-`. The file holds the entry exactly as it will read in `CHANGELOG.md`: a
  `## YYYY-MM-DD — TYPE: SUMMARY` heading followed by bullets. Two open
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
  entry to `CHANGELOG.md` alongside a fragment. **It is not enforced yet.**
  Reviewers check it by hand until the operator applies the CI patch
  `~/.claude/handoffs/2026-10-19-dotfiles-operator-pass/ci-changelog-check.patch`. The filename is never
  derived from the branch, because two branches can share a slug.
- **In CI today**, `doc-refs.test.sh` runs the script's self-test and `--check` on
  the checkout's own fragments.
- **Docs:** `CLAUDE-GUIDE.md`, `ROADMAP.md`, the scripts README and the
  pointer lines under the `CHANGELOG.md` title describe the flow. The
  doc-contract entry for `changelog.d/*.md` landed separately, in #663. Tests:
  `claude/scripts/tests/assemble-changelog.test.sh`.

## 2026-10-19 — feat(hooks): operator-action items live in the repo they concern

- **`claude/hooks/OperatorQueueReminder.hook.sh`**: the issue source is now one
  GraphQL search over the private home repo (`OPERATOR_QUEUE_REPO`, default
  `jckeen/claude-memory`) plus every repo of the `OPERATOR_QUEUE_OWNERS`
  accounts (default `jckeen Keen-Media therealnewsnetwork`; empty = home repo
  only). Owner values keep only GitHub login characters, so none can add a
  qualifier to the query. Because the items enter every session's context,
  only issues the operator wrote (`author:@me`) in private repos count, in the
  query and again in jq (`viewerDidAuthor`, `repository.isPrivate`): a
  stranger's issue in a public repo, a collaborator's, or one whose body
  someone else last edited or whose title someone else last renamed (GitHub's
  `editor` does not track renames) never renders. A refresh fails, rather
  than caching a partial list, when the search hits GitHub's 1000-result cap
  or the gh account changes while it runs.
  Each heading names its repo (`SLUG (REPO#N)`).
  With no body `project:` line, an issue outside the home repo takes its repo
  name as its project; labels count only in the home repo and only as a plain
  `project:SLUG`, since any collaborator can write a label. The owners are part of the cache key, which is
  versioned, so a cache written before these filters is never rendered, and
  carries a digest of the gh identity (token variables and `hosts.yml`, read
  locally), so switching gh accounts never shows another account's items.
  `OPERATOR_QUEUE_REPO` must be one plain `[host/]owner/name` (anything else
  refuses the issue source with one line), and at most ten owners are kept,
  so the scope in status lines stays bounded. Messages and
  the footer name the whole scope and print the hook's own search as a runnable
  `gh api graphql` command (`gh search issues --repo --owner` would AND them).
- Data move, 2026-10-19 (one-shot, run from a session; the queue file was
  the source of truth): 64 items moved from `jckeen/claude-memory` to 12
  private repos (their claude-memory issues closed "not planned" with a link
  to the new issue). 21 stay in claude-memory (dotfiles and agent-pack are
  public; fleet items span several repos). 2 were refreshed from the file and
  2 that were already done were closed.
- Antigravity's write permission for the retired queue file is removed.

## 2026-10-19 — fix: ccw shares each session's todos and tasks with the second account

- **`claude/scripts/link-claude-profile.sh`** (#591): the profile now links
  `todos/` and `tasks/` back to `~/.claude`, using the same mechanism as
  `projects/` and `file-history/`, so a session resumed on the other account
  still sees its todos and tasks. Both directories are created in the default
  profile when missing, and `--check` reports one that was removed as drift
  rather than accepting a dangling link. `session-env/` stays per account
  because it can carry account-bound environment.
- The guarantees from #632 are unchanged: an ancestor of `~/.claude` is
  refused, a symlinked `.claude.json` is drift, and a populated private
  directory is never overwritten.
- Docs: `CLAUDE-GUIDE.md` (A second account) and `claude/scripts/README.md`
  now name the shared sidecars and the per-account `session-env/`.
- Tests: seven new assertions in `claude/scripts/tests/claude-profile.test.sh`.

## 2026-10-19 — fix: the changelog fragment validator bans more constructs that hide or drop text

- **`claude/scripts/assemble-changelog.sh --check`** now refuses (#664):
  - a `>` quote marker exposed behind a nested list marker (`- - > x`); it
    used to be stripped as a container prefix, so the quote passed;
  - `<` followed by a letter, `/`, `!` or `?` anywhere on a line, inline
    code included (inline HTML can hide text);
  - a closing bracket followed by a colon anywhere on a line (a link
    reference definition renders as nothing);
  - any control byte but tab, NUL included, counted outside awk;
  - a fragment name with an embedded newline (the name is now matched as a
    whole string, not per line), and two names that differ only in case;
  - an entry heading whose summary has no letter or digit (`feat: **`), or
    holds a bracket or ampersand, since a link or entity can render as
    nothing while its destination or name supplies the letters.
- Items 1 and 2 (rule-only text after the prefix strip, pipe tables) were
  already refused on `main`; regression tests now pin them. Item 3 (one
  preamble code path) and the PR-scope rule belong to the operator CI patch,
  not this content-only script.
- Eight fragments already on `main` wrote placeholders in angle brackets
  inside inline code; they now use `NAME`-style placeholders so they pass.
- **`claude/scripts/tests/assemble-changelog.test.sh`**: one test per case.
  HTML-opening lines that were refused by line shape are now refused first
  by the inline HTML ban.

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
- **Template `if` filter**: the template registers
  `PreMergeCodexHarvest.hook.sh` with `"if": "Bash(gh pr merge*)"`, so the
  hook only spawns for merge commands. Hardening the parsing in that hook,
  `worktree-guard.sh` and `conventional-commit.sh` is a separate PR.
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
- **`setup.sh`**: the seed copies the template into a temp file beside the
  target, checks it is complete, then installs it with `ln`, which is atomic
  and refuses an existing file. A failed or partial read leaves no
  settings.json behind for later runs to skip (Codex bot, #681).

## 2026-10-19 — fix: jules-dispatch max_files limit cannot wrap, and oversized PRs are recorded however they ended

- **`claude/scripts/jules-dispatch.sh`** (#639): `max_files` and
  `max_prs_per_run` are capped at six digits in the frontmatter, and a
  ledger `max_files` is capped the same way. A PR's `changedFiles` is capped
  at nine digits. Before, a value past 2^63-1 wrapped in `[[ -gt ]]`, so every
  non-empty pull request read as oversized.
- Reconcile now checks the size before the closed/merged no-op. A PR merged
  or closed before reconcile ran but over its session's limit is recorded
  `blocked-oversized` and counted in `reconcile.oversized`, not `noop`.
- An oversized PR that an earlier partial pass labeled
  `jules-routine:ROUTINE` has that label removed, so it no longer passes
  as a compliant routine result.
- Tests: three new cases in `claude/scripts/tests/jules-dispatch.test.sh`,
  covering a 20-digit limit in the ledger and the frontmatter, label removal,
  and a merged oversized PR.

## 2026-10-19 — fix(hooks): operator-queue reminder bounds its snapshot, cleans refresh temporaries, prints status only

- **`claude/hooks/OperatorQueueReminder.hook.sh`** (#654): the SessionStart
  snapshot of the issue cache is now cut at one byte over the 64 KiB render
  limit, so an oversized cache no longer gets copied whole into the temp
  dir before the size guard refuses it. The cache is opened once on a file
  descriptor. The bytes and the mtime both come from that one file, so the
  one-snapshot property holds even if a refresh renames a new cache over it
  mid-copy. An oversized snapshot is never read as "no open issues".
- Same hook (#654): a refresh shell sent TERM, INT or HUP removes its
  `.raw.*`/`.new.*` temporaries on the way out. A refresh that recovers a
  killed predecessor's in-flight marker removes that predecessor's
  temporaries: only this cache's own mktemp names in the state dir, only
  files owned by the user. This is safe under the lock, because every fetch
  worker inherits the lock's descriptor. The flock serialisation, the
  in-flight/failure markers and their ordering are unchanged.
- Same hook (#652): the output is descriptive status only. The closing line
  that told the session to re-check items, comment on or close issues, or
  bump `verified:` dates is replaced by one saying what the items are and
  where their verified date comes from. The warning lines now name the `gh`
  command that lists the issues, without telling anyone to run it. The rule
  for how a session acts on an item moves to the handoff skill through the
  operator lane.
- **`claude/scripts/migrate-operator-queue.sh`** (#654): the existing-title
  check now lists issues with any labels (still in every state), so an issue
  whose `operator-action` label was removed still blocks a duplicate create
  and reruns stay safe. The check covers up to 10000 issues and refuses at
  that limit rather than dedupe over a partial list. A same-title issue is
  skipped as already migrated only when it carries the `operator-action`
  label and its field lines, in body order, are exactly the block's (same
  lines, same count, same order; the hook reads a field's first occurrence,
  so an extra or earlier conflicting line would change what it shows). The
  label is checked in jq on the label array, not a comma-joined string, so
  a label named `team,operator-action` doesn't count. Any other same-title
  issue is reported as "needs manual merge: #N" and never edited or
  adopted: a removed label, missing or different fields, a hand-filed
  issue, or a repeated queue title with a different action. `--apply` then
  exits 1 without the retire-the-file message, so retiring the file can
  never hide an item from the hook or drop its deadline and dates.
- Tests: fixture cases for the bounded snapshot (an `rm` wrapper measures
  it), recovery cleanup of only pattern-matching files, TERM cleanup, exact
  prior migrations versus manual-merge matches (missing label, comma label,
  hand-filed, action-only, a conflicting earlier field, an extra trailing
  field, reordered fields, a different duplicate), and the status-only
  trailer. The `cp`-wrapper
  race case now wraps `head`, the snapshot's new reader.

## 2026-10-19 — fix(hooks): every printed mods-ok key clears its PluginDriftCheck warning

- `PluginDriftCheck.hook.ts` (#648): an id that `shown()` cannot print unchanged (unsafe characters, or over 300 characters) was marked "cannot be allowlisted", so the warning's `# mods-ok: ID` remediation could never clear it. Such an id is now printed sanitized alongside the key `sha256:HEX16` (the first 16 hex digits of the SHA-256 of the raw id's UTF-16LE code units), and that key is its only allowlist match; a verbatim id is still its own key. The hash reads UTF-16 code units, not UTF-8, because UTF-8 encoding maps every lone surrogate to U+FFFD and would give distinct ids one key. The token contains `:`, which no verbatim id can, so a raw id cannot spell out another id's token. Output stays sanitized and length-bounded. A project `.claude/skills` mod, which the allowlist never covers, is marked `(sanitized)` with no key.
- `plugin-drift.test.sh`: the key the warning prints for an unsafe id is captured from the output and proven to clear it; a sha256 token does not cover a verbatim id; two names differing only in a lone surrogate get distinct keys; the existing >100-character safe id stays printed whole and allowlistable.
- Allowlist syntax documented in the hook header, `CLAUDE-GUIDE.md` (Hooks table) and `claude/plugins.txt`.

## 2026-10-19 — fix: run-tests shows progress, and the fuzz suite no longer depends on TMPDIR

- **`claude/scripts/run-tests.sh`** (#650): without `--verbose` a full run
  used to print nothing for about 17 minutes, and agents killed it as hung.
  Each suite's `PASS`/`FAIL` row now prints as the suite finishes. A suite
  that is still running prints `… still running: NAME (Ns)` every
  `RUN_TESTS_HEARTBEAT` seconds (default 30). The final summary is unchanged.
  The heartbeat's `sleep` writes to `/dev/null`, so it cannot hold a caller's
  pipe open, and an EXIT trap stops the heartbeat if the runner dies.
- **`setup.sh --dry-run` mutated a `$HOME` outside `/tmp`** (#621, root
  cause): the dry-run printed `codex --version`. In Codex 0.163, every
  invocation creates `$CODEX_HOME/tmp/arg0-linux/` helper links. It skips
  that only when `CODEX_HOME` sits under the system temp dir, which is `/tmp`
  under the fuzz suite's `env -i`. So `setup-fuzz-layouts` passed with
  `TMPDIR` under `/tmp` and failed 25 of 26 layouts with "mutated $HOME" under
  `/var/tmp` or `~/.cache`. The "unsupported destination type" lines in that
  output are expected refusals for symlinked fixtures, not the failure. The
  dry-run now skips the codex version probe, as it already skipped
  `codex login status`. A new `setup-dry-run` case puts a recording `codex`
  stub on `PATH` and asserts the dry-run never calls it, whether or not the
  host has Codex installed.
- **Git discovery is confined per suite** (#621): `run-tests.sh` runs every
  suite with `GIT_CEILING_DIRECTORIES` extended by the resolved `/tmp`,
  `/var/tmp` and `$TMPDIR`, never the repo root itself. A temp root that has
  become a repository, such as the `/tmp/.git` mount point Codex's sandbox
  creates (#368), can no longer be discovered from a fixture. An empty
  `/tmp/.git` never confused `git` itself; it tripped `worktree-lifecycle`'s
  own ancestor walk, and #623 already moved those fixtures to a clean root.
- **`--changed` treats changelog fragments as test-free**: a changed
  `changelog.d/*.md` selects no suite and no longer widens the run to every
  suite, and a diff of only fragments runs none. No other Markdown is exempt.
- `run-tests.test.sh` gains cases for the progress order, the heartbeat, the
  interval validation, the ceiling, and fragment-only and fragment-plus-script
  diffs.

## 2026-10-19 — fix: setup.sh installs the CLI stack from one list, and a running tmux server picks up the managed config

- **`lib-checks.sh`**: each `CLI_STACK_TOOLS` entry now carries everything
  both consumers need, as `NAME:DEBIAN_BINARY:APT_PACKAGE:BREW_PACKAGE`
  (empty fields default to the name; a `?`-marked apt package is
  installed on its own line because older archives lack it, as with eza).
  `cli_stack_entry` parses one entry; `check_cli_stack` uses it (#636).
- **`setup.sh`**: the #204 install and shim block loops over
  `CLI_STACK_TOOLS` instead of hardcoding rg/fd/bat/eza and the fd/bat
  shims, so a tool added to the list is installed, shimmed and checked alike
  (#636).
- **`setup.sh`** and **`cct`** (`.bash_aliases`): when `tmux list-sessions`
  finds a running server, `tmux source-file ~/.tmux.conf` loads the managed
  config into it. Before, a server started earlier kept its old config until
  every session closed. `list-sessions`, not `tmux info`, because `info`
  fails when every session is detached. `setup.sh` invokes tmux only when the
  server socket already exists, since any tmux client creates its socket
  directory and `$TMUX_TMPDIR` may sit under `$HOME`. `--dry-run` prints the
  reload instead of running it (#643).
- **`claude/scripts/tests/setup-dry-run.test.sh`**: runs setup against a
  PATH that hides every name in `CLI_STACK_TOOLS` and asserts each entry is
  apt-installed, then plants only the Debian binaries and asserts each is
  shimmed, not reinstalled. A fake tmux covers the dry-run preview, the live
  reload, no tmux call at all without a server socket, a stale socket, and
  `cct`'s reload. A real tmux on a private socket dir covers a server whose
  only session is detached. The suite now sets
  `TMUX_TMPDIR` and unsets `TMUX`, so no run can reach a developer's real
  tmux server.

## 2026-10-19 — fix: legacy skill-dir migration never deletes, so a race can't lose a source file

- **`lib-symlinks.sh`** (issue #638): `symlink_migrate_legacy_skill_dir`
  drained the legacy per-file dir in place. If a concurrent `--heal` swapped
  `$dst` for the directory link between the `[ -L "$dst/x" ]` check and the
  `rm`, the `rm` resolved through the link and deleted the real tracked
  `$src/x`. Review rounds that patched the drain each found another
  delete-by-path race, because neither shell nor Node can unlink "only if
  still a symlink". So the migration no longer deletes anything.
- **Move aside, then link**: the whole legacy dir is renamed (`rename(2)`
  through `perl`, atomic) into
  `~/.claude/.migrated-skill-dirs/NAME.UTC-TIMESTAMP.PID`, and
  `check_link` then creates the directory link. A rename that would cross
  filesystems is refused, never copied. A run whose rename fails because a
  rival already moved the dir returns success and lets `check_link` judge.
- **Nothing is ever renamed back**, since `rename(2)` cannot refuse to
  overwrite. A rival's directory link grabbed by mistake stays in the
  archive. Content that changed mid-migration goes to the archive's `kept/`
  and is reported. `check-claude.sh` then warns `KEPT` on every run until
  the user removes it.
- **Archive hygiene**: `check-claude.sh` flags every archived entry that is
  not only old links as `KEPT`, wherever it landed. An archive root, `kept/`
  or archived dir the check cannot read and traverse is `KEPT` too: what it
  can't see inside isn't safe to delete. An entry is safe to delete
  by hand only if it is not flagged (`CLAUDE-GUIDE.md`). The orphan,
  broken-link and backup scans skip the archive by a quoted `case` prefix
  match, not `find -path`, which read glob characters in `$HOME` as a
  pattern. An archived dangling link is therefore never `ORPHAN`, and `--fix`
  never touches the archive. `check-deployed-orphans.sh` lists it
  as known state. A read-only legacy dir cannot move to another parent, so
  it is reported and left in place, still reachable. A dir the migrator
  cannot read or traverse is never judged legacy, since its content cannot
  be seen.
- **Callers see every outcome**: the migration returns `2` when it archived
  changed content, and `0` when a rival already moved or relinked `$dst`.
  `setup.sh --repair` counts only a `2` as broken, even after it relinks the
  bundle; a rival that finished the repair is no error. Everything under
  `kept/` is always `KEPT`. Top-level archive links count as old only when
  they point into that skill's own source. A link the rename grabs counts as
  a rival's repair only if it is exactly the bundle link (`readlink` equals
  the source, as `check_link` compares). Any other link is someone's own
  config, so it goes to `kept/` and is reported. When content is archived,
  setup's install path still links the skill and fails only after the whole
  tree is linked. When the hook's rename fails because a rival already
  installed exactly the bundle link, that counts as done (#694).
  A `$dst` that a rival moves away during the filesystem check is that
  rival's success, not a cross-filesystem error. This holds in the shell and
  the hook.
- **`claude/hooks/SymlinkRepair.hook.ts`**: the SessionStart mirror had the
  same in-place `unlinkSync`. It now does the same rename-aside, with the same
  `kept/` handling and every post-rename check inside its handler, and lets
  `ensureLink` judge a destination a rival already relinked.
- **Tests** (`heal-race`, `symlink-enumerate`, `deployed-orphans`): fake `rm`
  and `perl` on PATH play the races deterministically.
  - A rival finishing mid-migration costs no source file; the old loop lost
    `$src/f1`.
  - A regular file that appears at `$dst` survives, and so does one swapped
    into the moved dir, which lands under `kept/` and is warned about.
  - Further cases cover the archive name and links, the hook's archive, the
    read-only and unreadable cases, the `KEPT` audit, and the scans run
    with glob characters in `$HOME`.

## 2026-10-19 — fix: re-sourcing the managed tmux config no longer duplicates terminal entries

- **`.tmux.conf`**: `terminal-features` and `terminal-overrides` are set at a
  fixed array index (`set -s terminal-features[100] …`, the man page's
  `command-alias[100]` form) instead of appended with `set -as`. Since #643,
  `setup.sh` and `cct` re-source the config into a running server, and each
  append added another copy of the same entry (#673).
- **`claude/scripts/tests/setup-dry-run.test.sh`**: a real tmux on a private
  socket dir sources the repo's `.tmux.conf` three times, then asserts both
  array options hold their entry exactly once. Only the server the test
  started is killed, by its PID.

## 2026-10-19 — fix: worktree retirement branch cleanup and retained-archive exemptions (#640)

- **`claude/scripts/worktree-lifecycle.py`**: `--delete-branch` now encodes the
  branch name with `os.fsencode`, inside the error handler, so a non-UTF-8
  name no longer raises after the ref has already been deleted.
- Branch configuration is now removed by unsetting every listed
  `branch.NAME.*` key and then checking that none remain. A section Git
  stored as `[Branch "x"]`, which `--remove-section branch.x` refuses, no
  longer survives.
- Retirement now merges the second scan's process exemptions and writes them
  to `recovery.json` before the "worktree changed during archival" check. An
  archive kept because of that check still names every identity a scan
  skipped.
- New tests in `claude/scripts/tests/worktree-lifecycle.test.py` cover all
  three.

## 2026-10-17 — feat: operator-action queue can come from GitHub issues

- **`claude/hooks/OperatorQueueReminder.hook.sh`**: a second source, open
  issues labelled `operator-action` in the private `OPERATOR_QUEUE_REPO`
  (default `github.com/jckeen/claude-memory`; the host is always explicit).
  The phone and cloud sessions can read these; the local
  `~/.claude/operator-queue.md` cannot reach them. SessionStart only renders
  an owner-only cache under `~/.local/state/operator-queue/`. When the cache
  is missing or older than 10 minutes, the hook starts `--refresh` detached.
  That refresh pages the issues through one GraphQL query, using
  `comments(last: 1)` for the newest comment. It turns them into the same
  `## <slug>` blocks and replaces the cache atomically. Refreshes run under
  `flock(1)`, which the kernel grants atomically and drops when the holder
  dies. A refresh that finds the lock held waits up to five seconds, then
  gives up without fetching, so refreshes never overlap and the last write is
  always the newest fetch. A refresh marks itself in flight before fetching;
  while that marker exists the header says "a refresh is running or was
  interrupted" rather than presenting the cache as current. The hook does
  not try to tell a running refresh from a killed one, so it takes no lock:
  it reads the in-flight marker before the failure marker, and a refresh
  writes the failure before clearing the in-flight marker, so a refresh
  settling between the reads is never missed. A refresh that finds a killed
  predecessor's marker records that failure before fetching. The hook takes
  one snapshot of the cache, reads the markers after it, and renders only
  from it: a replacement mid-render cannot split the check from the output,
  and a refresh that replaced the cache and died is still seen in flight. A
  snapshot that cannot be taken prints a warning line instead of nothing. A
  refresh removes its in-flight marker only after its outcome is recorded.
  A refresh fetches only if, once it holds the lock, the cache is missing or
  older than 10 minutes (a queued refresh finds its predecessor's fresh
  cache and stops), so whenever a fetch is under way every session already
  names the cache as old.
  Accepted limit: the output is the state as of the hook's reads; a refresh
  that starts after them shows in the next session. Without `flock`
  (stock macOS) a refresh fails and the header says so. The cache name is the
  SHA-256 of the lowercased host/owner/repo: fixed-length, so any repo name
  fits the filesystem's name limit, and case variants of one repo share it.
  With no `sha256sum` or `shasum` the hook refuses with one warning line
  instead of falling back to a name every repo would share.
  The cache and the failure marker are judged by presence, never by an age
  that a concurrent refresh could make negative. `gh` and `jq` inherit the
  lock, so a refresh shell killed mid-fetch cannot free it while its `gh`
  still runs; where `timeout` exists the fetch is capped at two minutes. The Codex gate found two earlier hand-rolled locks
  racy (pid file, then mtime guard), which is why `flock` replaced them. A slow or stalled
  `gh`/`jq` therefore costs SessionStart nothing. The Codex gate found the
  in-hook fetch's timeout unsound three ways, which is why the fetch moved out
  of the hook. `added` comes from the body's `- added:` line, falling back to
  the creation date. `verified` is the newer of the body's calendar-valid
  `- verified:` date and the newest comment, so migrated items keep their
  real age and a re-verify comment, not a label edit, refreshes an item. The
  body's full `- project:` value wins over the `project:` label, so a
  multi-project item matches each of its repos. Nothing reads as "no open
  items" unless a refresh within 10 minutes said so. The header names an old
  cache, or one older than a failed refresh. With no cache, one line says a
  refresh is running or that the last one failed. A queue file that exists,
  even empty, stays the source until a line in its first five *starts* with
  the historical banner, so nothing goes dark mid-migration.
- **`claude/scripts/migrate-operator-queue.sh`** (new): dry-run by default,
  one row per block with its `project:<name>` label and target. `--apply`
  creates the missing labels and one issue per block, with the block's field
  lines verbatim in the body; titles that already have an issue are skipped,
  so a re-run is safe. It refuses any repo GitHub does not report as PRIVATE,
  and refuses when the existing-title list is too long to be complete. Titles
  match exactly as strings (no awk escape processing or numeric comparison),
  and a title repeated within one queue is created once. The repo defaults to
  the hook's `OPERATOR_QUEUE_REPO`. `--apply` holds a `flock` keyed on GitHub's own lowercased name for the
  repo (so a case variant or a renamed repo's old name shares it) from the
  existing-title check to the last create, so two applies on one machine never
  duplicate a title.
  On 2026-10-17 a dry run against the live queue listed 83 of 83 blocks as
  new, all bound for the private repo. The handoff skills still write to the
  file; their switch to issues is a separate, operator-reviewed
  instruction-surface change.
- Tests: `operator-queue-reminder.test.sh` now runs with a fake `gh` first on
  PATH, because an empty-queue case had been reaching the real GitHub. It adds
  cases for the issue source: online, fresh cache, stale cache plus offline,
  no cache plus offline, historical versus live file, and no open issues. The
  new `migrate-operator-queue.test.sh` is wired into the CI checkers shard.

## 2026-10-16 — fix: sync-plugins honours service selection and reconciles removals

- **`claude/scripts/sync-plugins.sh`** (Codex review on #577 and #574): reads
  the saved agent-service selection the way setup.sh does. It syncs nothing
  when Claude Code is deselected and skips `*@openai-codex` plugins when Codex
  is, so the every-launch sync in `cc` no longer reinstalls an opted-out Codex
  plugin. A damaged selection file is refused rather than read as "all". A new
  `# removed: <plugin>@<marketplace>` manifest line uninstalls that plugin's
  user-scope install; a plugin merely absent from the manifest is never
  touched. `claude/plugins.txt` marks `superpowers@claude-plugins-official`
  removed, so machines that still carry it drop it on the next fresh launch.
  When `installed_plugins.json` can't be read (python3 missing, not a regular file or malformed
  JSON), the script warns, and each pending removal fails with a named
  diagnostic and exit 1. A pending removal is never skipped silently.
- **`claude/hooks/PluginDriftCheck.hook.ts`:** applies the same filter. A
  deselected service's plugin is no longer reported as missing or un-enabled.
  The rule lives once in `lib-services.sh` (`services_effective`,
  `services_filter_plugins`), and both the hook and `sync-plugins.sh` call
  it. An unreadable selection reports every plugin, plus a note saying the
  selection could not be read.
- **Tests:** new cases in `plugin-drift.test.sh` (13 failed before the fix,
  all pass after).

## 2026-10-16 — fix: PluginDriftCheck mod scan covers in-place and project plugins

- **`claude/hooks/PluginDriftCheck.hook.ts`** (Codex threads on #599 and
  #646): the mod scan now also reads every relative-path entry of a
  marketplace added from a local `directory` or `file` source (Claude Code
  loads these in place, never from `cache/`; a `file` catalog is read from
  its recorded path), and `<name>@skills-dir` plugins under the project's
  `.claude/skills`, where the project is the hook input's `cwd` (it follows a
  `--worktree`) plus `$CLAUDE_PROJECT_DIR`. Entries are scanned enabled or
  not: enablement can come from `--settings`, managed settings or
  `--add-dir`, which the hook cannot see, so a filter would fail open.
- **Allowlist:** a project mod is named even when allowlisted, since it
  shares the `@skills-dir` id space with `~/.claude/skills` and a cloned repo
  could reuse an allowlisted name. A safe id prints whole (up to 300
  characters) so a long one stays allowlistable; a sanitized one says it
  cannot be.
- **Output hardening:** every id and path printed passes through `shown()`
  (only `[A-Za-z0-9._@/-]`, capped when changed), so a name from a
  marketplace or a cloned repo cannot inject lines or close the
  `<system-reminder>`.
- **Unverifiable, not skipped:** a `hooks.json`, `plugin.json` or
  `marketplace.json` of any origin that exists but cannot be read or parsed
  is named under "Plugin mods (unverifiable)"; only a missing file is
  skipped. All plugin JSON goes through one reader that accepts a regular
  file of at most 1 MiB, so a FIFO cannot hang the hook and `/dev/zero`
  cannot exhaust memory. Each catalog entry and plugin dir is checked in its
  own try/catch, each warning section is guarded, and no untrusted value is
  stringified before a `typeof` check (a `{"toString":null}` name used to
  exit the hook with no output). Best-effort and advisory: a parser
  differential with Claude Code's loader stays possible (#647).
- **Tests:** `plugin-drift.test.sh` runs every case with a throwaway HOME and
  project dir and explicit stdin, with fixtures for both origins, an
  allowlist-shadowing project plugin, injection names, a hostile catalog,
  malformed, FIFO, `/dev/zero` and oversized files, long ids and a
  `--worktree` cwd (40 of 105 failed on origin/main, all pass after; an
  intermediate version hung on the FIFO until the test's timeout).

## 2026-10-16 — test: heal-race rivals no longer hold the capture pipe

- **`claude/scripts/tests/heal-race.test.sh`** (#635 review): the in-flight
  fixture's background rival inherited the checker's captured stdout, so the
  capture waited for it and "checker finished only after the rival" passed
  even when the checker exited early. Rivals now redirect away from the
  capture, and the test waits for one with a bounded `wait_rival` instead of
  a bare `wait`, which never covered the checker's children. Against a
  checker that exits before the migration completes, that assertion passed
  before and fails after.

## 2026-10-16 — fix: check-claude warns on a missing CLI stack and waits out a racing migration

- **`check-claude.sh` / `lib-checks.sh`** (closes #605): the CLI tools the
  Claude config tells sessions to prefer now live in one list,
  `CLI_STACK_TOOLS` in `lib-checks.sh`, and `check_cli_stack` prints a `TOOL`
  warning for each one missing (or present only under its Debian name, with
  the `setup.sh` shim hint). Advisory: it does not fail the check, because
  `cc` blocks launch on a failed checker.
- **`check-claude.sh --heal`** (PR #604 review, #635 review): a real
  directory where a skill bundle link belongs now goes through one bounded
  settle loop (a few seconds) before it is reported: converted while it is
  legacy, waited on while a concurrent `--heal` is still draining it (even
  when the first scan raced that drain and saw it as foreign), and reported
  promptly once a non-legacy listing holds still. Previously a concurrent
  conversion produced a false `FAILED` or `NOT LINKED`. Two concurrent
  checkers on a 500-entry legacy bundle: 10/10 trials had a failing checker
  before, 0/10 after, with the source bundle intact in every trial.
- **Tests:** `heal-race.test.sh` covers the in-flight migration, an entry
  vanishing mid-scan, stable foreign content, and the tool advisory under a
  controlled PATH (9 failed against the origin/main checker, all pass after).

## 2026-10-16 — fix: run-tests.sh leaves no bytecode caches behind

- **`claude/scripts/run-tests.sh`** (refs #581): now exports
  `PYTHONDONTWRITEBYTECODE=1`. Any suite that imported a skill's script wrote
  `__pycache__` under `agents/skills/`, which is an instruction surface. The
  review gate that had just run the suites then refused its own receipt
  ("dirty instruction surface outside committed target"). That cost three
  agent gate runs on 2026-10-16. `run-tests.test.sh` has a new case covering it.
  The receipt-side fix (ignore a gitignored `*.pyc`-only cache, as #514 did for
  `node_modules`) is gate machinery and stays on #581.

## 2026-10-16 — fix: setup.sh service-selection edge cases (Codex review on #577)

- **`setup.sh`:** picks the action once (the first of `--help`, `--check`,
  `--repair`, `--show-services`), so `--repair --show-services` from a linked
  worktree no longer slips past the worktree guard; `--help` runs before the
  saved service selection is loaded, so it works when that file is damaged;
  and the WSL audio routing for Claude `/voice` is skipped when Claude is
  not a selected service.
- **`lib-services.sh`:** `services_save` refuses a directory at the selection
  path instead of moving the temp file into it and reporting success.
- **Tests:** new cases in `setup-services.test.sh` and
  `setup-worktree-guard.test.sh` (4 failed before the fix, all pass after;
  the audio case runs only on WSL).

## 2026-10-16 — fix: worktree expiry rechecks recovery files and reports accurately

- **`claude/scripts/worktree-lifecycle.py expire`** (Codex threads on #570
  and #576): `--apply` rechecks `recovery.json` and the bundle and metadata
  tar hashes on the staged checkout, then confirms after the final inspection
  that none of them changed since, so the slow hash never sits between that
  inspection and `git worktree remove`; any failure in the staged inspection is
  retained and rolled back instead of escaping;
  a failed rollback names where the checkout actually is; the metadata tar is
  streamed instead of loaded whole, and its hard-link members are compared by
  content, so a quarantine with hard-linked metadata can expire; an entry
  expired in this run no longer counts toward `retired`/`oldest_days`; and an
  entry with both `worktree` and `worktree-expiring` registered is retained as
  ambiguous, naming both, instead of reported as one interrupted expiry.
- **`hygiene-status.sh`:** reads `retired-worktrees.json` even when
  `status.json` is absent (`--status` prints `no-data` and then the line; the
  quiet modes still report an expirable entry).
- **Tests:** new and extended cases in `worktree-lifecycle.test.py`, each
  failing before the fix and passing after.

## 2026-10-16 — fix: harden the ccw profile linker

- **`claude/scripts/link-claude-profile.sh`** (refs #591): refuses a profile
  directory that contains `~/.claude` (such as `$HOME`), not only the default
  directory and its descendants; refuses a symlinked or non-file
  `.claude.json` instead of reading through it or replacing it; `--check`
  reports a missing or broken shared state directory (`projects`, `plugins`,
  `file-history`) instead of accepting a dangling link to it; and a link a
  concurrent `ccw` launch made first is accepted rather than reported as drift.
- **Tests:** one case per finding in `tests/claude-profile.test.sh`
  (8 failed before the fix, all pass after).

## 2026-10-16 — fix(hooks): SymlinkRepair creates ~/.claude before top-level links

- **`claude/hooks/SymlinkRepair.hook.ts`** (follow-up to #598, Codex review
  on #625): when `~/.claude` itself was absent, the top-level pass ran before
  any category dir created it, so every top-level link (`CLAUDE.md`,
  `statusline.sh`, ...) failed and stayed missing until the next SessionStart.
  The hook now creates the config root before that pass.
- **Tests:** `symlink-enumerate.test.sh` covers a HOME with no `~/.claude`
  and a non-empty `nolink.txt` (failed before the fix, passes after).

## 2026-10-16 — fix: small fixes from unresolved Codex review threads

- **`claude/scripts/resolve-changelog.py`:** a CHANGELOG that git still
  reports unmerged but whose markers are gone (`git checkout --ours`, an
  editor) is now resolved from the index stages instead of reported as
  "nothing to do", which let a following `git add` drop the other side's
  entries.
- **`claude/hooks/OperatorQueueReminder.hook.sh`:** `OPERATOR_QUEUE_SHOW_ALL=1`
  now prints every item; it was still cut at the item cap.
- **`claude/scripts/harvest-codex-comments.sh`:** a filed comment on an
  instruction surface is classified before the outdated/resolved skips, so a
  failed `instruction-surface` label is repaired after the comment goes
  obsolete. An obsolete comment that was never filed still labels nothing.
- **`ROADMAP.md`:** the 2026-06 enforcement-hardening details link points at
  the Q2 changelog archive. **`antigravity/permissions.json`:** the symlinked
  `read_file` note is descriptive, not an imperative (#608).
- **Tests:** each code fix has a case that failed before it.

## 2026-10-16 — test: fleet-codex-review's unreadable-file case works under root

- **`claude/scripts/tests/fleet-codex-review.test.sh`:** the unreadable
  canonical workflow was simulated with `chmod 000`, which root ignores, so
  the case would fail in a root-run container. A directory now stands in for
  the file, and reading it fails for every user. Raised by the GitHub Codex
  bot on #622.

## 2026-10-16 — test: worktree-lifecycle fixtures survive Codex's /tmp/.git

- **`claude/scripts/tests/worktree-lifecycle.test.py`:** Codex's Linux
  sandbox mounts a tmpfs at `/tmp/.git` (`bwrap --tmpfs /tmp/.git`). That
  leaves an empty `/tmp/.git` on the host after every sandboxed command, so
  this suite's guard refused to start whenever any Codex run had been active.
  That failed `run-tests` in every agent's review gate on 2026-10-16. The
  marker can appear mid-run, while another session's sandboxed commands are
  active, so the module now roots its fixtures outside `/tmp`: the first
  temp base with no Git marker above it, trying `/var/tmp`,
  `$XDG_RUNTIME_DIR`, `~/.cache` and only then the system one. Candidates
  are resolved before the check, because retirement resolves symlinks.
  Any candidate longer than 24 characters is skipped, because the suite's
  socket fixtures break once the root reaches about 53 characters.
  Only this test process's `tempfile` default changes, so `TMPDIR` is left
  alone for suites that need it under `/tmp` (#621). The guard still fails
  with a clear message when none of them is clean. Verified: with an empty
  `/tmp/.git` present, 120 tests pass and nothing is left in `/var/tmp`.

## 2026-10-15 — Automatic Codex Remote Control startup

- Added an opt-in systemd user service that supervises the foreground server,
  restarts it after a crash, and preserves the connection-only `cx` launcher.
  Its launcher checks the saved opt-in, uses the standalone CLI, and loads user
  tools including the current NVM default.
- Shared strict opt-in parsing between the service and `cx`, rejecting multiple
  JSON documents, duplicate keys, and nonstandard numeric constants.
- Added a Windows login-task installer that keeps the selected WSL distribution
  running for phone access with terminals closed, without a console window or
  changes to sleep policy.
- Verified repeated service starts preserve a connected client, competing native
  starts refuse the live socket, and a disposable server recovers after a crash.

## 2026-10-16 — feat: a codex-findings queue, and codex-threads.sh to work it

- **`.github/workflows/codex-findings.yml`:** labels a PR `codex-findings`
  while the GitHub Codex bot has an unresolved review thread on it, and
  removes the label once none remain. It recounts on each bot review and on
  `workflow_dispatch`. `gh pr list --label codex-findings` is then the queue
  of PRs blocked on bot findings, so no agent has to poll each PR (#617). A
  failed or truncated read leaves the label as it was. Fork PRs are skipped.
- **`fleet-codex-review.sh`:** rolls out both workflows, shipping only the
  files that are missing or out of date. It still creates the ruleset only
  once both are current. A failed read of a workflow file or of the
  rulesets now skips the repo and fails the run. Before, it counted as
  "missing" or "no ruleset", so a temporary GitHub error could ship a file
  the repo already had or create a duplicate ruleset.
- **`claude/scripts/codex-threads.sh`:** `list --pr N` (or
  `--merged-since DATE`) prints one TSV line per unresolved thread the GitHub
  Codex bot opened: thread id, location, priority, outdated flag, title and
  link. `resolve --thread ID --reply TEXT` posts the reply and then resolves
  the thread. It refuses an empty reply and refuses a thread anyone other
  than the bot opened. Once the `codex-review` ruleset requires resolved
  threads (#615), this is how an agent answers each finding before merge,
  either "fixed in" or "moot because". Resolving a PR's last bot thread also
  starts `codex-findings.yml`, because GitHub has no workflow trigger for a
  resolved thread. The reply and the resolve are separate requests, so a
  rejected reply never leaves a thread closed without a reason. A thread
  from another repository is refused. A failed or truncated read, including
  a merged-PR list that reaches its limit, exits 1 rather than printing a
  partial list. A failed recount after a resolve exits 1 and names the
  command that finishes the job.
- **Why:** a 2026-10-16 triage found 35 unresolved bot threads on merged
  PRs #564–#604, because auto-merge lands before the bot comments (#617).
- **Tests:** `codex-threads.test.sh` and `codex-findings-label.test.sh`
  (both run against a fake `gh`, and the second extracts the workflow's
  script), wired into the CI `checkers` shard. `fleet-codex-review.test.sh`
  gains cases for partial rollouts.

## 2026-10-16 — fix(hooks): SymlinkRepair no longer crashes on a missing category dir

- **`claude/hooks/SymlinkRepair.hook.ts`** (#598): on a fresh machine or a new
  `CLAUDE_CONFIG_DIR` profile where the hook ran before `setup.sh`, a missing
  `~/.claude/scripts` (or `hooks/`, `agents/`, `chrome/`) made the first
  `symlinkSync` throw `ENOENT`, exiting the hook 1 and skipping every later
  category. The hook now creates each category dir first, and a link or dir it
  cannot create is reported as skipped rather than thrown, so it exits 0 as its
  header promises. The scripts category also links `*.py` (receipt helpers),
  matching `lib-symlinks.sh`.
- **Tests:** `symlink-enumerate.test.sh`'s hook cases no longer pre-create
  `~/.claude/scripts`; new cases cover a missing category dir, `*.py` linking,
  and a read-only category dir (7 failed before the fix, all pass after).

## 2026-10-16 — fix(ci): codex-review clock read died of SIGPIPE

- **`.github/workflows/codex-review.yml`:** the first live run (the close of
  #614) failed with "could not read GitHub's clock". The `Date`-header awk
  exited at its first match, closing the pipe while `gh api -i` was still
  writing the body; `gh` died of SIGPIPE and `pipefail` reported a failed read.
  Measured locally: 3 of 5 early-exit reads returned 141, and 0 of 5 for a
  reader that drains its input. It failed closed (pending, failed run), but it
  would have failed about half of every evaluation. The awk now reads to the
  end. A sweep of the script and of `fleet-codex-review.sh` found no other
  reader that exits early on a pipe.
- **Tests:** the fake `gh` now sends a 256 KiB body after the headers, so an
  early-exiting reader fails deterministically (69 of 85 cases failed before
  the fix, 85 of 85 pass after).

## 2026-10-14 — ci: hold merges until the Codex bot review finishes, fleet-wide

- **`.github/workflows/codex-review.yml`:** posts a `codex-review` commit status
  on each PR head: pending while the GitHub Codex bot reviews, success once its
  summary table shows a completed review of the head (each review type passes
  on any completed run, so a successful retry supersedes a failed attempt).
  **One PR per head commit (design verdict):** statuses are stored per commit
  but the review question is per PR, and five Codex gate rounds of per-case
  patches kept reopening that seam, so a PR decides its status only while it is
  the sole open, non-draft, same-repository PR with that head (a fork PR
  there posts nothing, so a contributor cannot hold a PR); siblings hold.
  **One writer per repository:** every run evaluates every open PR from live
  state under a single repo-wide concurrency group that never cancels, so no
  stale verdict lands after a newer one and no one (a fork contributor
  included) can starve the writer by triggering events; a PR waiting for the
  bot to pick it up gets one wait to the end of its window instead of a poll
  per PR. Only changes are written (GitHub caps statuses at 1000 per commit and context).
  Drafts post nothing; a failed evaluation ends that PR's run and revokes its
  head to pending (never a fork PR's head), since a failed job does not clear
  an earlier success; the PR-list read is retried three times, and if it still
  fails the triggering PR's head is revoked. Every same-repository PR event
  first invalidates its head (pending) from a read-free job, and the writer
  runs after it, so a lost or failed evaluation leaves a head pending, never
  at an older success; the writer's posts are compare-and-set on GitHub's
  clock (a pass never overwrites a status written after it began reading, and
  re-reads after a success, reverting to pending if anything newer arrived
  or the re-read still fails after three attempts, which also fails the run),
  so an older pass cannot leave a stale success over a newer invalidation.
  GitHub has no conditional status write, so a success can stand for the
  second or two before that revert; no commit-status design can close it.
  Same-repository PRs are settled (both passes) before any fork is evaluated.
  A `workflow_dispatch` run evaluates every open PR; the rollout script starts
  one when it activates the ruleset, since PRs opened before then have no
  status and may see no further event. A head the bot has not reviewed gets one `@codex review` request and
  holds; after a base retarget the request waits until no review is running,
  and only a run completing after it counts. Docs-only diffs (no instruction
  surface or dot-directory, names mirroring `review-receipt.py`) and
  all-Dependabot-commit PRs pass at once; fork PRs hold for a `codex-skip`
  applied by an admin or maintainer; it fails open only when the bot never
  posts a summary (3 min), which is how a repo without the bot looks.
  **Threat model:** it stops a PR, usually agent-opened, from auto-merging
  before the bot reviewed its head; it is not a boundary against a repository
  writer, which no commit status can be. Write access across the fleet at
  rollout: the owner everywhere, plus one outside writer on each of
  allora-engine, clarity-engine and creator-studios. Event-driven
  (`pull_request_target` plus the bot's summary-comment edits), so it does not
  poll for the review. Measured on the 12 PRs merged before this: auto-merge
  fired about 5 minutes after opening, the bot's verdict arrived after 2–10
  minutes, and #599 and #604 merged before their findings landed.
- **`claude/scripts/fleet-codex-review.sh`:** copies that workflow into each
  fleet repo through a PR, then creates a dedicated `codex-review` ruleset
  requiring the status (pinned to the GitHub Actions app, so a hand-posted
  status cannot satisfy it) and resolved review threads. Thread resolution is what
  makes the hold mean something: without it the status turns green at the
  moment the findings appear.
- **Tests:** `codex-review-status.test.sh` (85 cases; the status script run
  from the workflow file against a fake `gh`) and `fleet-codex-review.test.sh`
  (10 cases; never a ruleset before the workflow is current, never a forced
  branch reset, a failed write opens no PR), both in the `checkers` shard.
- **Docs:** `docs/BRANCH_PROTECTION.md` (the layered ruleset),
  `claude/scripts/README.md`.

## 2026-10-14 — fix(agy): remove retired `unsandboxed(...)` permission rules and migrate machine-local grants

- **`antigravity/permissions.json`:** removed all retired `unsandboxed(...)`
  rules from `permissions` (`allow`, `ask`, `deny`) and `retired` (Antigravity
  CLI retired `unsandboxed(...)` in favor of unified `command(...)` rules and
  prints a startup warning ignoring them), while keeping the public baseline
  `allow`, `ask`, and `deny` sets conservative (`git push` out of baseline
  `allow`, `command(gh pr merge|create)`, `command(gh issue create)`, and
  `command(git worktree remove)` in `ask`).
- **`claude/scripts/agy-apply-permissions.py`:** rejected `unsandboxed(...)` in
  `RULE_RE`, added `UNSANDBOXED_RE` migration in `apply` to convert legacy
  `unsandboxed(...)` entries across `allow`, `ask`, and `deny` to `command(...)`
  (dropping wildcard `unsandboxed(*)` only in `allow` while migrating wildcard
  and specific restrictions in `ask` and `deny`, and retiring any migrated
  rule listed in `retired`), and taught `check` to fail when invalid
  `unsandboxed(...)` rules remain.
- **Tests:** expanded `claude/scripts/tests/agy-permissions.test.sh` (27 cases)
  to assert zero `unsandboxed(...)` entries in the baseline, legacy
  `unsandboxed(...)` migration across all buckets, `allow` wildcard filtering,
  and operator `ask`/`deny` restriction preservation.

## 2026-10-13 — fix(agy): retire symlinked `$HOME` read rules and make `check-antigravity.sh` sandbox-aware

- **`antigravity/permissions.json` & `claude/scripts/agy-apply-permissions.py`:**
  retired `read_file(~/.bash_aliases)` and `read_file(~/.gitconfig)` (whose
  `$HOME` symlinks resolve into `~/dev/dotfiles/` and get bind-mounted `ro` by
  `bwrap` on top of the `rw` `~/dev/` mount) via `retired` (`allow`-only,
  preserving any operator-added `ask` or `deny` restrictions). Added common
  sandboxed dev/test commands, `read_url(https://antigravity.google/)`,
  `unsandboxed(git push --force-with-lease)` in `ask`, and
  `unsandboxed(git push --force|-f)` in `deny`, plus `~` expansion on
  `command(~...)` and `unsandboxed(~...)` rules.
- **`check-antigravity.sh`:** detects when `~/.gemini/config` and
  `~/.gemini/antigravity-cli` are masked by Antigravity's `/setup/deny*`
  `tmpfs` mounts in `/proc/self/mountinfo` (`AGY_MOUNTINFO_FILE`, encoding
  target paths for `\134` and `\040` mountinfo escapes and passing via
  `ENVIRON["MP"]`), verifies the bind-mounted regular file `GEMINI.md` via
  `cmp -s`, reports `SANDBOX` for sandbox-masked host files instead of 6 false
  `MISSING`/`NOT LINKED`/`DRIFT` warnings, and continues checking `skills/*`
  and orphan symlinks.
- **Tests:** expanded `agy-permissions.test.sh` (24 cases) and
  `antigravity-config.test.sh` (11 cases, including `\134`- and `\040`-escaped
  simulated sandbox `mountinfo` match and drift checks).

## 2026-10-05 — fix: concurrent `check-claude.sh --heal` runs no longer nest a self-link in skill bundles (#603)

- **Every `src -> dst` link site uses `ln -sn`** (`lib-checks.sh` heal,
  `setup.sh` ×5, `link-claude-profile.sh`). Two panes launching `cc` within
  the same second both saw the post-#601 skill links as `MISSING`; the loser's
  plain `ln -s` followed the directory link the winner had just made and
  dropped `claude/skills/<name>/<name> -> claude/skills/<name>` inside seven
  source bundles. `-n` (GNU and BSD) never dereferences an existing directory
  link, so the loser's `ln` fails and the post-heal assertion still holds.
- **`check-claude.sh --heal` tolerates a conversion the other run finished
  first**: a failed `symlink_migrate_legacy_skill_dir` is `FAILED` only while
  the destination is still a legacy per-file directory; otherwise it falls
  through to `check_link`. This was the "Agent health check failed" the
  losing launcher printed.
- **New `SELFLINK` check** over `claude/skills/*/`: a link nested inside its
  own bundle is reported, and `--fix` removes it (it carries no data). The
  previous checker passed "All good" with seven of them present. A failed
  `rm` under `--fix` (self-link, orphan, stale backup) now reports `FAILED`
  and exits 1 instead of printing `CLEANED` under `set +e` (Codex gate
  finding on this PR).
- `heal-race.test.sh` (26 cases, wired into the `checkers` shard): fresh
  heal, SELFLINK report/fix and a foreign link that is not one, the heal path
  driven into an already-linked destination, and the lost and stuck migration
  races.

## 2026-10-02 — fix(hooks): PluginDriftCheck names installed mods (#594)

- **`PluginDriftCheck.hook.ts` now names every installed plugin that ships a
  mod** — a `"modules"` key in its `hooks/hooks.json`, which Claude Code
  2.1.287 runs as in-session JS/TS. A mod's `tool.check` hook answers after
  the permission rules and `PreToolUse` hooks and can replace their decision,
  so it sits above every guard this repo ships as a settings hook. The scan
  covers every cached version under `~/.claude/plugins/cache/`, claude.ai
  synced plugins under `~/.claude/plugins/synced/`, and skills-directory
  plugins under `~/.claude/skills/`; an unreadable or malformed `hooks.json`
  is skipped. The warning now also fires when the manifest is empty. No
  installed plugin had a `"modules"` key on 2026-10-02, so the live session
  stays silent.
- **Allowlist: a whole-line `# mods-ok: <id>` comment in `claude/plugins.txt`**
  (`<plugin>@<marketplace>`, `<name>@synced` or `<name>@skills-dir`). A
  comment, not a section or trailing marker, because `setup.sh`,
  `sync-plugins.sh` and `check-install-integrity.sh` treat any other line as a
  plugin to install. Documented in the manifest header.
- `CLAUDE-GUIDE.md` (Hooks) carries the review rule: `claude plugin validate
  <dir>` before installing or updating a mod, with `tool.check`,
  `prompt.submit`, a `tool.call` hook that answers without `next`, and
  `$.process.*` / `$.http.fetch` / `$.env.*` calls each needing a deliberate
  yes.
- `plugin-drift.test.sh` gains fixtures for a cached, a synced and a
  skills-dir mod, an allowlisted mod, a plugin without the key, a malformed
  `hooks.json`, and a `# mods-ok:` line under `sync-plugins.sh`.

## 2026-10-02 — fix(hooks): stale-push and pre-merge harvest warnings reach the transcript (#593)

- **`PrePushStaleSHACheck.hook.ts` and `PreMergeCodexHarvest.hook.sh` now
  report through stdout JSON.** Both are PreToolUse hooks that exit 0 and
  wrote their warning to stderr, which the hooks reference sends to the debug
  log only, so neither the user nor Claude ever saw the stale-review warning
  or the harvest output. Each now prints one object,
  `{"systemMessage": …, "hookSpecificOutput": {"hookEventName": "PreToolUse",
  "additionalContext": …}}`: `systemMessage` shows the warning to the user and
  `additionalContext` puts it next to the tool result for Claude. Nothing to
  report still means empty stdout; both still always exit 0 and fail open.
  The harvest hook captures the harvester's stdout and stderr into the message.
- **Tests.** New `claude/scripts/tests/pre-push-stale-sha.test.sh` drives the
  bun hook with stub `git`/`gh` and asserts the JSON shape on a stale review
  and empty stdout on every no-warning path (wired into the `checkers` shard);
  the `PreMergeHookTests` in `harvest-codex-comments.test.py` now assert the
  same shape and the silent case.

## 2026-10-02 — fix: link each Claude skill as one directory symlink (#592)

- **A skill's supporting files now deploy.** `symlink_enumerate()` and
  `SymlinkRepair.hook.ts` linked only the top-level regular files of each
  `claude/skills/<name>/`, so `references/`, `scripts/`, `assets/` and
  `.claude-plugin/` never reached `~/.claude/skills/<name>/`. Each skill is
  now one directory link, `~/.claude/skills/<name>` → `claude/skills/<name>`,
  the shape the Codex `~/.agents/skills` and Antigravity skill links already
  use. Recursing per file was the rejected alternative: it still breaks a mod
  shipped as a skill directory, because Claude Code refuses a plugin module
  whose symlink resolves outside the plugin directory.
- **Existing installs convert in place.** A real `~/.claude/skills/<name>/`
  holding only our own per-file links (live or dangling) is removed and
  replaced by the directory link: by `setup.sh`, `setup.sh --repair`,
  `check-claude.sh --heal` (so `cc` launch), and the SessionStart hook. Backing
  it up instead would leave `<name>.backup/` with a resolvable `SKILL.md`,
  which would load as a duplicate skill. Without a repair flag the checkers
  report it as `LEGACY`.
- **A skill directory with any other content is never deleted.** `setup.sh`
  backs it up to `<name>.backup` before linking; the hook leaves it and
  reports it. `check-claude.sh` reports a backed-up directory as `STALE`, and
  `--fix` no longer tries to delete it (it removed only regular files before).
- `symlink-enumerate.test.sh` covers the one-record-per-bundle shape, the
  legacy-layout predicate, and the hook producing the same links.
  `retired-skill-links.test.py` now accepts a restored `fable-mode` source
  reached through the bundle link, since `--heal` converts its per-file dir.
  The hook crashing when a category dir is missing is #598.

## 2026-10-02 — feat(agents): six subject-matter-expert agents; model and effort pins

- **Six `sme-*` subagents: `sme-context`, `sme-evals`, `sme-models`,
  `sme-mods`, `sme-skills`, `sme-workflows`.** Each is a body distilled from
  Anthropic's developer blog (claude.dev) and the Claude Code docs, verified
  against Claude Code 2.1.287 on 2026-10-02, for delegating a question about
  tooling newer than the model's training: context and prompt caching, evals,
  model and effort choice, mods, skills, and dynamic workflows. Each re-checks
  a version gate, limit, default or price against the live docs before quoting
  it, and is read-only. `claude/AgentPack.md` lists them in a new roster
  section; the agent count is now 24.
- **Model and effort frontmatter, because a subagent that names no model
  inherits the session's price.** `repo-scout` is pinned to `haiku` and
  `package-scout` to `sonnet` (lookups); the SME agents to `opus` with
  `omitClaudeMd: true` (they answer from their own body and the delegation
  prompt; the key needs v2.1.271+). `security-reviewer`, `schema-reviewer` and
  `qa-lead` set `effort: high`, which overrides the session level both ways
  (raises medium, lowers xhigh or max; there is no floor key). Every other
  agent still inherits.
- **`security-reviewer` hands the pattern scan to soundcheck only where the
  project enables it** (`soundcheck@soundcheck` in the project's
  `enabledPlugins`); otherwise it runs a quick pattern pass itself before the
  in-context checks.
- **`perf-accessibility` measures first**: a number before reasoning from code,
  deterministic counts over wall-clock, proof that a proxy moves wall-clock,
  a CI ratchet for proven wins, and performance findings labeled static-only
  when the app can't be run.
- Follow-ups: #592 (skill subfolders never sync), #593 (two hooks' warnings go
  to the debug log), #594 (flag plugins that ship a mod), #595 (no behavioral
  evals).

## 2026-10-01 — feat: `ccw` runs Claude on a second account

- **`ccw` launches `cc` on a second (work) Claude account.** It sets
  `CLAUDE_CONFIG_DIR` to `~/.claude-work` (`CLAUDE_WORK_CONFIG_DIR` overrides),
  so that login and its subscription usage are separate from the default
  account's. It takes `cc`'s arguments and refuses to launch on a profile that
  is not fully wired.
- **`link-claude-profile.sh` shares the setup between the two.** Settings,
  instructions, skills, agents, plugins, `projects/` and `file-history/` in the
  profile are links to `~/.claude`, so memory is unified and a session resumes
  on either account. User-scope MCP servers are copied from `~/.claude.json`.
  Nothing existing is overwritten; `--check` reports only.
- **The status line shows `◆ <profile>`** on a session running off a
  non-default config directory.

---

Older entries, one HISTORICAL file per quarter:

- [2026 Q3](docs/changelog/CHANGELOG-2026-Q3.md)
- [2026 Q2](docs/changelog/CHANGELOG-2026-Q2.md)
- [2026 Q1](docs/changelog/CHANGELOG-2026-Q1.md)
