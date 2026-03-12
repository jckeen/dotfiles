# Dotfiles

Personal dev environment config for WSL Ubuntu. Clone and run `./setup.sh` on a fresh machine.

## Quick start

```bash
# 1. Install WSL (from PowerShell as admin)
wsl --install

# 2. Open Ubuntu and clone this repo
cd ~/dev  # or wherever you keep code
git clone https://github.com/jckeen/dotfiles.git
cd dotfiles

# 3. Run setup
chmod +x setup.sh
./setup.sh
```

## What gets installed

| Tool | Purpose |
|------|---------|
| `tmux` | Terminal multiplexer (persistent sessions) |
| `gh` | GitHub CLI (auth, PRs, issues) |
| `git` | Version control |
| `node` | Node.js LTS |
| `claude` | Claude Code CLI |

## What gets configured

- **Git** — user identity, VS Code as editor, Windows credential manager for auth in WSL
- **Claude Code** — global settings, permissions, CLAUDE.md instructions, Agent Pack
- **tmux** — config file (if `.tmux.conf` exists in repo)

## WSL-specific notes

- Git credentials are shared with Windows via Git Credential Manager
- Repos on `/mnt/c/` need `safe.directory` config (setup.sh handles the dotfiles repo; add others manually)
- Your Windows `dev` folder is at `/mnt/c/Users/jckee/dev`

## Adding new config

1. Add the config file to this repo
2. Add a copy/symlink step in `setup.sh`
3. Commit and push
