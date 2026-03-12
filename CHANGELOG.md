# Changelog

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
