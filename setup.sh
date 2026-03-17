#!/bin/bash
# Bootstrap a fresh WSL Ubuntu environment with dev tools and config.
# Run from the dotfiles repo root: ./setup.sh
#
# Uses symlinks so edits to ~/.claude/* automatically stay in sync
# with this repo.

set -e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"

# Helper: create a symlink, backing up any existing file
link_file() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -f "$dst" ]; then
    mv "$dst" "$dst.backup"
    echo "  -> backed up existing $dst to $dst.backup"
  fi
  ln -s "$src" "$dst"
}

echo "=== Dotfiles setup from $DOTFILES_DIR ==="

# ─── 1. System packages ───────────────────────────────────────────────
echo ""
echo "--- Installing system packages ---"
sudo apt update && sudo apt install -y \
  gh \
  git \
  curl \
  unzip \
  jq \
  pulseaudio-utils \
  libasound2-plugins \
  alsa-utils

# ─── 1b. Audio (ALSA → PulseAudio for WSLg) ─────────────────────────
echo ""
echo "--- Setting up ALSA → PulseAudio routing ---"
link_file "$DOTFILES_DIR/.asoundrc" "$HOME_DIR/.asoundrc"
sudo cp "$DOTFILES_DIR/.asoundrc" /etc/asound.conf
echo "  -> .asoundrc linked, /etc/asound.conf written"

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
link_file "$DOTFILES_DIR/.gitconfig" "$HOME_DIR/.gitconfig"

# WSL credential helper (uses Windows Git Credential Manager)
git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"

# Mark common dev directories as safe (WSL ownership issue)
git config --global --add safe.directory /mnt/c/Users/jckee/dev/dotfiles

echo "  -> .gitconfig linked"

# ─── 5. Claude Code config ───────────────────────────────────────────
echo ""
echo "--- Setting up Claude Code config ---"
mkdir -p "$HOME_DIR/.claude/skills"
mkdir -p "$HOME_DIR/.claude/agents"

link_file "$DOTFILES_DIR/claude/settings.json" "$HOME_DIR/.claude/settings.json"
link_file "$DOTFILES_DIR/claude/CLAUDE.md" "$HOME_DIR/.claude/CLAUDE.md"
link_file "$DOTFILES_DIR/claude/AgentPackJCK.md" "$HOME_DIR/.claude/AgentPackJCK.md"
link_file "$DOTFILES_DIR/claude/statusline.sh" "$HOME_DIR/.claude/statusline.sh"
chmod +x "$DOTFILES_DIR/claude/statusline.sh"
echo "  -> Claude config linked"

# Hooks
mkdir -p "$HOME_DIR/.claude/hooks"
for hook in "$DOTFILES_DIR/claude/hooks/"*.sh; do
  [ -f "$hook" ] && link_file "$hook" "$HOME_DIR/.claude/hooks/$(basename "$hook")"
done
# chmod the source files (symlinks inherit target permissions)
chmod +x "$DOTFILES_DIR/claude/hooks/"*.sh 2>/dev/null || true
echo "  -> Claude hooks linked"

# Skills (slash commands) — directory-based format
for skill_dir in "$DOTFILES_DIR/claude/skills/"*/; do
  [ -d "$skill_dir" ] || continue
  skill_name=$(basename "$skill_dir")
  mkdir -p "$HOME_DIR/.claude/skills/$skill_name"
  for skill_file in "$skill_dir"*; do
    [ -f "$skill_file" ] && link_file "$skill_file" "$HOME_DIR/.claude/skills/$skill_name/$(basename "$skill_file")"
  done
done
# Legacy flat skill files (if any remain)
for skill in "$DOTFILES_DIR/claude/skills/"*.md; do
  [ -f "$skill" ] && link_file "$skill" "$HOME_DIR/.claude/skills/$(basename "$skill")"
done
echo "  -> Claude skills linked"

# Agents (custom subagents)
for agent in "$DOTFILES_DIR/claude/agents/"*.md; do
  [ -f "$agent" ] && link_file "$agent" "$HOME_DIR/.claude/agents/$(basename "$agent")"
done
echo "  -> Claude agents linked"

# ─── 6. GitHub CLI auth ──────────────────────────────────────────────
if ! gh auth status &>/dev/null; then
  echo ""
  echo "--- GitHub CLI not authenticated ---"
  echo "Run: gh auth login"
  echo "(Choose HTTPS and browser-based login)"
else
  echo "GitHub CLI already authenticated"
fi

# ─── 7. Shell aliases ─────────────────────────────────────────────────
if [ -f "$DOTFILES_DIR/.bash_aliases" ]; then
  echo ""
  echo "--- Setting up shell aliases ---"
  link_file "$DOTFILES_DIR/.bash_aliases" "$HOME_DIR/.bash_aliases"
  echo "  -> .bash_aliases linked"
  # Ensure .bashrc sources .bash_aliases (Ubuntu default usually does)
  if [ -f "$HOME_DIR/.bashrc" ] && ! grep -q '\.bash_aliases' "$HOME_DIR/.bashrc"; then
    echo '' >> "$HOME_DIR/.bashrc"
    echo '# Load custom aliases' >> "$HOME_DIR/.bashrc"
    echo '[ -f ~/.bash_aliases ] && . ~/.bash_aliases' >> "$HOME_DIR/.bashrc"
    echo "  -> Added .bash_aliases sourcing to .bashrc"
  fi
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "All config files are symlinked — edits in ~/.claude/"
echo "will automatically be reflected in your dotfiles repo."
echo ""
echo "Manual steps remaining:"
echo "  1. Run 'gh auth login' if not already authenticated"
echo "  2. Add any project repos to git safe.directory as needed:"
echo "     git config --global --add safe.directory /mnt/c/Users/jckee/dev/<repo>"
