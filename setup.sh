#!/bin/bash
# Bootstrap a fresh WSL Ubuntu environment with dev tools and config.
# Run from the dotfiles repo root: ./setup.sh

set -e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"

echo "=== Dotfiles setup from $DOTFILES_DIR ==="

# ─── 1. System packages ───────────────────────────────────────────────
echo ""
echo "--- Installing system packages ---"
sudo apt update && sudo apt install -y \
  tmux \
  gh \
  git \
  curl \
  unzip

# ─── 2. Node.js (via NodeSource if not present) ───────────────────────
if ! command -v node &>/dev/null; then
  echo ""
  echo "--- Installing Node.js ---"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt install -y nodejs
else
  echo "Node.js already installed: $(node -v)"
fi

# ─── 3. Claude Code CLI ──────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  echo ""
  echo "--- Installing Claude Code CLI ---"
  npm install -g @anthropic-ai/claude-code
else
  echo "Claude Code already installed: $(claude --version 2>/dev/null || echo 'installed')"
fi

# ─── 4. Git config ───────────────────────────────────────────────────
echo ""
echo "--- Setting up Git config ---"
cp "$DOTFILES_DIR/.gitconfig" "$HOME_DIR/.gitconfig"

# WSL credential helper (uses Windows Git Credential Manager)
git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"

# Mark common dev directories as safe (WSL ownership issue)
git config --global --add safe.directory /mnt/c/Users/jckee/dev/dotfiles

echo "  -> .gitconfig installed"

# ─── 5. Claude Code config ───────────────────────────────────────────
echo ""
echo "--- Setting up Claude Code config ---"
mkdir -p "$HOME_DIR/.claude"
cp "$DOTFILES_DIR/claude/settings.json" "$HOME_DIR/.claude/settings.json"
cp "$DOTFILES_DIR/claude/CLAUDE.md" "$HOME_DIR/.claude/CLAUDE.md"
cp "$DOTFILES_DIR/claude/AgentPackJCK.md" "$HOME_DIR/.claude/AgentPackJCK.md"
echo "  -> Claude config installed"

# ─── 6. GitHub CLI auth ──────────────────────────────────────────────
if ! gh auth status &>/dev/null; then
  echo ""
  echo "--- GitHub CLI not authenticated ---"
  echo "Run: gh auth login"
  echo "(Choose HTTPS and browser-based login)"
else
  echo "GitHub CLI already authenticated"
fi

# ─── 7. tmux ──────────────────────────────────────────────────────────
if [ -f "$DOTFILES_DIR/.tmux.conf" ]; then
  echo ""
  echo "--- Setting up tmux config ---"
  cp "$DOTFILES_DIR/.tmux.conf" "$HOME_DIR/.tmux.conf"
  echo "  -> .tmux.conf installed"
else
  echo "No .tmux.conf in dotfiles (tmux will use defaults)"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Manual steps remaining:"
echo "  1. Run 'gh auth login' if not already authenticated"
echo "  2. Add any project repos to git safe.directory as needed:"
echo "     git config --global --add safe.directory /mnt/c/Users/jckee/dev/<repo>"
