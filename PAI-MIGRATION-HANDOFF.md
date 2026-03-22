# PAI Migration Handoff

**Date:** 2026-03-22
**Status:** In progress (multi-session)
**New repo:** `jckeen/Personal_AI_Infrastructure` (fork of `danielmiessler/Personal_AI_Infrastructure`)
**Working clone:** `~/dev/pai`

## What We Did

Forked Daniel Miessler's PAI (Personal AI Infrastructure) as the next evolution of this dotfiles setup. PAI provides structured memory, a learning loop, an Algorithm system (7-phase problem-solving), context routing, voice server, and 12 installable Packs — capabilities we'd otherwise build from scratch.

The dotfiles repo stays as an archive. The PAI fork becomes the new `~/.claude/` directory.

## Migration Plan

Full plan at: `~/.claude/plans/wild-plotting-raven.md`

### What's Being Migrated (our unique value to PAI locations)

| Component | Source (this repo) | Target (PAI fork) |
|---|---|---|
| **9 skills** | `claude/skills/*/SKILL.md` | `skills/_PERSONAL/_*/SKILL.md` |
| **16 agents** | `claude/agents/*.md` | `agents/*.md` (merged with PAI's) |
| **AgentPack orchestration** | `claude/AgentPack.md` | `PAI/USER/AGENTPACK.md` |
| **6 autonomous scripts** | `claude/scripts/*.sh` | `PAI/USER/SCRIPTS/*.sh` |
| **Status line** | `claude/statusline.sh` | `statusline-command.sh` (replaces PAI's) |
| **CLAUDE.md rules** | `claude/CLAUDE.md` | `PAI/USER/AISTEERINGRULES.md` |
| **Conventional commit hook** | `claude/hooks/conventional-commit.sh` | `hooks/ConventionalCommit.hook.ts` (ported to TS) |
| **Format-on-edit hook** | `claude/hooks/format-on-edit.sh` | `hooks/FormatOnEdit.hook.ts` (ported to TS) |
| **Security patterns** | `claude/hooks/block-dangerous.sh` + `block-secrets.sh` | `PAI/USER/PAISECURITYSYSTEM/patterns.yaml` |
| **Shell aliases** | `.bash_aliases` | Stays in dotfiles, symlinked to `~` |
| **Git config** | `.gitconfig` + `.gitconfig.local` | Stays in dotfiles, symlinked to `~` |
| **WSL audio** | `.asoundrc` | Stays in dotfiles, symlinked to `~` |

### What's Being Replaced (PAI provides better versions)

| Our component | PAI replacement |
|---|---|
| `block-dangerous.sh` | `SecurityValidator.hook.ts` + custom patterns.yaml |
| `block-secrets.sh` | `SecurityValidator.hook.ts` + custom patterns.yaml |
| Basic auto-memory | PAI structured MEMORY/ (WORK, LEARNING, SIGNALS, STATE) |
| Manual context management | PAI context routing (lazy-load docs by topic) |
| Simple CLAUDE.md | PAI CLAUDE.md.template with Algorithm system |

### What Stays Here (bootstrap layer)

This repo continues to hold platform-level config that isn't Claude-specific:
- `setup.sh` — Rewritten to clone PAI fork + install Bun + symlink externals
- `.bash_aliases` — Shell functions, `cc` launcher, worktree shortcuts
- `.gitconfig` / `.gitconfig.local` — Git identity and platform config
- `.asoundrc` — WSL audio routing
- `check-claude.sh` — Health check (may move to PAI/USER/SCRIPTS/ later)

## Skills Inventory (all 9 migrating)

1. `/kickoff` — New project bootstrap
2. `/changelog` — Session change logging
3. `/log-error` — Error documentation with classification
4. `/review` — Code quality review (last 3 commits)
5. `/handoff` — Session transition notes
6. `/fix-issue` — GitHub issue to branch to test to fix to PR
7. `/simplify` — Complexity removal via code-simplifier agent
8. `/commit-push-pr` — One-shot stage to build to commit to push to PR
9. `/claude-server` — Remote worktree access

## Agents Inventory (all 16 migrating)

### Review agents (read-only): 12
backend-architect, code-simplifier, content-reviewer, frontend-architect, growth-strategist, launch-operator, perf-accessibility, product-strategist, qa-lead, security-reviewer, trust-safety, ux-reviewer

### Utility agents (read+write): 4
dependency-doctor, repo-scout, schema-reviewer, test-writer

### Overlap with PAI agents (evaluate during migration)
- Our `backend-architect` / `frontend-architect` vs PAI's `Architect.md`
- Our `qa-lead` vs PAI's `QATester.md`
- Our `security-reviewer` vs PAI's `Pentester.md`
- Our `ux-reviewer` vs PAI's `UIReviewer.md`

## Autonomous Scripts Inventory (all 7 migrating)

- `common.sh` — 5-tier safety system (READONLY to LINT to FIX to COMMIT to PUSH)
- `health-check.sh` — Repo-scout + dependency-doctor combined
- `full-review.sh` — 3-phase agent pack review (all 12 review agents)
- `test-coverage.sh` — Identify untested code, write tests
- `fix-issues.sh` — Pick oldest GitHub issue, branch, test-first fix
- `overnight.sh` — Orchestrate health/test/fix across all repos
- `review-and-push.sh` — Morning gate: test to review to verdict to push

## Sessions Remaining

- **Session 2:** Port hooks to TypeScript, create security patterns.yaml
- **Session 3:** Migrate skills, agents, autonomous scripts, status line
- **Session 4:** Merge settings.json, install all 12 packs
- **Session 5:** Voice server setup, rewrite setup.sh bootstrap
- **Session 6:** End-to-end verification, fresh machine test

## Key Decisions

1. **Fork PAI** (not submodule, not cherry-pick) — `~/.claude/` IS the repo
2. **Port hooks to TypeScript** — consistent with PAI's Bun runtime
3. **Full pack suite** — all 12 packs installed
4. **Voice server** — ElevenLabs TTS enabled
5. **Track upstream** — `git remote add upstream` + periodic merge
