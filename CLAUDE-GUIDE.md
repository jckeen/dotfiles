# Working with Claude Code — Quick Reference

See the [README](README.md) for setup and the guided tour. This is the cheat sheet — the canonical daily reference for slash commands, hooks, shortcuts, and shell commands.

---

## First-time setup

```bash
cd ~/dev
git clone https://github.com/jckeen/dotfiles.git
cd dotfiles && chmod +x setup.sh && ./setup.sh
# Flags: --check | --repair | --dry-run | --help
```

The script auto-detects your platform (macOS, WSL, or Linux) and installs everything accordingly.

Then: `gh auth login` and `claude` to authenticate.

---

## Starting a Session

```bash
cc                       # Recommended: sync repos + memory, health check, launch
claude                   # Start new session directly
claude --continue        # Resume most recent
claude --resume          # Pick from recent sessions
claude-server            # Isolated worktree + remote access
cct [project]            # cc inside a named tmux session — survives a closed terminal
ccw [project]            # cc on a second (work) Claude account — separate usage, same setup
```

Remote access is always on. Connect from anywhere at `claude.ai/code`.
It only stays online while the local `claude` process is running, so for a
session you want reachable after closing the terminal, start it with `cct`
and detach (`Ctrl-b d`); `cct <project>` again reattaches.

### A second account (`ccw`)

`ccw` runs `cc` signed in to a second Claude account, so a work subscription
and a personal one each carry their own usage. Claude Code keeps one login per
config directory; `ccw` points `CLAUDE_CONFIG_DIR` at `~/.claude-work`
(override with `CLAUDE_WORK_CONFIG_DIR`) and the first run asks you to sign in.

`claude/scripts/link-claude-profile.sh` links the profile's settings, global
instructions, skills, agents, plugins, transcripts, memory, and each
session's todos and tasks back to `~/.claude`, and copies the user-scope MCP
servers across. A session started under `cc` can be resumed under `ccw` and
the other way round, which is the way to carry on when one account reaches
its limit. The status line shows `◆ work` on a `ccw` session.

What stays with each account: the login, MCP and connector sign-ins, folder
trust prompts, prompt history, per-session environment (`session-env/`), and
everything hosted on claude.ai — Remote Control sessions, connectors, routines
and artifacts appear under whichever account the session runs on. Work run
through `ccw` is subject to that organization's admin and retention settings.

---

## The Workflow

```
Plan → Build → Verify → Simplify → Review → Log → Handoff
```

1. **Shift+Tab (x2)** — Enter Plan Mode
2. Go back and forth until the plan is solid
3. Switch to Normal Mode — Claude executes
4. `/verify` — Confirm it actually works (run the tests, run the app, observe behavior). This is the **#1 quality multiplier** — a real feedback loop is worth 2–3× the result.
5. `/simplify` — Remove unnecessary complexity
6. `/review` — Check quality and security
7. `/changelog` — Log what happened
8. `/handoff` — If ending the session

> **Changelog in this repo:** a PR adds its entry as one fragment under
> `changelog.d/` (named after the branch by convention) instead of editing
> `CHANGELOG.md`. `assemble-changelog.sh --check` validates it before push,
> and fragments are folded into `CHANGELOG.md` by hand at release time — see
> [`claude/scripts/README.md`](claude/scripts/README.md).

> **Push-time Codex gate:** `commit-push-pr` runs a local Codex review
> (`codex-review-gate.sh` → `codex exec --output-schema`, structured JSON over
> a gate-computed, injection-fenced diff) between staging and commit. It
> **blocks the push on critical/high/medium findings** and **files a GitHub
> issue per low finding** so nothing is lost. Adversarial mode:
> `--claim "<claim>" --repro "<cmd>"` makes the reviewer refute a specific
> claim. The merge gate is that Codex review **+ CI green** (ADR-0003). If
> Codex can't run it degrades open (won't wedge a push); set
> `CODEX_GATE_REQUIRED=1` to hard-require it. Diffs touching the reviewer's
> own instruction files (AGENTS*.md / codex/) fail closed toward the
> Antigravity gate + human review.

---

## Slash Commands

| Command | Use |
|---------|-----|
| `/kickoff` | New project setup |
| `/changelog` | Log session changes |
| `/log-error` | Document error patterns |
| `/review` | Quality/security review |
| `/antigravity-review` | Gemini second-opinion review gate (Antigravity) |
| `/handoff` | Session transition |
| `/fix-issue 123` | Fix a GitHub issue end-to-end |
| `/simplify` | Remove over-engineering |
| `/commit-push-pr` | Commit + push + PR in one shot |
| `/claude-server` | Spawn worktree + remote |
| `/decompose` | Break a complex task into subtasks |
| `/orchestrate` | Full-lifecycle max-effort mode — roll-call skills, fan out parallel agents, close the loop |
| `/branch-hygiene` | Audit and clean up stale git branches |
| `/jj` | Drive jujutsu (jj) for single-agent work; worktrees for multi-agent |
| `/review-gates` | Multi-agent review-gate mechanics: lane selection, handoff payload, verdict persistence |
| `/session-retro` | Retro that proposes improvements to your skills (fires on "thanks", or run it) |
| `/drift-sweep` | Bootstrap a repo's doc contract; audit doc drift vs issues/PRs/worktrees |

> Most of these **auto-invoke** when their triggers match — you rarely need to
> type them. The ones worth remembering by hand: `/orchestrate`, `/decompose`,
> `/fix-issue N`, and `/handoff`.
>
> This table mirrors `claude/skills/` exactly and is asserted in CI by
> `check-skill-parity.sh`. `/verify` (step 4 of The Workflow above) is Claude
> Code's **built-in** verification skill, not a repo skill, so it isn't listed.

---

## Key Shortcuts

| Key | Action |
|-----|--------|
| `Shift+Tab` (x2) | Plan Mode |
| `Ctrl+G` | Edit plan in editor |
| `Ctrl+B` | Background task |
| `Esc` | Stop (context preserved) |
| `Esc+Esc` | Rewind menu |
| `/clear` | Reset context |
| `/compact` | Compress context |
| `/btw` | Side question (no context cost) |

---

## Shell Commands

| Command | What it does |
|---------|-------------|
| `cc [project]` | Pull repos, sync memory, health check, heal plugin drift, launch Claude (optionally in `~/dev/<project>`). A failed pull or memory sync warns and continues on local state; a failed `check-claude` blocks. Reloads `~/.bash_aliases` first if it changed since the shell started (so do `cx`/`agy`); removes an empty stub `.git` from the dev dir; warns when the primary dotfiles checkout is off `main` |
| `cx [project]` | Same launch ergonomics for Codex (runs `check-codex` instead); reuses a listening shared server when Remote Control is already enabled and otherwise launches locally; preserves explicit endpoints and leaves daemon startup and repair to explicit maintenance |
| `pull-all` | Fast-forward pull on every ordinary checkout in dev dir; linked worktrees fetch only. Nonzero when any repo fails, with the repo name and first git error per line |
| `sync-memory` | Commit and push pending memory changes; nonzero when publication is refused (no upstream, non-memory paths in the commit, a credential-like file name such as `*oauth*.md` — the abort names the file — push failure). Inside `cc` that refusal is a warning, not a launch blocker |
| `check-claude` | Verify all Claude config symlinks are healthy (read-only), and warn on hook-wiring drift. `cc` runs `--heal` on **every** launch (incl. `--resume`/`--continue`) to auto-create missing links (an old per-file skill directory is moved whole into `~/.claude/.migrated-skill-dirs/`, never deleted; any archived entry that is not only old links, such as content that changed mid-migration, is reported as `KEPT` every run, and an entry is safe to delete by hand only if `check-claude` does not flag it); ambiguous states stay report-only. A self-link nested inside a source skill bundle (`claude/skills/<name>/<name>`) is reported as `SELFLINK`; `--fix` removes it. A missing CLI tool the config prefers (`CLI_STACK_TOOLS` in `lib-checks.sh`) prints an advisory `TOOL` warning that does not fail the check |
| `check-codex` | Verify public-safe Codex symlinks; warn about private/generated state |
| `check-antigravity.sh` | Verify public-safe Antigravity symlinks (`~/.gemini/config/`); warn about private/generated state |
| `dotfiles-update` | Pull latest dotfiles and re-run setup.sh |
| `claude-server` | Spawn isolated worktree + remote control session |
| `cct [project]` | `cc` inside a named tmux session (attaches if it already exists). A tmux server that is already running gets `~/.tmux.conf` re-sourced first, as `setup.sh` also does, so config edits reach it. Keeps the process, and its Remote Control link, alive after the terminal closes. Opt-in; `cc` and `wsl6` stay tmux-free |
| `ccw [cc args]` | `cc` on a second (work) Claude account: separate login and usage, shared settings, skills, plugins, memory and transcripts. See [A second account](#a-second-account-ccw) |
| `wt-claude <name>` | Create a worktree and launch Claude in it |
| `projects` | List projects in the dev dir |
| `sessions` | Show active Claude sessions and their working dirs |
| `ledger` | Session spend by day/project (data written by the status line); `--prune` drops >90-day entries |

### Worktrees & multi-session

| Command | What it does |
|---------|-------------|
| `za` … `ze` / `z0` | Jump to worktree `-a`…`-e` / back to the main worktree |
| `gwl` / `gwa` / `gwr` | `git worktree` list / add / remove |
| `cc-pane <project> [-H]` | Open project in a new Windows Terminal split pane (vertical default) |
| `cc-tab <project>` | Open project in a new tab |
| `cc-multi <p1> <p2> …` | One tab per project, each fully `cc`-synced |
| `wsl6`, `ccgrid`, `cctab`, `ccpane` | PowerShell-side launchers — see [docs/WINDOWS.md](docs/WINDOWS.md) |

> From inside a Claude session: `! cc-pane <project>` opens another project
> alongside without leaving Claude.

> **The primary dotfiles checkout stays on `main`.** `~/.bash_aliases`, hooks,
> skills and agents are symlinks into `~/dev/dotfiles`, so whatever branch is
> checked out there is the live shell config for every new shell. Do dotfiles
> branch work in a worktree (`wt-claude <name>` from `~/dev/dotfiles`); the
> `cc`/`cx`/`agy` preflight warns while the primary is off `main`.

---

## Hooks

Hooks only run if they're **registered in `settings.json`** (the `hooks` block).
The owner's lives in the private `claude-memory` repo. The public
[`claude/settings.example.json`](claude/settings.example.json) registers every
hook below plus the status line, except the hooks listed with their reasons in
[`claude/settings-optout.txt`](claude/settings-optout.txt):
`StripProjectPermissions.hook.ts` deletes a project's whole `permissions`
block, deny rules included, which is only safe beside a global allowlist the
template does not ship; `OperatorQueueReminder.hook.sh` defaults to the
owner's private queue repo (set `OPERATOR_QUEUE_REPO` and add it yourself).
`setup.sh` copies the template to `~/.claude/settings.json` when neither that
file nor `claude-memory` exists (`settings-example.test.sh` fails CI when a
hook file is missing from it and not listed), and `check-hooks-wired.sh` does
not ask for the listed hooks. A full private setup adds
`"CHECK_HOOKS_REQUIRE_ALL": "1"` to its settings `env` to require every hook. The
hook *files* below ship in
`claude/hooks/`; the **Wired** column is the source of truth for what's actually
active. `check-hooks-wired.sh` runs at every `cc` launch and warns if a hook file
is present but not registered — the drift that once left every hook inert.

| Hook | Trigger | Wired | What it does |
|------|---------|:-----:|-------------|
| `SymlinkRepair.hook.ts` | SessionStart (FIRST) | ✅ | Re-links missing dotfiles→`~/.claude/` symlinks (hooks/scripts/agents per file; each skill as one directory link, converting the old per-file layout by moving the old directory whole into `~/.claude/.migrated-skill-dirs/`, never deleting; an archived entry is safe to delete by hand only if `check-claude` does not flag it `KEPT`) every session — incl. **resume** — when new files land and `setup.sh` hasn't re-run; advisory, never clobbers |
| `StripProjectPermissions.hook.ts` | SessionStart | ✅ | Strips project-level permission overrides that fight global settings |
| `HygieneStatus.hook.sh` | SessionStart | ✅ | Surfaces branch-hygiene drift from the daily systemd timer |
| `PluginDriftCheck.hook.ts` | SessionStart, UserPromptSubmit | SessionStart ✅; UserPromptSubmit: `check-hooks-wired.sh` reports | Diffs **user-scope** installed plugins against `claude/plugins.txt`; points at `sync-plugins.sh` if anything's missing. A plugin of a deselected agent service (`lib-services.sh`, shared with `sync-plugins.sh`) is not drift; an unreadable selection reports everything and says so. `--scope project` and `--scope local` plugins belong to their checkout and are ignored in both directions; `setup.sh` and `sync-plugins.sh` apply the same rule. Also names every installed plugin (cache, relative-path plugins loaded in place from a local-path marketplace, claude.ai synced, `~/.claude/skills` and the project's `.claude/skills`) that ships a **mod** — a `"modules"` key in its `hooks/hooks.json` — unless a `# mods-ok: <id>` line in `plugins.txt` allowlists it (a project `.claude/skills` mod is always named, since a cloned repo could reuse an allowlisted name). A plugin whose `hooks.json`, `plugin.json` or `marketplace.json` exists but can't be parsed (or isn't a regular file of at most 1 MiB) is named as unverifiable rather than skipped. Every local-marketplace catalog entry is scanned, enabled or not, and the project is the hook input's `cwd` (it follows `--worktree`) plus `$CLAUDE_PROJECT_DIR`. A printed id that needed sanitizing (or is over 300 characters) is shown with its allowlist key `sha256:<first 16 hex of the SHA-256 of the raw id's UTF-16LE code units>`, and only that key allowlists it (#648). On UserPromptSubmit it stats every path the last scan read and rescans only when one changed, naming just the mods this session was not yet told about (#618). Best-effort and advisory, not a security boundary — see below |
| `conventional-commit.sh` | PreToolUse (`Bash`) | ✅ | Enforces `type: description` commit format on Claude's commits. Extracts the message with POSIX `awk`/`sed` (no `grep -P`, so it works on macOS), reads a quoted message that spans lines, and validates the first non-blank line; a commit whose `-m` message it cannot read is denied |
| `format-on-edit.sh` | PostToolUse (`Edit\|Write`) | ✅ | Auto-formats edited files — **project-gated**: runs a formatter only where the project opts in (local prettier, or a black/rustfmt/gofmt config). No global fallback, so docs and non-configured repos are never reformatted |
| `HandoffReminder.hook.sh` | SessionStart | ✅ | Surfaces a recent handoff note for the current project into context at session start |
| `OperatorQueueReminder.hook.sh` | SessionStart | ✅ | Prints open operator items with age, deadline-first, past-due flagged. Source: `~/.claude/operator-queue.md` (USER ACTION queue appended by the handoff skills) until its first lines carry the historical banner, then open `operator-action` issues found by one GitHub search over the private home repo `OPERATOR_QUEUE_REPO` (default `github.com/jckeen/claude-memory`) plus every repo of the `OPERATOR_QUEUE_OWNERS` accounts (default in the hook header), counting only issues the operator wrote in private repos. Each item lives in the private repo it concerns; the home repo holds only items for public repos or several repos. Each heading names its repo (`<slug> (<repo>#<n>)`). Rendered from a cache that a detached `--refresh` renews when it is over 10 min old (no network time at SessionStart; an old or failed cache is named in the header); `claude/scripts/migrate-operator-queue.sh` moved the file's items into the home repo (dry-run by default; it skips only an exact prior migration, a same-title issue with `operator-action` whose field lines are exactly the block's in order, and any other same-title issue is reported "needs manual merge: #N", never edited, and fails `--apply`). Only the session project's items (matched on any word of `project:` against the repo's main-checkout basename, so worktrees count; the cwd basename outside git) plus anything past due or due today print in full; every other project is one line, `<project>: N items (oldest Xd, next deadline YYYY-MM-DD)`, and a footer names the file. `OPERATOR_QUEUE_SHOW_ALL=1` prints everything; `OPERATOR_QUEUE_FILE` points it at another queue. Items whose newest `verified:`/`added:` date is >30 days old (or undated) get `[stale — re-verify]` and the header counts them; the output is status only (what the queue holds, its source, its freshness), never an instruction to act on an item; bounded by the item, action-length and queue-size caps in the hook header; silent when empty or absent |
| `ntfy-awaiting-input.sh` | PreToolUse (`AskUserQuestion`) | ✅ | Pushes an ntfy.sh notification when Claude asks a question (`NTFY_TOPIC` in settings env). Overlaps Claude Code's built-in push notifs — drop whichever proves noisier |
| `PrePushStaleSHACheck.hook.ts` | PreToolUse (`Bash`) | ✅ | Warns on `git push` when a reviewer's last-reviewed SHA ≠ HEAD, as stdout JSON: `systemMessage` for you, `additionalContext` for Claude (exit-0 stderr reaches only the debug log, #593); the old PAI queue emission was removed 2026-06-10 |
| `PreMergeCodexHarvest.hook.sh` | PreToolUse (`Bash` on `gh pr merge`) | ✅ | Harvests Codex review comments into the PR's consolidated issue before merge (only when the whole command starts with the merge, after `VAR=value` assignments: a search, an echo or quoted text never fires it. A merge inside a compound command, `$(…)` or `if …; then` is deliberately not recognised — the close-time workflow harvests every PR anyway, while a false trigger files a junk issue); under `--auto` the bot has not reviewed yet, so it notes that the close-time workflow (`harvest-codex-comments.yml`) will file the findings; reports through stdout JSON (`systemMessage` + `additionalContext`, #593); warn-only and always exits successfully |
| `worktree-guard.sh` | PreToolUse (`Bash`) | ✅ | Blocks `git checkout -b`/`git switch` in the **primary** checkout when >1 worktree exists — prevents a branch switch from clobbering another active session's working tree. Checks every segment of a compound command (`&&`, `\|\|`, `;`, `\|`, `&`, `$(…)`, newlines), so `git worktree list && git switch -c x` is caught, and fails closed: raw text with quotes kept is matched, per segment and for the whole command, so quoted options or separators cannot hide a `switch`. There is no `git worktree` exemption: a worktree command without a `switch`/`checkout` word passes the cheap exit, and one containing such a word is judged like any other (a safe false positive); after `--`, checkout arguments are pathspecs. Ops inside linked worktrees are never blocked; environment errors (no jq, not a repo) still allow |

> Security blocking (dangerous commands, secrets) is handled by the permission allowlist in `settings.json`, not by a dedicated hook.

**Mods sit above every hook here.** A mod (a plugin whose `hooks/hooks.json`
has a `"modules"` key) runs code in the session, and a `tool.check` hook in one
can approve a call that an `ask` rule or a non-managed `PreToolUse` hook — all
of the above — would stop; outside managed settings or a Team/Enterprise plan,
even a `deny` rule. Before installing or updating a mod, run
`claude plugin validate <dir>` and read its `hooks:` and `calls:` lines.
`tool.check`, `prompt.submit`, a `tool.call` hook that answers without calling
`next`, and `$.process.*`, `$.http.fetch` or `$.env.*` calls each need a
deliberate yes. Then add `# mods-ok: <id>` to `claude/plugins.txt` so
`PluginDriftCheck.hook.ts` stops naming it (#594).

**The mod scan is best-effort.** It is a static parse, and loader-differential
cases (#647) stay open: Claude Code exposes no list of the hook modules it
loaded. `claude plugin list --json` names plugins and their directories but no
modules, and no hook event fires on a plugin install, enable or
`/reload-plugins`. So a `hooks/hooks.json` the loader reads differently from
`JSON.parse` can hide a mod; a file the hook cannot parse is named as
unverifiable instead. The mid-session rescan polls file signatures on each
prompt, so a change is seen at the next prompt, not when it happens (#618).
`/plugin` shows which mods the session actually loaded; trust
it over the hook when they disagree. The upstream request for a loaded-modules
listing or a plugin-reload event is drafted, for the operator to file, in
`~/.claude/handoffs/2026-10-19-dotfiles-operator-pass/upstream-claude-code-plugin-introspection.md`.
Plugins relocated by `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_PLUGIN_CACHE_DIR` or
`CLAUDE_CODE_PLUGIN_DIRS` are not yet covered: the hook, `sync-plugins.sh` and
`lib-checks.sh` all read `~/.claude`, and #699 moves them together.

---

## Autonomous Scripts

Headless scripts for unattended Claude Code work. All live in `~/.claude/scripts/` (on PATH after setup).

| Script | What it does | Example |
|--------|-------------|--------|
| `health-check.sh` | Read-only repo health audit | `health-check.sh ~/dev/atlas` |
| `test-coverage.sh` | Write tests for uncovered code | `test-coverage.sh ~/dev/atlas --full-auto` |
| `fix-issues.sh` | Auto-pick and fix GitHub issues | `fix-issues.sh ~/dev/atlas` |
| `full-review.sh` | 3-phase agent pack review (12+ subagents) | `full-review.sh ~/dev/atlas` |
| `overnight.sh` | Orchestrate all scripts across all repos | `overnight.sh --deep --full-auto` |
| `review-and-push.sh` | Morning review of overnight changes | `review-and-push.sh ~/dev/atlas --auto-push` |

All scripts use safety tiers from `common.sh` — each gets the minimum permissions needed.

**Also in `claude/scripts/`:** `sync-plugins.sh` — idempotently installs any plugins listed in `claude/plugins.txt` that are missing locally (skipping a deselected agent service's plugins) and uninstalls any named by a `# removed: <id>` line. Auto-run by `cc` on every fresh launch (pre-exec, so installs apply to the session being started); a fast path exits silently when there's no drift. Also runnable manually, or follow the warning from `PluginDriftCheck.hook.ts` at session start. The manifest lives in the dotfiles repo and is the cross-machine source of truth.

---

## Stop Hooks (Auto-QA Pattern)

Add a `Stop` hook to a project's `.claude/settings.local.json` to auto-run checks after each Claude response. If checks fail, errors feed back to Claude automatically.

**Template** — adapt the commands per project:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "cd $CLAUDE_PROJECT_DIR && npm run typecheck 2>&1 | tail -20; npm run lint 2>&1 | tail -20"
          }
        ]
      }
    ]
  }
}
```

**Tips:**
- Put this in `.claude/settings.local.json` (project-level, gitignored), not global settings
- Pipe through `tail` to keep output concise — Claude sees the full hook output
- Chain multiple checks with `&&` or `;` depending on whether you want fail-fast
- Common combos: `tsc --noEmit`, `eslint .`, `pytest`, `cargo check`, `go vet ./...`

---

## CLAUDE.local.md

Use `CLAUDE.local.md` alongside `CLAUDE.md` for personal preferences that shouldn't be committed to the repo. Claude reads both automatically. Add it to `.gitignore`.

Useful for: personal workflow preferences, local paths, machine-specific context.

---

## Golden Rules

1. **Context is finite** — `/clear` between unrelated tasks
2. **Plan before building** — Plan Mode for anything non-trivial
3. **Always verify** — tests, screenshots, or expected outputs
4. **Use subagents** — for investigation and review (protects context)
5. **Be specific** — vague prompts waste tokens on wrong approaches
6. **Parallelize** — run multiple sessions with git worktrees
7. **CLAUDE.md compounds** — keep it pruned and accurate

---

## When Things Go Wrong

| Problem | Fix |
|---------|-----|
| Claude repeating itself | `/clear` and start fresh |
| Same error 3+ times | "Stop. Explain why this is failing" |
| Ignoring CLAUDE.md rules | CLAUDE.md too long — prune it |
| Context getting high | `/handoff` then `/clear` |
| Need to explore without cost | "Use subagents to investigate X" |
