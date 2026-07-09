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
```

Remote access is always on. Connect from anywhere at `claude.ai/code`.

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
| `/verify` | Confirm a change works by running it — Claude Code's built-in verification skill (tests, app, behavior) |
| `/review` | Quality/security review |
| `/handoff` | Session transition |
| `/fix-issue 123` | Fix a GitHub issue end-to-end |
| `/simplify` | Remove over-engineering |
| `/commit-push-pr` | Commit + push + PR in one shot |
| `/claude-server` | Spawn worktree + remote |
| `/decompose` | Break a complex task into subtasks |
| `/orchestrate` | Full-lifecycle max-effort mode — roll-call skills, fan out parallel agents, close the loop |
| `/branch-hygiene` | Audit and clean up stale git branches |
| `/jj` | Drive jujutsu (jj) for single-agent work; worktrees for multi-agent |
| `/session-retro` | Retro that proposes improvements to your skills (fires on "thanks", or run it) |
| `/drift-sweep` | Bootstrap a repo's doc contract; audit doc drift vs issues/PRs/worktrees |
| `/fable-mode` | Recalibrate any model to the Fable conduct layer (`claude/FABLE.md`) |

> Most of these **auto-invoke** when their triggers match — you rarely need to
> type them. The ones worth remembering by hand: `/orchestrate`, `/decompose`,
> `/fix-issue N`, and `/handoff`.

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
| `cc [project]` | Pull repos, sync memory, health check, heal plugin drift, launch Claude (optionally in `~/dev/<project>`) |
| `cx [project]` | Same launch ergonomics for Codex (runs `check-codex` instead) |
| `pull-all` | Fast-forward pull on every repo in dev dir |
| `sync-memory` | Commit and push pending memory changes |
| `check-claude` | Verify all Claude config symlinks are healthy (read-only), and warn on hook-wiring drift. `cc` runs `--heal` on **every** launch (incl. `--resume`/`--continue`) to auto-create missing links; ambiguous states stay report-only |
| `check-codex` | Verify public-safe Codex symlinks; warn about private/generated state |
| `check-antigravity` | Verify public-safe Antigravity symlinks (`~/.gemini/config/`); warn about private/generated state |
| `dotfiles-update` | Pull latest dotfiles and re-run setup.sh |
| `claude-server` | Spawn isolated worktree + remote control session |
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

---

## Hooks

Hooks only run if they're **registered in `settings.json`** (the `hooks` block,
which lives in the private `claude-memory` repo). The hook *files* below ship in
`claude/hooks/`; the **Wired** column is the source of truth for what's actually
active. `check-hooks-wired.sh` runs at every `cc` launch and warns if a hook file
is present but not registered — the drift that once left every hook inert.

| Hook | Trigger | Wired | What it does |
|------|---------|:-----:|-------------|
| `SymlinkRepair.hook.ts` | SessionStart (FIRST) | ✅ | Re-links missing dotfiles→`~/.claude/` symlinks (hooks/scripts/agents/skills) every session — incl. **resume** — when new files land and `setup.sh` hasn't re-run; advisory, never clobbers |
| `StripProjectPermissions.hook.ts` | SessionStart | ✅ | Strips project-level permission overrides that fight global settings |
| `HygieneStatus.hook.sh` | SessionStart | ✅ | Surfaces branch-hygiene drift from the daily systemd timer |
| `PluginDriftCheck.hook.ts` | SessionStart | ✅ | Diffs installed plugins against `claude/plugins.txt`; points at `sync-plugins.sh` if anything's missing |
| `conventional-commit.sh` | PreToolUse (`Bash`) | ✅ | Enforces `type: description` commit format on Claude's commits |
| `format-on-edit.sh` | PostToolUse (`Edit\|Write`) | ✅ | Auto-formats edited files — **project-gated**: runs a formatter only where the project opts in (local prettier, or a black/rustfmt/gofmt config). No global fallback, so docs and non-configured repos are never reformatted |
| `HandoffReminder.hook.sh` | SessionStart | ✅ | Surfaces a recent handoff note for the current project into context at session start |
| `ntfy-awaiting-input.sh` | PreToolUse (`AskUserQuestion`) | ✅ | Pushes an ntfy.sh notification when Claude asks a question (`NTFY_TOPIC` in settings env). Overlaps Claude Code's built-in push notifs — drop whichever proves noisier |
| `PrePushStaleSHACheck.hook.ts` | PreToolUse (`Bash`) | ✅ | Warns on `git push` when a reviewer's last-reviewed SHA ≠ HEAD (stderr only; the old PAI queue emission was removed 2026-06-10) |
| `worktree-guard.sh` | PreToolUse (`Bash`) | ✅ | Blocks `git checkout -b`/`git switch` in the **primary** checkout when >1 worktree exists — prevents a branch switch from clobbering another active session's working tree. Always allows `git worktree` commands and ops inside linked worktrees. Fail-open (exits 0 on any error) |

> Security blocking (dangerous commands, secrets) is handled by the permission allowlist in `settings.json`, not by a dedicated hook.

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

**Also in `claude/scripts/`:** `sync-plugins.sh` — idempotently installs any plugins listed in `claude/plugins.txt` that are missing locally. Auto-run by `cc` on every fresh launch (pre-exec, so installs apply to the session being started); a fast path exits silently when there's no drift. Also runnable manually, or follow the warning from `PluginDriftCheck.hook.ts` at session start. The manifest lives in the dotfiles repo and is the cross-machine source of truth.

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
