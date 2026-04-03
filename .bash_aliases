# Claude Code scripts on PATH
export PATH="$HOME/.claude/scripts:$PATH"

# Claude Code aliases
alias claude-server='claude remote-control --spawn worktree'
alias claude-rc='claude --remote-control'

# Detect dev directory — reads from ~/.claude/dev-dir (written by setup.sh)
_dev_dir() {
  if [ -f "$HOME/.claude/dev-dir" ]; then
    cat "$HOME/.claude/dev-dir"
  else
    echo "$HOME/dev"
  fi
}

# Pull latest for all git repos under dev directory
pull-all() {
  local dev_dir
  dev_dir="$(_dev_dir)"
  if [ ! -d "$dev_dir" ]; then
    echo "Dev directory not found: $dev_dir"
    return 1
  fi
  for repo in "$dev_dir"/*/; do
    if [ -d "$repo/.git" ]; then
      local name=$(basename "$repo")
      if git -C "$repo" remote -v 2>/dev/null | grep -q .; then
        printf "  %-20s" "$name"
        git -C "$repo" pull --ff-only 2>&1 | tail -1
      fi
    fi
  done
}

# Check Claude config symlinks are healthy
check-claude() {
  "$(_dev_dir)/dotfiles/check-claude.sh" "$@"
}

# Commit and push any pending memory changes from last session
sync-memory() {
  local dev_dir
  dev_dir="$(_dev_dir)"
  local mem_repo="$dev_dir/claude-memory"
  if [ -d "$mem_repo/.git" ]; then
    if [ -n "$(git -C "$mem_repo" status --porcelain 2>/dev/null)" ]; then
      echo "  Saving memory..."
      git -C "$mem_repo" add -A
      git -C "$mem_repo" commit -q -m "auto: sync memory $(date +%Y-%m-%d)"
      git -C "$mem_repo" push -q 2>/dev/null && echo "  Memory saved." || echo "  Memory committed locally (push failed)."
    fi
  fi
}

# Launch Claude, syncing everything first
# Usage: cc          — launch from current dir (defaults to ~/dev if outside a git repo)
#        cc <project> — cd into ~/dev/<project> first, then launch
cc() {
  local dev_dir
  dev_dir="$(_dev_dir)"

  # If a project name was passed, cd into it
  if [ -n "$1" ] && [ -d "$dev_dir/$1" ]; then
    cd "$dev_dir/$1"
  elif ! git rev-parse --is-inside-work-tree &>/dev/null; then
    # Not in a git repo — default to dev directory
    cd "$dev_dir"
  fi

  echo "Syncing repos..."
  pull-all
  echo ""
  sync-memory
  "$(_dev_dir)/dotfiles/check-claude.sh"
  echo ""

  # Preload architecture diagrams if the project has them
  local diagram_args=()
  if [ -d ".ai/diagrams" ] && ls .ai/diagrams/*.md &>/dev/null; then
    local diagrams=""
    for f in .ai/diagrams/*.md; do
      diagrams+="$(cat "$f")"$'\n'
    done
    diagram_args=(--append-system-prompt "$diagrams")
  fi

  # Set terminal tab color from .claude-color if present
  if [ -f ".claude-color" ]; then
    local hex
    hex=$(head -1 .claude-color | tr -d '[:space:]#')
    if [[ "$hex" =~ ^[0-9a-fA-F]{6}$ ]]; then
      local r=$((16#${hex:0:2})) g=$((16#${hex:2:2})) b=$((16#${hex:4:2}))
      # Windows Terminal tab color (OSC 9;9)
      printf '\033]9;9;rgb(%d,%d,%d)\033\\' "$r" "$g" "$b"
    fi
  fi

  claude --remote-control --chrome "${diagram_args[@]}" "$@"

  # Reset tab color on exit
  printf '\033]9;9;\033\\' 2>/dev/null
}

# Update dotfiles: pull latest and re-run setup
dotfiles-update() {
  local dotfiles_dir
  dotfiles_dir="$(_dev_dir)/dotfiles"
  if [ ! -d "$dotfiles_dir/.git" ]; then
    echo "Dotfiles repo not found at $dotfiles_dir"
    return 1
  fi
  echo "Pulling latest dotfiles..."
  git -C "$dotfiles_dir" pull --ff-only || { echo "Pull failed — resolve manually."; return 1; }
  echo "Re-running setup..."
  bash "$dotfiles_dir/setup.sh"
}

# ─── Git worktree shortcuts (Boris's #1 productivity tip) ────────────
# Quick jump to worktrees: za, zb, zc, zd, ze
# Create them with: git worktree add ../project-a -b feature-a
alias za='cd ../$(basename "$PWD")-a 2>/dev/null || echo "Worktree -a not found. Create with: git worktree add ../$(basename "$PWD")-a -b branch-name"'
alias zb='cd ../$(basename "$PWD")-b 2>/dev/null || echo "Worktree -b not found. Create with: git worktree add ../$(basename "$PWD")-b -b branch-name"'
alias zc='cd ../$(basename "$PWD")-c 2>/dev/null || echo "Worktree -c not found. Create with: git worktree add ../$(basename "$PWD")-c -b branch-name"'
alias zd='cd ../$(basename "$PWD")-d 2>/dev/null || echo "Worktree -d not found. Create with: git worktree add ../$(basename "$PWD")-d -b branch-name"'
alias ze='cd ../$(basename "$PWD")-e 2>/dev/null || echo "Worktree -e not found. Create with: git worktree add ../$(basename "$PWD")-e -b branch-name"'
alias z0='cd "$(git rev-parse --show-toplevel 2>/dev/null)" || echo "Not in a git repo"'

# Worktree management
alias gwl='git worktree list'
alias gwa='git worktree add'
alias gwr='git worktree remove'

# Quick Claude in a new worktree
wt-claude() {
  local name="${1:?Usage: wt-claude <name> [branch]}"
  local branch="${2:-$name}"
  local base
  base="$(git rev-parse --show-toplevel)"
  local wt_path="${base}-${name}"
  if [ ! -d "$wt_path" ]; then
    git worktree add "$wt_path" -b "$branch" 2>/dev/null || git worktree add "$wt_path" "$branch"
  fi
  echo "Starting Claude in worktree: $wt_path"
  (cd "$wt_path" && claude)
}

# WSL: open URLs in Windows Chrome
export BROWSER="/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"
# WSL: force-enable Claude in Chrome
export CLAUDE_CODE_ENABLE_CFC=1
