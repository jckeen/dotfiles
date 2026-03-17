#!/bin/bash
# Bootstrap a dev environment with Claude Code config and tools.
# Works on macOS, WSL (Ubuntu), and native Linux.
# Run from the dotfiles repo root: ./setup.sh
#
# Uses symlinks so edits to ~/.claude/* automatically stay in sync
# with this repo.

set -e

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"

# ─── Platform detection ──────────────────────────────────────────────
detect_platform() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    PLATFORM="macos"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    PLATFORM="wsl"
  else
    PLATFORM="linux"
  fi
  echo "Detected platform: $PLATFORM"
}

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

detect_platform

echo "=== Dotfiles setup from $DOTFILES_DIR ==="

# ─── 1. System packages ───────────────────────────────────────────────
echo ""
echo "--- Installing system packages ---"
if [[ "$PLATFORM" == "macos" ]]; then
  if ! command -v brew &>/dev/null; then
    echo "Homebrew not found. Install it first:"
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
  fi
  brew install gh git curl jq || true
else
  sudo apt update && sudo apt install -y \
    gh \
    git \
    curl \
    unzip \
    jq
fi

# ─── 1b. Audio (WSL only — ALSA → PulseAudio for WSLg) ──────────────
if [[ "$PLATFORM" == "wsl" ]]; then
  echo ""
  echo "--- Setting up ALSA → PulseAudio routing (WSL) ---"
  sudo apt install -y pulseaudio-utils libasound2-plugins alsa-utils
  link_file "$DOTFILES_DIR/.asoundrc" "$HOME_DIR/.asoundrc"
  sudo cp "$DOTFILES_DIR/.asoundrc" /etc/asound.conf
  echo "  -> .asoundrc linked, /etc/asound.conf written"
fi

# ─── 2. Node.js (if not present) ─────────────────────────────────────
if ! command -v node &>/dev/null; then
  echo ""
  echo "--- Installing Node.js ---"
  if [[ "$PLATFORM" == "macos" ]]; then
    brew install node
  else
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt install -y nodejs
  fi
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

# Generate a platform-appropriate .gitconfig.local
if [[ "$PLATFORM" == "macos" ]]; then
  cat > "$DOTFILES_DIR/.gitconfig.local" <<'GITCONF'
[core]
	editor = code --wait
[credential]
	helper = osxkeychain
GITCONF
elif [[ "$PLATFORM" == "wsl" ]]; then
  cat > "$DOTFILES_DIR/.gitconfig.local" <<'GITCONF'
[core]
	editor = "C:\\Users\\jckee\\AppData\\Local\\Programs\\Microsoft VS Code\\bin\\code" --wait
[credential]
	helper = /mnt/c/Program\\ Files/Git/mingw64/bin/git-credential-manager.exe
GITCONF
else
  cat > "$DOTFILES_DIR/.gitconfig.local" <<'GITCONF'
[core]
	editor = code --wait
[credential]
	helper = store
GITCONF
fi

link_file "$DOTFILES_DIR/.gitconfig" "$HOME_DIR/.gitconfig"
link_file "$DOTFILES_DIR/.gitconfig.local" "$HOME_DIR/.gitconfig.local"

# WSL-specific: mark /mnt/c/ repos as safe
if [[ "$PLATFORM" == "wsl" ]]; then
  git config --global --add safe.directory /mnt/c/Users/jckee/dev/dotfiles
fi

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
if [ -d "$DOTFILES_DIR/claude/hooks" ]; then
  mkdir -p "$HOME_DIR/.claude/hooks"
  for hook in "$DOTFILES_DIR/claude/hooks/"*.sh; do
    [ -f "$hook" ] || continue
    link_file "$hook" "$HOME_DIR/.claude/hooks/$(basename "$hook")"
  done
  # chmod source files (symlinks inherit target permissions)
  chmod +x "$DOTFILES_DIR/claude/hooks/"*.sh 2>/dev/null || true
  echo "  -> Claude hooks linked"
fi

# Skills (slash commands) — directory-based format
for skill_dir in "$DOTFILES_DIR/claude/skills/"*/; do
  [ -d "$skill_dir" ] || continue
  skill_name="$(basename "$skill_dir")"
  mkdir -p "$HOME_DIR/.claude/skills/$skill_name"
  for skill_file in "$skill_dir"*; do
    [ -f "$skill_file" ] && link_file "$skill_file" "$HOME_DIR/.claude/skills/$skill_name/$(basename "$skill_file")"
  done
done
echo "  -> Claude skills linked"

# Agents (custom subagents)
if [ -d "$DOTFILES_DIR/claude/agents" ]; then
  for agent in "$DOTFILES_DIR/claude/agents/"*.md; do
    [ -f "$agent" ] && link_file "$agent" "$HOME_DIR/.claude/agents/$(basename "$agent")"
  done
  echo "  -> Claude agents linked"
fi

# ─── 6. GitHub CLI auth ──────────────────────────────────────────────
if ! gh auth status &>/dev/null; then
  echo ""
  echo "--- GitHub CLI not authenticated ---"
  echo "Run: gh auth login"
  echo "(Choose HTTPS and browser-based login)"
else
  echo "GitHub CLI already authenticated"
fi

# ─── 7. Shell config ─────────────────────────────────────────────────
echo ""
echo "--- Setting up shell config ---"

if [[ "$PLATFORM" == "macos" ]]; then
  # macOS uses zsh by default
  SHELL_RC="$HOME_DIR/.zshrc"
  link_file "$DOTFILES_DIR/.bash_aliases" "$HOME_DIR/.bash_aliases"
  if [ -f "$SHELL_RC" ] && ! grep -q '\.bash_aliases' "$SHELL_RC"; then
    echo '' >> "$SHELL_RC"
    echo '# Load aliases (shared with bash)' >> "$SHELL_RC"
    echo '[ -f ~/.bash_aliases ] && . ~/.bash_aliases' >> "$SHELL_RC"
    echo "  -> Added .bash_aliases sourcing to .zshrc"
  elif [ ! -f "$SHELL_RC" ]; then
    echo '# Load aliases (shared with bash)' > "$SHELL_RC"
    echo '[ -f ~/.bash_aliases ] && . ~/.bash_aliases' >> "$SHELL_RC"
    echo "  -> Created .zshrc with .bash_aliases sourcing"
  fi
  echo "  -> .bash_aliases linked (sourced from .zshrc)"
else
  link_file "$DOTFILES_DIR/.bash_aliases" "$HOME_DIR/.bash_aliases"
  if [ -f "$HOME_DIR/.bashrc" ] && ! grep -q '\.bash_aliases' "$HOME_DIR/.bashrc"; then
    echo '' >> "$HOME_DIR/.bashrc"
    echo '# Load custom aliases' >> "$HOME_DIR/.bashrc"
    echo '[ -f ~/.bash_aliases ] && . ~/.bash_aliases' >> "$HOME_DIR/.bashrc"
    echo "  -> Added .bash_aliases sourcing to .bashrc"
  fi
  echo "  -> .bash_aliases linked"
fi

echo ""
echo "=== Setup complete ($PLATFORM) ==="
echo ""
echo "All config files are symlinked — edits in ~/.claude/"
echo "will automatically be reflected in your dotfiles repo."
echo ""
echo "Manual steps remaining:"
echo "  1. Run 'gh auth login' if not already authenticated"
echo "  2. Run 'claude' and follow the login prompt"
if [[ "$PLATFORM" == "wsl" ]]; then
  echo "  3. Add project repos to git safe.directory as needed:"
  echo "     git config --global --add safe.directory /mnt/c/Users/jckee/dev/<repo>"
fi
