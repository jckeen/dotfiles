# Working with Claude Code — Quick Reference

See the [README](README.md) for the full best practices guide. This is the cheat sheet.

---

## First-time setup

```bash
cd ~/dev
git clone https://github.com/jckeen/dotfiles.git
cd dotfiles && chmod +x setup.sh && ./setup.sh      # prompts: are you using PAI? [Y/n]
# Flags: --no-pai (Claude Code only, no PAI) | --pai (assume yes, non-interactive)
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
4. `/simplify` — Remove unnecessary complexity
5. `/review` — Check quality and security
6. `/changelog` — Log what happened
7. `/handoff` — If ending the session

---

## Slash Commands

| Command | Use |
|---------|-----|
| `/kickoff` | New project setup |
| `/changelog` | Log session changes |
| `/log-error` | Document error patterns |
| `/review` | Quality/security review |
| `/handoff` | Session transition |
| `/fix-issue 123` | Fix a GitHub issue end-to-end |
| `/simplify` | Remove over-engineering |
| `/commit-push-pr` | Commit + push + PR in one shot |
| `/claude-server` | Spawn worktree + remote |

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
| `cc` | Pull repos, sync memory, health check, launch Claude |
| `pull-all` | Fast-forward pull on every repo in dev dir |
| `sync-memory` | Commit and push pending memory changes |
| `check-claude` | Verify all Claude config symlinks are healthy |
| `dotfiles-update` | Pull latest dotfiles and re-run setup.sh |
| `claude-server` | Spawn isolated worktree + remote control session |
| `wt-claude <name>` | Create a worktree and launch Claude in it |

---

## Hooks

| Hook | Trigger | What it does |
|------|---------|-------------|
| `conventional-commit.sh` | PreToolUse | Enforces `type: description` commit format (feat, fix, refactor, etc.) |
| `format-on-edit.sh` | PostToolUse | Auto-formats edited files (prettier, black, rustfmt, gofmt) |
| `ntfy-awaiting-input.sh` | PreToolUse | Push notification when Claude needs input |
| `StripProjectPermissions.hook.ts` | SessionStart | Strips project-level permission overrides that fight global settings |
| `HygieneStatus.hook.sh` | SessionStart | Surfaces branch-hygiene drift detected by the daily systemd timer (thin wrapper around `hygiene-status.sh --reminder`) |
| `PluginDriftCheck.hook.ts` | SessionStart | Diffs installed plugins against `claude/plugins.txt` manifest; warns and points at `sync-plugins.sh` if anything is missing |
| `SymlinkRepair.hook.ts` | SessionStart (place FIRST) | Re-installs missing dotfiles→`~/.claude/` symlinks for hooks/scripts/agents/skills when new files land in the repo and `setup.sh` hasn't been re-run; advisory-only, never clobbers |
| `PRWatcherAutoLaunch.hook.ts` | PostToolUse | Detects `gh pr create` / `mcp__github__create_pull_request` and spawns `WatchPRReviews.ts` in the background so the watch→fix→re-review loop runs without manual Monitor invocation |
| `PRWatcherSurface.hook.ts` | UserPromptSubmit | Surfaces unread PR-watcher events (Codex/human reviews, comments, CI) into `additionalContext` so the assistant proactively addresses feedback |
| `PrePushStaleSHACheck.hook.ts` | PreToolUse | On `git push`, warns (never blocks) when the push will obsolete an in-flight reviewer's `reviewed_sha`; logs a `[stale-push]` event for the surface hook |

> Security blocking (dangerous commands, secrets) is handled by the PAI SecurityValidator hook, not in dotfiles.

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

**Also in `claude/scripts/`:** `sync-plugins.sh` — idempotently installs any plugins listed in `claude/plugins.txt` that are missing locally. Run it manually, or follow the warning from `PluginDriftCheck.hook.ts` at session start. The manifest lives in the dotfiles repo and is the cross-machine source of truth.

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
