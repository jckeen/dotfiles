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
BOOTSTRAP_SCRIPT="$HOME/dev/claude-memory/bootstrap.sh"

# Counters for summary
LINKS_CREATED=0
LINKS_VERIFIED=0
LINKS_BROKEN=0

# ─── Symlink health audit (--check / --repair) ──────────────────────
# Checks ALL symlinks: dotfiles AND claude-memory (bootstrap.sh)
run_health_audit() {
  local mode="$1"  # "check" or "repair"
  local errors=0
  local verified=0
  local repaired=0

  echo "=== Symlink Health Audit (mode: $mode) ==="
  echo ""

  # ── Dotfiles symlinks ──
  echo "--- Dotfiles symlinks ---"
  local CLAUDE_SRC="$DOTFILES_DIR/claude"
  local CLAUDE_DST="$HOME_DIR/.claude"
  local NOLINK="AgentPack.md CLAUDE.md settings.json"

  # Top-level files
  for f in "$CLAUDE_SRC/"*; do
    [ -f "$f" ] || continue
    local name
    name="$(basename "$f")"
    case " $NOLINK " in *" $name "*) continue ;; esac
    audit_link "$f" "$CLAUDE_DST/$name" "$name" "$mode" && verified=$((verified + 1)) || errors=$((errors + 1))
  done

  # Hooks
  for f in "$CLAUDE_SRC/hooks/"*.sh "$CLAUDE_SRC/hooks/"*.ts; do
    [ -f "$f" ] || continue
    local name
    name="$(basename "$f")"
    audit_link "$f" "$CLAUDE_DST/hooks/$name" "hooks/$name" "$mode" && verified=$((verified + 1)) || errors=$((errors + 1))
  done

  # Skills
  for skill_dir in "$CLAUDE_SRC/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    local skill_name
    skill_name="$(basename "$skill_dir")"
    for skill_file in "$skill_dir"*; do
      [ -f "$skill_file" ] || continue
      local fname
      fname="$(basename "$skill_file")"
      audit_link "$skill_file" "$CLAUDE_DST/skills/$skill_name/$fname" "skills/$skill_name/$fname" "$mode" && verified=$((verified + 1)) || errors=$((errors + 1))
    done
  done

  # Agents
  for f in "$CLAUDE_SRC/agents/"*.md; do
    [ -f "$f" ] || continue
    local name
    name="$(basename "$f")"
    audit_link "$f" "$CLAUDE_DST/agents/$name" "agents/$name" "$mode" && verified=$((verified + 1)) || errors=$((errors + 1))
  done

  # Scripts
  if [ -d "$CLAUDE_SRC/scripts" ]; then
    for f in "$CLAUDE_SRC/scripts/"*.sh; do
      [ -f "$f" ] || continue
      local name
      name="$(basename "$f")"
      audit_link "$f" "$CLAUDE_DST/scripts/$name" "scripts/$name" "$mode" && verified=$((verified + 1)) || errors=$((errors + 1))
    done
  fi

  # Chrome
  if [ -d "$CLAUDE_SRC/chrome" ]; then
    for f in "$CLAUDE_SRC/chrome/"*; do
      [ -f "$f" ] || continue
      local name
      name="$(basename "$f")"
      audit_link "$f" "$CLAUDE_DST/chrome/$name" "chrome/$name" "$mode" && verified=$((verified + 1)) || errors=$((errors + 1))
    done
  fi

  echo ""

  # ── Claude-memory symlinks (via bootstrap.sh --check) ──
  echo "--- Claude-memory symlinks ---"
  if [ -f "$BOOTSTRAP_SCRIPT" ]; then
    if bash "$BOOTSTRAP_SCRIPT" --check; then
      echo "  All claude-memory symlinks OK"
    else
      errors=$((errors + 1))
      if [ "$mode" = "repair" ]; then
        echo "  Repairing claude-memory symlinks..."
        bash "$BOOTSTRAP_SCRIPT" && echo "  Repaired." || echo "  Repair failed."
      fi
    fi
  else
    echo "  (bootstrap.sh not found at $BOOTSTRAP_SCRIPT — skipping claude-memory checks)"
  fi

  echo ""
  echo "=== Audit Summary ==="
  echo "  Verified: $verified"
  echo "  Broken:   $errors"
  if [ "$mode" = "repair" ] && [ "$errors" -gt 0 ]; then
    echo "  (Attempted repairs on broken links)"
  fi

  [ "$errors" -eq 0 ] && return 0 || return 1
}

# Check a single symlink. Returns 0 if OK, 1 if broken.
# In repair mode, recreates broken links.
audit_link() {
  local src="$1" dst="$2" label="$3" mode="$4"
  if [ -L "$dst" ]; then
    local target
    target="$(readlink "$dst")"
    if [ "$target" = "$src" ] && [ -e "$dst" ]; then
      return 0  # OK
    fi
    # Wrong target or broken
    printf '  \033[31mBROKEN\033[0m  %s -> %s (expected %s)\n' "$label" "$target" "$src"
    if [ "$mode" = "repair" ]; then
      rm "$dst"
      mkdir -p "$(dirname "$dst")"
      ln -s "$src" "$dst"
      printf '  \033[32mFIXED\033[0m   %s\n' "$label"
    fi
    return 1
  elif [ -f "$dst" ]; then
    printf '  \033[33mNOT LINKED\033[0m  %s (regular file, not symlink)\n' "$label"
    if [ "$mode" = "repair" ]; then
      mv "$dst" "$dst.backup"
      mkdir -p "$(dirname "$dst")"
      ln -s "$src" "$dst"
      printf '  \033[32mFIXED\033[0m   %s (old file backed up to %s.backup)\n' "$label" "$label"
    fi
    return 1
  elif [ ! -e "$dst" ]; then
    printf '  \033[33mMISSING\033[0m  %s\n' "$label"
    if [ "$mode" = "repair" ]; then
      mkdir -p "$(dirname "$dst")"
      ln -s "$src" "$dst"
      printf '  \033[32mFIXED\033[0m   %s\n' "$label"
    fi
    return 1
  fi
  return 0
}

# Handle --check and --repair flags
case "${1:-}" in
  --check)
    run_health_audit "check"
    exit $?
    ;;
  --repair)
    run_health_audit "repair"
    exit $?
    ;;
esac

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
MISSING_PKGS=""
for cmd in gh git curl jq; do
  command -v "$cmd" &>/dev/null || MISSING_PKGS="$MISSING_PKGS $cmd"
done

if [ -n "$MISSING_PKGS" ]; then
  echo "Missing packages:$MISSING_PKGS"
  if [[ "$PLATFORM" == "macos" ]]; then
    if ! command -v brew &>/dev/null; then
      echo "Homebrew not found. Install it first:"
      echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
      exit 1
    fi
    read -rp "Install via brew? [Y/n] " yn
    [[ "$yn" =~ ^[Nn] ]] && { echo "Skipping. Install manually and re-run."; exit 1; }
    brew install $MISSING_PKGS || true
  else
    read -rp "Install via apt? (requires sudo) [Y/n] " yn
    [[ "$yn" =~ ^[Nn] ]] && { echo "Skipping. Install manually and re-run."; exit 1; }
    sudo apt update && sudo apt install -y $MISSING_PKGS unzip
  fi
else
  echo "All required packages already installed."
fi

# ─── 1b. Audio (WSL only — ALSA → PulseAudio for WSLg) ──────────────
if [[ "$PLATFORM" == "wsl" ]]; then
  echo ""
  echo "--- ALSA → PulseAudio routing (WSL, needed for /voice) ---"
  read -rp "Set up audio routing for Claude /voice? (requires sudo) [y/N] " yn
  if [[ "$yn" =~ ^[Yy] ]]; then
    sudo apt install -y pulseaudio-utils libasound2-plugins alsa-utils
    link_file "$DOTFILES_DIR/.asoundrc" "$HOME_DIR/.asoundrc"
    sudo cp "$DOTFILES_DIR/.asoundrc" /etc/asound.conf
    echo "  -> .asoundrc linked, /etc/asound.conf written"
  else
    echo "  -> Skipped audio setup"
  fi
fi

# ─── 2. Node.js (if not present) ─────────────────────────────────────
if ! command -v node &>/dev/null; then
  echo ""
  echo "--- Installing Node.js ---"
  if [[ "$PLATFORM" == "macos" ]]; then
    brew install node
  else
    echo "  Node.js not found. Install via your preferred method:"
    echo "    Option 1: curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -"
    echo "    Option 2: sudo apt install -y nodejs npm"
    echo "    Option 3: Install nvm: https://github.com/nvm-sh/nvm"
    echo ""
    echo "  Then re-run setup.sh."
    exit 1
  fi
else
  echo "Node.js already installed: $(node -v)"
fi

# ─── 2b. Bun (required by *.hook.ts files — #!/usr/bin/env bun) ───────
# StripProjectPermissions.hook.ts and any future TypeScript hooks run via
# bun at SessionStart. Missing bun = `cc` fails on first launch with a
# confusing "bun: not found" error.
#
# The systemd voice-server unit hardcodes %h/.bun/bin/bun (systemd can't
# do PATH lookups), so we always ensure a symlink at ~/.bun/bin/bun
# pointing at whichever bun is on PATH — regardless of install method
# (brew, npm, curl installer).
if ! command -v bun &>/dev/null && [ ! -x "$HOME/.bun/bin/bun" ]; then
  echo ""
  echo "--- Installing Bun (JS runtime for TypeScript hooks) ---"
  if [[ "$PLATFORM" == "macos" ]] && command -v brew &>/dev/null; then
    brew install oven-sh/bun/bun
  else
    # Official installer; writes to ~/.bun and appends PATH lines to
    # ~/.bashrc and ~/.zshrc automatically.
    curl -fsSL https://bun.sh/install | bash
  fi
  # Make bun usable for the remainder of this script
  if [ -x "$HOME/.bun/bin/bun" ]; then
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
  fi
  echo "  -> Bun installed: $(bun --version 2>/dev/null || echo 'see installer output')"
else
  # Ensure current shell can find bun if only ~/.bun/bin exists on disk
  if ! command -v bun &>/dev/null && [ -x "$HOME/.bun/bin/bun" ]; then
    export PATH="$HOME/.bun/bin:$PATH"
  fi
  echo "Bun already installed: $(bun --version 2>/dev/null || echo 'installed')"
fi

# Canonicalize bun at ~/.bun/bin/bun — the systemd unit and other scripts
# hardcode this path. If bun ended up somewhere else (brew, npm), drop a
# symlink so hardcoded paths keep working.
if command -v bun &>/dev/null && [ ! -e "$HOME/.bun/bin/bun" ]; then
  _bun_found="$(command -v bun)"
  mkdir -p "$HOME/.bun/bin"
  ln -sf "$_bun_found" "$HOME/.bun/bin/bun"
  echo "  -> bun symlinked: ~/.bun/bin/bun -> $_bun_found"
fi

# ─── 3. Claude Code CLI ──────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  echo ""
  echo "--- Installing Claude Code CLI ---"
  npm install -g @anthropic-ai/claude-code
else
  echo "Claude Code already installed: $(claude --version 2>/dev/null || echo 'installed')"
fi

# ─── 3a. Claude Code authentication ──────────────────────────────────
# Plugin install and `cc` itself need an authenticated session. Detect
# unauth state via `claude auth status` (exit 0 + "loggedIn": true) and
# offer to run `claude auth login` (browser OAuth) right now.
CLAUDE_AUTHED=0
if command -v claude &>/dev/null; then
  echo ""
  echo "--- Checking Claude Code authentication ---"
  if claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
    echo "  -> Already signed in to Claude"
    CLAUDE_AUTHED=1
  else
    echo "  Claude Code is not authenticated."
    echo "  Plugin install and 'cc' both require a signed-in session."
    read -rp "Run 'claude auth login' now (opens browser)? [Y/n] " yn
    if [[ ! "$yn" =~ ^[Nn] ]]; then
      claude auth login || true
      if claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
        CLAUDE_AUTHED=1
      fi
    fi
    if [ "$CLAUDE_AUTHED" -eq 0 ]; then
      echo ""
      echo "  Skipping plugin install. After login, re-run: $0"
    fi
  fi
fi

# ─── 3b. Claude Code plugins ─────────────────────────────────────────
# Installs plugins listed in claude/plugins.txt (format: plugin@marketplace).
# Idempotent: marketplace registration and each plugin install are skipped
# when already present. Requires Claude authentication (§3a).
PLUGIN_LIST="$DOTFILES_DIR/claude/plugins.txt"
if [ -f "$PLUGIN_LIST" ] && command -v claude &>/dev/null && [ "$CLAUDE_AUTHED" -eq 1 ]; then
  echo ""
  echo "--- Installing Claude Code plugins ---"

  # Collect marketplaces referenced by the plugin list
  MARKETPLACES="$(awk -F'@' '/^[^#[:space:]]/ && NF==2 {print $2}' "$PLUGIN_LIST" | sort -u)"

  # Register each marketplace if not already known
  MARKETPLACE_LIST="$(claude plugin marketplace list 2>/dev/null || true)"
  for mp in $MARKETPLACES; do
    # Match header lines like "  ❯ <marketplace-name>" (anchor on word boundaries)
    if echo "$MARKETPLACE_LIST" | grep -Eq "❯[[:space:]]+${mp}([[:space:]]|$)"; then
      echo "  -> Marketplace $mp already registered"
    else
      case "$mp" in
        claude-plugins-official)
          claude plugin marketplace add github:anthropics/claude-plugins-official \
            && echo "  -> Registered marketplace: $mp" \
            || echo "  -> Failed to register marketplace: $mp (continuing)"
          ;;
        anthropic-agent-skills)
          claude plugin marketplace add github:anthropics/skills \
            && echo "  -> Registered marketplace: $mp" \
            || echo "  -> Failed to register marketplace: $mp (continuing)"
          ;;
        *)
          echo "  -> Unknown marketplace $mp — add registration logic to setup.sh or register manually"
          ;;
      esac
    fi
  done

  # Cache installed plugin list once to avoid spawning claude per-plugin
  INSTALLED_PLUGINS="$(claude plugin list 2>/dev/null || true)"

  # Install each plugin if not already installed
  while IFS= read -r line; do
    # Strip comments/whitespace
    plugin="${line%%#*}"
    plugin="$(echo "$plugin" | tr -d '[:space:]')"
    [ -z "$plugin" ] && continue

    # Match "❯ <plugin>@<marketplace>" exactly at a word boundary so e.g.
    # "code-review@x" cannot false-match "code-review-2@x".
    if echo "$INSTALLED_PLUGINS" | grep -qE "❯[[:space:]]+${plugin}([[:space:]]|$)"; then
      echo "  -> $plugin already installed"
    else
      echo "  -> Installing $plugin"
      claude plugin install "$plugin" || echo "     (install failed — continuing)"
    fi
  done < "$PLUGIN_LIST"
fi

# ─── 4. Git config ───────────────────────────────────────────────────
echo ""
echo "--- Setting up Git config ---"

# Prompt for git identity (written to .gitconfig.local, not committed)
GIT_NAME="${GIT_NAME:-}"
GIT_EMAIL="${GIT_EMAIL:-}"
if git config user.name &>/dev/null; then
  GIT_NAME="$(git config user.name)"
  GIT_EMAIL="$(git config user.email)"
  echo "  Using existing git identity: $GIT_NAME <$GIT_EMAIL>"
else
  read -rp "Git user name: " GIT_NAME
  read -rp "Git email: " GIT_EMAIL
fi

# Generate a platform-appropriate .gitconfig.local (identity + platform config)
if [[ "$PLATFORM" == "macos" ]]; then
  cat > "$DOTFILES_DIR/.gitconfig.local" <<GITCONF
[user]
	name = ${GIT_NAME}
	email = ${GIT_EMAIL}
[core]
	editor = code --wait
[credential]
	helper = osxkeychain
GITCONF
elif [[ "$PLATFORM" == "wsl" ]]; then
  WIN_USER=$(/mnt/c/Windows/System32/cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')
  cat > "$DOTFILES_DIR/.gitconfig.local" <<GITCONF
[user]
	name = ${GIT_NAME}
	email = ${GIT_EMAIL}
[core]
	editor = "C:\\\\Users\\\\${WIN_USER}\\\\AppData\\\\Local\\\\Programs\\\\Microsoft VS Code\\\\bin\\\\code" --wait
[credential]
	helper = /mnt/c/Program\\\\ Files/Git/mingw64/bin/git-credential-manager.exe
GITCONF
else
  cat > "$DOTFILES_DIR/.gitconfig.local" <<GITCONF
[user]
	name = ${GIT_NAME}
	email = ${GIT_EMAIL}
[core]
	editor = code --wait
[credential]
	helper = store
GITCONF
fi

link_file "$DOTFILES_DIR/.gitconfig" "$HOME_DIR/.gitconfig"
link_file "$DOTFILES_DIR/.gitconfig.local" "$HOME_DIR/.gitconfig.local"

# WSL-specific: mark dev repos as safe
if [[ "$PLATFORM" == "wsl" ]]; then
  git config --global --add safe.directory "$DOTFILES_DIR"
  git config --global --add safe.directory "$DEV_DIR/claude-memory"
fi

echo "  -> .gitconfig linked"

# ─── 5. Claude Code config ───────────────────────────────────────────
echo ""
echo "--- Setting up Claude Code config ---"
mkdir -p "$HOME_DIR/.claude/skills"
mkdir -p "$HOME_DIR/.claude/agents"

# Files to keep in dotfiles but NOT symlink into ~/.claude/
# PAI config (CLAUDE.md, settings.json) lives in claude-memory (private)
# AgentPack.md is loaded on-demand by CLAUDE.md references
NOLINK="AgentPack.md CLAUDE.md settings.json"

# Link top-level files (auto-discovers, no hardcoded list)
for f in "$DOTFILES_DIR/claude/"*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  case " $NOLINK " in *" $name "*) continue ;; esac
  link_file "$f" "$HOME_DIR/.claude/$name"
done
chmod +x "$DOTFILES_DIR/claude/statusline.sh" 2>/dev/null || true
echo "  -> Claude config linked"

# Hooks
if [ -d "$DOTFILES_DIR/claude/hooks" ]; then
  mkdir -p "$HOME_DIR/.claude/hooks"
  for hook in "$DOTFILES_DIR/claude/hooks/"*.sh "$DOTFILES_DIR/claude/hooks/"*.ts; do
    [ -f "$hook" ] || continue
    link_file "$hook" "$HOME_DIR/.claude/hooks/$(basename "$hook")"
  done
  # chmod source files (symlinks inherit target permissions)
  chmod +x "$DOTFILES_DIR/claude/hooks/"*.sh "$DOTFILES_DIR/claude/hooks/"*.ts 2>/dev/null || true
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

# Scripts (headless automation)
if [ -d "$DOTFILES_DIR/claude/scripts" ]; then
  mkdir -p "$HOME_DIR/.claude/scripts"
  for script in "$DOTFILES_DIR/claude/scripts/"*.sh; do
    [ -f "$script" ] || continue
    link_file "$script" "$HOME_DIR/.claude/scripts/$(basename "$script")"
  done
  chmod +x "$DOTFILES_DIR/claude/scripts/"*.sh 2>/dev/null || true
  echo "  -> Claude scripts linked"
fi

# PAI config from claude-memory (private repo)
_mem_repo="$(dirname "$DOTFILES_DIR")/claude-memory"

# Core PAI config (CLAUDE.md, settings.json)
if [ -d "$_mem_repo/pai-config" ]; then
  for f in "$_mem_repo/pai-config/"*; do
    [ -f "$f" ] || continue
    cp "$f" "$HOME_DIR/.claude/$(basename "$f")"
  done
  echo "  -> PAI config copied (CLAUDE.md, settings.json from claude-memory)"
fi

# PAI USER config (identity, steering rules, DA personality)
if [ -d "$_mem_repo/pai-user" ]; then
  mkdir -p "$HOME_DIR/.claude/PAI/USER"
  for f in "$_mem_repo/pai-user/"*.md; do
    [ -f "$f" ] || continue
    cp "$f" "$HOME_DIR/.claude/PAI/USER/$(basename "$f")"
  done
  echo "  -> PAI USER config copied (from claude-memory)"
fi

# Chrome (WSL bridge setup script)
if [ -d "$DOTFILES_DIR/claude/chrome" ]; then
  mkdir -p "$HOME_DIR/.claude/chrome"
  for f in "$DOTFILES_DIR/claude/chrome/"*; do
    [ -f "$f" ] && link_file "$f" "$HOME_DIR/.claude/chrome/$(basename "$f")"
  done
  chmod +x "$DOTFILES_DIR/claude/chrome/"*.sh 2>/dev/null || true
  echo "  -> Claude chrome scripts linked"
fi

# Dev dir: derived from dotfiles repo location (parent of this repo)
# Written to ~/.claude/dev-dir so all scripts have a single source of truth
DEV_DIR="$(dirname "$DOTFILES_DIR")"
echo "$DEV_DIR" > "$HOME_DIR/.claude/dev-dir"
echo "  -> dev-dir set to $DEV_DIR"

# Memory (optional private repo for persistent Claude memory)
MEMORY_REPO="$DEV_DIR/claude-memory"
MEMORY_SRC="$MEMORY_REPO/dev/memory"
# Claude scopes memory by working directory, encoding the path with dashes
MEMORY_PROJECT_DIR="$(echo "$DEV_DIR" | sed 's|^/||; s|/|-|g')"
MEMORY_DST="$HOME_DIR/.claude/projects/-${MEMORY_PROJECT_DIR}/memory"
if [ -d "$MEMORY_SRC" ]; then
  mkdir -p "$(dirname "$MEMORY_DST")"
  if [ -L "$MEMORY_DST" ]; then
    rm "$MEMORY_DST"
  elif [ -d "$MEMORY_DST" ]; then
    # Preserve any existing memory files before linking
    cp -n "$MEMORY_DST"/*.md "$MEMORY_SRC/" 2>/dev/null || true
    rm -r "$MEMORY_DST"
  fi
  ln -s "$MEMORY_SRC" "$MEMORY_DST"
  echo "  -> Claude memory linked (private repo)"
else
  echo "  -> Claude memory repo not found at $MEMORY_REPO"
  echo "     Create your own: gh repo create claude-memory --private --clone"
  echo "     Then mkdir -p claude-memory/dev/memory and re-run setup.sh"
fi

# ─── 6. GitHub CLI auth ──────────────────────────────────────────────
if ! gh auth status &>/dev/null; then
  echo ""
  echo "--- GitHub CLI not authenticated ---"
  echo "Run: gh auth login"
  echo "(Choose HTTPS and browser-based login)"
else
  echo "GitHub CLI already authenticated"
  # Wire gh as git's credential helper for github.com so `git pull` /
  # `git clone` in every repo (e.g., `pull-all` inside cc) uses the
  # existing gh token instead of prompting for username/password.
  #
  # We write directly to ~/.gitconfig.local instead of running
  # `gh auth setup-git`, because the latter edits ~/.gitconfig — which
  # is symlinked to this repo's tracked .gitconfig and would pollute
  # the shared dotfile with machine-specific helper paths.
  GH_BIN="$(command -v gh)"
  LOCAL_GITCONFIG="$HOME_DIR/.gitconfig.local"
  if [ -n "$GH_BIN" ] && ! git config --file "$LOCAL_GITCONFIG" --get-all credential.https://github.com.helper 2>/dev/null | grep -q "gh auth git-credential"; then
    echo "  -> Wiring gh as git credential helper (→ $LOCAL_GITCONFIG)..."
    for host in github.com gist.github.com; do
      git config --file "$LOCAL_GITCONFIG" --add "credential.https://${host}.helper" ""
      git config --file "$LOCAL_GITCONFIG" --add "credential.https://${host}.helper" "!${GH_BIN} auth git-credential"
    done
  else
    echo "  -> git credential helper already wired to gh"
  fi
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
  elif [ ! -f "$HOME_DIR/.bashrc" ]; then
    echo '# Load custom aliases' > "$HOME_DIR/.bashrc"
    echo '[ -f ~/.bash_aliases ] && . ~/.bash_aliases' >> "$HOME_DIR/.bashrc"
    echo "  -> Created .bashrc with .bash_aliases sourcing"
  fi
  echo "  -> .bash_aliases linked"

  # WSL: auto-cd into Linux-native dev directory for better I/O performance
  if [[ "$PLATFORM" == "wsl" ]]; then
    if grep -q 'cd /mnt/c/' "$HOME_DIR/.bashrc" 2>/dev/null; then
      # Replace any existing cd to Windows mount with Linux-native path
      sed -i "s|cd /mnt/c/.*|# Start in Linux-native dev directory for better WSL performance\ncd ~/dev|" "$HOME_DIR/.bashrc"
      echo "  -> Updated .bashrc: cd ~/dev (was pointing to /mnt/c/)"
    elif ! grep -q 'cd ~/dev' "$HOME_DIR/.bashrc" 2>/dev/null; then
      echo '' >> "$HOME_DIR/.bashrc"
      echo '# Start in Linux-native dev directory for better WSL performance' >> "$HOME_DIR/.bashrc"
      echo 'cd ~/dev' >> "$HOME_DIR/.bashrc"
      echo "  -> Added auto-cd to ~/dev in .bashrc"
    fi
  fi
fi

# ─── 8. Bootstrap claude-memory (private repo) ──────────────────────
if [ -f "$BOOTSTRAP_SCRIPT" ]; then
  echo ""
  echo "--- Running claude-memory bootstrap ---"
  bash "$BOOTSTRAP_SCRIPT" || echo "  (bootstrap.sh had errors — run it manually to debug)"
fi

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
echo "=== Setup complete ($PLATFORM) ==="
echo ""
echo "Running post-setup health audit..."
echo ""
run_health_audit "check" || true
echo ""
echo "All config files are symlinked — edits in ~/.claude/"
echo "will automatically be reflected in your dotfiles repo."
echo ""
echo "Manual steps remaining:"
echo "  1. Run 'gh auth login' if not already authenticated"
if [ "${CLAUDE_AUTHED:-0}" -eq 0 ]; then
  echo "  2. Run 'claude auth login' to sign in to Claude (required for cc + plugins)"
  echo "  3. Re-run this setup.sh to install plugins"
  echo "  4. Run 'cc' to pull repos and start Claude (or 'claude' to skip repo sync)"
else
  echo "  2. Run 'cc' to pull repos and start Claude (or 'claude' to skip repo sync)"
fi
if [[ "$PLATFORM" == "wsl" ]]; then
  echo ""
  echo "  WSL Chrome bridge:"
  echo "    Run 'bash ~/.claude/chrome/setup-wsl-chrome-bridge.sh' to enable claude --chrome"
  echo "    (bridges Windows Chrome to WSL2 Claude Code via native messaging)"
  echo ""
  echo "  WSL performance tip:"
  echo "    Keep your repos under ~/dev (Linux filesystem), NOT /mnt/c/ (Windows mount)."
  echo "    File I/O on the Linux filesystem is ~10x faster than the Windows mount."
  echo "    Your shell will auto-cd to ~/dev on startup."
  echo ""
  echo "  3. Add project repos to git safe.directory as needed:"
  echo "     git config --global --add safe.directory $DEV_DIR/<repo>"
fi
