# Changelog

## 2026-03-18 (session 3 — full sweep)

### What changed
- **Removed handoffs/ from repo** — `git rm`'d session-specific handoff files, added `claude/handoffs/` to `.gitignore`. Handoffs are ephemeral and potentially sensitive; they shouldn't live in a public dotfiles repo
- **safe.directory for claude-memory** — setup.sh WSL section now auto-adds the claude-memory repo to git safe.directory alongside dotfiles
- **Scripts deployment** — setup.sh now symlinks `claude/scripts/*.sh` into `~/.claude/scripts/`, and `.bash_aliases` adds that directory to PATH. Headless scripts (health-check.sh, overnight.sh, etc.) are now callable directly
- **`dotfiles-update` function** — new shell function in `.bash_aliases`: pulls latest dotfiles repo, re-runs setup.sh. One command to get up to date
- **Secret-detection hook** (`block-secrets.sh`) — PreToolUse hook that blocks staging known secret files (.env, credentials.json, private keys, etc.) and catches `git add -A` / `git add .` to prevent accidental secret sweep-ins. Also scans commit messages for inline API keys
- **Conventional commit hook** (`conventional-commit.sh`) — PreToolUse hook that validates commit messages match `type: description` format (feat, fix, refactor, chore, docs, test, style). Handles both heredoc and inline -m styles
- **Agent evaluation** — reviewed all 5 "thin" agents (content-reviewer, ux-reviewer, product-strategist, growth-strategist, trust-safety) against built-in subagent_type equivalents. All 5 kept — they add structured output formats, grounding rules ("only report issues with file/line references"), and domain-specific checklists that the built-ins lack

### Decisions made
- All 16 agents stay — no redundancy with built-in subagent_types
- Handoffs belong in gitignore, not the repo — they're session-specific and may contain sensitive context
- Scripts deployed via PATH rather than individual aliases — cleaner and auto-discovers new scripts
- `git add -A` / `git add .` blocked by hook — enforces staging specific files, which prevents accidental secret commits

## 2026-03-18 (session 2 — continued)

### What changed (latest)
- **Private `claude-memory` repo** — memory files moved to `github.com/jckeen/claude-memory` (private), symlinked into `~/.claude/projects/`. Keeps dotfiles public while memory stays private and survives machine rebuilds
- **setup.sh wires memory automatically** — detects dev directory, creates symlink, preserves existing files if migrating
- **check-claude.sh verifies memory** — checks symlink health, catches broken/missing links
- **CLAUDE.md changelog rule tightened** — changed from "at end of session" to "after every 1-2 commits" to prevent drift
- **`cc` auto-syncs memory** — commits and pushes pending memory changes from the last session before launching Claude. New `sync-memory` function in `.bash_aliases`
- **README documents memory setup** — step-by-step instructions for creating a private `claude-memory` repo, explains why it's separate from dotfiles
- **Full doc audit fixes** — agent counts corrected to 16 everywhere, CLAUDE-GUIDE.md now lists `cc` as recommended start command, `.bash_aliases` paths use `_dev_dir()` instead of hardcoded `~/dev/dotfiles`, `sync-claude.sh` respects NOLINK list, README line threshold aligned to 400, handoffs directory added to repo tree

### What changed (earlier)
- **Removed AgentPackJCK.md** — old project-specific agent pack from shitmyspousesays.com, superseded by the generic agent pack
- **Removed stale `.claude/` directory** from dotfiles repo — contained old flat-format skills and empty handoffs, all superseded by `claude/` directory
- **Added `check-claude.sh`** — health check script that verifies config symlinks, detects orphans (symlinks whose dotfiles source was removed), finds stale backups, and supports `--fix` for auto-cleanup. Runs as part of `cc` command before launching Claude
- **AgentPack.md now on-demand** — no longer symlinked into `~/.claude/` (saves context tokens every session). CLAUDE.md tells Claude where to find it when needed for multi-agent reviews
- **CLAUDE.md trimmed from 119 to 89 lines** — removed "Available Skills" and "Available Subagents" listings (Claude already discovers these from installed files)
- **setup.sh auto-discovers files** — no longer hardcodes which top-level files to link. Uses `NOLINK` list for intentional exceptions (like AgentPack.md)
- **check-claude.sh safety** — orphan detection only touches symlinks pointing into the dotfiles repo. Backup cleanup only removes `.backup` files where the original is already a working symlink
- **Cleaned up 9 stale `.backup` files** across `~/.claude/`

### Decisions made
- Dotfiles repo is the right pattern but needed pruning — keep what's custom, lean on built-in platform features for the rest
- Custom skills (all 9) are worth keeping — they add workflow guardrails the official plugins intentionally omit
- Custom agent MD files kept for now — the 4 without built-in equivalents (repo-scout, test-writer, schema-reviewer, dependency-doctor) are clearly needed; the others add output format templates that improve quality
- `full-review.sh` needs real-world testing — may not reliably spawn 12 subagents in headless mode

## 2026-03-18

### What changed
- **4 new agents** — `repo-scout` (fast codebase orientation), `dependency-doctor` (dep audits, CVEs), `test-writer` (bug reproduction, coverage), `schema-reviewer` (DB schema/migration safety). Agent Pack now at 16 agents
- **Autonomous scripts** (`claude/scripts/`) — headless Claude Code runners with tiered permissions:
  - `health-check.sh` — read-only repo briefing + dependency audit
  - `test-coverage.sh` — write tests for uncovered code
  - `full-review.sh` — full 3-phase agent pack review
  - `fix-issues.sh` — pick up GitHub issues and fix them
  - `overnight.sh` — orchestrate all scripts across multiple repos
  - `review-and-push.sh` — AI reviews overnight changes, pushes only after tests pass + review clears
- **5 safety tiers** — READONLY, LINT, FIX, COMMIT, PUSH via `--allowedTools` scoping. No script pushes by default. `--full-auto` flag available as opt-in for `--dangerously-skip-permissions`
- **Honesty guardrails** — all review agents and the script prompt wrapper now instruct Claude not to hallucinate findings. "A clean report is a valid outcome"
- **Auto-detect repos** — `overnight.sh` discovers repos via `CLAUDE_REPOS` env var, `~/.claude/repos` config file, or auto-scanning the dev directory. Works on macOS, Linux, and WSL without editing scripts
- **Full documentation** in `claude/scripts/README.md` — prerequisites, all flags, env vars, cron scheduling, morning workflow, setup guide for dotfiles users

### Decisions made
- Opus 4.6 everywhere — accuracy over cost savings
- `--allowedTools` scoping over `--dangerously-skip-permissions` as default
- Nothing pushes automatically — review-and-push.sh is the gatekeeper
- Deferred: cross-repo-tracker, incident-responder, api-documenter (not needed yet)

## 2026-03-17

### What changed
- **CLAUDE.md overhaul** — Rewrote global instructions based on Boris Cherny's tips and official Claude Code best practices. Added: context hygiene as top priority, verification rules (always test before shipping), interview pattern for vague prompts, CLAUDE.md maintenance rules (under 200 lines, prune ruthlessly), subagent-for-review pattern
- **New PostToolUse hook: `format-on-edit.sh`** — Auto-formats files after Claude edits them using the project's formatter (prettier, black, rustfmt, gofmt). This is what the Claude Code team uses internally — handles the last 10% of formatting
- **New subagents** — Added `security-reviewer` (reviews code for injection, auth flaws, secrets, insecure data handling) and `code-simplifier` (finds and removes unnecessary complexity, premature abstractions, dead code)
- **New skills** — Added `/fix-issue` (pick up a GitHub issue end-to-end: investigate → plan → test → implement → PR) and `/simplify` (delegates to code-simplifier subagent, applies safe changes automatically)
- **README rewritten as best practices guide** — Comprehensive Claude Code mastery guide sourced from Boris Cherny (creator), official docs, and experience. Covers: context management, Plan Mode, verification, prompting patterns, parallelization, CLAUDE.md as compounding engineering, hooks vs CLAUDE.md, anti-patterns to avoid
- **CLAUDE-GUIDE.md condensed to quick reference** — Cheat sheet format instead of duplicating the README
- **settings.json updated** — Added PostToolUse hook for formatting, set `preferredModel: "opus"` (Boris's recommendation: Opus requires less steering and is faster in practice)
- **setup.sh updated** — Now deploys agents directory and hooks with proper permissions, handles directory-based skill format correctly
- **sync-claude.sh updated** — Now syncs agents directory with add/remove tracking

### Decisions made
- Hooks for enforcement, CLAUDE.md for guidance — anything that MUST happen every time goes in a hook, not CLAUDE.md
- Opus as default model — per Boris Cherny: "you steer it less and it's better at tool use, so it's almost always faster"
- Subagents for investigation and review — protects main context from file-read bloat
- README is the single source of truth for best practices — CLAUDE-GUIDE.md is just a quick reference card
- Verification is non-negotiable — baked into CLAUDE.md as a top-level rule

### Follow-up additions
- Added `/commit-push-pr` skill — Boris's most-used daily command. Commits, pushes, and creates a PR in one shot
- Added self-improvement loop rule to CLAUDE.md — "Every time you make a mistake, suggest adding a rule to prevent it"
- Added voice dictation and "let Claude handle git" tips to README
- Updated CLAUDE-GUIDE.md quick reference with new commands

### Sources
- Boris Cherny (creator of Claude Code): https://howborisusesclaudecode.com
- Official best practices: https://code.claude.com/docs/en/best-practices
- Boris's Threads posts on parallelization, Plan Mode, hooks, and subagents
- Boris on Lenny's Podcast: https://www.lennysnewsletter.com/p/head-of-claude-code-what-happens
- Boris on The Pragmatic Engineer: https://newsletter.pragmaticengineer.com/p/building-claude-code-with-boris-cherny
- Trail of Bits claude-code-config for security patterns

## 2026-03-16

### What changed
- Fixed Claude Code `/voice` in WSL2: added `libasound2-plugins` to setup.sh, created `.asoundrc` that routes ALSA through PulseAudio/WSLg, and setup.sh now deploys it to both `~/.asoundrc` (symlink) and `/etc/asound.conf` (copy)
- Root cause: WSL has no direct hardware audio — ALSA needs to be told to route through WSLg's PulseAudio server

### Manual steps after setup.sh
- Ensure Windows microphone permissions are enabled (Settings > Privacy & Security > Microphone)
- Verify with: `arecord -D default -f cd -d 3 /tmp/test.wav && aplay /tmp/test.wav`
- Relaunch Claude Code, then `/voice` should work

## 2026-03-15

### What changed
- Added `pulseaudio-utils` to setup.sh for Claude Code voice mode in WSL

## 2026-03-14

### What changed
- Enabled always-on remote control (`enableRemoteControl: true` in settings.json)
- Added shell aliases: `claude-server` (spawn worktree + remote) and `claude-rc` (remote control current session)
- Sessions are now accessible from `claude.ai/code` and Claude mobile app — no more TMUX dependency

### Decisions made
- Remote control replaces tmux as the primary way to persist and access Claude sessions
- Shell aliases in `.bash_aliases` deployed via symlink in setup.sh

## 2026-03-12

### What changed
- Made Agent Pack generic — no longer tied to SMSS project
- Added Claude Code starter guide (`CLAUDE-GUIDE.md`)
- Added tmux config with mouse support
- Created 4 skills: `/kickoff`, `/changelog`, `/log-error`, `/review`
- Added session workflow and context hygiene rules to global CLAUDE.md
- Expanded `setup.sh` into full WSL bootstrap (installs tmux, gh, node, claude, configures git credential helper)
- Switched setup.sh to symlinks instead of copies (keeps dotfiles and live config in sync)

### Decisions made
- Global CLAUDE.md owns workflow rules; project CLAUDE.md owns project-specific context only
- Agent Pack stays generic — project-specific priorities go in each project's CLAUDE.md
- Skills live in dotfiles and deploy to `~/.claude/skills/`

## 2026-03-11

### What changed
- Initial dotfiles setup: `.gitconfig`, Claude settings, CLAUDE.md
- Added Agent Pack (originally SMSS-specific)

### Decisions made
- Dotfiles repo as single source of truth for dev environment config
- Claude Code config managed via dotfiles, not manually
