# Dotfiles

Dev environment config with Claude Code workflows, skills, and safety guards. Works on **macOS**, **WSL (Ubuntu)**, and **native Linux**.

## Quick start

```bash
# Clone this repo
cd ~/dev  # or wherever you keep code
git clone https://github.com/jckeen/dotfiles.git
cd dotfiles

# Run setup
chmod +x setup.sh
./setup.sh
```

The setup script auto-detects your platform and installs the right packages and config.

## What gets installed

| Tool | Purpose |
|------|---------|
| `gh` | GitHub CLI (auth, PRs, issues) |
| `git` | Version control |
| `node` | Node.js LTS |
| `claude` | Claude Code CLI |

## What gets configured

- **Git** — user identity, editor (VS Code), credential helper (platform-appropriate)
- **Claude Code** — global settings, permissions, CLAUDE.md instructions, Agent Pack, skills, safety hooks, remote control
- **Shell aliases** — `pull-all`, `cc` (Claude launcher), `claude-server`, `claude-rc`

## Platform-specific behavior

| Feature | macOS | WSL | Linux |
|---------|-------|-----|-------|
| Package manager | Homebrew | apt | apt |
| Shell config | `.zshrc` | `.bashrc` | `.bashrc` |
| Credential helper | osxkeychain | Git Credential Manager (Windows) | git-credential-store |
| Audio (for /voice) | Built-in | ALSA → PulseAudio | N/A |
| Git safe.directory | Not needed | Auto-configured for `/mnt/c/` | Not needed |

## Adding new config

1. Add the config file to this repo
2. Add a symlink step in `setup.sh`
3. Commit and push
