# Changelog

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
